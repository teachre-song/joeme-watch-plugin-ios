//
//  JoemeWatchModule.m
//  joeme-watch
//
//  JOEMEFIT 手表（维普沃 Veepoo BLE SDK）uni-app iOS 原生插件模块
//
//  iOS SDK 与 Android 的关键差异（封装时已抹平，JS 侧 utils/joeme-watch.js 无需改动）：
//   1. Android 是 VPOperateManager 单例管所有；iOS 是"三段式"：
//      VPBleCentralManage（扫描/连接/断开/密码）+ peripheralManage（业务）+ VPDataBaseOperation（取数）
//   2. 2.0 起拿到 sharedBleManager 后必须手动赋值 peripheralManage = VPPeripheralManage.shareVPPeripheralManager()
//   3. 密码验证在连接流程内自动完成（BleVerifyPasswordSuccess），不像 Android 是独立一步
//   4. 扫描无超时参数，需自己用定时器 stopScan
//   5. 连接传 VPPeripheralModel 对象（扫描时缓存），不是 mac 字符串
//   6. 同步个人信息传 birth（出生年份），不是 age；带睡眠目标要用模型版
//      VPSyncPersonalInfo（targetSleepDuration 单位分钟，身高字段名为 status）
//   7. 健康测量没有独立 stop 接口，统一是把对应 start 接口的参数传 NO（startMeasure/stopMeasure 已封装）
//   8. 血糖上报值是 100 倍、体温上报值是 ℃ 的 10 倍，模块内已换算成 mmol/L、℃ 再给 JS
//
//  方法签名已对照 VeepooBleSDK.framework/Headers 逐一核对。
//  JS 侧契约见 utils/joeme-watch.js，方法名与事件名均不可随意改动。
//

#import "JoemeWatchModule.h"
#import <VeepooBleSDK/VeepooBleSDK.h>
#import <math.h>
// dispatch_block_create/cancel（readActivityByDay 的可取消看门狗）需要显式引入
#import <dispatch/dispatch.h>
// 这三个模型在 VPPeripheralBaseManage.h 里只有 @class 前置声明，
// 直接用它们的属性必须单独引入头文件（umbrella header 没有 import）。
#import <VeepooBleSDK/VPBodyCompositionValueModel.h>
#import <VeepooBleSDK/VPGSRResultModel.h>
#import <VeepooBleSDK/VPECGTestDataModel.h>
// 精准睡眠模型不在 umbrella 里（VPDataBaseOperation 只 @class 前置声明）
#import <VeepooBleSDK/VPAccurateSleepModel.h>
// 血压私人模式模型：VPPeripheralBaseManage 里只 @class，umbrella 也没有
#import <VeepooBleSDK/VPDevicePrivateBloodModel.h>
// 4G 配置模型：umbrella 只带了 VP4GFunctionConst.h，模型头需要单独引
#import <VeepooBleSDK/VP4GFunctionConfigurationInfoModel.h>
// ===== 以下为全量桥接新增业务模型（直接使用其属性，umbrella 头文件不自动带）=====
#import <VeepooBleSDK/VPAutoMonitTestModel.h>
#import <VeepooBleSDK/VPOxygenApneaRemindModel.h>
#import <VeepooBleSDK/VPDeviceHealthRemindModel.h>
#import <VeepooBleSDK/VPDeviceAlarmModel.h>
#import <VeepooBleSDK/VPDeviceNewAlarmModel.h>
#import <VeepooBleSDK/VPDeviceTextAlarmModel.h>
#import <VeepooBleSDK/VPWorldClockModel.h>
#import <VeepooBleSDK/VPDeviceBrightModel.h>
#import <VeepooBleSDK/VPScreenDurationModel.h>
#import <VeepooBleSDK/VPDeviceRaiseHandModel.h>
#import <VeepooBleSDK/VPDeviceContactsModel.h>
#import <VeepooBleSDK/VPDeviceFemaleModel.h>
#import <VeepooBleSDK/VPDeviceCountDownModel.h>
#import <VeepooBleSDK/VPDeviceHeartAlarmModel.h>
#import <VeepooBleSDK/VPDeviceLongSeatModel.h>
#import <VeepooBleSDK/VPDeviceGPSModel.h>
#import <VeepooBleSDK/VPDeviceSportControlModel.h>
#import <VeepooBleSDK/VPDeviceMessageTypeModel.h>
#import <VeepooBleSDK/VPPhotoDialModel.h>
#import <VeepooBleSDK/VPDeviceMarketDialModel.h>
#import <VeepooBleSDK/VPTCMTestDataModel.h>
#import <VeepooBleSDK/VPPttValueModel.h>

@interface JoemeWatchModule ()

/** JS 侧注册的全局事件回调（uni.requireNativePlugin 侧 startEventListen 传入） */
@property (nonatomic, copy) UniModuleKeepAliveCallback eventCallback;

/** 扫描到的设备缓存：mac(deviceAddress) -> VPPeripheralModel（连接时要回传对象） */
@property (nonatomic, strong) NSMutableDictionary<NSString *, VPPeripheralModel *> *scannedDevices;

/** 扫描超时定时器（iOS SDK 扫描无超时参数，需要自己停） */
@property (nonatomic, strong) NSTimer *scanTimer;

/** 扫描结束回调（扫描结束时触发一次，对齐 Android 的 onSearchStopped） */
@property (nonatomic, copy) UniModuleKeepAliveCallback scanCallback;

/** 当前进行中的手动测量类型；nil 表示空闲（设备同一时刻只能做一种测量） */
@property (nonatomic, copy) NSString *measuringType;

/** 血压测量模式（0 通用 / 1 私人），start/stop 必须一致 */
@property (nonatomic, assign) NSInteger bpTestMode;

/** 血糖是否私人模式，start/stop 必须一致 */
@property (nonatomic, assign) BOOL bloodGlucosePersonal;

/** 最近一次经典蓝牙状态（VPBTConnectStateChangeBlock 回调），电话页读取用 */
@property (nonatomic, strong) NSDictionary *lastBTInfo;

/** ECG 实时波形：已下发的 filterSignals 下标（SDK 只追加，据此发增量） */
@property (nonatomic, assign) NSUInteger ecgWaveIndex;
/** ECG 实时波形：上次下发时间（按 100ms 合帧，与 Demo 刷新节奏一致） */
@property (nonatomic, assign) NSTimeInterval ecgWaveFlushAt;
/** ECG 实时波形：帧序号（页面可用来判断是否丢帧） */
@property (nonatomic, assign) NSInteger ecgWaveSeq;
/** 本次 ECG 测量的模型（结束时取 filterSignals 补发尾段） */
@property (nonatomic, strong) VPECGTestDataModel *ecgModel;

@end

/** 分页累计原始点的小容器：同一 (h,m) 合并（分页可能重复回同一包）。
 必须定义在 JoemeWatchModule 的 @implementation 之外 —— ObjC 不允许 @implementation 嵌套。 */
@interface VMutablePointsHolder : NSObject
@property (nonatomic, strong) NSMutableDictionary<NSString *, NSMutableDictionary *> *byKey;
- (void)addPoint:(NSDictionary *)p;
- (void)mergeAtHour:(NSInteger)h minute:(NSInteger)m values:(NSDictionary *)values;
- (NSArray<NSDictionary *> *)sortedPoints;
@end

@implementation VMutablePointsHolder
- (instancetype)init {
    if (self = [super init]) { _byKey = [NSMutableDictionary dictionary]; }
    return self;
}
- (void)addPoint:(NSDictionary *)p {
    if (!p) return;
    NSString *key = [NSString stringWithFormat:@"%02ld:%02ld",
                     (long)[p[@"h"] integerValue], (long)[p[@"m"] integerValue]];
    if (!self.byKey[key]) self.byKey[key] = [p mutableCopy];
}
- (void)mergeAtHour:(NSInteger)h minute:(NSInteger)m values:(NSDictionary *)values {
    NSString *key = [NSString stringWithFormat:@"%02ld:%02ld", (long)h, (long)m];
    NSMutableDictionary *p = self.byKey[key];
    if (!p) return;   // 只合并到已存在的原始点上（避免造出没有步数/心率的幽灵点）
    [p addEntriesFromDictionary:values];
}
- (NSArray<NSDictionary *> *)sortedPoints {
    NSArray<NSString *> *keys = [self.byKey.allKeys sortedArrayUsingSelector:@selector(compare:)];
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *k in keys) [out addObject:self.byKey[k]];
    return out;
}
@end

@implementation JoemeWatchModule

// ==================== 事件下发 ====================

/** 注册全局事件回调：JS 侧 init() 成功后调用，把 mapNativeEvent 传进来 */
UNI_EXPORT_METHOD(@selector(startEventListen:callback:))
- (void)startEventListen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    self.eventCallback = callback;
}

/** 统一下发事件 { type, data }，与 Android sendEvent 保持一致 */
- (void)sendEvent:(NSString *)type data:(NSDictionary *)data {
    UniModuleKeepAliveCallback cb = self.eventCallback;
    if (!cb) return;
    NSDictionary *wrap = @{
        @"type": type ?: @"",
        @"data": data ?: @{}
    };
    // SDK 回调理论上已在主线程，这里再兜底一次，避免跨线程调用 JS 桥
    if ([NSThread isMainThread]) {
        cb(wrap, YES); // keepAlive=YES：事件监听是持久的
    } else {
        dispatch_async(dispatch_get_main_queue(), ^{
            cb(wrap, YES);
        });
    }
}

static NSDictionary *resultWithCode(NSInteger code) {
    return @{ @"code": @(code) };
}

// ==================== 1. 初始化 ====================

UNI_EXPORT_METHOD(@selector(initWatch:callback:))
- (void)initWatch:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];

    // 2.0 起必须手动指定业务管理器，否则所有业务接口无响应
    if (!manager.peripheralManage) {
        manager.peripheralManage = [VPPeripheralManage shareVPPeripheralManager];
    }

    // 单例持有的 block 用 weak 引用，避免模块与 JS 回调被强持有到进程结束
    __weak typeof(self) weakSelf = self;

    // 手机系统蓝牙开关状态监听 -> on('bluetooth')
    manager.VPBleCentralManageChangeBlock = ^(VPCentralManagerState state) {
        [weakSelf sendEvent:@"bluetooth" data:@{ @"open": @(state == VPCentralManagerStatePoweredOn) }];
    };

    // 设备连接状态监听（持久，含断开/重连/验密） -> on('status') / on('pwd')
    manager.VPBleConnectStateChangeBlock = ^(VPDeviceConnectState state) {
        [weakSelf handlePersistentConnectState:state];
    };

    // 经典蓝牙（BT 通话通道）状态 -> on('btStatus') / on('btInfo')
    manager.peripheralManage.VPBTConnectStateChangeBlock = ^(VPDeviceBTState btState, BOOL btSwitchOpen, BOOL mediaSwitchOpen) {
        NSString *state = @"disconnected";
        if (btState == VPDeviceBTStateConnected) state = @"connected";
        else if (btState == VPDeviceBTStateAdvertising) state = @"connecting";
        NSDictionary *info = @{
            @"state": state,
            @"connected": @(btState == VPDeviceBTStateConnected),
            @"status": (btState == VPDeviceBTStateConnected ? @"CONNECTED" : @"DISCONNECTED"),
            @"btOpen": @(btSwitchOpen),
            @"audioOpen": @(mediaSwitchOpen)
        };
        weakSelf.lastBTInfo = info;
        [weakSelf sendEvent:@"btInfo" data:info];
        [weakSelf sendEvent:@"btStatus" data:@{ @"state": state }];
    };

    callback(resultWithCode(200), NO);
}

// ==================== 2. 扫描 ====================

UNI_EXPORT_METHOD(@selector(startScanDevice:callback:))
- (void)startScanDevice:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSInteger timeout = 8;
    if (options && options[@"timeout"]) timeout = [options[@"timeout"] integerValue];
    if (timeout <= 0) timeout = 8;

    if (!self.scannedDevices) self.scannedDevices = [NSMutableDictionary dictionary];
    [self.scannedDevices removeAllObjects];

    // 重新扫描前先废掉上一次的定时器，避免旧定时器提前结束本轮扫描
    if (self.scanTimer) {
        [self.scanTimer invalidate];
        self.scanTimer = nil;
    }

    // iOS 扫描回调每次设备触发，无独立"扫描结束"回调，结束时用定时器停掉后回调
    [[VPBleCentralManage sharedBleManager] veepooSDKStartScanDeviceAndReceiveScanningDevice:^(VPPeripheralModel *model) {
        [self handleScannedDevice:model];
    }];

    self.scanCallback = callback;
    __weak typeof(self) weakSelf = self;
    self.scanTimer = [NSTimer scheduledTimerWithTimeInterval:timeout repeats:NO block:^(NSTimer *timer) {
        [[VPBleCentralManage sharedBleManager] veepooSDKStopScanDevice];
        [weakSelf finishScan];
    }];

    // 注意：不像 Android 立刻回调，这里等扫描结束（定时器触发）才回调，对齐 JS 侧 await startScan(8)
}

UNI_EXPORT_METHOD(@selector(stopScanDevice:callback:))
- (void)stopScanDevice:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[VPBleCentralManage sharedBleManager] veepooSDKStopScanDevice];
    [self finishScan];
    callback(resultWithCode(200), NO);
}

/** 扫描结束统一收口：清定时器、触发一次扫描结束回调 */
- (void)finishScan {
    if (self.scanTimer) {
        [self.scanTimer invalidate];
        self.scanTimer = nil;
    }
    UniModuleKeepAliveCallback cb = self.scanCallback;
    self.scanCallback = nil;
    if (cb) cb(resultWithCode(200), NO);
}

// ==================== 3. 连接 ====================

UNI_EXPORT_METHOD(@selector(connectDevice:callback:))
- (void)connectDevice:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *mac = options ? options[@"mac"] : nil;
    VPPeripheralModel *model = mac ? self.scannedDevices[mac] : nil;
    if (!model) {
        callback(@{ @"code": @(-1), @"message": @"未找到设备，请先扫描" }, NO);
        return;
    }

    // 连接结果由 DeviceConnectBlock 一次性回调（BleConnecting/BleConnectSuccess/BleVerifyPasswordSuccess…）
    // 状态/密码事件统一走 initWatch 里注册的持久监听 vpBleConnectStateChangeBlock，避免重复下发
    __block BOOL callbackFired = NO;
    [[VPBleCentralManage sharedBleManager] veepooSDKConnectDevice:model deviceConnectBlock:^(DeviceConnectState state) {
        if (callbackFired) return;
        switch (state) {
            case BleVerifyPasswordSuccess:
            case BleConnectSuccess:
                callbackFired = YES;
                callback(resultWithCode(200), NO);
                break;
            case BleVerifyPasswordFailure:
                // 连接成功但密码验证失败，连接本身算成功，密码失败走事件
                callbackFired = YES;
                callback(resultWithCode(200), NO);
                break;
            case BlePoweredOff:
                callbackFired = YES;
                callback(@{ @"code": @(-1), @"message": @"手机蓝牙未开启" }, NO);
                break;
            case BleConnectFailed:
                callbackFired = YES;
                callback(@{ @"code": @(-1), @"message": @"连接失败" }, NO);
                break;
            case BleConnectTimeout:
                callbackFired = YES;
                callback(@{ @"code": @(-1), @"message": @"连接超时" }, NO);
                break;
            case BleConfirmTimeout:
                callbackFired = YES;
                callback(@{ @"code": @(-1), @"message": @"设备确认超时" }, NO);
                break;
            case BleConnecting:
            default:
                break;
        }
    }];
}

// ==================== 4. 密码验证（业务操作的前置条件） ====================

UNI_EXPORT_METHOD(@selector(confirmDevicePwd:callback:))
- (void)confirmDevicePwd:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *pwd = options ? options[@"pwd"] : nil;
    if (!pwd.length) pwd = @"0000"; // 首次连接默认密码

    // 注：iOS 连接流程内已自动验密，此方法作为"再验一次/补验"存在，
    // 正常流程下 connectDevice 返回 BleVerifyPasswordSuccess 时已发过 on('pwd')
    [[VPBleCentralManage sharedBleManager] veepooSDKSynchronousPasswordWithType:VerifyPasswordType
                                                                       password:pwd
                                                         SynchronizationResult:^(PasswordSynchronTpye result) {
        if (result == PasswordValidationSuccess || result == PasswordValidationAllSuccess) {
            [self emitDeviceInfo];
        }
        callback(resultWithCode(200), NO);
    }];
}

// ==================== 5. 业务接口 ====================

UNI_EXPORT_METHOD(@selector(syncPersonInfo:callback:))
- (void)syncPersonInfo:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSInteger sex = options ? [options[@"sex"] integerValue] : 1;
    NSUInteger height = options ? [options[@"height"] unsignedIntegerValue] : 170;
    NSUInteger weight = options ? [options[@"weight"] unsignedIntegerValue] : 60;
    NSInteger age = options ? [options[@"age"] integerValue] : 25;
    NSUInteger targetStep = options ? [options[@"targetStep"] unsignedIntegerValue] : 8000;
    // sleepAim 是睡眠目标（分钟，0 也合法），没传才用 480 兜底 —— 不能用「值为 0」判断是否传了
    NSInteger sleepAim = (options && options[@"sleepAim"]) ? [options[@"sleepAim"] integerValue] : 480;
    if (height <= 0) height = 170;
    if (weight <= 0) weight = 60;
    if (age <= 0) age = 25;
    if (targetStep <= 0) targetStep = 8000;
    // iOS 头文件写明目标步数范围 0-60000（超出时 SDK 可能直接同步失败），
    // Android 侧允许到 65535；两端取交集 60000，页面滑块上限也已对齐。
    if (targetStep > 60000) targetStep = 60000;
    if (sleepAim < 0 || sleepAim > 1440) sleepAim = 480;

    // 带睡眠目标必须走模型版接口：五参的
    // veepooSDKSynchronousPersonalInformationWithStature:... 没有 sleep 参数。
    // 模型版的 height 字段叫 status（SDK 的历史命名），别被名字骗了。
    VPSyncPersonalInfo *personalInfo = [[VPSyncPersonalInfo alloc] init];
    personalInfo.status = (int)height;
    personalInfo.weight = (int)weight;
    personalInfo.age = (int)age;
    personalInfo.sex = (int)(sex == 1 ? 1 : 0);
    personalInfo.targetStep = (int)targetStep;
    personalInfo.targetSleepDuration = (int)sleepAim;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSynchronousPersonalInformation:personalInfo result:^(NSUInteger settingResult) {
        [self sendEvent:@"personInfo" data:@{ @"success": @(settingResult == 1) }];
        NSMutableDictionary *result = [resultWithCode(200) mutableCopy];
        // 回显实际下发的目标，便于 JS 侧核对（尤其 sleepAim 的分钟换算）
        result[@"targetStep"] = @(targetStep);
        result[@"sleepAim"] = @(sleepAim);
        callback(result, NO);
    }];
}

UNI_EXPORT_METHOD(@selector(readBattery:callback:))
- (void)readBattery:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    // 用带充电状态的接口（iOS 反而有充电态，比 Android 更全）
    [pm veepooSDKReadDeviceBatteryAndChargeInfo:^(BOOL isPercent, VPDeviceChargeState chargeState, BOOL percenTypeIsLowBat, NSUInteger battery) {
        // 格数(0-4)换算成百分比，对齐 Android 的 level 语义
        NSUInteger level = isPercent ? battery : battery * 25;
        BOOL charging = (chargeState == VPDeviceChargeStateCharging);
        NSDictionary *d = @{
            @"level": @(level),
            @"isCharging": @(charging),
            @"state": @(chargeState),
            @"isLowBattery": @(percenTypeIsLowBat)
        };
        [self sendEvent:@"battery" data:d];
        callback(@{ @"code": @200, @"level": @(level), @"isCharging": @(charging),
                    @"state": @(chargeState), @"isLowBattery": @(percenTypeIsLowBat) }, NO);
    }];
}

UNI_EXPORT_METHOD(@selector(startHeartDetect:callback:))
- (void)startHeartDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKTestHeartStart:YES testResult:^(VPTestHeartState state, NSUInteger heartValue) {
        BOOL done = (state == VPTestHeartStateNotWear ||
                     state == VPTestHeartStateDeviceBusy ||
                     state == VPTestHeartStateOver);
        [self sendEvent:@"heart" data:@{
            @"status": @(state),
            @"value": @(heartValue),
            @"isDone": @(done)
        }];
    }];
    callback(resultWithCode(200), NO);
}

UNI_EXPORT_METHOD(@selector(stopHeartDetect:callback:))
- (void)stopHeartDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKTestHeartStart:NO testResult:nil];
    callback(resultWithCode(200), NO);
}

UNI_EXPORT_METHOD(@selector(readHealthData:callback:))
- (void)readHealthData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    // 一次性读全部基础数据（睡眠/计步/心率/血压/血氧/HRV 等），进度通过 on('health') 下发
    [pm veepooSdkStartReadDeviceAllDataWithReadStateChangeBlock:^(VPReadDeviceBaseDataState state,
                                                                  NSUInteger totalDay,
                                                                  NSUInteger currentReadDayNumber,
                                                                  NSUInteger readCurrentDayProgress) {
        switch (state) {
            case VPReadDeviceBaseDataStart:
                [self sendEvent:@"healthData" data:@{ @"progress": @0 }];
                break;
            case VPReadDeviceBaseDataReading:
                [self sendEvent:@"healthData" data:@{ @"progress": @(readCurrentDayProgress / 100.0) }];
                break;
            case VPReadDeviceBaseDataComplete:
                [self sendEvent:@"healthData" data:@{ @"complete": @YES }];
                break;
            default:
                break;
        }
    }];
    callback(resultWithCode(200), NO);
    // TODO(第二版)：读完后按天提取睡眠/五分组数据
    //   [pm veepooSDK_readSleepDataWithDayNumber:i result:^(NSArray *sleep){...}]
    //   [pm veepooSDK_readBasicDataWithDayNumber:i maxPackage:1 result:^(...){...}]
    //   天数取自 peripheralModel.saveDays
}

UNI_EXPORT_METHOD(@selector(disconnectWatch:callback:))
- (void)disconnectWatch:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [[VPBleCentralManage sharedBleManager] veepooSDKDisconnectDevice];
    callback(resultWithCode(200), NO);
}

// ==================== 12. 关机 ====================

/**
 手表关机。

 iOS SDK 对应 VPPeripheralBaseManage.veepooSDKPowerOffDevice：头文件里是**裸声明、不带 result block**，
 SDK 只保证命令已下发，**拿不到回执**（不像验密/电量/心率那样有回调）。
 关机成功后设备随即断电断开，initWatch 注册的持久连接监听会补发 status(connected=false)。

 与 Android（F2 调试命令通道，设备会回帧）对齐后，on('power') 的语义：
   Android：{ ok: code==1, code }        —— 设备真的回了帧，ok 才是"设备已确认关机"
   iOS    ：{ ok: NO, code: -1, sent: YES } —— sent 只表示"命令已下发"，ok 恒为 NO，
            不把"已发出"伪装成"设备已确认关机"，JS 侧按 sent 分支展示。

 前置条件与其他业务操作一致：已连接 + 密码验证通过。
 */
UNI_EXPORT_METHOD(@selector(powerOffDevice:callback:))
- (void)powerOffDevice:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    if (!manager.peripheralManage) {
        // 对齐 Android：未 initWatch 就调业务接口时给明确错误，而不是静默无响应
        callback(@{ @"code": @(-1), @"message": @"未初始化：请先调用 initWatch" }, NO);
        return;
    }
    if (!manager.peripheralModel) {
        callback(@{ @"code": @(-1), @"message": @"设备未连接，请先连接并完成密码验证" }, NO);
        return;
    }

    [manager.peripheralManage veepooSDKPowerOffDevice];

    // SDK 无回执：sent=YES 表示命令已下发，ok 保持 NO
    [self sendEvent:@"power" data:@{ @"ok": @NO, @"code": @(-1), @"sent": @YES }];
    callback(resultWithCode(200), NO);
}

// ==================== 13. 健康测量（手动单次测量） ====================

/** 支持的手动测量类型（与 Android 端 MEASURE_TYPES、utils/joeme-watch.js 完全一致） */
static NSArray<NSString *> *JoemeMeasureTypes(void) {
    static NSArray<NSString *> *types = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        types = @[@"spo2", @"bp", @"temperature", @"hrv", @"fatigue", @"stress", @"emotion", @"met",
                  @"breath", @"bloodGlucose", @"bodyComposition", @"gsr", @"ecg"];
    });
    return types;
}

/** measure 事件的公共字段 */
- (NSMutableDictionary *)measureEvent:(NSString *)type phase:(NSString *)phase isDone:(BOOL)isDone {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"type"] = type;
    d[@"phase"] = phase;     // start / testing / result / failed / stop
    d[@"isDone"] = @(isDone);
    return d;
}

/** 一次测量结束，释放占用 */
- (void)endMeasuring {
    self.measuringType = nil;
}

/**
 开始一次手动测量。options: { type, model?, personalMode? }
   type         必填，取值见 JoemeMeasureTypes()
   model        仅 bp：'public'（通用，默认）/ 'private'（私人）
   personalMode 仅 bloodGlucose：是否私人模式，默认 NO
 结果通过 on('measure') 持续下发，本回调只表示命令已下发。
 */
UNI_EXPORT_METHOD(@selector(startMeasure:callback:))
- (void)startMeasure:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *type = options[@"type"];
    if (![type isKindOfClass:[NSString class]] || ![JoemeMeasureTypes() containsObject:type]) {
        callback(@{ @"code": @(-1), @"message": [NSString stringWithFormat:@"不支持的测量类型：%@，支持：%@",
                                                 type ?: @"(空)",
                                                 [JoemeMeasureTypes() componentsJoinedByString:@","]] }, NO);
        return;
    }
    if (self.measuringType.length) {
        callback(@{ @"code": @(-1), @"message": [NSString stringWithFormat:@"已有测量进行中（%@），请先 stopMeasure",
                                                 self.measuringType] }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (!pm) {
        callback(@{ @"code": @(-1), @"message": @"未初始化：请先调用 initWatch" }, NO);
        return;
    }

    self.measuringType = type;
    __weak typeof(self) weakSelf = self;

    if ([type isEqualToString:@"spo2"]) {
        [pm veepooSDKTestOxygenStart:YES testResult:^(VPTestOxygenState state, NSUInteger oxygenValue) {
            [weakSelf handleSpo2State:state value:oxygenValue];
        }];
    } else if ([type isEqualToString:@"bp"]) {
        NSString *model = options[@"model"];
        self.bpTestMode = [@"private" isEqualToString:model] ? 1 : 0;
        [pm veepooSDKTestBloodStart:YES
                           testMode:(NSUInteger)self.bpTestMode
                         testResult:^(VPTestBloodState state, NSUInteger progress,
                                      NSUInteger highBlood, NSUInteger lowBlood) {
            [weakSelf handleBpState:state progress:progress high:highBlood low:lowBlood];
        }];
    } else if ([type isEqualToString:@"temperature"]) {
        [pm veepooSDK_temperatureTestStart:YES
                                    result:^(VPTemperatureTestState state, BOOL enable, NSInteger progress,
                                             NSInteger tempValue, NSInteger originalTempValue) {
            [weakSelf handleTemperatureState:state enable:enable progress:progress
                                   tempValue:tempValue originalTempValue:originalTempValue];
        }];
    } else if ([type isEqualToString:@"hrv"]) {
        [pm veepooSDK_HRVTest:YES callBack:^(int con, VPTestHRVState ack, int hrvValue) {
            [weakSelf handleHrvCon:con ack:ack value:hrvValue];
        }];
    } else if ([type isEqualToString:@"fatigue"]) {
        [pm veepooSDKTestFatigueStart:YES
                           testResult:^(VPTestFatigueState state, NSUInteger progress, NSUInteger fatigueValue) {
            [weakSelf handleFatigueState:state progress:progress value:fatigueValue];
        }];
    } else if ([type isEqualToString:@"stress"]) {
        [pm veepooSDK_stressTestStart:YES result:^(VPDeviceStressTestState state, NSInteger progress,
                                                   NSInteger stress) {
            [weakSelf handleStressState:state progress:progress stress:stress];
        }];
    } else if ([type isEqualToString:@"emotion"]) {
        [pm veepooSDK_emotionTest:YES callBack:^(int con, VPTestEmotionState ack, int progress,
                                                 NSInteger value) {
            [weakSelf handleEmotionCon:con ack:ack progress:progress value:value];
        }];
    } else if ([type isEqualToString:@"met"]) {
        [pm veepooSDK_metTest:YES callBack:^(int con, VPTestMetState ack, int progress, int met) {
            [weakSelf handleMetCon:con ack:ack progress:progress met:met];
        }];
    } else if ([type isEqualToString:@"breath"]) {
        [pm veepooSDKTestBreathingRateStart:YES
                                 testResult:^(VPTestBreathingRateState state, NSUInteger progress,
                                              NSUInteger value) {
            [weakSelf handleBreathState:state progress:progress value:value];
        }];
    } else if ([type isEqualToString:@"bloodGlucose"]) {
        BOOL personal = [options[@"personalMode"] boolValue];
        self.bloodGlucosePersonal = personal;
        [pm veepooSDKTestBloodGlucoseStart:YES
                           isPersonalModel:personal
                                testResult:^(VPDeviceBloodGlucoseTestState state, NSUInteger progress,
                                             NSUInteger value, NSUInteger level) {
            [weakSelf handleBloodGlucoseState:state progress:progress value:value level:level];
        }];
    } else if ([type isEqualToString:@"bodyComposition"]) {
        [pm veepooSDKTestBodyCompositionStart:YES
                                     progress:^(NSInteger lead, NSProgress *progress) {
            [weakSelf handleBodyCompositionLead:lead progress:progress];
        } testResult:^(VPDeviceBodyCompositionState state, VPBodyCompositionValueModel *model) {
            [weakSelf handleBodyCompositionState:state model:model];
        }];
    } else if ([type isEqualToString:@"gsr"]) {
        [pm veepooSDKTestGSRStart:YES
                         progress:^(NSProgress *progress) {
            [weakSelf handleGsrProgress:progress];
        } testResult:^(VPDeviceGSRState state, VPGSRResultModel *model) {
            [weakSelf handleGsrState:state model:model];
        }];
    } else if ([type isEqualToString:@"ecg"]) {
        // 每次开始测量都重置波形游标：filterSignals 是整个测量过程的累计数组
        self.ecgWaveIndex = 0;
        self.ecgWaveFlushAt = 0;
        self.ecgWaveSeq = 0;
        self.ecgModel = nil;
        [pm veepooSDKTestECGStart:YES
                       testResult:^(VPTestECGState state, NSUInteger progress, VPECGTestDataModel *model) {
            [weakSelf handleEcgState:state progress:progress model:model];
        }];
    }

    [self sendEvent:@"measure" data:[self measureEvent:type phase:@"start" isDone:NO]];
    callback(resultWithCode(200), NO);
}

// ---------- 各类型状态映射 ----------

/** 血氧：Testing/Over 期间持续给值，Over 为正常结束 */
- (void)handleSpo2State:(VPTestOxygenState)state value:(NSUInteger)value {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"血氧测量中";
    switch (state) {
        case VPTestOxygenStateStart:
        case VPTestOxygenStateTesting:
            break;
        case VPTestOxygenStateCalibration:
            message = @"血氧校准中";
            break;
        case VPTestOxygenStateCalibrationComplete:
            message = @"血氧校准完成";
            break;
        case VPTestOxygenStateOver:
            phase = value > 0 ? @"result" : @"stop";
            isDone = YES;
            success = value > 0;
            message = value > 0 ? @"血氧测量完成" : @"血氧测量结束（无有效值）";
            break;
        case VPTestOxygenStateNotWear:
            phase = @"failed"; isDone = YES; message = @"血氧测量失败：佩戴检测未通过";
            break;
        case VPTestOxygenStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"血氧测量失败：设备正忙";
            break;
        case VPTestOxygenStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"血氧测量失败：设备不支持该功能";
            break;
        default:   // Invalid 等
            phase = @"failed"; isDone = YES; message = @"血氧测量失败：功能暂时不可用";
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"spo2" phase:phase isDone:isDone];
    d[@"value"] = @(value);
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 血压：一次约 50-55 秒，TestMode 0 通用 / 1 私人，结果只在结束时给一次 */
- (void)handleBpState:(VPTestBloodState)state progress:(NSUInteger)progress
                 high:(NSUInteger)high low:(NSUInteger)low {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"血压测量中（约需 50-55 秒）";
    switch (state) {
        case VPTestBloodStateTesting:
            break;
        case VPTestBloodStateComplete:
            phase = (high > 0 || low > 0) ? @"result" : @"stop";
            isDone = YES;
            success = (high > 0 || low > 0);
            message = success ? @"血压测量完成" : @"血压测量结束（无有效值）";
            break;
        case VPTestBloodStateTestInterrupt:
            phase = @"stop"; isDone = YES; message = @"血压测量已中断";
            break;
        case VPTestBloodStateTestFail:
            phase = @"failed"; isDone = YES; message = @"血压测量失败：测试无效";
            break;
        case VPTestBloodStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"血压测量失败：设备正忙";
            break;
        case VPTestBloodStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"血压测量失败：设备不支持该功能";
            break;
        default:
            phase = @"failed"; isDone = YES; message = @"血压测量失败";
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"bp" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(high);
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    d[@"extra"] = @{ @"systolic": @(high), @"diastolic": @(low),
                     @"model": self.bpTestMode == 1 ? @"private" : @"public" };
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 体温：tempValue 是 ℃ 的 10 倍，Open 期间回进度，Close 为正常结束 */
- (void)handleTemperatureState:(VPTemperatureTestState)state enable:(BOOL)enable
                      progress:(NSInteger)progress tempValue:(NSInteger)tempValue
             originalTempValue:(NSInteger)originalTempValue {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"体温测量中";
    switch (state) {
        case VPTemperatureTestStateOpen:
            break;
        case VPTemperatureTestStateClose:
            phase = tempValue > 0 ? @"result" : @"stop";
            isDone = YES;
            success = tempValue > 0;
            message = tempValue > 0 ? @"体温测量完成" : @"体温测量结束（无有效值）";
            break;
        case VPTemperatureTestStateUnsupported:
            phase = @"failed"; isDone = YES; message = @"体温测量失败：设备不支持该功能";
            break;
        case VPTemperatureTestStateNotWear:
            phase = @"failed"; isDone = YES; message = @"体温测量失败：佩戴检测未通过";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"temperature" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(tempValue / 10.0);          // 摄氏度
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    d[@"extra"] = @{ @"originalTemp": @(originalTempValue / 10.0),   // 原始/体表温度
                     @"deviceBusy": @(enable) };
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** HRV：设备持续回值，没有"完成"回调，靠用户 stopMeasure 收尾 */
- (void)handleHrvCon:(int)con ack:(VPTestHRVState)ack value:(int)hrvValue {
    BOOL ok = (ack == VPTestHRVStateTesting);
    NSString *phase = ok ? @"testing" : @"failed";
    NSMutableDictionary *d = [self measureEvent:@"hrv" phase:phase isDone:!ok];
    d[@"value"] = @(hrvValue);
    d[@"success"] = @(NO);
    d[@"state"] = @(ack);
    d[@"message"] = ok ? @"HRV 测量中" : [self hrvFailText:ack];
    d[@"extra"] = @{ @"con": @(con) };
    [self sendEvent:@"measure" data:d];
    if (!ok) [self endMeasuring];
}

- (NSString *)hrvFailText:(VPTestHRVState)ack {
    switch (ack) {
        case VPTestHRVStateAlreadyStarted: return @"HRV 测量失败：设备已在测量中";
        case VPTestHRVStateLowPower: return @"HRV 测量失败：设备电量过低";
        case VPTestHRVStateDeviceBusy: return @"HRV 测量失败：设备正忙";
        case VPTestHRVStateNotWear: return @"HRV 测量失败：佩戴检测未通过";
        default: return @"HRV 测量失败";
    }
}

/** 疲劳度：Complete 为正常结束，等级 1-4 */
- (void)handleFatigueState:(VPTestFatigueState)state progress:(NSUInteger)progress
                     value:(NSUInteger)fatigueValue {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"疲劳度测量中";
    switch (state) {
        case VPTestFatigueStateTesting:
            break;
        case VPTestFatigueStateComplete:
            phase = fatigueValue > 0 ? @"result" : @"stop";
            isDone = YES;
            success = fatigueValue > 0;
            message = success ? [NSString stringWithFormat:@"疲劳度测量完成：%@",
                                 [self fatigueLevelText:fatigueValue]]
                              : @"疲劳度测量结束（无有效值）";
            break;
        case VPTestFatigueStateTestInterrupt:
            phase = @"stop"; isDone = YES; message = @"疲劳度测量已中断";
            break;
        case VPTestFatigueStateTestFail:
            phase = @"failed"; isDone = YES; message = @"疲劳度测量失败：测试无效";
            break;
        case VPTestFatigueStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"疲劳度测量失败：设备正忙";
            break;
        case VPTestFatigueStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"疲劳度测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"fatigue" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(fatigueValue);
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    d[@"extra"] = @{ @"levelText": [self fatigueLevelText:fatigueValue] };
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 疲劳度等级文案（SDK 定义 1-4） */
- (NSString *)fatigueLevelText:(NSUInteger)value {
    switch (value) {
        case 1: return @"不疲劳";
        case 2: return @"轻度疲劳";
        case 3: return @"一般疲劳";
        case 4: return @"重度疲劳";
        default: return @"未知";
    }
}

/** 压力：Complete 为正常结束，Over 表示人为结束 */
- (void)handleStressState:(VPDeviceStressTestState)state progress:(NSInteger)progress stress:(NSInteger)stress {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"压力测量中";
    switch (state) {
        case VPDeviceStressTestStateComplete:
            phase = stress > 0 ? @"result" : @"stop";
            isDone = YES;
            success = stress > 0;
            message = success ? @"压力测量完成" : @"压力测量结束（无有效值）";
            break;
        case VPDeviceStressTestStateOver:
            phase = @"stop"; isDone = YES; message = @"压力测量已结束";
            break;
        case VPDeviceStressTestStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"压力测量失败：设备正忙";
            break;
        case VPDeviceStressTestStateLowPower:
            phase = @"failed"; isDone = YES; message = @"压力测量失败：设备电量过低";
            break;
        case VPDeviceStressTestStateNotWear:
            phase = @"failed"; isDone = YES; message = @"压力测量失败：佩戴检测未通过";
            break;
        case VPDeviceStressTestStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"压力测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"stress" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(stress);
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 情绪：Testing 期间随进度给值，没有单独的成功回调，靠 stopMeasure 收尾 */
- (void)handleEmotionCon:(int)con ack:(VPTestEmotionState)ack progress:(int)progress value:(NSInteger)value {
    BOOL ok = (ack == VPTestEmotionStateTesting);
    NSMutableDictionary *d = [self measureEvent:@"emotion" phase:(ok ? @"testing" : @"failed") isDone:!ok];
    d[@"progress"] = @(progress);
    d[@"value"] = @(value);
    d[@"success"] = @(NO);
    d[@"state"] = @(ack);
    d[@"message"] = ok ? @"情绪测量中" : [self simpleFailText:(NSInteger)ack type:@"情绪"];
    d[@"extra"] = @{ @"con": @(con) };
    [self sendEvent:@"measure" data:d];
    if (!ok) [self endMeasuring];
}

/** 梅脱（MET）：Testing 期间随进度给值，靠 stopMeasure 收尾 */
- (void)handleMetCon:(int)con ack:(VPTestMetState)ack progress:(int)progress met:(int)met {
    BOOL ok = (ack == VPTestMetStateTesting);
    NSMutableDictionary *d = [self measureEvent:@"met" phase:(ok ? @"testing" : @"failed") isDone:!ok];
    d[@"progress"] = @(progress);
    d[@"value"] = @(met);
    d[@"success"] = @(NO);
    d[@"state"] = @(ack);
    d[@"message"] = ok ? @"梅脱测量中" : [self simpleFailText:(NSInteger)ack type:@"梅脱"];
    d[@"extra"] = @{ @"con": @(con) };
    [self sendEvent:@"measure" data:d];
    if (!ok) [self endMeasuring];
}

/**
 情绪/梅脱共用同一套状态枚举布局（Testing/AlreadyStarted/LowPower/DeviceBusy/NotWear），
 这里按数值映射文案：1 已在测量 / 2 低电 / 3 正忙 / 4 未佩戴。
 */
- (NSString *)simpleFailText:(NSInteger)ack type:(NSString *)type {
    switch (ack) {
        case 1: return [NSString stringWithFormat:@"%@测量失败：设备已在测量中", type];
        case 2: return [NSString stringWithFormat:@"%@测量失败：设备电量过低", type];
        case 3: return [NSString stringWithFormat:@"%@测量失败：设备正忙", type];
        case 4: return [NSString stringWithFormat:@"%@测量失败：佩戴检测未通过", type];
        default: return [NSString stringWithFormat:@"%@测量失败", type];
    }
}

/** 呼吸率：Over/Complete 为正常结束 */
- (void)handleBreathState:(VPTestBreathingRateState)state progress:(NSUInteger)progress
                    value:(NSUInteger)value {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"呼吸率测量中";
    switch (state) {
        case VPTestBreathingRateStateStart:
        case VPTestBreathingRateStateTesting:
            break;
        case VPTestBreathingRateStateOver:
        case VPTestBreathingRateStateComplete:
            phase = value > 0 ? @"result" : @"stop";
            isDone = YES;
            success = value > 0;
            message = success ? @"呼吸率测量完成" : @"呼吸率测量结束（无有效值）";
            break;
        case VPTestBreathingRateStateNotWear:
            phase = @"failed"; isDone = YES; message = @"呼吸率测量失败：佩戴检测未通过";
            break;
        case VPTestBreathingRateStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"呼吸率测量失败：设备正忙";
            break;
        case VPTestBreathingRateStateFailure:
            phase = @"failed"; isDone = YES; message = @"呼吸率测量失败：测试无效";
            break;
        case VPTestBreathingRateStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"呼吸率测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"breath" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(value);
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 血糖：上报值是 100 倍，这里换算成 mmol/L；Open 期间回进度，Close 为正常结束 */
- (void)handleBloodGlucoseState:(VPDeviceBloodGlucoseTestState)state progress:(NSUInteger)progress
                          value:(NSUInteger)value level:(NSUInteger)level {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"血糖测量中";
    switch (state) {
        case VPDeviceBloodGlucoseTestStateOpen:
            break;
        case VPDeviceBloodGlucoseTestStateClose:
            phase = value > 0 ? @"result" : @"stop";
            isDone = YES;
            success = value > 0;
            message = success ? @"血糖测量完成" : @"血糖测量结束（无有效值）";
            break;
        case VPDeviceBloodGlucoseTestStateUnsupported:
            phase = @"failed"; isDone = YES; message = @"血糖测量失败：设备不支持该功能";
            break;
        case VPDeviceBloodGlucoseTestStateLowPower:
            phase = @"failed"; isDone = YES; message = @"血糖测量失败：设备电量过低";
            break;
        case VPDeviceBloodGlucoseTestStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"血糖测量失败：设备正忙";
            break;
        case VPDeviceBloodGlucoseTestStateNotWear:
            phase = @"failed"; isDone = YES; message = @"血糖测量失败：佩戴检测未通过";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"bloodGlucose" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    d[@"value"] = @(value / 100.0);                 // mmol/L
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    d[@"extra"] = @{ @"rawValue": @(value),
                     @"riskLevel": @(level),
                     @"model": self.bloodGlucosePersonal ? @"private" : @"public" };
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** 身体成分：进度回 (lead, progress)，lead=0 表示手已放在电极片上 */
- (void)handleBodyCompositionLead:(NSInteger)lead progress:(NSProgress *)progress {
    NSMutableDictionary *d = [self measureEvent:@"bodyComposition" phase:@"testing" isDone:NO];
    d[@"progress"] = @(leadProgressPercent(progress));
    d[@"message"] = lead == 0 ? @"身体成分测量中（保持握持电极片）" : @"身体成分测量中（请双手握住电极片）";
    d[@"extra"] = @{ @"lead": @(lead), @"leadOk": @(lead == 0) };
    [self sendEvent:@"measure" data:d];
}

/** 身体成分结果：Complete 为正常结束，Over 表示人为结束 */
- (void)handleBodyCompositionState:(VPDeviceBodyCompositionState)state model:(VPBodyCompositionValueModel *)model {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"身体成分测量中";
    switch (state) {
        case VPDeviceBodyCompositionStateComplete:
            phase = @"result"; isDone = YES; success = YES; message = @"身体成分测量完成";
            break;
        case VPDeviceBodyCompositionStateOver:
            phase = @"stop"; isDone = YES; message = @"身体成分测量已结束";
            break;
        case VPDeviceBodyCompositionStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"身体成分测量失败：设备正忙";
            break;
        case VPDeviceBodyCompositionStateLowPower:
            phase = @"failed"; isDone = YES; message = @"身体成分测量失败：设备电量过低";
            break;
        case VPDeviceBodyCompositionStateFailure:
            phase = @"failed"; isDone = YES; message = @"身体成分测量失败：测试无效";
            break;
        case VPDeviceBodyCompositionStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"身体成分测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"bodyComposition" phase:phase isDone:isDone];
    if (model) {
        d[@"progress"] = @100;
        d[@"value"] = model.bodyFatPercentage ?: @"";   // 主值取体脂率（字符串，SDK 原样）
        NSMutableDictionary *extra = [NSMutableDictionary dictionary];
        extra[@"bmi"] = model.bmi ?: @"";
        extra[@"bodyFatPercentage"] = model.bodyFatPercentage ?: @"";
        extra[@"fatMass"] = model.fatMass ?: @"";
        extra[@"leanBodyMass"] = model.leanBodyMass ?: @"";
        extra[@"muscleRate"] = model.muscleRate ?: @"";
        extra[@"muscleMass"] = model.muscleMass ?: @"";
        extra[@"subcutaneousFat"] = model.subcutaneousFat ?: @"";
        extra[@"bodyMoisture"] = model.bodyMoisture ?: @"";
        extra[@"waterContent"] = model.waterContent ?: @"";
        extra[@"skeletalMuscleRate"] = model.skeletalMuscleRate ?: @"";
        extra[@"boneMass"] = model.boneMass ?: @"";
        extra[@"proportionOfProtein"] = model.proportionOfProtein ?: @"";
        extra[@"proteinAmount"] = model.proteinAmount ?: @"";
        extra[@"basalMetabolicRate"] = model.basalMetabolicRate ?: @"";
        extra[@"stature"] = @(model.stature);
        extra[@"weight"] = @(model.weight);
        extra[@"gender"] = @(model.gender);
        d[@"extra"] = extra;
    }
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** NSProgress -> 0-100 的整数进度 */
static NSInteger leadProgressPercent(NSProgress *progress) {
    if (!progress) return 0;
    double fraction = progress.fractionCompleted;
    if (fraction <= 0) return 0;
    if (fraction >= 1) return 100;
    return (NSInteger)(fraction * 100);
}

/** 皮电：进度回调 */
- (void)handleGsrProgress:(NSProgress *)progress {
    NSMutableDictionary *d = [self measureEvent:@"gsr" phase:@"testing" isDone:NO];
    d[@"progress"] = @(leadProgressPercent(progress));
    d[@"message"] = @"皮电测量中";
    [self sendEvent:@"measure" data:d];
}

/** 皮电结果：Complete 为正常结束，Over 表示人为结束 */
- (void)handleGsrState:(VPDeviceGSRState)state model:(VPGSRResultModel *)model {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"皮电测量中";
    switch (state) {
        case VPDeviceGSRStateComplete:
            phase = @"result"; isDone = YES; success = YES; message = @"皮电测量完成";
            break;
        case VPDeviceGSRStateOver:
            phase = @"stop"; isDone = YES; message = @"皮电测量已结束";
            break;
        case VPDeviceGSRStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"皮电测量失败：设备正忙";
            break;
        case VPDeviceGSRStateLowPower:
            phase = @"failed"; isDone = YES; message = @"皮电测量失败：设备电量过低";
            break;
        case VPDeviceGSRStateFailure:
            phase = @"failed"; isDone = YES; message = @"皮电测量失败：测试无效";
            break;
        case VPDeviceGSRStateNotWear:
            phase = @"failed"; isDone = YES; message = @"皮电测量失败：佩戴检测未通过";
            break;
        case VPDeviceGSRStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"皮电测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    NSMutableDictionary *d = [self measureEvent:@"gsr" phase:phase isDone:isDone];
    if (model) {
        d[@"progress"] = @100;
        d[@"value"] = @(model.emotin_level);   // 主值取情绪（SDK 属性名就是 emotin_level）
        // 皮肤含水量/交感神经活跃度/皮质醇/抑郁风险：SDK 只给了这几个字段
        d[@"extra"] = @{ @"emotionLevel": @(model.emotin_level),
                         @"skinMoisture": @(model.skin_moisture),
                         @"snsActivation": @(model.sns_activation),
                         @"cortisolValue": @(model.cortisol_value),
                         @"depressionRisk": @(model.depression_risk) };
    }
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/** ECG：动态测量，靠用户 stopMeasure 收尾；NotLead 表示导联脱落 */
- (void)handleEcgState:(VPTestECGState)state progress:(NSUInteger)progress model:(VPECGTestDataModel *)model {
    NSString *phase = @"testing";
    BOOL isDone = NO, success = NO;
    NSString *message = @"ECG 测量中";
    switch (state) {
        case VPTestECGStateStart:
        case VPTestECGStateTesting:
            break;
        case VPTestECGStateNotLead:
            message = @"ECG 测量中：导联脱落，请贴紧电极片";
            break;
        case VPTestECGStateOver:
        case VPTestECGStateComplete:
            phase = @"result"; isDone = YES;
            success = (model.aveHeart.integerValue > 0);
            message = success ? @"ECG 测量完成" : @"ECG 测量结束（无有效值）";
            break;
        case VPTestECGStateFailure:
            phase = @"failed"; isDone = YES; message = @"ECG 测量失败：测试无效";
            break;
        case VPTestECGStateDeviceBusy:
            phase = @"failed"; isDone = YES; message = @"ECG 测量失败：设备正忙";
            break;
        case VPTestECGStateNoFunction:
            phase = @"failed"; isDone = YES; message = @"ECG 测量失败：设备不支持该功能";
            break;
        default:
            break;
    }
    if (model) self.ecgModel = model;
    // 波形随每次回调增量下发（filterSignals 是累计数组，只发新追加的部分）
    [self flushEcgWave:model force:isDone];

    NSMutableDictionary *d = [self measureEvent:@"ecg" phase:phase isDone:isDone];
    d[@"progress"] = @(progress);
    if (isDone && model.aveHeart.length) {
        d[@"value"] = @(model.aveHeart.integerValue);        // 结束取平均心率
    } else if (model.muHearts.count) {
        d[@"value"] = model.muHearts.lastObject;             // 过程中取最新一次心率
    }
    d[@"success"] = @(success);
    d[@"state"] = @(state);
    d[@"message"] = message;
    NSMutableDictionary *extra = [[self ecgExtraFromModel:model] mutableCopy];
    // 多诊断报告（付费能力）：心电图测量结束后 SDK 从结果模型算，历史记录没有模型，不给
    if (isDone && success && model) [self mergeEcgReport:extra model:model];
    d[@"extra"] = extra;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
}

/**
 合并多诊断报告字段（字段名对齐 Android ecgDiagnosisExtra，单位也一致：
 qrsAmp/stMeanAmp 是 mv×100，pwvMeanVal 是 m/s×10）。
 iOS 的风险项名与 Android 略有差异：angiosclerosisRisk vs angioscleroticRisk，
 这里统一成 Android 名（页面只认一套）。
 */
- (void)mergeEcgReport:(NSMutableDictionary *)extra model:(VPECGTestDataModel *)model {
    VPECGTestResultReportModle *report = [VPECGTestResutHandle resultReportWithModel:model];
    if (!report || report.riskParamArr.count == 0) return;   // 非付费设备/无诊断数据
    extra[@"multiDiagnosis"] = @YES;
    extra[@"diseaseRisk"] = @(report.diseaseRisk.integerValue);
    extra[@"pressureIndex"] = @(report.pressureIndex.integerValue);
    extra[@"fatigueIndex"] = @(report.fatigueIndex.integerValue);
    extra[@"myocarditisRisk"] = @(report.myocarditisRisk.integerValue);
    extra[@"chdRisk"] = @(report.chdRisk.integerValue);
    extra[@"angioscleroticRisk"] = @(report.angiosclerosisRisk.integerValue);
    extra[@"qrsTime"] = @(report.qrsTime.integerValue);
    extra[@"qrsAmp"] = @(report.qrsAmp.integerValue);
    extra[@"pwvMeanVal"] = @(report.pwvMeanVal.integerValue);
    extra[@"stMeanAmp"] = @(report.stMeanAmp.integerValue);
    extra[@"diseaseSdnn"] = @(report.diseaseSdnn.integerValue);
    extra[@"diseaseRmssd"] = @(report.diseaseRmssd.integerValue);
    extra[@"risk32"] = report.riskParamArr;
    extra[@"diagnosis8"] = @[
        model.result1 ?: @"", model.result2 ?: @"", model.result3 ?: @"", model.result4 ?: @"",
        model.result5 ?: @"", model.result6 ?: @"", model.result7 ?: @"", model.result8 ?: @""
    ];
}

/**
 ECG 结果字段（实时结果与历史记录共用，字段名对齐 Android 的 ecgResultExtra）。
 iOS 的数值字段都是 NSString，这里统一转成 NSNumber，页面不用再两边判类型。
 filterSignals / powers 保持 ADC 原值，页面用 ecgType + gain 换算 mV
 （Android 是原生算 mV，iOS 传增益让页面用 SDK 公式换算，见 ecg-cache.js）。
 */
- (NSDictionary *)ecgExtraFromModel:(VPECGTestDataModel *)model {
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    if (!model) return extra;
    extra[@"ecgType"] = model.ecgType ?: @"";
    extra[@"testType"] = model.type ?: @"";
    extra[@"date"] = model.date ?: @"";
    extra[@"testTime"] = model.testTime ?: @"";
    extra[@"duration"] = @(model.duration.integerValue);
    extra[@"aveHeart"] = @(model.aveHeart.integerValue);
    extra[@"heart"] = @(model.aveHeart.integerValue);
    extra[@"aveHrv"] = @(model.aveHrv.integerValue);
    extra[@"hrv"] = @(model.aveHrv.integerValue);
    extra[@"aveResRate"] = @(model.aveResRate.integerValue);
    extra[@"resRate"] = @(model.aveResRate.integerValue);
    extra[@"aveQT"] = @(model.aveQT.integerValue);
    extra[@"qt"] = @(model.aveQT.integerValue);
    extra[@"avePWV"] = @(model.avePWV.integerValue);
    extra[@"frequency"] = @(model.frequency.integerValue);
    extra[@"drawfrequency"] = @(model.uploadFrequency.integerValue);
    extra[@"lead"] = @(model.lead.integerValue);
    extra[@"state"] = @(model.state.integerValue);
    extra[@"gain"] = @([model getGainValue]);
    extra[@"multiDiagnosis"] = @NO;       // 由调用方按是否拿到多诊断报告覆盖
    NSArray *signals = model.filterSignals ?: @[];
    extra[@"filterSignals"] = signals;
    extra[@"powers"] = @[];               // iOS 侧无逐点信号质量，页面按默认值画
    extra[@"waveMv"] = [self ecgMvArrayFromModel:model signals:signals];
    extra[@"wavePoints"] = @(signals.count);
    NSDate *tm = [self ecgDateFromModel:model];
    if (tm) extra[@"ts"] = @((long long)(tm.timeIntervalSince1970 * 1000));
    return extra;
}

/**
 filterSignals（ADC）-> mV 数组，用 SDK 的换算函数（ecgType/testType/gain 三分支都在里面）。
 与 Android 的 waveMv 同口径，页面只认这一个字段，不用自己实现换算。
 */
- (NSArray<NSNumber *> *)ecgMvArrayFromModel:(VPECGTestDataModel *)model signals:(NSArray *)signals {
    if (!model || !signals.count) return @[];
    NSUInteger gain = [model getGainValue];
    NSString *ecgType = model.ecgType ?: @"";
    NSString *testType = model.type ?: @"";
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:signals.count];
    for (id v in signals) {
        CGFloat adc = [v doubleValue];
        CGFloat mv = [VPECGTestDataModel convertToMvWithValue:adc ecgType:ecgType testType:testType gain:gain];
        [out addObject:@(round(mv * 1000.0) / 1000.0)];
    }
    return out;
}

/** model.date + testTime -> NSDate（yyyy-MM-dd HH:mm:ss，本地时区） */
- (NSDate *)ecgDateFromModel:(VPECGTestDataModel *)model {
    if (!model.date.length) return nil;
    static NSDateFormatter *fmt = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        fmt = [[NSDateFormatter alloc] init];
        fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
        fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSString *time = model.testTime.length ? model.testTime : @"00:00:00";
    return [fmt dateFromString:[NSString stringWithFormat:@"%@ %@", model.date, time]];
}

/**
 实时波形增量下发。SDK 的 filterSignals 只追加不重置，用 ecgWaveIndex 记已发的长度。
 按 100ms 合帧（Demo 注释的推荐刷新节奏），收尾时 force 一次补发尾段。
 发送的是 ADC 原始值 —— mV 换算交给页面（iOS SDK 的换算函数是 ObjC 侧 API）。
 */
- (void)flushEcgWave:(VPECGTestDataModel *)model force:(BOOL)force {
    if (!model || !model.filterSignals.count) return;
    if (self.ecgWaveIndex >= model.filterSignals.count && !force) return;
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (!force && now - self.ecgWaveFlushAt < 0.1) return;
    self.ecgWaveFlushAt = now;
    NSArray *all = model.filterSignals;
    NSUInteger start = MIN(self.ecgWaveIndex, all.count);
    NSArray *slice = [all subarrayWithRange:NSMakeRange(start, all.count - start)];
    self.ecgWaveIndex = all.count;
    if (!slice.count) return;
    [self sendEvent:@"ecgWave" data:@{
        @"points": [self ecgMvArrayFromModel:model signals:slice],   // 与 Android 同口径：mV
        @"powers": @[],
        @"raw": @NO,
        @"drawFrequency": @(model.uploadFrequency.integerValue),
        @"frequency": @(model.frequency.integerValue),
        @"ecgType": model.ecgType ?: @"",
        @"gain": @([model getGainValue]),
        @"seq": @(++self.ecgWaveSeq)
    }];
}

/**
 停止测量。options: { type }，不传则停止当前进行中的那次。
 iOS 没有独立的 stop 接口，都是把对应 start 接口的参数传 NO；
 血压/血糖要把 start 时的模式原样传回。
 */
UNI_EXPORT_METHOD(@selector(stopMeasure:callback:))
- (void)stopMeasure:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *type = options[@"type"];
    if (![type isKindOfClass:[NSString class]] || !type.length) type = self.measuringType;
    if (!type.length) {
        callback(resultWithCode(200), NO);   // 没有进行中的测量，静默成功
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (!pm) {
        callback(@{ @"code": @(-1), @"message": @"未初始化：请先调用 initWatch" }, NO);
        return;
    }

    if ([type isEqualToString:@"spo2"]) {
        [pm veepooSDKTestOxygenStart:NO testResult:^(VPTestOxygenState state, NSUInteger value) {}];
    } else if ([type isEqualToString:@"bp"]) {
        [pm veepooSDKTestBloodStart:NO
                           testMode:(NSUInteger)self.bpTestMode
                         testResult:^(VPTestBloodState state, NSUInteger progress,
                                      NSUInteger high, NSUInteger low) {}];
    } else if ([type isEqualToString:@"temperature"]) {
        [pm veepooSDK_temperatureTestStart:NO
                                    result:^(VPTemperatureTestState state, BOOL enable,
                                             NSInteger progress, NSInteger tempValue,
                                             NSInteger originalTempValue) {}];
    } else if ([type isEqualToString:@"hrv"]) {
        [pm veepooSDK_HRVTest:NO callBack:^(int con, VPTestHRVState ack, int hrvValue) {}];
    } else if ([type isEqualToString:@"fatigue"]) {
        [pm veepooSDKTestFatigueStart:NO
                           testResult:^(VPTestFatigueState state, NSUInteger progress,
                                        NSUInteger value) {}];
    } else if ([type isEqualToString:@"stress"]) {
        [pm veepooSDK_stressTestStart:NO
                               result:^(VPDeviceStressTestState state, NSInteger progress,
                                        NSInteger stress) {}];
    } else if ([type isEqualToString:@"emotion"]) {
        [pm veepooSDK_emotionTest:NO callBack:^(int con, VPTestEmotionState ack, int progress,
                                                 NSInteger value) {}];
    } else if ([type isEqualToString:@"met"]) {
        [pm veepooSDK_metTest:NO callBack:^(int con, VPTestMetState ack, int progress, int met) {}];
    } else if ([type isEqualToString:@"breath"]) {
        [pm veepooSDKTestBreathingRateStart:NO
                                 testResult:^(VPTestBreathingRateState state, NSUInteger progress,
                                              NSUInteger value) {}];
    } else if ([type isEqualToString:@"bloodGlucose"]) {
        [pm veepooSDKTestBloodGlucoseStart:NO
                           isPersonalModel:self.bloodGlucosePersonal
                                testResult:^(VPDeviceBloodGlucoseTestState state, NSUInteger progress,
                                             NSUInteger value, NSUInteger level) {}];
    } else if ([type isEqualToString:@"bodyComposition"]) {
        [pm veepooSDKTestBodyCompositionStart:NO
                                     progress:^(NSInteger lead, NSProgress *progress) {}
                                   testResult:^(VPDeviceBodyCompositionState state,
                                                VPBodyCompositionValueModel *model) {}];
    } else if ([type isEqualToString:@"gsr"]) {
        [pm veepooSDKTestGSRStart:NO
                         progress:^(NSProgress *progress) {}
                       testResult:^(VPDeviceGSRState state, VPGSRResultModel *model) {}];
    } else if ([type isEqualToString:@"ecg"]) {
        [self flushEcgWave:self.ecgModel force:YES];   // 尾段波形补发
        [pm veepooSDKTestECGStart:NO
                       testResult:^(VPTestECGState state, NSUInteger progress,
                                    VPECGTestDataModel *model) {}];
    }

    NSMutableDictionary *d = [self measureEvent:type phase:@"stop" isDone:YES];
    d[@"message"] = @"已下发停止测量命令";
    [self sendEvent:@"measure" data:d];
    [self endMeasuring];
    callback(resultWithCode(200), NO);
}

// ==================== 内部方法 ====================

/** 扫描到设备：缓存最新模型 + 首次下发 on('scan') */
- (void)handleScannedDevice:(VPPeripheralModel *)model {
    if (!model) return;
    NSString *mac = model.deviceAddress;
    if (!mac.length) return;
    if (!self.scannedDevices) self.scannedDevices = [NSMutableDictionary dictionary];
    BOOL isNew = (self.scannedDevices[mac] == nil);
    // 始终覆盖为最新模型：设备名/RSSI 可能随后续广播补全，连接时要用最全的那份
    self.scannedDevices[mac] = model;
    if (isNew) {
        [self sendEvent:@"scan" data:@{
            @"name": model.deviceName ?: @"",
            @"mac": mac,
            @"rssi": model.RSSI ?: @0
        }];
    }
}

/** 持久连接状态监听回调（initWatch 注册，处理断开/重连/验密） */
- (void)handlePersistentConnectState:(VPDeviceConnectState)state {
    switch (state) {
        case VPDeviceConnectStateDisConnect:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @NO }];
            break;
        case VPDeviceConnectStateConnect:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @YES }];
            break;
        case VPDeviceConnectStateVerifyPasswordSuccess:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @YES }];
            [self emitDeviceInfo];
            break;
        case VPDeviceConnectStateVerifyPasswordFailure:
            // 蓝牙已连但验密失败：不能发 pwd（JS 层会无条件当成"验密通过"），仅更新连接状态
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @YES }];
            break;
        case VPDeviceConnectStateTimeout:
        case VPDeviceConfirmStateTimeout:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @NO, @"timeout": @YES }];
            break;
        case VPDeviceDiscoverNewUpdateFirm:
        default:
            break;
    }
}

/** 当前已连接设备的地址，未连接时为空串 */
- (NSString *)currentMac {
    return [VPBleCentralManage sharedBleManager].peripheralModel.deviceAddress ?: @"";
}

/** 验密成功后下发 on('pwd') 设备信息 + on('func') 功能包（设备号/固件/保存天数） */
- (void)emitDeviceInfo {
    VPPeripheralModel *pm = [VPBleCentralManage sharedBleManager].peripheralModel;
    if (!pm) return;
    [self sendEvent:@"pwd" data:@{
        @"deviceNumber": @(pm.deviceNumber),
        @"deviceVersion": pm.deviceVersion ?: @"",
        @"deviceTestVersion": pm.deviceTestVersion ?: @""
    }];
    // 对应 Android 的 funcSupport 事件（JS 侧映射为 'func'），携带数据保存天数
    // contactType：2 表示设备支持 SOS 紧急联系人（与 Android FunctionDeviceSupportData.getContactType 同源）
    [self sendEvent:@"funcSupport" data:@{
        @"watchDataDay": @(pm.saveDays),
        @"contactType": @(pm.contactType)
    }];
}

// ==================== 全量桥接（契约第 1~13 节） ====================
// 说明：本节只新增，不改动上方既有方法。所有方法名/事件名严格对齐 bridge-spec.md。
// SDK 方法签名均对照 VeepooBleSDK.framework/Headers 逐一核对，未编造。

/**
 业务前置检查（对齐 powerOffDevice 的判定）：
 返回 YES 表示已 initWatch 且设备已连接验密，可继续；NO 表示已给 callback 错误回执。
 */
- (BOOL)checkReady:(UniModuleKeepAliveCallback)callback {
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    if (!manager.peripheralManage) {
        callback(@{ @"code": @(-1), @"message": @"未初始化：请先调用 initWatch" }, NO);
        return NO;
    }
    if (!manager.peripheralModel) {
        callback(@{ @"code": @(-1), @"message": @"设备未连接，请先连接并完成密码验证" }, NO);
        return NO;
    }
    return YES;
}

// ---------- 1. 基础设置（conn） ----------

/**
 同步时间给设备。
 iOS SDK：veepooSDKSettingTimeWithResult:（block 内 BOOL success）
 Android：settingTime(...)；JS：joemeWatch.setTime()
 事件：on('time') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setTime:callback:))
- (void)setTime:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingTimeWithResult:^(BOOL success) {
        [self sendEvent:@"time" data:@{ @"ok": @(success) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置设备名称。options: { name }。
 iOS SDK：veepooSDKSettingDeviceNameWithString:resultBlock:（state 0=成功 1=失败 2=溢出 3=不足）
 Android：bleDeviceRename(...)；JS：joemeWatch.setDeviceName(name)
 事件：on('deviceName') -> { ok, state }
 */
UNI_EXPORT_METHOD(@selector(setDeviceName:callback:))
- (void)setDeviceName:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *name = options[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"name 不能为空" }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceNameWithString:name resultBlock:^(NSUInteger state) {
        [self sendEvent:@"deviceName" data:@{ @"ok": @(state == 0), @"state": @(state) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取当前连接设备 RSSI。一次性读取：callback 与事件都带数据。
 iOS SDK：veepooSDKReadConnectedPeripheralRSSIValue:（VPReadRSSIBlock = void(^)(NSInteger rssiValue)）
 Android：readRssi(...)；JS：joemeWatch.readRSSI() -> resolve { rssi }
 事件：on('rssi') -> { rssi }
 */
UNI_EXPORT_METHOD(@selector(readRSSI:callback:))
- (void)readRSSI:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKReadConnectedPeripheralRSSIValue:^(NSInteger rssiValue) {
        NSDictionary *d = @{ @"rssi": @(rssiValue) };
        [self sendEvent:@"rssi" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    }];
}

/**
 清除设备数据（恢复出厂，清完设备自动关机断开）。
 iOS SDK：veepooSDKClearDeviceData（裸声明，无回执）——同 powerOff 处理。
 Android：clearDeviceData(...)；JS：joemeWatch.clearDeviceData()
 事件：无；callback(200) 表示已下发。
 */
UNI_EXPORT_METHOD(@selector(clearDeviceData:callback:))
- (void)clearDeviceData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKClearDeviceData];
    callback(resultWithCode(200), NO);
}

/**
 复位设备（冷启动重启，数据不清，会断开）。
 iOS SDK：veepooSDKResetDeviceData（裸声明，无回执）
 Android：resetDeviceData(...)；JS：joemeWatch.resetDeviceData()
 事件：无；callback(200) 表示已下发。
 */
UNI_EXPORT_METHOD(@selector(resetDeviceData:callback:))
- (void)resetDeviceData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKResetDeviceData];
    callback(resultWithCode(200), NO);
}

/**
 读取电量与充电状态（与现有 readBattery 同接口，独立暴露）。
 iOS SDK：veepooSDKReadDeviceBatteryAndChargeInfo:
 事件：on('battery')；callback 带 { level, isCharging, state, isLowBattery }。
 */
UNI_EXPORT_METHOD(@selector(readBatteryAndCharge:callback:))
- (void)readBatteryAndCharge:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKReadDeviceBatteryAndChargeInfo:^(BOOL isPercent, VPDeviceChargeState chargeState, BOOL percenTypeIsLowBat, NSUInteger battery) {
        NSUInteger level = isPercent ? battery : battery * 25;   // 格数换算百分比，对齐 readBattery
        BOOL charging = (chargeState == VPDeviceChargeStateCharging);
        NSDictionary *d = @{
            @"level": @(level),
            @"isCharging": @(charging),
            @"state": @(chargeState),
            @"isLowBattery": @(percenTypeIsLowBat)
        };
        [self sendEvent:@"battery" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    }];
}

/**
 设置设备语言。options: { lang: 'zh' | 'en' }。
 iOS SDK：veepooSDKSettingLanguage:result:（UInt8：中文=1 英文=2，头文件列出 1~34 全量语言枚举）
 Android：settingDeviceLanguage(..., ELanguage)；JS：joemeWatch.setLanguage(lang)
 事件：on('language') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setLanguage:callback:))
- (void)setLanguage:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *lang = options[@"lang"];
    UInt8 languageType = 2; // 默认英文
    if ([lang isKindOfClass:[NSString class]]) {
        if ([lang isEqualToString:@"zh"]) languageType = 1;
        else if ([lang isEqualToString:@"en"]) languageType = 2;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingLanguage:languageType result:^(BOOL success) {
        [self sendEvent:@"language" data:@{ @"ok": @(success) }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 2. 自动监测与提醒（auto） ----------

/**
 设置自动测量开关。options: { type, on, timeInterval?, startHour?, startMinute?, endHour?, endMinute? }
   type: 'heart' | 'bp' | 'bloodGlucose' | 'stress' | 'spo2' | 'temperature' | 'hrv' | 'bloodComp'
 iOS SDK：先 veepooSDKReadAutoMonitSwitchInfo: 取出设备当前模型（model.type 只读），
          命中对应 type 后改 on/时间，再 veepooSDKSetAutoMonitSwitchWithModel:result:
 Android：setAutoMeasureSettingData(...)；JS：joemeWatch.setAutoMonitor(...)
 事件：on('autoMonitor') -> { ok, type }
 注：模型 type 为只读属性，必须先读再改，不能直接 new 一个指定 type 的模型。
 */
UNI_EXPORT_METHOD(@selector(setAutoMonitor:callback:))
- (void)setAutoMonitor:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *type = options[@"type"];
    BOOL on = [options[@"on"] boolValue];
    VPAutoMonitTestType ttype = VPAutoMonitTestTypeHeartRate;
    if ([type isEqualToString:@"heart"]) ttype = VPAutoMonitTestTypeHeartRate;
    else if ([type isEqualToString:@"bp"]) ttype = VPAutoMonitTestTypeBloodPressure;
    else if ([type isEqualToString:@"bloodGlucose"]) ttype = VPAutoMonitTestTypeBloodGlucose;
    else if ([type isEqualToString:@"stress"]) ttype = VPAutoMonitTestTypeStress;
    else if ([type isEqualToString:@"spo2"]) ttype = VPAutoMonitTestTypeBloodOxygen;
    else if ([type isEqualToString:@"temperature"]) ttype = VPAutoMonitTestTypeBodyTemperature;
    else if ([type isEqualToString:@"hrv"]) ttype = VPAutoMonitTestTypeHRV;
    else if ([type isEqualToString:@"bloodComp"]) ttype = VPAutoMonitTestTypeBloodComponents;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKReadAutoMonitSwitchInfo:^(NSArray<VPAutoMonitTestModel *> *models) {
        VPAutoMonitTestModel *target = nil;
        for (VPAutoMonitTestModel *m in models) {
            if (m.type == ttype) { target = m; break; }
        }
        if (!target) {
            [weakSelf sendEvent:@"autoMonitor" data:@{ @"ok": @NO, @"message": @"设备不支持该自动测量类型" }];
            callback(resultWithCode(200), NO);
            return;
        }
        target.on = on;
        if (options[@"timeInterval"]) target.timeInterval = [options[@"timeInterval"] unsignedIntegerValue];
        if (options[@"startHour"]) target.startHour = [options[@"startHour"] unsignedCharValue];
        if (options[@"startMinute"]) target.startMinute = [options[@"startMinute"] unsignedCharValue];
        if (options[@"endHour"]) target.endHour = [options[@"endHour"] unsignedCharValue];
        if (options[@"endMinute"]) target.endMinute = [options[@"endMinute"] unsignedCharValue];
        [pm veepooSDKSetAutoMonitSwitchWithModel:target result:^(BOOL success, VPAutoMonitTestModel *m) {
            [weakSelf sendEvent:@"autoMonitor" data:@{ @"ok": @(success), @"type": type ?: @"" }];
            callback(resultWithCode(200), NO);
        }];
    }];
}

/**
 24 小时血氧自动检测开关。options: { on: bool }。
 iOS SDK：veepooSDKSettingAllDayOxygenTest:result:（VPSettingFunctionState：1=开 2=关）
 Android：settingSpo2hAutoDetect(...)；JS：joemeWatch.setAllDayOxygen(on)
 事件：on('allDayOxygen') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setAllDayOxygen:callback:))
- (void)setAllDayOxygen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingAllDayOxygenTest:(on ? VPSettingFunctionOpen : VPSettingFunctionClose) result:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        [self sendEvent:@"allDayOxygen" data:@{ @"ok": @(ok) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 血氧呼吸暂停提醒。options: { on, startHour?, startMinute?, endHour?, endMinute?, duration? }
 iOS SDK：veepooSDKSettingOxygenApneaRemind:settingMode:successResult:failureResult:（settingMode 1=设置）
          模型 VPOxygenApneaRemindModel：state 1=开 2=关，defaultTime 固定 YES
 Android：settingSBBR(...)；JS：joemeWatch.setOxygenApnea({...})
 事件：on('oxygenApnea') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setOxygenApnea:callback:))
- (void)setOxygenApnea:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPOxygenApneaRemindModel *m = [[VPOxygenApneaRemindModel alloc] init];
    m.state = [options[@"on"] boolValue] ? 1 : 2;
    if (options[@"startHour"]) m.startH = [options[@"startHour"] integerValue];
    if (options[@"startMinute"]) m.startM = [options[@"startMinute"] integerValue];
    if (options[@"endHour"]) m.endH = [options[@"endHour"] integerValue];
    if (options[@"endMinute"]) m.endM = [options[@"endMinute"] integerValue];
    if (options[@"duration"]) m.durationTime = [options[@"duration"] integerValue];
    m.defaultTime = YES; // 头文件注明该参数暂时都给 YES
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingOxygenApneaRemind:m settingMode:1 successResult:^(VPOxygenApneaRemindModel *model) {
        [self sendEvent:@"oxygenApnea" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"oxygenApnea" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 健康提醒（久坐/喝水/远眺等）。options: { type, on, startHour?, startMinute?, endHour?, endMinute?, interval? }
   type: 'longSeat' | 'drink' | 'lookFar' | 'sport' | 'medicine' | 'read' | 'trip' | 'washHands'
 iOS SDK：veepooSDKSettingHealthRemindWithRemindType:opCode:remindModel:resultBlock:deviceInfoDidChangeBlock:
          （opCode 1=设置 2=读取）
 Android：settingHealthRemind(...)；JS：joemeWatch.setHealthRemind(type, options)
 事件：on('healthRemind') -> { ok, type }
 */
UNI_EXPORT_METHOD(@selector(setHealthRemind:callback:))
- (void)setHealthRemind:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *type = options[@"type"];
    VPDeviceHealthRemindType rt = VPDeviceHealthRemindTypeLongSeat;
    if ([type isEqualToString:@"longSeat"]) rt = VPDeviceHealthRemindTypeLongSeat;
    else if ([type isEqualToString:@"drink"]) rt = VPDeviceHealthRemindTypeDrinkWater;
    else if ([type isEqualToString:@"lookFar"]) rt = VPDeviceHealthRemindTypeLookFarAway;
    else if ([type isEqualToString:@"sport"]) rt = VPDeviceHealthRemindTypeSport;
    else if ([type isEqualToString:@"medicine"]) rt = VPDeviceHealthRemindTypeTakeMedicine;
    else if ([type isEqualToString:@"read"]) rt = VPDeviceHealthRemindTypeRead;
    else if ([type isEqualToString:@"trip"]) rt = VPDeviceHealthRemindTypeTrip;
    else if ([type isEqualToString:@"washHands"]) rt = VPDeviceHealthRemindTypeWashHands;

    VPDeviceHealthRemindModel *m = [[VPDeviceHealthRemindModel alloc] init];
    m.type = rt;
    m.open = [options[@"on"] boolValue];
    m.startHour = [options[@"startHour"] unsignedCharValue];
    m.startMinute = [options[@"startMinute"] unsignedCharValue];
    m.endHour = [options[@"endHour"] unsignedCharValue];
    m.endMinute = [options[@"endMinute"] unsignedCharValue];
    m.remindInterval = [options[@"interval"] unsignedCharValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingHealthRemindWithRemindType:rt opCode:1 remindModel:m resultBlock:^(BOOL success, BOOL complete, VPDeviceHealthRemindModel *successModel) {
        [self sendEvent:@"healthRemind" data:@{ @"ok": @(success), @"type": type ?: @"" }];
        callback(resultWithCode(200), NO);
    } deviceInfoDidChangeBlock:^(VPDeviceHealthRemindModel *changeModel) {}];
}

/**
 健康灯（LED）开关。options: { on: bool }。
 iOS SDK：veepooSDKSetHealthLightStatus:callBack:（VPHealthLightStatusType：0=Off 1=慢闪 2=常闪 3=常亮；
          on 映射为慢闪 SlowFlash，off 映射为 Off）
 Android：setHealthLightStatus(...)；JS：joemeWatch.setHealthLight({ on })
 事件：on('healthLight') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setHealthLight:callback:))
- (void)setHealthLight:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPHealthLightStatusType t = on ? VPHealthLightStatusTypeSlowFlash : VPHealthLightStatusTypeOff;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSetHealthLightStatus:t callBack:^(BOOL result, VPHealthLightStatusType type) {
        [self sendEvent:@"healthLight" data:@{ @"ok": @(result) }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 3. 闹钟与时钟（alarm） ----------

/**
 设置老闹钟（固定 3 组）。options: { list: [{ hour, minute, enable? }] }，最多 3 组。
 iOS SDK：veepooSDKSettingDeviceAlarmWithAlarmModel1:alarmModel2:alarmModel3:settingMode:successResult:failureResult:
          （settingMode=VPSettingAlarmMode(1)；VPDeviceAlarmModel alarmState 0=关 1=开）
 Android：settingAlarm(..., List<AlarmSetting>)；JS：joemeWatch.setAlarm(list)
 事件：on('alarm') -> { ok }
 注：iOS 每次设置都要把 3 组全部下发，未提供的组以 0 点/关闭占位。
 */
UNI_EXPORT_METHOD(@selector(setAlarm:callback:))
- (void)setAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceAlarmModel *a1 = [[VPDeviceAlarmModel alloc] initWithAlarmHour:0 alarmMinute:0 alarmState:0];
    VPDeviceAlarmModel *a2 = [[VPDeviceAlarmModel alloc] initWithAlarmHour:0 alarmMinute:0 alarmState:0];
    VPDeviceAlarmModel *a3 = [[VPDeviceAlarmModel alloc] initWithAlarmHour:0 alarmMinute:0 alarmState:0];
    NSArray *slots = @[a1, a2, a3];
    NSArray *list = options[@"list"];
    if ([list isKindOfClass:[NSArray class]]) {
        for (NSInteger i = 0; i < MIN(list.count, 3); i++) {
            NSDictionary *e = list[i];
            if (![e isKindOfClass:[NSDictionary class]]) continue;
            VPDeviceAlarmModel *m = slots[i];
            m.alarmHour = [e[@"hour"] unsignedIntegerValue];
            m.alarmMinute = [e[@"minute"] unsignedIntegerValue];
            m.alarmState = [e[@"enable"] boolValue] ? 1 : 0;
        }
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceAlarmWithAlarmModel1:a1 alarmModel2:a2 alarmModel3:a3 settingMode:VPSettingAlarmMode successResult:^(VPDeviceAlarmModel *r1, VPDeviceAlarmModel *r2, VPDeviceAlarmModel *r3) {
        [self sendEvent:@"alarm" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"alarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置/新增新闹钟。options: { hour, minute, repeat?, enable?, id? }
 iOS SDK：veepooSDKSettingDeviceNewAlarmWithNewAlarmModel:settingMode:successResult:failureResult:
          （settingMode 1=设置(增/改)；模型字段均为 NSString，用 initWithAlarmDict: 构造）
 Android：addAlarm2(...)；JS：joemeWatch.setNewAlarm(model)
 事件：on('newAlarm') -> { ok }
 注：repeatState 为 8 位二进制转十进制字符串（bit0 恒 0，其后周一~周日）；alarmScene 取值待厂商确认。
 */
UNI_EXPORT_METHOD(@selector(setNewAlarm:callback:))
- (void)setNewAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"alarmHour"]    = [NSString stringWithFormat:@"%@", options[@"hour"] ?: @0];
    dict[@"alarmMinute"]  = [NSString stringWithFormat:@"%@", options[@"minute"] ?: @0];
    dict[@"alarmState"]   = [NSString stringWithFormat:@"%lu", (unsigned long)([options[@"enable"] boolValue] ? 1 : 0)];
    dict[@"alarmID"]      = [NSString stringWithFormat:@"%@", options[@"id"] ?: options[@"alarmID"] ?: @1];
    dict[@"repeatState"]  = [NSString stringWithFormat:@"%@", options[@"repeat"] ?: @0];
    dict[@"alarmScene"]   = @"0";
    dict[@"alarmDate"]    = @"0000-00-00";
    VPDeviceNewAlarmModel *m = [[VPDeviceNewAlarmModel alloc] initWithAlarmDict:dict];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceNewAlarmWithNewAlarmModel:m settingMode:1 successResult:^(NSArray *alarmArray) {
        [self sendEvent:@"newAlarm" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"newAlarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置/新增文字闹钟。options: { hour, minute, repeat?, enable?, id?, content }
 iOS SDK：veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:settingMode:successResult:failureResult:
          （settingMode=VPDeviceTextAlarmSettingModelAddOrChange(2)；alarmText 最长 60 字节）
 Android：addTextAlarm(...)；JS：joemeWatch.setTextAlarm(model)
 事件：on('textAlarm') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setTextAlarm:callback:))
- (void)setTextAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"alarmHour"]    = [NSString stringWithFormat:@"%@", options[@"hour"] ?: @0];
    dict[@"alarmMinute"]  = [NSString stringWithFormat:@"%@", options[@"minute"] ?: @0];
    dict[@"alarmState"]   = [NSString stringWithFormat:@"%lu", (unsigned long)([options[@"enable"] boolValue] ? 1 : 0)];
    dict[@"alarmID"]      = [NSString stringWithFormat:@"%@", options[@"id"] ?: options[@"alarmID"] ?: @1];
    dict[@"repeatState"]  = [NSString stringWithFormat:@"%@", options[@"repeat"] ?: @0];
    dict[@"alarmText"]    = options[@"content"] ?: @"";
    dict[@"alarmDate"]    = @"0000-00-00";
    VPDeviceTextAlarmModel *m = [[VPDeviceTextAlarmModel alloc] initWithAlarmDict:dict];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:m settingMode:VPDeviceTextAlarmSettingModelAddOrChange successResult:^(NSArray *alarmArray) {
        [self sendEvent:@"textAlarm" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"textAlarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取世界时钟。一次性读取：callback 与事件都带 list。
 iOS SDK：veepooSDKWorldClockReadWithModels:result:（models 传本地缓存，首次传 @[]）
          VPWorldClockModel：dataID(1-10)、cityName、standardTimeZoneDiffer(相对 GMT 的 15 分钟数)
 Android：readWorldClock(...)；JS：joemeWatch.readWorldClock() -> resolve { list, count }
 事件：on('worldClock') -> { list, count }
 */
UNI_EXPORT_METHOD(@selector(readWorldClock:callback:))
- (void)readWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockReadWithModels:@[] result:^(BOOL success, NSArray<VPWorldClockModel *> *models) {
        NSMutableArray *list = [NSMutableArray array];
        for (VPWorldClockModel *wc in models) {
            [list addObject:@{
                @"id": @(wc.dataID),
                @"timeZone": wc.standardTimeZoneDiffer ?: @0,
                @"timeZoneName": wc.cityName ?: @"",
                // iOS 模型没有「时区名称」字段，保持空串与 Android 字段对齐
                @"genericTimeZoneName": @"",
                @"open": @YES
            }];
        }
        NSDictionary *d = @{ @"list": list, @"count": @(list.count) };
        [self sendEvent:@"worldClock" data:d];
        NSMutableDictionary *res = [resultWithCode(success ? 200 : -1) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    }];
}

/**
 新增世界时钟。options: { timeZone | offset, timeZoneName | city, id? }
 iOS SDK：veepooSDKWorldClockAddWithModel:result:
 Android：addWorldClock(...)；JS：joemeWatch.addWorldClock({...})
 事件：on('worldClockOp') -> { ok, op:'add', id }
 id 不传时由 iOS 侧不写 dataID（0），由设备分配；Android 侧会补最小空闲 id。
 */
UNI_EXPORT_METHOD(@selector(addWorldClock:callback:))
- (void)addWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPWorldClockModel *m = [[VPWorldClockModel alloc] init];
    m.cityName = options[@"timeZoneName"] ?: options[@"city"] ?: @"";
    m.dataID = [options[@"id"] unsignedCharValue];
    m.standardTimeZoneDiffer = options[@"timeZone"] ?: options[@"offset"] ?: @0;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockAddWithModel:m result:^(BOOL success) {
        [self sendEvent:@"worldClockOp" data:@{ @"ok": @(success), @"op": @"add", @"id": @(m.dataID) }];
        callback(resultWithCode(success ? 200 : -1), NO);
    }];
}

/**
 删除世界时钟。options: { id }（dataID，1 起）。
 iOS SDK：veepooSDKWorldClockDeleteWithID:result:
 Android：deleteWorldClock(...)；JS：joemeWatch.deleteWorldClock({ id })
 事件：on('worldClockOp') -> { ok, op:'delete', id }
 */
UNI_EXPORT_METHOD(@selector(deleteWorldClock:callback:))
- (void)deleteWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    uint8_t delID = [options[@"id"] unsignedCharValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockDeleteWithID:delID result:^(BOOL success) {
        [self sendEvent:@"worldClockOp" data:@{ @"ok": @(success), @"op": @"delete", @"id": @(delID) }];
        callback(resultWithCode(success ? 200 : -1), NO);
    }];
}

/**
 清空世界时钟。iOS SDK 没有「批量删除」接口，这里按 options.list 逐条删除。
 options: { list: [{ id }] }（不传时返回 -1，由页面先 readWorldClock 再传回来）
 Android：clearWorldClocks(...)；JS：joemeWatch.clearWorldClocks()
 事件：on('worldClockOp') -> { ok, op:'deleteAll', count }
 */
UNI_EXPORT_METHOD(@selector(clearWorldClocks:callback:))
- (void)clearWorldClocks:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSArray *list = options[@"list"];
    if (![list isKindOfClass:[NSArray class]] || list.count == 0) {
        callback(resultWithCode(-1), NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __block NSInteger remain = list.count;
    __block BOOL allOk = YES;
    for (NSDictionary *item in list) {
        uint8_t delID = [item[@"id"] unsignedCharValue];
        [pm veepooSDKWorldClockDeleteWithID:delID result:^(BOOL success) {
            if (!success) allOk = NO;
            remain--;
            if (remain <= 0) {
                [self sendEvent:@"worldClockOp" data:@{
                    @"ok": @(allOk), @"op": @"deleteAll", @"count": @(list.count)
                }];
                callback(resultWithCode(allOk ? 200 : -1), NO);
            }
        }];
    }
}

/**
 调整世界时钟顺序。
 options: { from, to } 1-based（同 Android）或 { fromIndex, toIndex } 0-based。
 iOS SDK：veepooSDKWorldClockAdjustOrderFromArrIndex:toArrIndex:result:（内部按 0-based 数组下标）
 Android：moveWorldClock(...)；JS：joemeWatch.moveWorldClock({...})
 事件：on('worldClockOp') -> { ok, op:'move' }
 */
UNI_EXPORT_METHOD(@selector(moveWorldClock:callback:))
- (void)moveWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger from = options[@"from"] ? [options[@"from"] integerValue]
                                     : [options[@"fromIndex"] integerValue];
    NSInteger to = options[@"to"] ? [options[@"to"] integerValue]
                                  : [options[@"toIndex"] integerValue];
    // from/to 传的是 1-based 时转成 0-based；fromIndex/toIndex 已经是 0-based
    if (options[@"from"] || options[@"to"]) {
        if (from > 0) from -= 1;
        if (to > 0) to -= 1;
    }
    if (from < 0 || to < 0) {
        callback(resultWithCode(-1), NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockAdjustOrderFromArrIndex:(uint8_t)from
                                        toArrIndex:(uint8_t)to
                                            result:^(BOOL success) {
        [self sendEvent:@"worldClockOp" data:@{ @"ok": @(success), @"op": @"move" }];
        callback(resultWithCode(success ? 200 : -1), NO);
    }];
}

// ---------- 4. 屏幕与显示（screen） ----------

/**
 设置屏幕亮度。options: { brightness, isAutomatic, firstStart?, firstEnd?, otherValue? }
 iOS SDK：veepooSDKSettingBrightWithBrightModel:settingMode:successResult:failureResult:（settingMode 1=设置）
          模型 VPDeviceBrightModel initWithStartHour:startMinute:endHour:endMinute:firstBrightValue:otherBrightValue:
 Android：settingScreenLight(...)；JS：joemeWatch.setBright({...})
 事件：on('screenLight') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setBright:callback:))
- (void)setBright:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger brightness = [options[@"brightness"] integerValue];
    BOOL automatic = [options[@"isAutomatic"] boolValue];
    NSInteger firstStartH = [options[@"firstStart"] integerValue] ?: 22;
    NSInteger firstEndH   = [options[@"firstEnd"] integerValue] ?: 8;
    NSInteger otherValue  = [options[@"otherValue"] integerValue] ?: brightness;
    VPDeviceBrightModel *m = [[VPDeviceBrightModel alloc] initWithStartHour:firstStartH startMinute:0 endHour:firstEndH endMinute:0 firstBrightValue:brightness otherBrightValue:otherValue];
    m.isAutomatic = automatic;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingBrightWithBrightModel:m settingMode:1 successResult:^(VPDeviceBrightModel *bm) {
        [self sendEvent:@"screenLight" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"screenLight" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置亮屏时长。options: { sec }（秒）。
 iOS SDK：veepooSDKSettingScreenDuration:settingMode:successResult:failureResult:
          （VPScreenDurationModel.currentDuration；settingMode 1=设置）
 Android：setScreenLightTime(..., int)；JS：joemeWatch.setScreenDuration(sec)
 事件：on('screenDuration') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setScreenDuration:callback:))
- (void)setScreenDuration:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger sec = [options[@"sec"] integerValue];
    VPScreenDurationModel *m = [[VPScreenDurationModel alloc] init];
    m.currentDuration = sec;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingScreenDuration:m settingMode:1 successResult:^(VPScreenDurationModel *dm) {
        [self sendEvent:@"screenDuration" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"screenDuration" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置屏幕样式（表盘位置）。options: { style: int }（区间 1 ~ peripheralModel.screenTypes）。
 iOS SDK：veepooSDKSettingDeviceScreenStyle:settingMode:dialType:result:（非废弃版本）
 Android：settingScreenStyle(..., int)；JS：joemeWatch.setScreenStyle(style)
 事件：on('screenStyle') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setScreenStyle:callback:))
- (void)setScreenStyle:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    int style = [options[@"style"] intValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceScreenStyle:style settingMode:1 dialType:VPDeviceDialTypeDefault result:^(VPDeviceDialType dt, int screenStyle, BOOL settingSuccess) {
        [self sendEvent:@"screenStyle" data:@{ @"ok": @(settingSuccess) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置翻腕亮屏。options: { on, startHour?, startMinute?, endHour?, endMinute? }
 iOS SDK：veepooSDKSettingRaiseHandWithRaiseHandModel:settingMode:successResult:failureResult:
          （settingMode 0=关 1=开；raiseHandState 0/1）
 Android：settingNightTurnWriste(...)；JS：joemeWatch.setRaiseHand({...})
 事件：on('raiseHand') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setRaiseHand:callback:))
- (void)setRaiseHand:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    NSUInteger startH = [options[@"startHour"] unsignedIntegerValue];
    NSUInteger startM = [options[@"startMinute"] unsignedIntegerValue];
    NSUInteger endH = [options[@"endHour"] unsignedIntegerValue] ?: 23;
    NSUInteger endM = [options[@"endMinute"] unsignedIntegerValue];
    VPDeviceRaiseHandModel *m = [[VPDeviceRaiseHandModel alloc] initWithRaiseHandStartHour:startH raiseHandStartMinute:startM raiseHandEndHour:endH raiseHandEndMinute:endM raiseHandState:(on ? 1 : 0) raiseHandSensitive:0];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingRaiseHandWithRaiseHandModel:m settingMode:(on ? 1 : 0) successResult:^(VPDeviceRaiseHandModel *rm) {
        [self sendEvent:@"raiseHand" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"raiseHand" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置常灭屏（ZT163 定制）。options: { on: bool }。
 iOS SDK：veepooSDK_ZT163SetDeviceAlwaysOffScreen:andResult:
 Android：setZT163DeviceAlwaysOffScreen(...)；JS：joemeWatch.setAlwaysOffScreen(on)
 事件：on('alwaysOffScreen') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setAlwaysOffScreen:callback:))
- (void)setAlwaysOffScreen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_ZT163SetDeviceAlwaysOffScreen:on andResult:^(BOOL success) {
        [self sendEvent:@"alwaysOffScreen" data:@{ @"ok": @(success) }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 5. 通知 / 社交 / 消息（notify） ----------

/**
 JS 消息类型 key -> iOS 枚举。
 与 Android applySocialMsgType 的 key 集合保持一致（页面只认一套 key）。
 iOS 没有 zalo / viber / flickr 的独立枚举（SDK 版本差异），这几个 key 直接忽略并由调用方收到 ok=NO。
 */
static BOOL JoemeMessageTypeFromKey(NSString *type, VPSettingMessageSwitchType *out) {
    if (![type isKindOfClass:[NSString class]]) return NO;
    if ([type isEqualToString:@"call"] || [type isEqualToString:@"phone"]) { *out = VPSettingCall; return YES; }
    if ([type isEqualToString:@"sms"] || [type isEqualToString:@"msg"]) { *out = VPSettingSMS; return YES; }
    if ([type isEqualToString:@"wechat"]) { *out = VPSettingWechat; return YES; }
    if ([type isEqualToString:@"qq"]) { *out = VPSettingQQ; return YES; }
    if ([type isEqualToString:@"sina"]) { *out = VPSettingSina; return YES; }
    if ([type isEqualToString:@"facebook"]) { *out = VPSettingFaceBook; return YES; }
    if ([type isEqualToString:@"twitter"]) { *out = VPSettingTwitter; return YES; }
    if ([type isEqualToString:@"flickr"]) { *out = VPSettingFlickr; return YES; }
    if ([type isEqualToString:@"linkin"] || [type isEqualToString:@"linkedin"]) { *out = VPSettingLinkedln; return YES; }
    if ([type isEqualToString:@"whatsapp"] || [type isEqualToString:@"whats"]) { *out = VPSettingwhatsapp; return YES; }
    if ([type isEqualToString:@"line"]) { *out = VPSettingLine; return YES; }
    if ([type isEqualToString:@"instagram"]) { *out = VPSettingInstagram; return YES; }
    if ([type isEqualToString:@"snapchat"]) { *out = VPSettingSnapchat; return YES; }
    if ([type isEqualToString:@"skype"]) { *out = VPSettingSkype; return YES; }
    if ([type isEqualToString:@"gmail"]) { *out = VPSettingGMail; return YES; }
    if ([type isEqualToString:@"dingding"] || [type isEqualToString:@"dingtalk"]) { *out = VPSettingDingTalk; return YES; }
    if ([type isEqualToString:@"wxwork"]) { *out = VPSettingWeChatWork; return YES; }
    if ([type isEqualToString:@"other"]) { *out = VPSettingOtherPlatform; return YES; }
    if ([type isEqualToString:@"tiktok"]) { *out = VPSettingOtherTikTok; return YES; }
    if ([type isEqualToString:@"telegram"]) { *out = VPSettingOtherTelegram; return YES; }
    if ([type isEqualToString:@"connected2"] || [type isEqualToString:@"connected2_me"]) { *out = VPSettingOtherConnected2; return YES; }
    if ([type isEqualToString:@"kakao"] || [type isEqualToString:@"kakaotalk"]) { *out = VPSettingKakaoTalk; return YES; }
    if ([type isEqualToString:@"shieldPolice"] || [type isEqualToString:@"shield_police"]) { *out = VPSettingJingYou; return YES; }
    if ([type isEqualToString:@"messenger"]) { *out = VPSettingMessenger; return YES; }
    return NO;
}

/** 单个字节（0=不支持 1=开启 2=关闭）转状态名，与 Android 的 EFunctionStatus 名对齐 */
static NSString *JoemeStatusName(uint8_t v) {
    switch (v) {
        case 1: return @"SUPPORT_OPEN";
        case 2: return @"SUPPORT_CLOSE";
        case 0:
        default: return @"UNSUPPORT";
    }
}

/**
 从 peripheralModel.deviceAncsData / deviceAncsDataTwo 解析开关整包。
 头文件写明的布局（下标 2 起）：
   包1：来电、短信、wechat、QQ、Sina、Facebook、Twitter、Flickr、LinkedIn、whatsApp、
         Line、Instagram、Snapchat、Skype、钉钉、企业微信；下标 19 低 4 位 = 其他应用
   包2：TikTok、Telegram、Connected2、…
 每字节 0=不支持 / 1=开启 / 2=关闭。
 与 Android socialMsgObj 输出同样结构：{ wechat:'SUPPORT_OPEN', wechatOpen:@YES, ... }
 */
- (NSDictionary *)socialMsgFromPeripheral {
    VPPeripheralModel *pm = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSMutableDictionary *o = [NSMutableDictionary dictionary];
    if (!pm) return o;

    uint8_t v1[32] = {0}, v2[32] = {0};
    NSData *d1 = pm.deviceAncsData;
    NSData *d2 = pm.deviceAncsDataTwo;
    if (d1.length > 2) [d1 getBytes:v1 length:MIN((NSUInteger)32, d1.length)];
    if (d2.length > 2) [d2 getBytes:v2 length:MIN((NSUInteger)32, d2.length)];

    // 下标 19 的低 4 位是「其他应用」，高 4 位是包号
    uint8_t other = (d1.length > 19) ? (v1[19] & 0x0F) : 0;

    NSArray<NSArray *> *pkt1 = @[
        @[@"call", @2], @[@"sms", @3], @[@"wechat", @4], @[@"qq", @5], @[@"sina", @6],
        @[@"facebook", @7], @[@"twitter", @8], @[@"flickr", @9], @[@"linkin", @10],
        @[@"whatsapp", @11], @[@"line", @12], @[@"instagram", @13], @[@"snapchat", @14],
        @[@"skype", @15], @[@"dingding", @16], @[@"wxwork", @17]
    ];
    for (NSArray *pair in pkt1) {
        NSString *key = pair[0];
        NSUInteger idx = [pair[1] unsignedIntegerValue];
        uint8_t v = (d1.length > idx) ? v1[idx] : 0;
        o[key] = JoemeStatusName(v);
        o[[key stringByAppendingString:@"Open"]] = @(v == 1);
    }
    o[@"other"] = JoemeStatusName(other);
    o[@"otherOpen"] = @(other == 1);

    NSArray<NSArray *> *pkt2 = @[
        @[@"tiktok", @2], @[@"telegram", @3], @[@"connected2", @4]
    ];
    for (NSArray *pair in pkt2) {
        NSString *key = pair[0];
        NSUInteger idx = [pair[1] unsignedIntegerValue];
        uint8_t v = (d2.length > idx) ? v2[idx] : 0;
        o[key] = JoemeStatusName(v);
        o[[key stringByAppendingString:@"Open"]] = @(v == 1);
    }
    // 包2 没覆盖到的类型保持「未知」，不要让页面误以为已关闭
    for (NSString *key in @[@"kakao", @"zalo", @"viber", @"shieldPolice", @"messenger", @"gmail"]) {
        if (!o[key]) {
            o[key] = @"UNKONW";
            o[[key stringByAppendingString:@"Open"]] = @NO;
        }
    }
    return o;
}

/**
 单条消息推送开关。options: { type, on }
   type: 'call' | 'sms' | 'wechat' | 'qq' | 'whatsapp' | 'line' | 'instagram' | 'other'
         | 'facebook' | 'twitter' | 'sina' | 'gmail' | 'dingding' | 'wxwork' | 'tiktok'
         | 'telegram' | 'connected2' | 'kakao' | 'messenger' | 'flickr' | 'linkin' | 'snapchat' | 'skype'
 iOS SDK：veepooSDKSettingMessageType:settingState:completeBlock:
          （VPSettingMessageSwitchType；VPSettingFunctionState 1=开 2=关）
 Android：setFunctionSocailMsgData + settingSocialMsg；JS：joemeWatch.setMessageType(type, on)
 事件：on('messageType') -> { ok, ...整包开关 }
 */
UNI_EXPORT_METHOD(@selector(setMessageType:callback:))
- (void)setMessageType:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *type = options[@"type"];
    BOOL on = [options[@"on"] boolValue];
    VPSettingMessageSwitchType mt = VPSettingCall;
    if (!JoemeMessageTypeFromKey(type, &mt)) {
        callback(@{ @"code": @(-1), @"message": [NSString stringWithFormat:@"不支持的消息类型：%@", type ?: @""] }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingMessageType:mt settingState:(on ? VPSettingFunctionOpen : VPSettingFunctionClose) completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(ok);
        // 设置完成后回读整包：iOS 的 ANCS 快照由 SDK 在回包时刷新，
        // 这样页面不必再发一轮 readSocialMsg
        [d addEntriesFromDictionary:[self socialMsgFromPeripheral]];
        [self sendEvent:@"messageType" data:d];
        callback(resultWithCode(200), NO);
    }];
}

/**
 批量消息推送开关。
 兼容两种入参：
   { data:  { wechat:true, qq:false } }   —— 与 Android / JS setSocialMsg 一致
   { items: [ { type, on }, ... ] }       —— 旧调用方式
 iOS SDK：veepooSDKSettingMessageWithData: 入参为预编码 NSData（格式不公开），
          这里改用同模块类型安全的批量接口 veepooSDKBatchSettingWithMessageTypeModels:completeBlock:
          （VPDeviceMessageTypeModel.messageType/open），语义等价。
 Android：settingSocialMsg(..., FunctionSocailMsgData)；JS：joemeWatch.setSocialMsg(data)
 事件：on('socialMsg') -> { ok, ...整包开关 }
 */
UNI_EXPORT_METHOD(@selector(setSocialMsg:callback:))
- (void)setSocialMsg:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSMutableArray<VPDeviceMessageTypeModel *> *models = [NSMutableArray array];

    id data = options[@"data"];
    if ([data isKindOfClass:[NSDictionary class]]) {
        [(NSDictionary *)data enumerateKeysAndObjectsUsingBlock:^(id key, id val, BOOL *stop) {
            VPSettingMessageSwitchType mt;
            if (!JoemeMessageTypeFromKey(key, &mt)) return;
            VPDeviceMessageTypeModel *m = [[VPDeviceMessageTypeModel alloc] init];
            m.messageType = mt;
            m.open = [val boolValue];
            [models addObject:m];
        }];
    }

    NSArray *items = options[@"items"];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            VPSettingMessageSwitchType mt;
            if (!JoemeMessageTypeFromKey(it[@"type"], &mt)) continue;
            VPDeviceMessageTypeModel *m = [[VPDeviceMessageTypeModel alloc] init];
            m.messageType = mt;
            m.open = [it[@"on"] boolValue];
            [models addObject:m];
        }
    }

    if (models.count == 0) {
        callback(@{ @"code": @(-1), @"message": @"没有可下发的消息类型" }, NO);
        return;
    }

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKBatchSettingWithMessageTypeModels:models completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(ok);
        [d addEntriesFromDictionary:[self socialMsgFromPeripheral]];
        [self sendEvent:@"socialMsg" data:d];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取消息推送开关。
 iOS 没有「主动读」接口：开关随验密一起下发（deviceAncsData / deviceAncsDataTwo），
 所以这里直接回最近的快照，并补发一次 socialMsg 事件，保证页面拿到完整结构。
 JS: joemeWatch.readSocialMsg()
 */
UNI_EXPORT_METHOD(@selector(readSocialMsg:callback:))
- (void)readSocialMsg:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSDictionary *d = [self socialMsgFromPeripheral];
    [self sendEvent:@"socialMsg" data:d];
    NSMutableDictionary *r = [NSMutableDictionary dictionaryWithDictionary:d];
    r[@"code"] = @200;
    r[@"cached"] = @YES;
    callback(r, NO);
}

/**
 基础功能开关。options: { type, on }
   type: 'raiseHand' | 'lose' | 'wearDetect' | 'metric' | 'timeFormat' | 'autoHeart' | 'autoBp'
         | 'disconnectRemind' | 'autoOxygen'
 iOS SDK：veepooSDKSettingBaseFunctionType:settingState:completeBlock:
 Android：setFunSwitchState(int, EFunctionStatus)；JS：joemeWatch.setBaseFunction({...})
 事件：on('baseFunction') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setBaseFunction:callback:))
- (void)setBaseFunction:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *type = options[@"type"];
    BOOL on = [options[@"on"] boolValue];
    VPSettingBaseFunctionSwitchType bt = VPSettingRaiseHand;
    if ([type isEqualToString:@"raiseHand"]) bt = VPSettingRaiseHand;
    else if ([type isEqualToString:@"lose"]) bt = VPSettingDeviceLose;
    else if ([type isEqualToString:@"wearDetect"]) bt = VPSettingWearDetection;
    else if ([type isEqualToString:@"metric"]) bt = VPSettingMetric;
    else if ([type isEqualToString:@"timeFormat"]) bt = VPSettingTimeFormat;
    else if ([type isEqualToString:@"autoHeart"]) bt = VPSettingAutomaticHRTest;
    else if ([type isEqualToString:@"autoBp"]) bt = VPSettingAutomaticBPTest;
    else if ([type isEqualToString:@"disconnectRemind"]) bt = VPSettingDisconnectRemind;
    else if ([type isEqualToString:@"autoOxygen"]) bt = VPSettingAutomaticOxygenTest;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingBaseFunctionType:bt settingState:(on ? VPSettingFunctionOpen : VPSettingFunctionClose) completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        [self sendEvent:@"baseFunction" data:@{ @"ok": @(ok) }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 6. 通讯录 / SOS（contact） ----------

/**
 读取通讯录。一次性读取：callback 与事件都带 list。
 iOS SDK：veepooSDKSettingDeviceContactsWithOpCode:opModel:toID:resultBlock:（opCode=Read(0)）
          VPDeviceContactsModel：contactID / nickName(≤20字节) / phoneNumber / isSOS
 Android：readContact(...)；JS：joemeWatch.readContact() -> resolve { list }
 事件：on('contact') -> { list }
 */
UNI_EXPORT_METHOD(@selector(readContact:callback:))
- (void)readContact:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeRead opModel:nil toID:0 resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
        NSMutableArray *list = [NSMutableArray array];
        for (VPDeviceContactsModel *c in contactModels) {
            [list addObject:@{
                // Android 侧字段名（contactID / settingSOS）为主，id / isSOS 保留给老调用方
                @"contactID": @(c.contactID),
                @"id": @(c.contactID),
                @"name": c.nickName ?: @"",
                @"phone": c.phoneNumber ?: @"",
                @"settingSOS": @(c.isSOS),
                @"isSOS": @(c.isSOS),
                @"supportSOS": @(YES)
            }];
        }
        NSDictionary *d = @{ @"list": list };
        [self sendEvent:@"contact" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    }];
}

/**
 新增通讯录。options: { name, phone, isSOS? }。
 iOS SDK：veepooSDKSettingDeviceContactsWithOpCode:...（opCode=Add(1)）
 Android：addContact(...)；JS：joemeWatch.addContact({...})
 事件：on('contactOp') -> { ok, op:'add' }
 */
UNI_EXPORT_METHOD(@selector(addContact:callback:))
- (void)addContact:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceContactsModel *m = [[VPDeviceContactsModel alloc] init];
    m.contactID = [options[@"contactID"] intValue];
    m.nickName = options[@"name"] ?: @"";
    m.phoneNumber = options[@"phone"] ?: @"";
    // Android 用 settingSOS，iOS 老调用方用 isSOS；两个都认
    m.isSOS = options[@"settingSOS"] ? [options[@"settingSOS"] boolValue] : [options[@"isSOS"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeAdd opModel:m toID:0 resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
        [self sendEvent:@"contactOp" data:@{ @"ok": @(state == VPDeviceContactsOpStateComplete), @"op": @"add" }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 删除通讯录。options: { id, name?, phone? }。
 iOS SDK：veepooSDKSettingDeviceContactsWithOpCode:...（opCode=Delete(2)）
 Android：deleteContact(...)；JS：joemeWatch.deleteContact({ id })
 事件：on('contactOp') -> { ok, op:'delete' }
 */
UNI_EXPORT_METHOD(@selector(deleteContact:callback:))
- (void)deleteContact:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceContactsModel *m = [[VPDeviceContactsModel alloc] init];
    // Android 用 contactID，iOS 老调用方用 id
    m.contactID = options[@"contactID"] ? [options[@"contactID"] intValue] : [options[@"id"] intValue];
    m.nickName = options[@"name"] ?: @"";
    m.phoneNumber = options[@"phone"] ?: @"";
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeDelete opModel:m toID:0 resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
        [self sendEvent:@"contactOp" data:@{ @"ok": @(state == VPDeviceContactsOpStateComplete), @"op": @"delete" }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置 SOS。options 二选一：
   - { callTimes: int }：设置 SOS 呼叫次数（veepooSDKSettingDeviceContactsSOSInfoWithOpCode:times:）
   - { id, name?, phone?, on }：设置某联系人是否为 SOS（通讯录 opCode=Edit，头文件注释即"操作是否开启SOS"）
 iOS SDK：veepooSDKSettingDeviceContactsSOSInfoWithOpCode:times:resultBlock: / veepooSDKSettingDeviceContactsWithOpCode:...(Edit)
 Android：setContactSOSState + setSOSCallTimes；JS：joemeWatch.setSOS({...})
 事件：on('sos') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setSOS:callback:))
- (void)setSOS:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (options[@"callTimes"]) {
        int times = [options[@"callTimes"] intValue];
        [pm veepooSDKSettingDeviceContactsSOSInfoWithOpCode:VPSOSOperationTypeSetting times:times resultBlock:^(VPDeviceContactsOpState state, int t, int timesMin, int timesMax) {
            BOOL ok = state == VPDeviceContactsOpStateComplete;
            [self sendEvent:@"sosCallTimes" data:@{ @"ok": @(ok), @"times": @(t) }];
            NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
            r[@"times"] = @(t);
            callback(r, NO);
        }];
    } else {
        VPDeviceContactsModel *m = [[VPDeviceContactsModel alloc] init];
        m.contactID = options[@"contactID"] ? [options[@"contactID"] intValue] : [options[@"id"] intValue];
        m.nickName = options[@"name"] ?: @"";
        m.phoneNumber = options[@"phone"] ?: @"";
        m.isSOS = [options[@"on"] boolValue];
        [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeEdit opModel:m toID:0 resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
            [self sendEvent:@"sos" data:@{ @"ok": @(state == VPDeviceContactsOpStateComplete), @"op": @"sos" }];
            callback(resultWithCode(200), NO);
        }];
    }
}

// ---------- 6b. 经典蓝牙（BT 通话通道） ----------

/**
 读取经典蓝牙状态。
 iOS SDK：无独立读取接口，状态由 VPBTConnectStateChangeBlock 持续上报并被本模块缓存
 JS：joemeWatch.readBTInfo() -> resolve { state, connected, btOpen, audioOpen }
 事件：on('btInfo')
 */
UNI_EXPORT_METHOD(@selector(readBTInfo:callback:))
- (void)readBTInfo:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSDictionary *d = self.lastBTInfo ?: @{
        @"state": @"disconnected", @"connected": @NO,
        @"status": @"DISCONNECTED", @"btOpen": @NO, @"audioOpen": @NO
    };
    [self sendEvent:@"btInfo" data:d];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    [r addEntriesFromDictionary:d];
    callback(r, NO);
}

/**
 设置经典蓝牙开关。
 iOS SDK：veepooSDK_openDeviceBTSwitch（只有「打开」一条命令，没有关闭/多媒体开关接口）
 JS：joemeWatch.setBTStatus({ btOpen }) / joemeWatch.connectBT({ on })
 事件：on('btInfo')（状态仍以 VPBTConnectStateChangeBlock 上报为准）
 差异：iOS 无 setBTStatus / connectBT(mac) / disconnectBT；关闭只能由用户在系统蓝牙里操作。
 */
UNI_EXPORT_METHOD(@selector(setBTStatus:callback:))
- (void)setBTStatus:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"btOpen"] ? [options[@"btOpen"] boolValue] : YES;
    if (on) {
        [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_openDeviceBTSwitch];
    }
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"sent"] = @(on);
    r[@"ok"] = @(YES);
    callback(r, NO);
}

/**
 连接经典蓝牙。
 iOS SDK：veepooSDK_openDeviceBTSwitch（开启开关即可触发系统配对）
 JS：joemeWatch.connectBT({ on })
 事件：on('btStatus')
 差异：iOS 无按 mac 连接/断开的接口，on=false 时不做任何事（返回 sent:false）。
 */
UNI_EXPORT_METHOD(@selector(connectBT:callback:))
- (void)connectBT:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options && options[@"on"] ? [options[@"on"] boolValue] : YES;
    if (on) {
        [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_openDeviceBTSwitch];
    }
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"sent"] = @(on);
    callback(r, NO);
}

// ---------- 7. 相机遥控（camera） ----------

/**
 查询设备是否支持相机遥控。
 iOS SDK 没有 Android 侧 FunctionCheckUtil.checkCamera() 那样的能力位查询接口，
 故 iOS 侧不做前置判定（返回 supported:true），是否可用由 veepooSDKSettingCameraType
 的实际回调决定，避免误判把入口置灰。
 Android：VPOperateManager.getFunctionCheck().checkCamera()
 JS：joemeWatch.isCameraSupported()
 返回：{ code, supported }
 */
UNI_EXPORT_METHOD(@selector(isCameraSupported:callback:))
- (void)isCameraSupported:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 注册常驻相机监听（不下发任何指令）。
 iOS SDK 没有独立的 setCameraListener：拍照回调必须随 veepooSDKSettingCameraType 一起注册，
 所以「手表自己进拍照页唤醒 App」在 iOS 上不成立，只能由 App 先发 Enter。
 此方法在 iOS 上等价于空操作，只为与 Android 保持 JS 接口一致。
 Android：setCameraListener（只占监听槽位，不写 0xB6）
 JS：joemeWatch.listenCamera()
 返回：{ code, supported }
 */
UNI_EXPORT_METHOD(@selector(listenCamera:callback:))
- (void)listenCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 静默拍照。
 本插件 iOS 端未实现无界面拍照（需 AVCapturePhotoOutput），直接回 -2 让 JS 回退到
 uni.chooseImage / plus.camera，避免调用方以为拍到了但其实没有。
 Android：Camera2 静默拍照 + 写入相册
 JS：joemeWatch.capturePhoto()
 返回：{ code: -2, message }
 */
UNI_EXPORT_METHOD(@selector(capturePhoto:callback:))
- (void)capturePhoto:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(-2) mutableCopy];
    r[@"message"] = @"iOS 端不支持静默拍照，请使用系统相机";
    callback(r, NO);
}

/**
 进入相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:settingAndMonitorResult:（VPCameraTypeEnter=1）
          回调里 VPCameraTypePhoto(2) 表示用户按下拍照，App 应据此调用系统相机拍照。
 Android：startCamera(...)；JS：joemeWatch.startCamera()
 事件：on('camera') -> { state, deviceInitiated }
 说明：iOS 的 VPCameraType 只有 Exit/Enter/Photo，没有「设备主动进入」语义，
       deviceInitiated 恒为 false。
 */
UNI_EXPORT_METHOD(@selector(startCamera:callback:))
- (void)startCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingCameraType:VPCameraTypeEnter settingAndMonitorResult:^(VPCameraType cameraType) {
        [weakSelf sendEvent:@"camera" data:@{ @"state": @(cameraType), @"deviceInitiated": @NO }];
    }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 退出相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:...（VPCameraTypeExit=0）
 Android：stopCamera(...)；JS：joemeWatch.stopCamera()
 事件：on('camera') -> { state, deviceInitiated }
 */
UNI_EXPORT_METHOD(@selector(stopCamera:callback:))
- (void)stopCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSettingCameraType:VPCameraTypeExit settingAndMonitorResult:^(VPCameraType cameraType) {}];
    [self sendEvent:@"camera" data:@{ @"state": @(VPCameraTypeExit), @"deviceInitiated": @NO }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

// ---------- 8. 查找设备 / 防丢（find） ----------

/**
 手机查找手环（手环响铃/震动）。options: { on: bool }。
 iOS SDK：veepooSDK_searchDeviceFuntionWithState:result:
 Android：settingFindDevice(..., boolean)；JS：joemeWatch.findDevice(on)
 事件：on('findDevice') -> { ok, open }
 */
UNI_EXPORT_METHOD(@selector(findDevice:callback:))
- (void)findDevice:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_searchDeviceFuntionWithState:on result:^(BOOL open, VPSearchDeviceFunctionState state) {
        [self sendEvent:@"findDevice" data:@{ @"ok": @(state == VPSearchDeviceFunctionStateEnter), @"open": @(open) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设备查找手机（让手机响铃）。
 iOS SDK：veepooSDKSettingDeviceExitSearchPhone（裸声明、无回执，同 powerOff 处理）
 Android：start/stopFindDeviceByPhone；JS：joemeWatch.findPhone(on)
 事件：on('findPhone') -> { ok:false, sent:true }（sent 仅表示命令已下发）
 */
UNI_EXPORT_METHOD(@selector(findPhone:callback:))
- (void)findPhone:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSettingDeviceExitSearchPhone];
    [self sendEvent:@"findPhone" data:@{ @"ok": @NO, @"sent": @YES }];
    callback(resultWithCode(200), NO);
}

// ---------- 9. 运动模式（sport） ----------

/**
 开始运动。options: { runMode? }（runMode 取 VPDeviceRuningMode 数值，0=普通单运动）。
 iOS SDK：veepooSDKSettingDeviceRunning:runMode:result:（settingType 1=开启）
 Android：startSportModel / startMultSportModel；JS：joemeWatch.startSport(mode)
 事件：on('sport') -> { state, ok }
 */
UNI_EXPORT_METHOD(@selector(startSport:callback:))
- (void)startSport:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceRuningMode runMode = VPDeviceRuningModeCommon;
    if (options[@"runMode"]) runMode = (VPDeviceRuningMode)[options[@"runMode"] integerValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceRunning:1 runMode:runMode result:^(int runningType, BOOL settingSuccess) {
        [self sendEvent:@"sport" data:@{ @"state": @(runningType), @"ok": @(settingSuccess) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 停止运动。iOS 无独立 stop 接口：start 接口传 0（settingType=0）。
 iOS SDK：veepooSDKSettingDeviceRunning:runMode:result:（settingType 0=关闭）
 Android：stopSportModel(...)；JS：joemeWatch.stopSport()
 事件：on('sport') -> { state }
 */
UNI_EXPORT_METHOD(@selector(stopSport:callback:))
- (void)stopSport:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSettingDeviceRunning:0 runMode:VPDeviceRuningModeCommon result:^(int runningType, BOOL settingSuccess) {
        [self sendEvent:@"sport" data:@{ @"state": @(runningType) }];
    }];
    callback(resultWithCode(200), NO);
}

/**
 运动过程控制（暂停/继续/停止）。options: { code: 'pause'|'resume'|'stop', type? }
 iOS SDK：veepooSDK_deviceSportControlWithCode:type:
          （VPDeviceSportControlOpCode：1=Start 2=Pause 3=Continue 4=Stop；type=VPDeviceRuningMode）
 Android：setSportControlInfo(...)；JS：joemeWatch.sportControl({...})
 事件：on('sportControl') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(sportControl:callback:))
- (void)sportControl:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *code = options[@"code"];
    VPDeviceSportControlOpCode oc = VPDeviceSportControlOpCodeStart;
    if ([code isEqualToString:@"pause"]) oc = VPDeviceSportControlOpCodePause;
    else if ([code isEqualToString:@"resume"]) oc = VPDeviceSportControlOpCodeContinue;
    else if ([code isEqualToString:@"stop"]) oc = VPDeviceSportControlOpCodeStop;
    VPDeviceRuningMode type = (VPDeviceRuningMode)[options[@"type"] integerValue];
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_deviceSportControlWithCode:oc type:type];
    [self sendEvent:@"sportControl" data:@{ @"ok": @YES }];
    callback(resultWithCode(200), NO);
}

// ---------- 10. 女性健康 / 倒计时（female） ----------

/**
 设置女性健康。options: { femaleState?, lastMenstrualDate?, menstrualCircle?, menstrualDays?,
                        expectedDateOfChildbirth?, babyBirthday?, isGirl?, on }
   femaleState: 'menstrual'|'pregnancy'|'gestation'|'baoma'|none
 iOS SDK：veepooSDKSettingDeviceFemaleWithFemaleModel:settingMode:successResult:failureResult:
          （settingMode 0=关 1=开；VPDeviceFemaleState 见 VPPublicDefine）
 Android：settingWomenState(...)；JS：joemeWatch.setFemale({...})
 事件：on('female') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setFemale:callback:))
- (void)setFemale:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceFemaleModel *m = [[VPDeviceFemaleModel alloc] init];
    NSString *state = options[@"femaleState"] ?: options[@"state"];
    if ([state isEqualToString:@"menstrual"]) m.femaleState = VPDeviceFemaleStateMenstrual;
    else if ([state isEqualToString:@"pregnancy"]) m.femaleState = VPDeviceFemaleStatePregnancy;
    else if ([state isEqualToString:@"gestation"]) m.femaleState = VPDeviceFemaleStateGestation;
    else if ([state isEqualToString:@"baoma"]) m.femaleState = VPDeviceFemaleStateBaoma;
    else m.femaleState = VPDeviceFemaleStateNone;
    m.lastMenstrualDate = options[@"lastMenstrualDate"] ?: @"";
    m.menstrualCircle = [options[@"menstrualCircle"] integerValue];
    m.menstrualDays = [options[@"menstrualDays"] integerValue];
    m.expectedDateOfChildbirth = options[@"expectedDateOfChildbirth"] ?: @"";
    m.babyBirthday = options[@"babyBirthday"] ?: @"";
    m.isGirl = [options[@"isGirl"] boolValue];
    NSUInteger mode = [options[@"on"] boolValue] ? 1 : 0;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceFemaleWithFemaleModel:m settingMode:mode successResult:^(VPDeviceFemaleModel *fm) {
        [self sendEvent:@"female" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"female" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置倒计时。options: { seconds?, repeatTime?, isShow?, settingOperation? }
 iOS SDK：veepooSDKSettingDeviceCountDownWithCountDownModel:settingMode:successResult:failureResult:
          （settingMode 1=设置；模型 settingOperation 0=关常驻 1=开常驻 2=立即单次）
 Android：settingCountDown(...)；JS：joemeWatch.setCountDown({...})
 事件：on('countDown') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setCountDown:callback:))
- (void)setCountDown:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceCountDownModel *m = [[VPDeviceCountDownModel alloc] init];
    m.currentCountDownTime = [options[@"seconds"] unsignedIntegerValue];
    m.repeatTime = [options[@"repeatTime"] unsignedIntegerValue];
    m.isShow = [options[@"isShow"] boolValue];
    m.settingOperation = [options[@"settingOperation"] unsignedIntegerValue] ?: 1;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceCountDownWithCountDownModel:m settingMode:1 successResult:^(VPDeviceCountDownModel *cm) {
        [self sendEvent:@"countDown" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"countDown" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 11. 心率报警 / 久坐（heart） ----------

/**
 设置心率报警。options: { high?, low?, on }（high 默认 160，low 默认 50）。
 iOS SDK：veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:settingMode:successResult:failureResult:
          （settingMode 0=关 1=开）
 Android：settingHeartWarning(...)；JS：joemeWatch.setHeartAlarm({...})
 事件：on('heartAlarm') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setHeartAlarm:callback:))
- (void)setHeartAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSUInteger high = [options[@"high"] unsignedIntegerValue] ?: 160;
    NSUInteger low = [options[@"low"] unsignedIntegerValue] ?: 50;
    BOOL on = [options[@"on"] boolValue];
    VPDeviceHeartAlarmModel *m = [[VPDeviceHeartAlarmModel alloc] initWithHeartMaxValue:high heartMinValue:low openState:on];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:m settingMode:(on ? 1 : 0) successResult:^(VPDeviceHeartAlarmModel *hm) {
        [self sendEvent:@"heartAlarm" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"heartAlarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 设置久坐提醒。options: { on, startHour?, startMinute?, endHour?, endMinute?, interval? }
 iOS SDK：veepooSDKSettingDeviceLongSeatWithLongSeatModel:settingMode:successResult:failureResult:
          （settingMode 0=关 1=开；interval 闸值分钟，区间 30~240）
 Android：settingLongSeat(...)；JS：joemeWatch.setLongSeat({...})
 事件：on('longSeat') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setLongSeat:callback:))
- (void)setLongSeat:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    NSUInteger startH = [options[@"startHour"] unsignedIntegerValue];
    NSUInteger startM = [options[@"startMinute"] unsignedIntegerValue];
    NSUInteger endH = [options[@"endHour"] unsignedIntegerValue] ?: 20;
    NSUInteger endM = [options[@"endMinute"] unsignedIntegerValue];
    NSUInteger interval = [options[@"interval"] unsignedIntegerValue] ?: 60;
    VPDeviceLongSeatModel *m = [[VPDeviceLongSeatModel alloc] initWithLongSeatStartHour:startH longSeatStartMinute:startM LongSeatEndHour:endH longSeatEndMinute:endM longSeatGateValue:interval longSeatState:(on ? 1 : 0)];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceLongSeatWithLongSeatModel:m settingMode:(on ? 1 : 0) successResult:^(VPDeviceLongSeatModel *lm) {
        [self sendEvent:@"longSeat" data:@{ @"ok": @YES }];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"longSeat" data:@{ @"ok": @NO }];
        callback(resultWithCode(200), NO);
    }];
}

// ---------- 12. 数据读取（read） ----------

/**
 读取全部健康数据（带进度，与现有 readHealthData 同底层，独立暴露）。
 iOS SDK：veepooSdkStartReadDeviceAllDataWithReadStateChangeBlock:（事件复用 healthData）
 Android：readAllHealthData(..., days)；JS：joemeWatch.readAllHealthData()
 事件：on('healthData') -> { progress } / { complete:true }；callback 仅表示已开始。
 */
UNI_EXPORT_METHOD(@selector(readAllHealthData:callback:))
- (void)readAllHealthData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSdkStartReadDeviceAllDataWithReadStateChangeBlock:^(VPReadDeviceBaseDataState state, NSUInteger totalDay, NSUInteger currentReadDayNumber, NSUInteger readCurrentDayProgress) {
        switch (state) {
            case VPReadDeviceBaseDataStart:
                [weakSelf sendEvent:@"healthData" data:@{ @"progress": @0 }];
                break;
            case VPReadDeviceBaseDataReading:
                [weakSelf sendEvent:@"healthData" data:@{ @"progress": @(readCurrentDayProgress / 100.0) }];
                break;
            case VPReadDeviceBaseDataComplete:
                [weakSelf sendEvent:@"healthData" data:@{ @"complete": @YES }];
                break;
            default:
                break;
        }
    }];
    callback(resultWithCode(200), NO);
}

/**
 读取运动模式（历史）数据，带进度。
 iOS SDK：veepooSDKStartReadDeviceRunningData:（进度）；读完后 veepooSDK_readDeviceRunningCrcResult: 拉取 CRC 列表。
          逐块详情读取为 veepooSDK_readDeviceRunningDataWithBlockNumber:result:（字典原样透传）。
 Android：readSportModelOrigin(...)；JS：joemeWatch.readDeviceRunningData()
 事件：on('runningData') -> { progress } / { complete:true } / { day:'crc', summary:[...] }；callback 仅表示已开始。
 注：逐块详情的字段结构以设备回包字典为准，透传给 JS。
 */
UNI_EXPORT_METHOD(@selector(readDeviceRunningData:callback:))
- (void)readDeviceRunningData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKStartReadDeviceRunningData:^(VPReadDeviceBaseDataState state, NSUInteger totalTimes, NSUInteger currentReadTimes, NSUInteger readCurrentTimesProgress) {
        switch (state) {
            case VPReadDeviceBaseDataStart: {
                [weakSelf sendEvent:@"runningData" data:@{ @"progress": @0 }];
                break;
            }
            case VPReadDeviceBaseDataReading: {
                [weakSelf sendEvent:@"runningData" data:@{ @"progress": @(readCurrentTimesProgress / 100.0) }];
                break;
            }
            case VPReadDeviceBaseDataComplete: {
                [weakSelf sendEvent:@"runningData" data:@{ @"complete": @YES }];
                // 读完后拉 CRC 列表（数组长度=设备存储的运动组数，值为 0 的组无数据）
                [pm veepooSDK_readDeviceRunningCrcResult:^(NSArray *crcValues) {
                    [weakSelf sendEvent:@"runningData" data:@{ @"day": @"crc", @"summary": crcValues ?: @[] }];
                }];
                break;
            }
            default:
                break;
        }
    }];
    callback(resultWithCode(200), NO);
}

/**
 读取设备身体成分历史（设备端离线存储）。
 iOS SDK：VPDataBaseOperation veepooSDKGetDeviceOffStoreBodyCompositionWithDate:andTableID: ——
          数据在连接+验密时已由 SDK 同步进本地数据库，这里按日期查库合并去重。
 Android：readBodyComponentData(...)；JS：joemeWatch.readBodyComponentData({ days } / { date })
 options：days 今天往前查的天数（默认 7，范围 1~30）；date 指定 yyyy-MM-dd 时只查该天（页面切日期用）
 事件：on('bodyComponentData') -> { list:[{ ts, date, testTime, isDeviceTest, stature, weight, gender,
        bmi, bodyFatPercentage, fatMass, leanBodyMass, muscleRate, muscleMass, subcutaneousFat,
        bodyMoisture, waterContent, skeletalMuscleRate, boneMass, proportionOfProtein,
        proteinAmount, basalMetabolicRate }] }
       字段保持 iOS 原生名（字符串数值），JS 桥 normalizeBodyComposition 会归一成 Android 字段名。
 */
UNI_EXPORT_METHOD(@selector(readBodyComponentData:callback:))
- (void)readBodyComponentData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSMutableArray *list = [NSMutableArray array];
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    dateFmt.dateFormat = @"yyyy-MM-dd";
    NSDateFormatter *fullFmt = [[NSDateFormatter alloc] init];
    fullFmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    NSString *mac = [self currentMac];
    NSMutableSet *seen = [NSMutableSet set];
    // 待查询日期列表：指定 date 只查该天；否则向前查最近 days 天
    NSArray<NSString *> *queryDates = nil;
    if (options[@"date"]) {
        queryDates = @[ options[@"date"] ];
    } else {
        NSInteger days = 7;
        if (options[@"days"]) days = [options[@"days"] integerValue];
        if (days < 1) days = 1;
        if (days > 30) days = 30;
        NSMutableArray *ds = [NSMutableArray array];
        for (NSInteger i = 0; i < days; i++) {
            [ds addObject:[dateFmt stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-i * 86400.0]]];
        }
        queryDates = ds;
    }
    for (NSString *date in queryDates) {
        NSArray<VPBodyCompositionValueModel *> *arr =
            [VPDataBaseOperation veepooSDKGetDeviceOffStoreBodyCompositionWithDate:date andTableID:mac];
        for (VPBodyCompositionValueModel *m in arr) {
            if (!m) continue;
            NSString *key = [NSString stringWithFormat:@"%@ %@", m.date ?: @"", m.testTime ?: @""];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            NSMutableDictionary *o = [NSMutableDictionary dictionary];
            o[@"date"] = m.date ?: @"";
            o[@"testTime"] = m.testTime ?: @"";
            o[@"isDeviceTest"] = @(m.isDeviceTest);
            o[@"stature"] = @(m.stature);
            o[@"weight"] = @(m.weight);
            o[@"gender"] = @(m.gender);
            o[@"bmi"] = m.bmi ?: @"";
            o[@"bodyFatPercentage"] = m.bodyFatPercentage ?: @"";
            o[@"fatMass"] = m.fatMass ?: @"";
            o[@"leanBodyMass"] = m.leanBodyMass ?: @"";
            o[@"muscleRate"] = m.muscleRate ?: @"";
            o[@"muscleMass"] = m.muscleMass ?: @"";
            o[@"subcutaneousFat"] = m.subcutaneousFat ?: @"";
            o[@"bodyMoisture"] = m.bodyMoisture ?: @"";
            o[@"waterContent"] = m.waterContent ?: @"";
            o[@"skeletalMuscleRate"] = m.skeletalMuscleRate ?: @"";
            o[@"boneMass"] = m.boneMass ?: @"";
            o[@"proportionOfProtein"] = m.proportionOfProtein ?: @"";
            o[@"proteinAmount"] = m.proteinAmount ?: @"";
            o[@"basalMetabolicRate"] = m.basalMetabolicRate ?: @"";
            NSDate *tm = [fullFmt dateFromString:[NSString stringWithFormat:@"%@ %@", m.date ?: @"", m.testTime ?: @"00:00:00"]];
            o[@"ts"] = tm ? @((long long)(tm.timeIntervalSince1970 * 1000)) : @0;
            [list addObject:o];
        }
    }
    [self sendEvent:@"bodyComponentData" data:@{ @"list": list }];
    callback(resultWithCode(200), NO);
}

/**
 读取 ECG 历史记录（仅设备端离线存储，App 手动测量的记录在 App 本地缓存，SDK 不落库）。
 对齐 Android 的 readEcgData：options { date: 'yyyy-MM-dd' } 指定日期，
  不传时按 date/days 向前查（默认今天，最多 30 天）。
 事件: on('ecgData') -> { list: [...] }，字段同测量结果 extra（ecgExtraFromModel），
  另带 recordSource:'device'。多诊断报告（VPECGTestResutHandle）只对 App 测量结果有效，
  读历史时没有对应对象，所以这里 multiDiagnosis=false。
 */
UNI_EXPORT_METHOD(@selector(readEcgData:callback:))
- (void)readEcgData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSDateFormatter *dateFmt = [[NSDateFormatter alloc] init];
    dateFmt.dateFormat = @"yyyy-MM-dd";
    NSString *mac = [self currentMac];
    NSMutableArray<NSString *> *queryDates = [NSMutableArray array];
    if (options[@"date"]) {
        [queryDates addObject:options[@"date"]];
    } else {
        NSInteger days = 1;
        if (options[@"days"]) days = [options[@"days"] integerValue];
        if (days < 1) days = 1;
        if (days > 30) days = 30;
        for (NSInteger i = 0; i < days; i++) {
            [queryDates addObject:[dateFmt stringFromDate:[NSDate dateWithTimeIntervalSinceNow:-i * 86400.0]]];
        }
    }
    NSMutableArray *list = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSString *date in queryDates) {
        NSArray<VPECGTestDataModel *> *arr =
            [VPDataBaseOperation veepooSDKGetDeviceOffStoreECGWithDate:date andTableID:mac];
        for (VPECGTestDataModel *m in arr) {
            if (!m) continue;
            NSString *key = [NSString stringWithFormat:@"%@ %@", m.date ?: @"", m.testTime ?: @""];
            if ([seen containsObject:key]) continue;
            [seen addObject:key];
            NSMutableDictionary *o = [[self ecgExtraFromModel:m] mutableCopy];
            // 历史记录里 filterSignals 是一次测量的完整波形，页面直接拿去画
            o[@"recordSource"] = @"device";
            o[@"success"] = @(m.aveHeart.integerValue > 0);
            [list addObject:o];
        }
    }
    // 按时间升序，与 Android 返回顺序一致（首页健康卡取最后一条）
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        long long ta = [a[@"ts"] longLongValue], tb = [b[@"ts"] longLongValue];
        return ta < tb ? NSOrderedAscending : (ta > tb ? NSOrderedDescending : NSOrderedSame);
    }];
    [self sendEvent:@"ecgData" data:@{ @"list": list, @"multiDiagnosis": @NO }];
    callback(resultWithCode(200), NO);
}

// ---------- 13. 可选·第三层（能桥则桥） ----------

/**
 进入 OTA 升级模式（仅进入，不做完整固件传输）。
 iOS SDK：veepooSDKSendUpdateFirmCommand:（带 block 版本）
 Android：enterOad(...)；JS：joemeWatch.enterOAD()
 事件：on('oad') -> { ok }
 注：完整固件升级需文件传输与各芯片方案支持，超出本次桥接范围。
 */
UNI_EXPORT_METHOD(@selector(enterOAD:callback:))
- (void)enterOAD:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSendUpdateFirmCommand:^(void) {
        [self sendEvent:@"oad" data:@{ @"ok": @YES }];
    }];
    callback(resultWithCode(200), NO);
}

/**
 下发 GPS 与时区。options: { lon, lat, timezone?, altitude? }（经纬度为十进制度）。
 iOS SDK：veepooSDK_setDeviceGPSAndTimezoneWithModel:result:
          （VPDeviceGPSModel：longitude/latitude 放大 100000 倍为 int；timezone 单位分钟、15 的倍数）
 Android：settingGpsLatLon(...)；JS：joemeWatch.gpsLocation({...})
 事件：on('gps') -> { ok, state }（state 0=不支持 1=成功 2=失败）
 */
UNI_EXPORT_METHOD(@selector(gpsLocation:callback:))
- (void)gpsLocation:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDeviceGPSModel *m = [[VPDeviceGPSModel alloc] init];
    m.longitude = (int)([options[@"lon"] doubleValue] * 100000);
    m.latitude  = (int)([options[@"lat"] doubleValue] * 100000);
    m.timezone  = (short)([options[@"timezone"] shortValue] ?: (8 * 60));
    m.timestamp = (long)[[NSDate date] timeIntervalSince1970];
    if (options[@"altitude"]) m.altitude = [options[@"altitude"] shortValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_setDeviceGPSAndTimezoneWithModel:m result:^(NSInteger state) {
        [self sendEvent:@"gps" data:@{ @"ok": @(state == 1), @"state": @(state) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 下发 AGPS 星历。options: { url }（rtcm 星历文件地址）。
 iOS SDK：veepooSDK_AGPSTransformWithFileUrl:timestamp:result:transformProgress:
 Android：makeDeviceIntoUpdateModeAGPS(...)；JS：joemeWatch.agps(url)
 事件：on('agps') -> { progress } / { ok, message }
 注：需设备支持 agpsFunction；时间戳取当前时间，星历文件生成时间戳待真机确认。
 */
UNI_EXPORT_METHOD(@selector(agps:callback:))
- (void)agps:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *urlStr = options[@"url"];
    if (![urlStr isKindOfClass:[NSString class]] || urlStr.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"url 不能为空" }, NO);
        return;
    }
    NSURL *fileUrl = [NSURL URLWithString:urlStr];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_AGPSTransformWithFileUrl:fileUrl timestamp:(long)[[NSDate date] timeIntervalSince1970] result:^(VPPhotoDialModel *p, VPDeviceMarketDialModel *d, NSError *error) {
        [self sendEvent:@"agps" data:@{ @"ok": @(error == nil), @"message": error.localizedDescription ?: @"" }];
        callback(resultWithCode(200), NO);
    } transformProgress:^(double progress) {
        [self sendEvent:@"agps" data:@{ @"progress": @(progress) }];
    }];
}

/**
 绑定 4G 设备账号。options: { account, password }。
 iOS SDK：veepooSDK_bind4GDeviceAccount:password:callback:
 Android：set4gServerInfo(...)；JS：joemeWatch.bind4GAccount({ account, password })
 事件：on('net4g') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(bind4GAccount:callback:))
- (void)bind4GAccount:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *account = options[@"account"];
    NSString *password = options[@"password"];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_bind4GDeviceAccount:account password:password callback:^(BOOL isSucc) {
        [self sendEvent:@"net4g" data:@{ @"ok": @(isSucc) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取当前表盘列表/信息。
 iOS SDK：veepooSDK_dialChannelWithChannelModel:dialType:photoDialModel:result:transformProgress:
          （VPDialChannelModelRead；需 JL 系设备）
 Android：listJLWatchList(...)；JS：joemeWatch.dialList() -> resolve { list }
 事件：on('dial') -> { list }
 注：返回 VPDeviceMarketDialModel.imageId（当前市场表盘图片 ID）；完整表盘下载列表需厂商联调。
 */
UNI_EXPORT_METHOD(@selector(dialList:callback:))
- (void)dialList:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_dialChannelWithChannelModel:VPDialChannelModelRead dialType:VPDeviceDialTypeMarket photoDialModel:nil result:^(VPPhotoDialModel *photoDialModel, VPDeviceMarketDialModel *deviceMarketDialModel, NSError *error) {
        NSMutableArray *list = [NSMutableArray array];
        if (deviceMarketDialModel) {
            [list addObject:@{ @"imageId": @(deviceMarketDialModel.imageId) }];
        }
        NSDictionary *d = @{ @"list": list };
        [self sendEvent:@"dial" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    } transformProgress:^(double progress) {}];
}

/**
 设置表盘。options: { dialId }。
 iOS SDK：veepooSDK_dialChannelWithChannelModel:...（Setup 模式；需 JL 系设备，市场表盘 bin 需先下载再流式传输）
 Android：setJLWatchDial / setJLWatchPhotoDial；JS：joemeWatch.setDial(dialId)
 事件：on('dial') -> { ok }
 注：iOS 端完整换表盘需 bin 文件流式下发，本桥接仅触发通道建立；dialId 到 bin 的映射待厂商/真机确认。
 */
UNI_EXPORT_METHOD(@selector(setDial:callback:))
- (void)setDial:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_dialChannelWithChannelModel:VPDialChannelModelSetup dialType:VPDeviceDialTypeMarket photoDialModel:nil result:^(VPPhotoDialModel *photoDialModel, VPDeviceMarketDialModel *deviceMarketDialModel, NSError *error) {
        [self sendEvent:@"dial" data:@{ @"ok": @(error == nil) }];
        callback(resultWithCode(200), NO);
    } transformProgress:^(double progress) {
        [self sendEvent:@"dial" data:@{ @"progress": @(progress) }];
    }];
}

/**
 打开设备经典蓝牙开关。options: { on }（iOS 仅有"打开"命令）。
 iOS SDK：veepooSDK_openDeviceBTSwitch（裸声明）
 Android：setBTSwitchStatus(...)；JS：joemeWatch.btOpen(on)
 事件：on('bt') -> { ok, sent }
 注：完整 BT 通话连接流程不桥接；BT 连接状态由 VPBTConnectStateChangeBlock 统一上报。
 */
UNI_EXPORT_METHOD(@selector(btOpen:callback:))
- (void)btOpen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_openDeviceBTSwitch];
    [self sendEvent:@"bt" data:@{ @"ok": @YES, @"sent": @YES }];
    callback(resultWithCode(200), NO);
}

/**
 PTT 测试（产测）。options: { on }。
 iOS SDK：veepooSDKPTTTest:valueBlock:signalBlock:
 Android：startReadPttSignData / openDevicePtt；JS：joemeWatch.ptt()
 事件：on('ptt') -> { value } / { signal }
 */
UNI_EXPORT_METHOD(@selector(ptt:callback:))
- (void)ptt:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL start = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKPTTTest:start valueBlock:^(VPPttValueModel *valueModel) {
        [self sendEvent:@"ptt" data:@{ @"value": valueModel ?: @{} }];
    } signalBlock:^(NSArray<NSNumber *> *signals) {
        [self sendEvent:@"ptt" data:@{ @"signal": signals ?: @[] }];
    }];
    callback(resultWithCode(200), NO);
}

/**
 GSensor 测试（产测）。options: { on }。
 iOS SDK：veepooSDKTestGSensorStart:testResult:（回包字典 key：totalSteps / x / y / z）
 Android：startGsensorSport / stopGsensorSport；JS：joemeWatch.gsensorTest(on)
 事件：on('gsensor') -> { totalSteps, x, y, z }
 */
UNI_EXPORT_METHOD(@selector(gsensorTest:callback:))
- (void)gsensorTest:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL start = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKTestGSensorStart:start testResult:^(NSDictionary *gSensorParameter) {
        [self sendEvent:@"gsensor" data:gSensorParameter ?: @{}];
    }];
    callback(resultWithCode(200), NO);
}

/**
 PPG 实时原始信号订阅（G08W/JM19A 等特定型号）。options: { on }。
 iOS SDK：veepooSDK_G08WProjectPPGSubscribe:（type 0/1/2 = 绿/红/红外；传 nil 取消订阅）
 Android：start/stopPPGRealTimeTransmission；JS：joemeWatch.ppgRealTime(on)
 事件：on('ppg') -> { type, data }
 */
UNI_EXPORT_METHOD(@selector(ppgRealTime:callback:))
- (void)ppgRealTime:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL start = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (start) {
        [pm veepooSDK_G08WProjectPPGSubscribe:^(int type, NSArray<NSNumber *> *valueArr) {
            [self sendEvent:@"ppg" data:@{ @"type": @(type), @"data": valueArr ?: @[] }];
        }];
    } else {
        [pm veepooSDK_G08WProjectPPGSubscribe:nil];
    }
    callback(resultWithCode(200), NO);
}

/**
 中医诊断 TCM 测试（JM19A 特定型号）。options: { on }。
 iOS SDK：veepooSDK_JM19AProjectTCMTestWithStart:testResult:（state/progress/VPTCMTestDataModel）
 Android：start/stopDetectTcmDiagnosis；JS：joemeWatch.tcmDiagnosis(on)
 事件：on('tcm') -> { state, progress }
 */
UNI_EXPORT_METHOD(@selector(tcmDiagnosis:callback:))
- (void)tcmDiagnosis:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL start = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_JM19AProjectTCMTestWithStart:start testResult:^(VPTestECGState state, NSUInteger progress, VPTCMTestDataModel *m) {
        [self sendEvent:@"tcm" data:@{ @"state": @(state), @"progress": @(progress) }];
    }];
    callback(resultWithCode(200), NO);
}

/**
 小体检 PPG+加速度主动测量（JH58 特定型号）。options: { on }。
 iOS SDK：veepooSDK_JH58ActiveTestPPGAndAcceleration:andResult:
          （VPJH58ActiveMeasurementState：1=实时 2=断点续传 3=关；on 映射实时开，off 映射关）
 Android：start/stopMiniCheckup；JS：joemeWatch.miniCheckup(on)
 事件：on('miniCheckup') -> { state }
 */
UNI_EXPORT_METHOD(@selector(miniCheckup:callback:))
- (void)miniCheckup:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPJH58ActiveMeasurementState st = on ? VPJH58ActiveMeasurementStateRealTime : VPJH58ActiveMeasurementStateOff;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_JH58ActiveTestPPGAndAcceleration:st andResult:^(VPJH58ActiveMeasurementResultState state) {
        [self sendEvent:@"miniCheckup" data:@{ @"state": @(state) }];
        callback(resultWithCode(200), NO);
    }];
}

// ==================== 批次 1：基础设置 / 屏幕与显示 ====================
// 对应 Android JoemeWatchModule 的 readBright / readScreenDuration / readScreenStyle /
// readNightRaiseHand / setNightRaiseHand / readLowPower / setLowPower / setWearCheck。
// iOS 的读写多复用同一个接口，用 settingMode 区分：1=设置 2=读取（详见各方法注释）。

// ---------- 4. 屏幕与显示（screen）读取 ----------

/**
 读取屏幕亮度设置。
 iOS SDK：veepooSDKSettingBrightWithBrightModel:settingMode:2（模型不能为 nil，传空模型即可）
 Android：readScreenLight；JS：joemeWatch.readBright()
 事件：on('screenLight') -> { ok, brightness, otherValue, isAutomatic, maxBrightValue,
                              startHour, startMinute, endHour, endMinute }
 备注：brightness 取 firstBrightValue（时间段内档位）；otherValue 是其它时间段档位。
 */
UNI_EXPORT_METHOD(@selector(readBright:callback:))
- (void)readBright:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingBrightWithBrightModel:[[VPDeviceBrightModel alloc] init]
                                  settingMode:2
                                successResult:^(VPDeviceBrightModel *bm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(bm != nil);
        if (bm) {
            d[@"brightness"] = @(bm.firstBrightValue);
            d[@"otherValue"] = @(bm.otherBrightValue);
            d[@"isAutomatic"] = @(bm.isAutomatic);
            d[@"maxBrightValue"] = @(bm.maxBrightValue);
            d[@"startHour"] = @(bm.firstBrightStartHour);
            d[@"startMinute"] = @(bm.firstBrightStartMinute);
            d[@"endHour"] = @(bm.firstBrightEndHour);
            d[@"endMinute"] = @(bm.firstBrightEndMinute);
        }
        [self sendEvent:@"screenLight" data:d];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"screenLight" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取亮屏时长。
 iOS SDK：veepooSDKSettingScreenDuration:settingMode:2
 Android：readScreenLightTime；JS：joemeWatch.readScreenDuration()
 事件：on('screenDuration') -> { ok, current, min, max, defaultDuration }
 页面（device/general.vue）只认 current 作为「自动熄屏秒数」。
 */
UNI_EXPORT_METHOD(@selector(readScreenDuration:callback:))
- (void)readScreenDuration:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingScreenDuration:[[VPScreenDurationModel alloc] init]
                           settingMode:2
                         successResult:^(VPScreenDurationModel *dm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(dm != nil);
        if (dm) {
            d[@"current"] = @(dm.currentDuration);
            d[@"min"] = @(dm.minDuration);
            d[@"max"] = @(dm.maxDuration);
            d[@"defaultDuration"] = @(dm.defaultDuration);
        }
        [self sendEvent:@"screenDuration" data:d];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"screenDuration" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取屏幕样式（设备内置表盘序号）。
 iOS SDK：veepooSDKSettingDeviceScreenStyle:settingMode:dialType:result:（读取时 screenStyle 传 0）
 Android：readScreenStyle；JS：joemeWatch.readScreenStyle()
 事件：on('screenStyle') -> { ok, style, screenTypes }
 screenTypes 来自 peripheralModel.screenTypes（0 表示该设备没有样式切换功能）。
 */
UNI_EXPORT_METHOD(@selector(readScreenStyle:callback:))
- (void)readScreenStyle:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceScreenStyle:0
                              settingMode:2
                                 dialType:VPDeviceDialTypeDefault
                                   result:^(VPDeviceDialType dt, int screenStyle, BOOL settingSuccess) {
        NSDictionary *d = @{
            @"ok": @(settingSuccess),
            @"style": @(screenStyle),
            @"screenTypes": @([VPBleCentralManage sharedBleManager].peripheralModel.screenTypes)
        };
        [self sendEvent:@"screenStyle" data:d];
        callback(resultWithCode(settingSuccess ? 200 : -1), NO);
    }];
}

/**
 读取夜间转腕（翻腕亮屏）设置。
 iOS SDK：veepooSDKSettingRaiseHandWithRaiseHandModel:settingMode:2（读取时传空模型，不能为 nil）
 Android：readNightTurnWriste；JS：joemeWatch.readNightRaiseHand()
 事件：on('nightRaise') -> { ok, isOpen, startHour, startMinute, endHour, endMinute,
                            level, defaultLevel, supportCustomSettingTime, summary }
 */
UNI_EXPORT_METHOD(@selector(readNightRaiseHand:callback:))
- (void)readNightRaiseHand:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingRaiseHandWithRaiseHandModel:[[VPDeviceRaiseHandModel alloc] init]
                                        settingMode:2
                                      successResult:^(VPDeviceRaiseHandModel *rm) {
        [self sendEvent:@"nightRaise" data:[self raiseHandEventFromModel:rm]];
        callback(resultWithCode(200), NO);
    } failureResult:^{
        [self sendEvent:@"nightRaise" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 设置夜间转腕（翻腕亮屏）：开关 + 生效时间 + 灵敏度。
 options: { on, startHour?, startMinute?, endHour?, endMinute?, level? }
 iOS SDK：veepooSDKSettingRaiseHandWithRaiseHandModel:settingMode:（1=开 0=关）
 Android：settingNightTurnWriste；JS：joemeWatch.setNightRaiseHand({...})
 事件：on('nightRaise') -> 同 readNightRaiseHand
 level 为灵敏度（SDK 范围 1-10）；不传时沿用设备当前值（读取一次后下发），
 避免把已有灵敏度覆盖成 0（0 在某些固件上表示「无灵敏度功能」，会写坏）。
 */
UNI_EXPORT_METHOD(@selector(setNightRaiseHand:callback:))
- (void)setNightRaiseHand:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    NSUInteger startH = options[@"startHour"] ? [options[@"startHour"] unsignedIntegerValue] : 0;
    NSUInteger startM = options[@"startMinute"] ? [options[@"startMinute"] unsignedIntegerValue] : 0;
    NSUInteger endH = options[@"endHour"] ? [options[@"endHour"] unsignedIntegerValue] : 23;
    NSUInteger endM = options[@"endMinute"] ? [options[@"endMinute"] unsignedIntegerValue] : 59;
    BOOL hasLevel = (options[@"level"] != nil);
    NSUInteger level = hasLevel ? [options[@"level"] unsignedIntegerValue] : 0;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;

    void (^doSet)(NSUInteger) = ^(NSUInteger sensitive) {
        VPDeviceRaiseHandModel *m = [[VPDeviceRaiseHandModel alloc] initWithRaiseHandStartHour:startH
                                                                           raiseHandStartMinute:startM
                                                                             raiseHandEndHour:endH
                                                                           raiseHandEndMinute:endM
                                                                               raiseHandState:(on ? 1 : 0)
                                                                           raiseHandSensitive:sensitive];
        [pm veepooSDKSettingRaiseHandWithRaiseHandModel:m
                                            settingMode:(on ? 1 : 0)
                                          successResult:^(VPDeviceRaiseHandModel *rm) {
            [weakSelf sendEvent:@"nightRaise" data:[weakSelf raiseHandEventFromModel:rm]];
            callback(resultWithCode(200), NO);
        } failureResult:^{
            [weakSelf sendEvent:@"nightRaise" data:@{ @"ok": @NO }];
            callback(resultWithCode(-1), NO);
        }];
    };

    if (hasLevel) {
        doSet(level);
        return;
    }
    // 未传 level：先读一次拿当前灵敏度，再按原值下发
    [pm veepooSDKSettingRaiseHandWithRaiseHandModel:[[VPDeviceRaiseHandModel alloc] init]
                                        settingMode:2
                                      successResult:^(VPDeviceRaiseHandModel *rm) {
        doSet(rm ? rm.sensitive : 0);
    } failureResult:^{
        doSet(0);
    }];
}

/** 翻腕亮屏模型 -> nightRaise 事件载荷（读取与设置共用，字段口径与 Android nightRaiseData 对齐） */
- (NSDictionary *)raiseHandEventFromModel:(VPDeviceRaiseHandModel *)rm {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"ok"] = @(rm != nil);
    if (!rm) return d;
    d[@"isOpen"] = @(rm.raiseHandState == 1);
    d[@"startHour"] = @(rm.raiseHandStartHour);
    d[@"startMinute"] = @(rm.raiseHandStartMinute);
    d[@"endHour"] = @(rm.raiseHandEndHour);
    d[@"endMinute"] = @(rm.raiseHandEndMinute);
    d[@"level"] = @(rm.sensitive);
    d[@"defaultLevel"] = @(rm.defaultSensitive);
    // iOS 没有 supportCustomSettingTime 字段：默认灵敏度为 0 即表示该设备没有灵敏度调节能力，
    // 与「不支持自定义生效时间」是同一类能力位缺失，页面据此隐藏时间/灵敏度入口。
    d[@"supportCustomSettingTime"] = @(rm.defaultSensitive > 0);
    return d;
}

// ---------- 2b. 低功耗 / 佩戴检测 ----------

/**
 读取低功耗设置。
 iOS SDK：veepooSDKSettingLowPowerSettingMode:VPReadFunctionState result:
          接口只回「功能状态」，具体时长字段在 peripheralModel.lowPowerModel 里（握手时下发）。
 Android：readLowPower；JS：joemeWatch.readLowPower()
 事件：on('lowPower') -> { ok, state, messageDuration, turnWristDuration, mainScreenDuration,
                          messageDelayMotorDuration, callMotorDuration }
 state：1=开 2=关（SDK 语义，不是布尔）。
 */
UNI_EXPORT_METHOD(@selector(readLowPower:callback:))
- (void)readLowPower:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingLowPowerSettingMode:VPReadFunctionState result:^(VPSettingFunctionCompleteState state) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        // Unknown/Failure 视为读取失败；Open/Close/Complete 都算读到了
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        d[@"ok"] = @(ok);
        d[@"state"] = @(state);
        VPLowPowerModel *m = [VPBleCentralManage sharedBleManager].peripheralModel.lowPowerModel;
        if (m) {
            d[@"messageDuration"] = @(m.messageDuration);
            d[@"turnWristDuration"] = @(m.turnWristDuration);
            d[@"mainScreenDuration"] = @(m.mainScreenDuration);
            d[@"messageDelayMotorDuration"] = @(m.messageDelayMotorDuration);
            d[@"callMotorDuration"] = @(m.callMotorDuration);
        }
        [self sendEvent:@"lowPower" data:d];
        callback(resultWithCode(ok ? 200 : -1), NO);
    }];
}

/**
 设置低功耗开关。options: { on }
 iOS SDK：veepooSDKSettingLowPowerSettingMode:（VPSettingFunctionOpen / Close）
 Android：settingLowpower；JS：joemeWatch.setLowPower(on)
 事件：on('lowPower') -> { ok, state }
 注意：头文件注明「第一次要先读取，不读直接设置开或关可能失败」，本方法内部先读再写。
 */
UNI_EXPORT_METHOD(@selector(setLowPower:callback:))
- (void)setLowPower:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;

    void (^doWrite)(void) = ^{
        [pm veepooSDKSettingLowPowerSettingMode:(on ? VPSettingFunctionOpen : VPSettingFunctionClose)
                                         result:^(VPSettingFunctionCompleteState state) {
            BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                       || state == VPFunctionCompleteComplete);
            [weakSelf sendEvent:@"lowPower" data:@{ @"ok": @(ok), @"state": @(state) }];
            callback(resultWithCode(ok ? 200 : -1), NO);
        }];
    };

    [pm veepooSDKSettingLowPowerSettingMode:VPReadFunctionState result:^(VPSettingFunctionCompleteState state) {
        doWrite();
    }];
}

/**
 佩戴检测开关。options: { on }
 iOS SDK：veepooSDKSettingBaseFunctionType:VPSettingWearDetection settingState:
 Android：setttingCheckWear；JS：joemeWatch.setWearCheck(on)
 事件：on('wearCheck') -> { ok, isOpen }
 */
UNI_EXPORT_METHOD(@selector(setWearCheck:callback:))
- (void)setWearCheck:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingBaseFunctionType:VPSettingWearDetection
                            settingState:(on ? VPSettingFunctionOpen : VPSettingFunctionClose)
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        [weakSelf sendEvent:@"wearCheck" data:@{ @"ok": @(ok), @"isOpen": @(on) }];
        callback(resultWithCode(ok ? 200 : -1), NO);
    }];
}

// ==================== 批次 2：健康数据读取 ====================
// 对应 Android 的 readSportStep / readSleepByDay / readActivityByDay / readSpo2hHistory /
// readHrvHistory / readTemperatureHistory / readRRData / readEcgData / readManualData / readDrinkData。
//
// iOS 与 Android 的读取模型差异很大，这里统一成 Android 的事件/返回形状：
//   Android 是「一次 BLE 命令 → 回调里直接带结构化数据」；
//   iOS 是「先 veepooSDK_readXxx(设备读一遍，SDK 落本地库) → 再从 VPDataBaseOperation 按日期查库」。
//   所以下面每个读取方法都是「读设备 → 等读完 → 查库 → 归一化」这一套流程。
// 库里的 dict key 已按二进制字符串常量核对（stepValue/sportValue/calValue/disValue/wearState/
// ppgs/highBlood/lowBlood/oxygens/resRates/hypoxiaTimes/cardiacLoads/apneaResults/isHypoxias/
// bodyTemperatrue/originalTemperatrue/stress/met），并对旧库的 Step/Dis/Cal/heartValue/systolic
// 等写法做了兜底（同一个 key 名在不同协议版本/表里会变，页面只认归一化后的一套）。

/** 相对天数索引（0=今天）-> yyyy-MM-dd（与 JS 端 dateFromDay 同算法，用本地零点） */
- (NSString *)dateStrForDay:(NSInteger)day {
    NSDate *d = [NSDate date];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *c = [cal components:(NSCalendarUnitYear | NSCalendarUnitMonth | NSCalendarUnitDay) fromDate:d];
    c.day -= day;
    NSDate *target = [cal dateFromComponents:c];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd";
    return [fmt stringFromDate:target];
}

/** NSNumber/NSString -> double；其它类型与 nil 返回 0（库里的值两种类型混用） */
static double JoemeDouble(id v) {
    if ([v isKindOfClass:[NSNumber class]]) return [(NSNumber *)v doubleValue];
    if ([v isKindOfClass:[NSString class]]) return [(NSString *)v doubleValue];
    return 0;
}

static NSInteger JoemeInt(id v) {
    return (NSInteger)JoemeDouble(v);
}

/** dict 上按多个候选 key 取值（库里不同协议版本 key 名不一致） */
static id JoemeFirstValue(NSDictionary *dict, NSArray<NSString *> *keys) {
    if (![dict isKindOfClass:[NSDictionary class]]) return nil;
    for (NSString *k in keys) {
        id v = dict[k];
        if (v && v != [NSNull null]) return v;
    }
    return nil;
}

/** dict 里的时间 -> (hour, minute)。支持 "HH:mm"/"HH:mm:ss" 字符串与 hour/minute 数值字段 */
static void JoemeTimeOfDict(NSDictionary *dict, NSInteger *hour, NSInteger *minute) {
    NSInteger h = 0, m = 0;
    id t = JoemeFirstValue(dict, @[ @"Time", @"time", @"TimeValue" ]);
    if ([t isKindOfClass:[NSString class]] && [(NSString *)t length] >= 4) {
        NSArray<NSString *> *parts = [(NSString *)t componentsSeparatedByString:@":"];
        if (parts.count >= 2) {
            h = [parts[0] integerValue];
            m = [parts[1] integerValue];
        }
    } else {
        h = JoemeInt(JoemeFirstValue(dict, @[ @"hour", @"hourValue", @"startHour" ]));
        m = JoemeInt(JoemeFirstValue(dict, @[ @"minute", @"minuteValue", @"startMinute" ]));
    }
    if (hour) *hour = h;
    if (minute) *minute = m;
}

/** 归一化一条 5 分钟原始数据（Android OriginData(3) 的字段名），iOS/旧库 key 都在这里兜底 */
- (NSMutableDictionary *)activityPointFromDict:(NSDictionary *)src {
    NSMutableDictionary *p = [NSMutableDictionary dictionary];
    NSInteger h = 0, m = 0;
    JoemeTimeOfDict(src, &h, &m);
    p[@"h"] = @(h);
    p[@"m"] = @(m);
    p[@"step"] = @(JoemeInt(JoemeFirstValue(src, @[ @"stepValue", @"Step", @"step" ])));
    p[@"cal"] = @(JoemeDouble(JoemeFirstValue(src, @[ @"calValue", @"Cal", @"cal" ])));
    p[@"dis"] = @(JoemeDouble(JoemeFirstValue(src, @[ @"disValue", @"Dis", @"dis" ])));
    p[@"rate"] = @(JoemeInt(JoemeFirstValue(src, @[ @"heartValue", @"HeartValue", @"heart", @"rate" ])));
    p[@"sport"] = @(JoemeInt(JoemeFirstValue(src, @[ @"sportValue", @"SportValue", @"sport" ])));
    // 血压：OriginData 里是 systolic/diastolic，新结构里叫 highBlood/lowBlood
    p[@"high"] = @(JoemeInt(JoemeFirstValue(src, @[ @"systolic", @"highBlood", @"high" ])));
    p[@"low"] = @(JoemeInt(JoemeFirstValue(src, @[ @"diastolic", @"lowBlood", @"low" ])));
    // 佩戴标志位：0=已佩戴（官方 isWearPass 口径），与 Android getWear() 一致
    p[@"wear"] = @(JoemeInt(JoemeFirstValue(src, @[ @"wearState", @"Wear", @"wear" ])));
    // 体温：新结构 bodyTemperatrue/originalTemperatrue（SDK 的拼写就是 Temperatrue），
    // 旧字典是 value/originalValue。单位已是 ℃（协议层不 ×10）。
    double temp = JoemeDouble(JoemeFirstValue(src, @[ @"bodyTemperatrue", @"bodyTempValue", @"temperature", @"value" ]));
    double baseTemp = JoemeDouble(JoemeFirstValue(src, @[ @"originalTemperatrue", @"originalTempValue", @"originalValue", @"baseTemperature" ]));
    if (temp > 0) p[@"temperature"] = @(temp);
    if (baseTemp > 0) p[@"baseTemperature"] = @(baseTemp);
    p[@"met"] = @(JoemeDouble(JoemeFirstValue(src, @[ @"met" ])));
    p[@"pressure"] = @(JoemeInt(JoemeFirstValue(src, @[ @"stress" ])));

    NSArray *ppgs = JoemeFirstValue(src, @[ @"ppgs" ]);
    if ([ppgs isKindOfClass:[NSArray class]] && [(NSArray *)ppgs count] > 0) p[@"ppgs"] = ppgs;
    NSArray *oxygens = JoemeFirstValue(src, @[ @"oxygens" ]);
    if ([oxygens isKindOfClass:[NSArray class]] && [(NSArray *)oxygens count] > 0) p[@"oxygens"] = oxygens;
    NSArray *resRates = JoemeFirstValue(src, @[ @"resRates" ]);
    if ([resRates isKindOfClass:[NSArray class]] && [(NSArray *)resRates count] > 0) p[@"resRates"] = resRates;
    NSArray *hypoxiaTimes = JoemeFirstValue(src, @[ @"hypoxiaTimes" ]);
    if ([hypoxiaTimes isKindOfClass:[NSArray class]] && [(NSArray *)hypoxiaTimes count] > 0) p[@"hypoxiaTimes"] = hypoxiaTimes;
    NSArray *cardiacLoads = JoemeFirstValue(src, @[ @"cardiacLoads" ]);
    if ([cardiacLoads isKindOfClass:[NSArray class]] && [(NSArray *)cardiacLoads count] > 0) p[@"cardiacLoads"] = cardiacLoads;
    NSArray *apneaResults = JoemeFirstValue(src, @[ @"apneaResults" ]);
    if ([apneaResults isKindOfClass:[NSArray class]] && [(NSArray *)apneaResults count] > 0) p[@"apneaResults"] = apneaResults;
    NSArray *isHypoxias = JoemeFirstValue(src, @[ @"isHypoxias" ]);
    if ([isHypoxias isKindOfClass:[NSArray class]] && [(NSArray *)isHypoxias count] > 0) p[@"isHypoxias"] = isHypoxias;
    return p;
}

/**
 读取当天计步（步数/距离/卡路里）。
 iOS SDK：先 veepooSdkSendStepCommand 让设备上报实时步数（SDK 落库），
          再 veepooSDKGetStepDataWithDate:andTableID:changeUserStature:result: 查库。
 Android：readSportStep；JS：joemeWatch.readSportStep() -> resolve { step, dis, kcal }
 事件：on('sportStep') -> { step, dis, kcal }
 说明：dis 单位 km、kcal 单位千卡（与 Android SportData 同名同单位）；
      设备不回包时最多等 3 秒，然后回库里的最新值（可能是 0，不会挂死）。
 */
UNI_EXPORT_METHOD(@selector(readSportStep:callback:))
- (void)readSportStep:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    VPPeripheralModel *model = manager.peripheralModel;
    NSString *mac = model.deviceAddress ?: @"";
    NSUInteger stature = model.deviceStature > 0 ? model.deviceStature : 175;
    NSString *today = [self dateStrForDay:0];

    // 触发一次设备上报，让 SDK 把最新步数写进库
    [pm veepooSdkSendStepCommand];

    __weak typeof(self) weakSelf = self;
    __block NSInteger tries = 0;
    __block void (^poll)(void);

    void (^deliver)(NSDictionary *) = ^(NSDictionary *dict) {
        NSInteger step = JoemeInt(JoemeFirstValue(dict, @[ @"Step", @"step" ]));
        double dis = JoemeDouble(JoemeFirstValue(dict, @[ @"Dis", @"dis" ]));
        double cal = JoemeDouble(JoemeFirstValue(dict, @[ @"Cal", @"kcal", @"cal" ]));
        NSDictionary *d = @{ @"step": @(step), @"dis": @(dis), @"kcal": @(cal) };
        [weakSelf sendEvent:@"sportStep" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    };

    poll = ^{
        [VPDataBaseOperation veepooSDKGetStepDataWithDate:today andTableID:mac changeUserStature:stature result:^(NSDictionary *stepDict) {
            tries++;
            // 库里已有当天数据（或已等满 10 次 ≈ 3 秒）就回；否则稍等再查
            if (stepDict.count > 0 || tries >= 10) {
                deliver(stepDict ?: @{});
                poll = nil;
                return;
            }
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)),
                           dispatch_get_main_queue(), ^{
                if (poll) poll();
            });
        }];
    };
    poll();
}

/**
 按天读取睡眠数据。
 iOS SDK：veepooSDK_readSleepDataWithDayNumber:result:（设备读一遍，SDK 落库）→ 归一化回调里的数组。
          精准睡眠（peripheralModel.sleepType==1）走 VPDataBaseOperation 的精准睡眠表。
 Android：readSleepDataSingleDay；JS：joemeWatch.readSleepByDay(day)
 事件：on('sleepHistory') -> { day, sleep: {...} } / { complete:true, day }
 sleep 字段（与 Android SleepData 同名）：date / allSleepTime / deepSleepTime / lowSleepTime（分钟）/
 wakeCount / sleepQulity（1-5 星）/ sleepDown:{hour,minute} / sleepUp:{hour,minute} /
 sleepLine（普通睡眠 5 分钟一格 0浅1深2醒；精准睡眠 1 分钟一格 0深1浅2REM3失眠4醒）/ precision。
 一天可能有多段睡眠，这里发第一条有数据的（页面只展示一段，与 Android 取整表首条同口径）。
 */
UNI_EXPORT_METHOD(@selector(readSleepByDay:callback:))
- (void)readSleepByDay:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"day"] ? [options[@"day"] integerValue] : 0;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    VPPeripheralModel *model = manager.peripheralModel;
    __weak typeof(self) weakSelf = self;

    void (^emitComplete)(void) = ^{
        [weakSelf sendEvent:@"sleepHistory" data:@{ @"complete": @YES, @"day": @(day) }];
        callback(resultWithCode(200), NO);
    };

    // 精准睡眠：设备把每一天的精准睡眠存进本地库，直接按日期查（结构见 VPAccurateSleepModel）
    if (model.sleepType == 1) {
        NSString *date = [self dateStrForDay:day];
        NSArray *arr = [VPDataBaseOperation veepooSDKGetAccurateSleepDataWithDate:date andTableID:model.deviceAddress ?: @""];
        VPAccurateSleepModel *m = nil;
        for (id it in arr) {
            if ([it isKindOfClass:[VPAccurateSleepModel class]]) { m = it; break; }
        }
        if (m) {
            [weakSelf sendEvent:@"sleepHistory" data:@{ @"day": @(day), @"sleep": [weakSelf sleepDictFromAccurateModel:m] }];
        }
        emitComplete();
        return;
    }

    [pm veepooSDK_readSleepDataWithDayNumber:day result:^(NSArray *sleepOneDayArray) {
        NSDictionary *picked = nil;
        for (id it in sleepOneDayArray) {
            if ([it isKindOfClass:[NSDictionary class]]) { picked = it; break; }
        }
        // 0=今天在部分固件上无数据（睡眠存的是昨天夜里那段），空表时补读 day+1 一次
        if (!picked && day == 0) {
            [pm veepooSDK_readSleepDataWithDayNumber:1 result:^(NSArray *retry) {
                NSDictionary *second = nil;
                for (id it in retry) {
                    if ([it isKindOfClass:[NSDictionary class]]) { second = it; break; }
                }
                if (second) {
                    [weakSelf sendEvent:@"sleepHistory" data:@{ @"day": @(day), @"sleep": [weakSelf sleepDictFromLegacyDict:second] }];
                }
                emitComplete();
            }];
            return;
        }
        if (picked) {
            [weakSelf sendEvent:@"sleepHistory" data:@{ @"day": @(day), @"sleep": [weakSelf sleepDictFromLegacyDict:picked] }];
        }
        emitComplete();
    }];
}

/** 普通睡眠字典（库/设备回调同结构）-> sleep 事件载荷 */
- (NSDictionary *)sleepDictFromLegacyDict:(NSDictionary *)src {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    NSString *sleepTime = JoemeFirstValue(src, @[ @"SLEEP_TIME", @"sleepTime", @"SLEEPDOWN" ]);
    NSString *wakeTime = JoemeFirstValue(src, @[ @"WAKE_TIME", @"wakeTime", @"SLEEPUP" ]);
    s[@"date"] = JoemeFirstValue(src, @[ @"date", @"DATE" ]) ?: @"";
    // 老库用小时浮点（DEEP_HOUR="2.833"），新结构用分钟字段；两种都归一到分钟
    double deepMin = JoemeDouble(JoemeFirstValue(src, @[ @"deepSleepTime", @"DEEP_MINUTE" ]));
    double lightMin = JoemeDouble(JoemeFirstValue(src, @[ @"lowSleepTime", @"LIGHT_MINUTE" ]));
    if (deepMin <= 0) deepMin = JoemeDouble(JoemeFirstValue(src, @[ @"DEEP_HOUR" ])) * 60.0;
    if (lightMin <= 0) lightMin = JoemeDouble(JoemeFirstValue(src, @[ @"LIGHT_HOUR" ])) * 60.0;
    double allMin = JoemeDouble(JoemeFirstValue(src, @[ @"allSleepTime", @"SLEEP_MINUTE" ]));
    if (allMin <= 0) {
        double h = JoemeDouble(JoemeFirstValue(src, @[ @"SLE_HOUR" ]));
        double m = JoemeDouble(JoemeFirstValue(src, @[ @"SLE_MINUTE" ]));
        allMin = h * 60.0 + m;
    }
    if (allMin <= 0) allMin = deepMin + lightMin;
    s[@"allSleepTime"] = @((NSInteger)llround(allMin));
    s[@"deepSleepTime"] = @((NSInteger)llround(deepMin));
    s[@"lowSleepTime"] = @((NSInteger)llround(lightMin));
    s[@"wakeCount"] = @(JoemeInt(JoemeFirstValue(src, @[ @"wakeCount", @"WakeUpTime", @"WAKE_COUNT" ])));
    NSInteger quality = JoemeInt(JoemeFirstValue(src, @[ @"sleepQulity", @"SLEEP_LEVEL", @"sleepQuality" ]));
    // 老库 SLEEP_LEVEL 就是 1-5 星；精准睡眠是 0-4，需要在精准分支 +1
    s[@"sleepQulity"] = @(quality);
    s[@"sleepLine"] = JoemeFirstValue(src, @[ @"sleepLine", @"SLE_LINE" ]) ?: @"";
    s[@"precision"] = @NO;
    s[@"sleepDown"] = [self hourMinuteDictFromString:sleepTime];
    s[@"sleepUp"] = [self hourMinuteDictFromString:wakeTime];
    return s;
}

/** 精准睡眠模型 -> sleep 事件载荷（sleepQulity 0-4 → 1-5，sleepLine 十六进制转 0-4 数字串） */
- (NSDictionary *)sleepDictFromAccurateModel:(VPAccurateSleepModel *)m {
    NSMutableDictionary *s = [NSMutableDictionary dictionary];
    s[@"date"] = m.sleepTime.length >= 10 ? [m.sleepTime substringToIndex:10] : (m.sleepTime ?: @"");
    s[@"allSleepTime"] = @([m.sleepDuration integerValue]);
    s[@"deepSleepTime"] = @([m.deepDuration integerValue]);
    s[@"lowSleepTime"] = @([m.lightDuration integerValue]);
    s[@"wakeCount"] = @([m.getUpTimes integerValue]);
    s[@"sleepQulity"] = @([m.sleepQuality integerValue] + 1);
    // 精准睡眠曲线：每个点 2 字节（高 3 bit 是状态 0深1浅2REM3失眠4醒）。
    // 页面按「一格 = 1 分钟」渲染，所以这里转成每格一个 0-4 字符的串。
    NSMutableString *line = [NSMutableString string];
    NSArray<NSDictionary *> *parsed = [m parseSleepLine];
    if (parsed.count > 0) {
        for (NSDictionary *it in parsed) {
            [line appendFormat:@"%@", it[@"type"] ?: @0];
        }
    }
    s[@"sleepLine"] = line;
    s[@"precision"] = @YES;
    s[@"sleepDown"] = [self hourMinuteDictFromString:m.sleepTime];
    s[@"sleepUp"] = [self hourMinuteDictFromString:m.wakeTime];
    return s;
}

/** "2017/02/09 01:15" / "2017-02-09 01:15" -> { hour, minute }（解析不到给 0,0） */
- (NSDictionary *)hourMinuteDictFromString:(NSString *)str {
    if (![str isKindOfClass:[NSString class]]) return @{ @"hour": @0, @"minute": @0 };
    NSArray *timePart = [str componentsSeparatedByString:@" "];
    NSString *t = timePart.count >= 2 ? timePart.lastObject : str;
    NSArray *hm = [t componentsSeparatedByString:@":"];
    return @{
        @"hour": hm.count >= 1 ? @([hm[0] integerValue]) : @0,
        @"minute": hm.count >= 2 ? @([hm[1] integerValue]) : @0
    };
}

/**
 按天读取活动数据（步数/距离/卡路里/运动量 + 5 分钟原始点）。
 iOS SDK：veepooSDK_readBasicDataWithDayNumber:maxPackage:result:（分页，读到 totalPackage 为止）
 Android：readOriginDataSingleDay；JS：joemeWatch.readActivityByDay(day) -> Promise<当天汇总>
 事件：on('activityByDay') -> { progress } / { complete, day, totalStep } / { timeout, day }
 返回：{ code, day, date, totalStep, totalDistance, totalCalorie, totalSportValue,
         pointCount, points:[{h,m,step,cal,dis,rate,sport,high,low,wear,temperature,
         baseTemperature,ppgs,oxygens,resRates,hypoxiaTimes,cardiacLoads,apneaResults,
         isHypoxias,met,pressure}] }
 说明：查库补两张「整读才落库」的表——血糖（glucose/glucoseRisk）与血液成分
      （bloodComponent），按 HH:mm 对齐到对应 5 分钟点；库里没有就不带字段，页面按 0 过滤。
 超时：设备不回包时 30 秒看门狗，发 timeout 事件并 reject（与 Android 行为一致）。
 */
UNI_EXPORT_METHOD(@selector(readActivityByDay:callback:))
- (void)readActivityByDay:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"day"] ? [options[@"day"] integerValue] : 0;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSInteger watchDay = model.saveDays > 0 ? model.saveDays : 7;
    if (day < 0 || day >= watchDay) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = [NSString stringWithFormat:@"该日期超出设备存储范围（可读 0~%ld 天前）", (long)(watchDay - 1)];
        r[@"day"] = @(day);
        callback(r, NO);
        return;
    }

    NSString *dateStr = [self dateStrForDay:day];
    NSString *mac = model.deviceAddress ?: @"";
    VMutablePointsHolder *holder = [[VMutablePointsHolder alloc] init];

    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    __block NSInteger reads = 0;
    __block void (^fetchNext)(NSInteger);
    __block dispatch_block_t watchdogRef = nil;

    void (^finish)(BOOL, NSString *) = ^(BOOL timeout, NSString *message) {
        if (finished) return;
        finished = true;
        if (watchdogRef) { dispatch_block_cancel(watchdogRef); watchdogRef = nil; }

        // 血糖 / 血液成分：整读后才落库，必须先并进 holder 再取 points（顺序不能反）
        [weakSelf mergeBloodGlucoseFromDBInto:holder date:dateStr mac:mac];
        [weakSelf mergeBloodComponentFromDBInto:holder date:dateStr mac:mac];

        NSArray<NSDictionary *> *points = [holder sortedPoints];
        NSMutableDictionary *r = [resultWithCode(timeout ? -1 : 200) mutableCopy];
        r[@"day"] = @(day);
        r[@"date"] = dateStr;
        r[@"points"] = points;
        r[@"pointCount"] = @(points.count);

        NSInteger totalStep = 0;
        double totalDis = 0, totalCal = 0, totalSport = 0;
        for (NSDictionary *p in points) {
            totalStep += [p[@"step"] integerValue];
            totalDis += [p[@"dis"] doubleValue];
            totalCal += [p[@"cal"] doubleValue];
            totalSport += [p[@"sport"] doubleValue];
        }
        r[@"totalStep"] = @(totalStep);
        r[@"totalDistance"] = @(round(totalDis * 1000.0) / 1000.0);
        r[@"totalCalorie"] = @(round(totalCal * 1000.0) / 1000.0);
        r[@"totalSportValue"] = @((NSInteger)llround(totalSport));

        if (timeout) {
            r[@"message"] = message ?: @"设备读取超时";
            [weakSelf sendEvent:@"activityByDay" data:@{ @"timeout": @YES, @"day": @(day) }];
        } else {
            NSMutableDictionary *ev = [NSMutableDictionary dictionary];
            ev[@"complete"] = @YES;
            ev[@"day"] = @(day);
            ev[@"totalStep"] = @(totalStep);
            [weakSelf sendEvent:@"activityByDay" data:ev];
        }
        callback(r, NO);
    };

    // 30 秒看门狗：每次有回调都会重置（慢设备不会被误判）
    void (^armWatchdog)(void) = ^{
        if (watchdogRef) dispatch_block_cancel(watchdogRef);
        dispatch_block_t blk = dispatch_block_create(0, ^{
            finish(YES, @"读取活动数据超时");
        });
        watchdogRef = blk;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), blk);
    };

    // 分页读取：maxPackage 表示「读到第几包」，先要第 1 包拿到总包数，再逐包推进
    fetchNext = ^(NSInteger maxPackage) {
        reads++;
        if (reads > 400) { finish(YES, @"读取活动数据包数异常"); return; }
        [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_readBasicDataWithDayNumber:day maxPackage:maxPackage result:^(NSArray *oneDayBasicArray, NSInteger totalPackage, NSInteger currentReadPackage) {
            armWatchdog();
            for (id it in oneDayBasicArray) {
                if (![it isKindOfClass:[NSDictionary class]]) continue;
                [holder addPoint:[weakSelf activityPointFromDict:it]];
            }
            [weakSelf sendEvent:@"activityByDay" data:@{
                @"progress": totalPackage > 0 ? @((double)currentReadPackage / (double)totalPackage) : @0
            }];
            if (totalPackage <= 0 || currentReadPackage >= totalPackage) {
                finish(NO, nil);
                return;
            }
            fetchNext(currentReadPackage + 1);
        }];
    };

    armWatchdog();
    fetchNext(1);
}

// 从库补血糖点：DB key "time"(HH:mm) + "bloodGlucoses"(字符串数组) + "bloodGlucoseLevels"
- (void)mergeBloodGlucoseFromDBInto:(VMutablePointsHolder *)holder date:(NSString *)date mac:(NSString *)mac {
    NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceBloodGlucoseDataWithDate:date andTableID:mac];
    for (NSDictionary *d in arr) {
        if (![d isKindOfClass:[NSDictionary class]]) continue;
        NSInteger h = 0, m = 0;
        JoemeTimeOfDict(d, &h, &m);
        id values = JoemeFirstValue(d, @[ @"bloodGlucoses" ]);
        id levels = JoemeFirstValue(d, @[ @"bloodGlucoseLevels" ]);
        if (![values isKindOfClass:[NSArray class]] || [(NSArray *)values count] == 0) continue;
        // 一个 5 分钟窗口可能有多条（元素对应每分钟），页面按单值处理：取第一个非 0
        double glucose = 0;
        for (id v in (NSArray *)values) {
            double n = JoemeDouble(v);
            if (n > 0) { glucose = n; break; }
        }
        if (glucose <= 0) continue;
        NSString *risk = @"NONE";
        if ([levels isKindOfClass:[NSArray class]] && [(NSArray *)levels count] > 0) {
            NSInteger lv = JoemeInt([(NSArray *)levels firstObject]);
            // DB 里 1/2/3 = 低/中/高
            if (lv == 1) risk = @"LOW";
            else if (lv == 2) risk = @"MIDDLE";
            else if (lv == 3) risk = @"HIGH";
        }
        [holder mergeAtHour:h minute:m values:@{ @"glucose": @(glucose), @"glucoseRisk": risk }];
    }
}

// 从库补血液成分点：VPDailyBloodAnalysisModel 的 time + 各血脂/尿酸数组
- (void)mergeBloodComponentFromDBInto:(VMutablePointsHolder *)holder date:(NSString *)date mac:(NSString *)mac {
    NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceBloodAnalysisDataWithDate:date andTableID:mac];
    for (VPDailyBloodAnalysisModel *m in arr) {
        if (![m isKindOfClass:[VPDailyBloodAnalysisModel class]]) continue;
        NSInteger h = 0, mnt = 0;
        JoemeTimeOfDict(@{ @"time": m.time ?: @"" }, &h, &mnt);
        NSMutableDictionary *bc = [NSMutableDictionary dictionary];
        NSArray<NSString *> *uric = m.uricAcids;
        if (uric.count > 0) bc[@"uricAcid"] = @(JoemeDouble(uric.firstObject));
        if (m.totalCholesterols.count > 0) bc[@"tcho"] = @(JoemeDouble(m.totalCholesterols.firstObject));
        if (m.triglycerides.count > 0) bc[@"tag"] = @(JoemeDouble(m.triglycerides.firstObject));
        if (m.highDensityLipoproteins.count > 0) bc[@"hdl"] = @(JoemeDouble(m.highDensityLipoproteins.firstObject));
        if (m.lowDensityLipoproteins.count > 0) bc[@"ldl"] = @(JoemeDouble(m.lowDensityLipoproteins.firstObject));
        BOOL hasValue = false;
        for (NSNumber *v in bc.allValues) {
            if ([v doubleValue] > 0) { hasValue = true; break; }
        }
        if (!hasValue) continue;
        [holder mergeAtHour:h minute:mnt values:@{ @"bloodComponent": bc }];
    }
}

/**
 读取旧协议血氧历史。
 iOS SDK：veepooSdkStartReadDeviceOxygenData（设备整读，SDK 落库）
          → veepooSDKGetDeviceOxygenDataWithDate:andTableID:（按天查库，逐分钟点）
 Android：readSpo2hOriginBySetting；JS：joemeWatch.readSpo2hHistory(day)
 事件：on('spo2hHistory') -> { progress } / { data:{day,date,time:{hour,minute},oxygen,heart,
        respiration,apneaResult,isHypoxia,hypoxiaTime,cardiacLoad,hrv} } / { complete:true, day }
 说明：协议 3/5 的血氧在 readActivityByDay 的 oxygens 上，这里仍可调用但库里有数据才回点。
 */
UNI_EXPORT_METHOD(@selector(readSpo2hHistory:callback:))
- (void)readSpo2hHistory:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"day"] ? [options[@"day"] integerValue] : 0;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    __weak typeof(self) weakSelf = self;

    [pm veepooSdkStartReadDeviceOxygenData:^(VPReadDeviceBaseDataState state, NSUInteger totalDay,
                                             NSUInteger currentReadDayNumber, NSUInteger readCurrentDayProgress) {
        if (state == VPReadDeviceBaseDataReading) {
            [weakSelf sendEvent:@"spo2hHistory" data:@{ @"progress": @(readCurrentDayProgress / 100.0) }];
            return;
        }
        if (state != VPReadDeviceBaseDataComplete) return;

        NSString *date = [weakSelf dateStrForDay:day];
        NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceOxygenDataWithDate:date
                                                                     andTableID:manager.peripheralModel.deviceAddress ?: @""];
        NSInteger count = 0;
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSInteger h = 0, m = 0;
            JoemeTimeOfDict(d, &h, &m);
            NSMutableDictionary *point = [NSMutableDictionary dictionary];
            point[@"day"] = @(day);
            point[@"date"] = date;
            point[@"time"] = @{ @"hour": @(h), @"minute": @(m) };
            point[@"oxygen"] = @(JoemeInt(JoemeFirstValue(d, @[ @"OxygenValue", @"oxygenValue", @"oxygen" ])));
            point[@"heart"] = @(JoemeInt(JoemeFirstValue(d, @[ @"HeartValue", @"heartValue", @"heart" ])));
            point[@"respiration"] = @(JoemeInt(JoemeFirstValue(d, @[ @"RespirationRate", @"respirationRate" ])));
            point[@"apneaResult"] = @(JoemeInt(JoemeFirstValue(d, @[ @"ApneaResult", @"apneaResult" ])));
            point[@"isHypoxia"] = @(JoemeInt(JoemeFirstValue(d, @[ @"IsHypoxia", @"isHypoxia" ])));
            point[@"hypoxiaTime"] = @(JoemeInt(JoemeFirstValue(d, @[ @"HypoxiaTime", @"hypoxiaTime" ])));
            point[@"cardiacLoad"] = @(JoemeInt(JoemeFirstValue(d, @[ @"CardiacLoad", @"cardiacLoad" ])));
            point[@"hrv"] = @(JoemeInt(JoemeFirstValue(d, @[ @"HRV", @"hrv" ])));
            [weakSelf sendEvent:@"spo2hHistory" data:@{ @"data": point }];
            count++;
        }
        [weakSelf sendEvent:@"spo2hHistory" data:@{ @"complete": @YES, @"day": @(day), @"count": @(count) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取 HRV 历史（旧协议口径）。
 iOS SDK：veepooSdkStartReadDeviceHrvData → veepooSDKGetDeviceHrvDataWithDate:andTableID:
 Android：readHRVOriginBySetting（协议 3/5 走原生数据，iOS 的 HRV 库同样来自整读）
 事件：on('hrvHistory') -> { progress } / { data:{day,date,time:{hour,minute},hrv} } / { complete:true, day }
 */
UNI_EXPORT_METHOD(@selector(readHrvHistory:callback:))
- (void)readHrvHistory:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"day"] ? [options[@"day"] integerValue] : 0;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    __weak typeof(self) weakSelf = self;

    [pm veepooSdkStartReadDeviceHrvData:^(VPReadDeviceBaseDataState state, NSUInteger totalDay,
                                          NSUInteger currentReadDayNumber, NSUInteger readCurrentDayProgress) {
        if (state == VPReadDeviceBaseDataReading) {
            [weakSelf sendEvent:@"hrvHistory" data:@{ @"progress": @(readCurrentDayProgress / 100.0) }];
            return;
        }
        if (state != VPReadDeviceBaseDataComplete) return;

        NSString *date = [weakSelf dateStrForDay:day];
        NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceHrvDataWithDate:date
                                                                   andTableID:manager.peripheralModel.deviceAddress ?: @""];
        NSInteger count = 0;
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSInteger h = 0, m = 0;
            JoemeTimeOfDict(d, &h, &m);
            NSInteger hrv = JoemeInt(JoemeFirstValue(d, @[ @"hrvValue", @"HRV", @"hrv" ]));
            if (hrv <= 0) continue;
            [weakSelf sendEvent:@"hrvHistory" data:@{ @"data": @{
                @"day": @(day),
                @"date": date,
                @"time": @{ @"hour": @(h), @"minute": @(m) },
                @"hrv": @(hrv)
            }}];
            count++;
        }
        [weakSelf sendEvent:@"hrvHistory" data:@{ @"complete": @YES, @"day": @(day), @"count": @(count) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取体温历史（独立历史接口口径）。
 iOS SDK：veepooSdkStartReadDeviceTemperatureData → veepooSDKGetDeviceTemperatureDataWithDate:andTableID:
          （头文件注明 temperatureType==5 时本接口不工作，需走 all-data / 日常数据）
 Android：readTemptureDataBySetting；JS：joemeWatch.readTemperatureHistory(day)
 事件：on('tempHistory') -> { progress } / { list:[{time:{hour,minute},temp,baseTemp,fromHandler}] }
                          / { complete:true } / { timeout:true, day }
 说明：temp=体温、baseTemp=体表温度，单位 ℃（库里是一位的浮点，页面按 >100 视为 ×10 会再除一次，
      这里直接给 ℃ 不放大）。体温类型 5 的设备读不到，看门狗 20 秒后发 timeout。
 */
UNI_EXPORT_METHOD(@selector(readTemperatureHistory:callback:))
- (void)readTemperatureHistory:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"day"] ? [options[@"day"] integerValue] : 0;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    VPPeripheralModel *model = manager.peripheralModel;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    void (^emitTimeout)(void) = ^{
        if (done) return;
        done = YES;
        [weakSelf sendEvent:@"tempHistory" data:@{ @"timeout": @YES, @"day": @(day) }];
        callback(resultWithCode(-1), NO);
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        emitTimeout();
    });

    // type 5 不支持独立历史接口（头文件明写），直接回 timeout，不让页面干等
    if (model.temperatureType == 5) {
        emitTimeout();
        return;
    }

    [pm veepooSdkStartReadDeviceTemperatureData:^(VPReadDeviceBaseDataState state, NSUInteger totalDay,
                                                  NSUInteger currentReadDayNumber, NSUInteger readCurrentDayProgress) {
        if (state == VPReadDeviceBaseDataReading) {
            [weakSelf sendEvent:@"tempHistory" data:@{ @"progress": @(readCurrentDayProgress / 100.0) }];
            return;
        }
        if (state != VPReadDeviceBaseDataComplete || done) return;
        done = YES;

        NSString *date = [weakSelf dateStrForDay:day];
        NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceTemperatureDataWithDate:date
                                                                          andTableID:model.deviceAddress ?: @""];
        NSMutableArray *list = [NSMutableArray array];
        for (NSDictionary *d in arr) {
            if (![d isKindOfClass:[NSDictionary class]]) continue;
            NSInteger h = 0, m = 0;
            JoemeTimeOfDict(d, &h, &m);
            double temp = JoemeDouble(JoemeFirstValue(d, @[ @"bodyTempValue", @"bodyTemperatrue", @"value" ]));
            double base = JoemeDouble(JoemeFirstValue(d, @[ @"originalTempValue", @"originalTemperatrue", @"originalValue" ]));
            if (temp <= 0 && base <= 0) continue;
            [list addObject:@{
                @"time": @{ @"hour": @(h), @"minute": @(m) },
                @"temp": @(temp),
                @"baseTemp": @(base),
                @"fromHandler": @NO
            }];
        }
        if (list.count > 0) {
            [weakSelf sendEvent:@"tempHistory" data:@{ @"list": list }];
        }
        [weakSelf sendEvent:@"tempHistory" data:@{ @"complete": @YES, @"day": @(day) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取 RR 逐跳原始数据。options: { dayState: 0|1|2 }
 iOS SDK：veepooSDK_readRRIntervalDataWithDayNumber:blockNumber:result:（每块回调一次）
 Android：readRRIntervalByDay；JS：joemeWatch.readRRData(day)
 事件：on('rrData') -> { progress, data:{blockNumber,date,time,rrs} } / { complete:true, listSize }
 说明：RR 数据每块是一分钟，块数 = 已采分钟数；SDK 没有「总块数」回调，这里从 1 读到
      第一个空块为止（最多 1440 块），避免无限请求。
 */
UNI_EXPORT_METHOD(@selector(readRRData:callback:))
- (void)readRRData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger day = options[@"dayState"] ? [options[@"dayState"] integerValue] : 0;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block NSInteger block = 1;
    __block NSInteger count = 0;
    __block BOOL finished = NO;
    __block void (^next)(void);

    next = ^{
        if (finished || block > 1440) {
            finished = YES;
            [weakSelf sendEvent:@"rrData" data:@{ @"complete": @YES, @"listSize": @(count) }];
            callback(resultWithCode(200), NO);
            return;
        }
        [pm veepooSDK_readRRIntervalDataWithDayNumber:day blockNumber:block result:^(id responseObject, NSProgress *progress, NSError *error) {
            if (error || ![responseObject isKindOfClass:[VPRRIntervalDataModel class]]) {
                finished = YES;
                [weakSelf sendEvent:@"rrData" data:@{ @"complete": @YES, @"listSize": @(count) }];
                callback(resultWithCode(error ? -1 : 200), NO);
                return;
            }
            VPRRIntervalDataModel *m = (VPRRIntervalDataModel *)responseObject;
            count++;
            NSUInteger bytes = m.dataConvertStream.length / 2;
            NSMutableArray *rrs = [NSMutableArray array];
            if (bytes > 0) {
                const uint8_t *raw = (const uint8_t *)m.dataConvertStream.bytes;
                for (NSUInteger i = 0; i < bytes; i++) {
                    uint16_t v = (uint16_t)(raw[i * 2] | (raw[i * 2 + 1] << 8));  // 小端
                    [rrs addObject:@(v)];
                }
            }
            NSDictionary *data = @{
                @"blockNumber": @(m.blockNumber),
                @"date": m.date ?: @"",
                @"time": m.time ?: @"",
                @"rrs": rrs
            };
            [weakSelf sendEvent:@"rrData" data:@{ @"progress": @(progress ? progress.fractionCompleted : 1.0), @"data": data }];
            block++;
            next();
        }];
    };
    next();
}

/**
 读取设备手动测量记录。options: { timestamp(毫秒), types: ['BLOOD_PRESSURE'|'BLOOD_GLUCOSE'|...] }
 iOS SDK：readManualTestDataWithTimestamp:dataType:result:（bitmask，一次回全部类型的数组）
 Android：readDeviceManualData；JS：joemeWatch.readManualData({...})
 事件（与 Android 同名同结构）：
   manualData.bp   -> { list:[{systolic,diastolic,heartRate,ts,measurementMode,testStatus,testTime,resultCredibility,version}] }
   manualData.hr   -> { list:[{ts,version,rate:[..]}] }
   manualData.bg   -> { list:[{ts,version,bloodGlucoseValue,risk}] }
   manualData.bc   -> { list:[{ts,version,uricAcid,tcho,tag,hdl,ldl}] }
   manualData.temp -> { list:[{ts,temperature,baseTemperature,version}] }
   manualData.spo2 -> { list:[{ts,value:[..]}] }
   manualData      -> { progress } / { complete:true } / { fail:true }
 单位换算（iOS 原始值是放大整数，Android 是浮点）：
   血糖 /100（协议上报 100 倍）；体温、皮温 /10；尿酸 /10（一位小数，μmol/L）；
   血脂四项 /100（两位小数，mmol/L）。血压与心率是原值。
 */
UNI_EXPORT_METHOD(@selector(readManualData:callback:))
- (void)readManualData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    double startMs = options[@"timestamp"] ? [options[@"timestamp"] doubleValue] : [[NSDate date] timeIntervalSince1970] * 1000.0;
    uint32_t startTs = (uint32_t)(startMs / 1000.0);

    // JS 的字符串 -> SDK 的位掩码；未传或全部无法识别时读全部
    VPManualTestDataType mask = VPManualTestDataNone;
    NSArray *types = options[@"types"];
    if ([types isKindOfClass:[NSArray class]]) {
        for (id t in types) {
            if (![t isKindOfClass:[NSString class]]) continue;
            NSString *s = [(NSString *)t uppercaseString];
            if ([s isEqualToString:@"BLOOD_PRESSURE"]) mask |= VPManualTestDataBloodPressure;
            else if ([s isEqualToString:@"HEART_RATE"]) mask |= VPManualTestDataHeartRate;
            else if ([s isEqualToString:@"BLOOD_GLUCOSE"] || [s isEqualToString:@"BLOOD_SUGAR"]) mask |= VPManualTestDataBloodSugar;
            else if ([s isEqualToString:@"BLOOD_OXYGEN"]) mask |= VPManualTestDataBloodOxygen;
            else if ([s isEqualToString:@"TEMPERATURE"] || [s isEqualToString:@"BODY_TEMPERATURE"]) mask |= VPManualTestDataTemperature;
            else if ([s isEqualToString:@"BLOOD_COMPOSITION"]) mask |= VPManualTestDataBloodComponents;
            else if ([s isEqualToString:@"STRESS"]) mask |= VPManualTestDataStress;
            else if ([s isEqualToString:@"HRV"]) mask |= VPManualTestDataHRV;
            else if ([s isEqualToString:@"MET"]) mask |= VPManualTestDataMet;
        }
    }
    if (mask == VPManualTestDataNone) mask = VPManualTestDataAll;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;

    [self sendEvent:@"manualData" data:@{ @"progress": @0 }];
    [pm readManualTestDataWithTimestamp:startTs dataType:mask result:^(VPManualTestDataModel *m) {
        if (!m) {
            [weakSelf sendEvent:@"manualData" data:@{ @"fail": @YES, @"message": @"设备无手动测量数据" }];
            callback(resultWithCode(200), NO);
            return;
        }

        // 血压
        if (m.bloodPressureArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualBloodPressureModel *r in m.bloodPressureArr) {
                [list addObject:@{
                    @"systolic": @(r.h_bp),
                    @"diastolic": @(r.l_bp),
                    @"heartRate": @(r.heart),
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"measurementMode": @(r.testModel),
                    @"testStatus": @(r.state),
                    @"testTime": @0,
                    @"resultCredibility": @(r.credibility),
                    @"version": @(r.protocol)
                }];
            }
            [weakSelf sendEvent:@"manualData.bp" data:@{ @"list": list }];
        }
        // 心率（每次测量一组逐跳值）
        if (m.heartRateArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualHeartRateModel *r in m.heartRateArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"version": @0,
                    @"rate": r.heartArray ?: @[]
                }];
            }
            [weakSelf sendEvent:@"manualData.hr" data:@{ @"list": list }];
        }
        // 血糖
        if (m.bloodSugarArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualBloodSugarModel *r in m.bloodSugarArr) {
                NSString *risk = @"NONE";
                if (r.haveLevel) {
                    if (r.bloodSugarLevel == 1) risk = @"LOW";
                    else if (r.bloodSugarLevel == 2) risk = @"MIDDLE";
                    else if (r.bloodSugarLevel == 3) risk = @"HIGH";
                }
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"version": @0,
                    @"bloodGlucoseValue": @(r.bloodSugarValue / 100.0),
                    @"risk": risk
                }];
            }
            [weakSelf sendEvent:@"manualData.bg" data:@{ @"list": list }];
        }
        // 血液成分
        if (m.bloodCompArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualBloodCompModel *r in m.bloodCompArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"version": @0,
                    @"uricAcid": @(r.uricAcid / 10.0),
                    @"tcho": @(r.totalCholesterol / 100.0),
                    @"tag": @(r.triglyceride / 100.0),
                    @"hdl": @(r.highDensityLipoprotein / 100.0),
                    @"ldl": @(r.lowDensityLipoprotein / 100.0)
                }];
            }
            [weakSelf sendEvent:@"manualData.bc" data:@{ @"list": list }];
        }
        // 体温
        if (m.bodyTempArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualBodyTempModel *r in m.bodyTempArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"temperature": @(r.bodyTemp / 10.0),
                    @"baseTemperature": @(r.origTemp / 10.0),
                    @"version": @0
                }];
            }
            [weakSelf sendEvent:@"manualData.temp" data:@{ @"list": list }];
        }
        // 血氧
        if (m.bloodOxygenArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPManualBloodOxygenModel *r in m.bloodOxygenArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"value": r.bloodOxygenArray ?: @[]
                }];
            }
            [weakSelf sendEvent:@"manualData.spo2" data:@{ @"list": list }];
        }

        [weakSelf sendEvent:@"manualData" data:@{ @"complete": @YES }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 读取饮酒提醒数据。
 iOS 端 SDK 没有饮酒数据读取接口（只有 peripheralModel.drinkState 这个握手状态位），
 与 Android readDrinkData 无法等价，这里明确回 -1 + drinkData 失败事件，避免页面干等。
 */
UNI_EXPORT_METHOD(@selector(readDrinkData:callback:))
- (void)readDrinkData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSDictionary *d = @{ @"fail": @YES, @"message": @"iOS SDK 不提供饮酒数据读取接口", @"unsupported": @YES };
    [self sendEvent:@"drinkData" data:d];
    NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
    [r addEntriesFromDictionary:d];
    callback(r, NO);
}

// ==================== 批次 3：能力探测与体温/血氧设置 ====================
// 对应 Android 的 getSpo2Capability / getTempCapability / readTemperatureSetting /
// setTemperatureUnit / readSpo2AutoDetect / setSpo2AutoDetect / readAutoMeasureSetting。
//
// iOS 没有 VpSpGetUtil 那样的能力位读取器，能力全在 VPPeripheralModel 上（握手时下发）：
//   oxygenType / oxygenAutoDetectType / temperatureType / hrvType / autoMonitSwitchType …
// 所以这里的探测结果直接由 peripheralModel 组装；route 的判定沿用 Android 的同一套规则
// （协议 3/5 → origin，其余 → 独立历史接口），只是协议号换成 iOS 的 fiveProtocolType。

/**
 血氧能力诊断（只读）。
 JS：joemeWatch.getSpo2Capability() -> resolve
   { code, protocolVersion, supportSpo2h, spo2hType, supportAllDay, supportNightMonitor,
     supportLowRemain, supportRemain, detecting, route }
 route：'none' 设备不支持血氧 / 'origin' 血氧挂在 5 分钟原始数据上 / 'spo2h' 走独立血氧历史表。
 说明：iOS 的血氧无论哪条通路都从 SDK 本地库取（readBasicData 或 readOxygenData），
      route 只用于页面选择「读哪一份数据」，两个方法在 iOS 上都能调用、都有兜底超时；
      supportLowRemain / supportRemain 是 Android 专有字段（低氧/呼吸暂停告警位），
      iOS 没有对应能力位，固定回 NO，页面按 false 处理即可。
 */
UNI_EXPORT_METHOD(@selector(getSpo2Capability:callback:))
- (void)getSpo2Capability:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    BOOL support = (m.oxygenType != 0);
    NSInteger protocol = m.fiveProtocolType;
    BOOL originRoute = (protocol == 3 || protocol == 5);

    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"protocolVersion"] = @(protocol);
    r[@"supportSpo2h"] = @(support);
    r[@"spo2hType"] = @(m.oxygenType);
    r[@"supportAllDay"] = @(support);
    r[@"supportNightMonitor"] = @(support);
    r[@"supportLowRemain"] = @NO;
    r[@"supportRemain"] = @NO;
    r[@"detecting"] = @NO;
    r[@"route"] = !support ? @"none" : (originRoute ? @"origin" : @"spo2h");
    callback(r, NO);
}

/**
 体温能力诊断（只读）。
 JS：joemeWatch.getTempCapability() -> resolve
   { code, temperatureType, supportReadTempture, supportCheckByApp, openDetectByApp,
     supportUnitSetting, supportAutoMeasure, temperatureUnit, route }
 route：'none'（temperatureType 0/1）/ 'origin'（2 或 5）/ 'history'（其余）。
 判定依据与 Android 注释一致：iOS 头文件明确「temperatureType 为 5 时独立体温历史接口不支持」，
 官方同步流程对 type==2 也只从日常数据取；其余类型才有独立体温表。
 supportUnitSetting：iOS 用 VPSettingTemperatureUnit 这个基本开关下发，能力位不存在，回 YES 由调用方试。
 */
UNI_EXPORT_METHOD(@selector(getTempCapability:callback:))
- (void)getTempCapability:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSInteger type = (NSInteger)m.temperatureType;
    NSString *route;
    if (type <= 1) route = @"none";
    else if (type == 2 || type == 5) route = @"origin";
    else route = @"history";

    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"temperatureType"] = @(type);
    // iOS 没有 isSupportReadTempture()/isSupportCheckTemptureByApp() 这类探针，
    // 用 route 反推：只有 history 通路才算「能独立读」，origin 通路则「设备自动测」。
    r[@"supportReadTempture"] = @([route isEqualToString:@"history"]);
    r[@"supportCheckByApp"] = @(type > 0);
    r[@"openDetectByApp"] = @NO;
    r[@"supportUnitSetting"] = @(type > 0);
    r[@"supportAutoMeasure"] = @(type >= 2);
    r[@"temperatureUnit"] = @"CELSIUS";
    r[@"route"] = route;
    callback(r, NO);
}

/**
 读取体温相关设置（结构化）。
 JS：joemeWatch.readTemperatureSetting() -> resolve + on('tempSetting')
   { code, unit:'C'|'F', unitRaw:'CELSIUS'|'FAHRENHEIT', autoDetect:true|false|null, autoRaw,
     temperatureType, supportReadTempture, supportCheckByApp, supportUnitSetting, supportAutoMeasure }
 实现：iOS 没有 CustomSettingData 读取接口，体温单位与自动检测都在「基本开关」里：
   VPSettingTemperatureUnit（读回 Open=摄氏 / Close=华氏）
   VPSettingAutomaticTemperatureTest（读回 Open=自动检测开 / Close=关）
 两者串行读取（SDK 不支持并发命令），任一失败就把该字段留空/null，页面保留本地值。
 */
UNI_EXPORT_METHOD(@selector(readTemperatureSetting:callback:))
- (void)readTemperatureSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;

    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"temperatureType"] = @(m.temperatureType);
    r[@"supportReadTempture"] = @(m.temperatureType > 1);
    r[@"supportCheckByApp"] = @(m.temperatureType > 0);
    r[@"supportUnitSetting"] = @(m.temperatureType > 0);
    r[@"supportAutoMeasure"] = @(m.temperatureType >= 2);

    void (^emit)(void) = ^{
        [weakSelf sendEvent:@"tempSetting" data:r];
        callback(r, NO);
    };

    // ① 读体温单位
    [pm veepooSDKSettingBaseFunctionType:VPSettingTemperatureUnit
                            settingState:VPReadFunctionState
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        if (state == VPFunctionCompleteOpen) {
            r[@"unit"] = @"C";
            r[@"unitRaw"] = @"CELSIUS";
        } else if (state == VPFunctionCompleteClose) {
            r[@"unit"] = @"F";
            r[@"unitRaw"] = @"FAHRENHEIT";
        } else {
            r[@"unit"] = @"C";
            r[@"unitRaw"] = @"";
        }

        // ② 读体温自动检测开关
        [pm veepooSDKSettingBaseFunctionType:VPSettingAutomaticTemperatureTest
                                settingState:VPReadFunctionState
                               completeBlock:^(VPSettingFunctionCompleteState autoState) {
            if (autoState == VPFunctionCompleteOpen) {
                r[@"autoDetect"] = @YES;
                r[@"autoRaw"] = @"SUPPORT_OPEN";
            } else if (autoState == VPFunctionCompleteClose) {
                r[@"autoDetect"] = @NO;
                r[@"autoRaw"] = @"SUPPORT_CLOSE";
            } else {
                // UNSUPPORT/失败：给 null，页面保留本地值（与 Android 同口径）
                r[@"autoDetect"] = [NSNull null];
                r[@"autoRaw"] = @"";
            }
            emit();
        }];
    }];
}

/**
 设置体温单位。options: { unit: 'C' | 'F' }
 JS：joemeWatch.setTemperatureUnit({unit}) -> resolve + on('tempSetting') { code, ok, unit, unitRaw }
 实现：iOS 把体温单位放在基本开关里（VPSettingTemperatureUnit，Open=摄氏 Close=华氏），
 与 Demo VPTemperatureViewController 里被注释掉的那行写法一致。
 */
UNI_EXPORT_METHOD(@selector(setTemperatureUnit:callback:))
- (void)setTemperatureUnit:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *u = options[@"unit"];
    BOOL celsius = !([u isKindOfClass:[NSString class]]
                     && ([u caseInsensitiveCompare:@"F"] == NSOrderedSame
                         || [u caseInsensitiveCompare:@"FAHRENHEIT"] == NSOrderedSame));
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingBaseFunctionType:VPSettingTemperatureUnit
                            settingState:(celsius ? VPSettingFunctionOpen : VPSettingFunctionClose)
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        r[@"ok"] = @(ok);
        r[@"unit"] = celsius ? @"C" : @"F";
        r[@"unitRaw"] = celsius ? @"CELSIUS" : @"FAHRENHEIT";
        [weakSelf sendEvent:@"tempSetting" data:r];
        callback(r, NO);
    }];
}

/**
 读取血氧自动检测（夜间自动监测）开关。
 JS：joemeWatch.readSpo2AutoDetect() -> resolve + on('spo2Auto')
   { isOpen:1|0|-1, openState, ok }
 实现：读基本开关 VPSettingAutomaticOxygenTest（枚举值 1000 那一档，Demo 用 tag=1000）。
      读不到时退回 peripheralModel.oxygenAutoDetectType（1=开，其它=未知）。
 */
UNI_EXPORT_METHOD(@selector(readSpo2AutoDetect:callback:))
- (void)readSpo2AutoDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingBaseFunctionType:VPSettingAutomaticOxygenTest
                            settingState:VPReadFunctionState
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        NSInteger open = -1;
        if (state == VPFunctionCompleteOpen) open = 1;
        else if (state == VPFunctionCompleteClose) open = 0;
        else if (model.oxygenAutoDetectType > 0) open = (model.oxygenAutoDetectType == 1 ? 1 : 0);

        NSDictionary *d = @{ @"isOpen": @(open), @"openState": @(state), @"ok": @(open >= 0) };
        [weakSelf sendEvent:@"spo2Auto" data:d];
        NSMutableDictionary *r = [resultWithCode(open >= 0 ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 设置血氧自动检测开关。options: { on }
 JS：joemeWatch.setSpo2AutoDetect({on}) -> resolve + on('spo2Auto') { isOpen, openState, ok }
 实现：veepooSDKSettingAllDayOxygenTest:（与 setAllDayOxygen 同一底层接口，
       iOS 侧这个接口就是「全天/夜间血氧自动检测」的总开关）。
 */
UNI_EXPORT_METHOD(@selector(setSpo2AutoDetect:callback:))
- (void)setSpo2AutoDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingAllDayOxygenTest:(on ? VPSettingFunctionOpen : VPSettingFunctionClose)
                                  result:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        NSDictionary *d = @{ @"isOpen": @(on ? 1 : 0), @"openState": @(state), @"ok": @(ok) };
        [weakSelf sendEvent:@"spo2Auto" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 读取自动测量开关列表。
 JS：joemeWatch.readAutoMeasureSetting() -> resolve + on('autoMeasureSetting') { list, items }
 实现：iOS 有结构化接口 veepooSDKReadAutoMonitSwitchInfo:（数组 VPAutoMonitTestModel），
      比 Android 的 toString 文本更可靠。为了不改页面（heart.vue 按 Android 的
      "AutoMeasureData{funType=PULSE_RATE, isSwitchOpen=true}" 文本解析），这里同时下发：
        items  结构化数组 [{type:'PULSE_RATE', on, timeInterval, startHour…}]
        list   与 Android 同形的文本（分号分隔，供现有解析器直接吃）
 */
UNI_EXPORT_METHOD(@selector(readAutoMeasureSetting:callback:))
- (void)readAutoMeasureSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKReadAutoMonitSwitchInfo:^(NSArray<VPAutoMonitTestModel *> *models) {
        NSMutableArray *items = [NSMutableArray array];
        NSMutableString *text = [NSMutableString string];
        for (VPAutoMonitTestModel *m in models) {
            NSString *name = [weakSelf autoMonitorTypeName:m.type];
            [items addObject:@{
                @"type": name,
                @"on": @(m.on),
                @"timeInterval": @(m.timeInterval),
                @"startHour": @(m.startHour),
                @"startMinute": @(m.startMinute),
                @"endHour": @(m.endHour),
                @"endMinute": @(m.endMinute),
                @"supportRangeTime": @(m.supportRangeTime),
                @"minStepValue": @(m.minStepValue)
            }];
            // 与 Android AutoMeasureData.toString 的可见字段对齐（页面只认 funType / isSwitchOpen）
            [text appendFormat:@"AutoMeasureData{funType=%@, isSwitchOpen=%@};",
             name, m.on ? @"true" : @"false"];
        }
        NSDictionary *d = @{ @"items": items, @"list": text };
        [weakSelf sendEvent:@"autoMeasureSetting" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/** VPAutoMonitTestType -> Android AutoMeasureData 的 funType 名（页面按这个字符串匹配） */
- (NSString *)autoMonitorTypeName:(VPAutoMonitTestType)type {
    switch (type) {
        case VPAutoMonitTestTypeHeartRate: return @"PULSE_RATE";
        case VPAutoMonitTestTypeBloodPressure: return @"BLOOD_PRESSURE";
        case VPAutoMonitTestTypeBloodGlucose: return @"BLOOD_GLUCOSE";
        case VPAutoMonitTestTypeStress: return @"STRESS";
        case VPAutoMonitTestTypeBloodOxygen: return @"BLOOD_OXYGEN";
        case VPAutoMonitTestTypeBodyTemperature: return @"TEMPERATURE";
        case VPAutoMonitTestTypeLorentz: return @"LORENTZ";
        case VPAutoMonitTestTypeHRV: return @"HRV";
        case VPAutoMonitTestTypeBloodComponents: return @"BLOOD_COMPONENTS";
        default: return @"UNKNOWN";
    }
}

/**
 读取全天血氧自动检测开关（AllSetSetting 通道）。
 JS：joemeWatch.readAllDayOxygen() -> resolve + on('allDayOxygen') { ok, isOpen, openState }
 说明：iOS 没有 AllSetData 回包，这里读基本开关 VPSettingAutomaticOxygenTest，
      与 readSpo2AutoDetect 共用同一能力位（只是事件名不同，页面各自监听）。
 */
UNI_EXPORT_METHOD(@selector(readAllDayOxygen:callback:))
- (void)readAllDayOxygen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingBaseFunctionType:VPSettingAutomaticOxygenTest
                            settingState:VPReadFunctionState
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose);
        BOOL isOpen = (state == VPFunctionCompleteOpen);
        if (!ok && model.oxygenAutoDetectType > 0) {
            isOpen = (model.oxygenAutoDetectType == 1);
            ok = YES;
        }
        NSDictionary *d = @{ @"ok": @(ok), @"isOpen": @(isOpen), @"openState": @(state) };
        [weakSelf sendEvent:@"allDayOxygen" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

// ==================== 批次 4：通知 / 通讯录 / SOS ====================
// 对应 Android 的 getNotifyState / openNotifyAccess / setNotifyForward / listNotifyApps /
// setNotifyOtherApps / sendSocialMsg / readContactList / moveContact / readSOSCallTimes。
//
// 关键差异：前 5 个是**手机本地能力**（NotificationListenerService + 通知使用权），
// 只有 Android 有；iOS 上收通知要靠 ANCS（系统蓝牙层），App 拿不到第三方通知内容，
// 所以这里统一返回「平台不支持」的结构（不 reject、不抛错），页面按 isAndroid 分支
// 本来就不会调用，这里只是防止跨端误调时炸掉。

/**
 本地通知转发状态（仅 Android）。iOS 无 NotificationListenerService。
 JS：joemeWatch.getNotifyState() -> resolve { granted:false, forwardEnabled:true, otherApps:[], unsupported:true }
 */
UNI_EXPORT_METHOD(@selector(getNotifyState:callback:))
- (void)getNotifyState:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"granted"] = @NO;
    r[@"forwardEnabled"] = @NO;
    r[@"otherApps"] = @[];
    r[@"unsupported"] = @YES;
    r[@"message"] = @"iOS 无通知使用权/通知转发（收通知走系统 ANCS）";
    callback(r, NO);
}

/** 打开系统「通知使用权」设置页（仅 Android）。iOS 无此页面，直接回 unsupported。 */
UNI_EXPORT_METHOD(@selector(openNotifyAccess:callback:))
- (void)openNotifyAccess:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"unsupported"] = @YES;
    r[@"message"] = @"iOS 无通知使用权设置";
    callback(r, NO);
}

/** 页面顶部「通知转发总开关」（仅 Android）。iOS 回 unsupported，不写设备。 */
UNI_EXPORT_METHOD(@selector(setNotifyForward:callback:))
- (void)setNotifyForward:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : NO;
    [self sendEvent:@"notifyForward" data:@{ @"ok": @NO, @"on": @(on), @"unsupported": @YES }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"unsupported"] = @YES;
    callback(r, NO);
}

/** 列出可转发的手机应用（仅 Android）。iOS 回空表 + unsupported。 */
UNI_EXPORT_METHOD(@selector(listNotifyApps:callback:))
- (void)listNotifyApps:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"list"] = @[];
    r[@"unsupported"] = @YES;
    callback(r, NO);
}

/** 保存「其他应用」白名单（仅 Android）。iOS 回 unsupported。 */
UNI_EXPORT_METHOD(@selector(setNotifyOtherApps:callback:))
- (void)setNotifyOtherApps:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSArray *packages = [options[@"packages"] isKindOfClass:[NSArray class]] ? options[@"packages"] : @[];
    [self sendEvent:@"notifyOtherApps" data:@{ @"ok": @NO, @"count": @(packages.count), @"unsupported": @YES }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"unsupported"] = @YES;
    callback(r, NO);
}

/**
 推送一条消息内容到设备（Android 用 sendSocialMsgContent）。
 iOS 没有对应的「App 主动推一条消息」接口：iOS 的推送链路是
 ANCS（系统在收到真实通知时自动转给手表），SDK 侧只提供图文传输
 （veepooSDKSendStartTransmissionMessage，那是「图文传输」功能，不是消息提醒）。
 因此这里回 -1 + unsupported，避免调用方以为消息发出去了。
 */
UNI_EXPORT_METHOD(@selector(sendSocialMsg:callback:))
- (void)sendSocialMsg:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *text = [options[@"text"] isKindOfClass:[NSString class]] ? options[@"text"] : @"";
    if (text.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"text 不能为空" }, NO);
        return;
    }
    NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
    r[@"unsupported"] = @YES;
    r[@"message"] = @"iOS 无 App 主动推送消息接口（系统 ANCS 自动转发真实通知）";
    callback(r, NO);
}

/**
 读取联系人列表（老入口，等价 readContact）。
 JS：joemeWatch.readContactList()
 */
UNI_EXPORT_METHOD(@selector(readContactList:callback:))
- (void)readContactList:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self readContact:options callback:callback];
}

/**
 移动联系人顺序。options: { from, to }（1-based 位置，与 Android/Demo 一致）
 iOS SDK：veepooSDKSettingDeviceContactsWithOpCode:opModel:toID:（opCode=Move，toID 是目标 1-based 位置）
 Android：moveContactWithPosition；JS：joemeWatch.moveContact({from,to})
 事件：on('contactOp') -> { ok, op:'move' }
 注意：设备语义是「把 from 这条移到 to 这个位置」，与 Android 的「交换」略有差别，
      页面拖拽是按相邻格逐条下发的，两者结果一致。
 */
UNI_EXPORT_METHOD(@selector(moveContact:callback:))
- (void)moveContact:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger from = options[@"from"] ? [options[@"from"] integerValue] : 0;
    NSInteger to = options[@"to"] ? [options[@"to"] integerValue] : 0;
    if (from <= 0 || to <= 0) {
        callback(@{ @"code": @(-1), @"message": @"移动联系人需要 from/to 两个位置（1-based）" }, NO);
        return;
    }
    VPDeviceContactsModel *m = [[VPDeviceContactsModel alloc] init];
    m.contactID = (int)from;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeMove
                                        opModel:m
                                           toID:(int)to
                                    resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
        BOOL ok = (state == VPDeviceContactsOpStateComplete);
        [self sendEvent:@"contactOp" data:@{ @"ok": @(ok), @"op": @"move" }];
        callback(resultWithCode(ok ? 200 : -1), NO);
    }];
}

/**
 读取紧急联系人呼叫次数。options: 无
 iOS SDK：veepooSDKSettingDeviceContactsSOSInfoWithOpCode:VPSOSOperationTypeRead
 Android：readSOSCallTimes；JS：joemeWatch.readSOSCallTimes() -> resolve { times, minTimes, maxTimes }
 事件：on('sosCallTimes') -> { times, minTimes, maxTimes }
 超时：不支持 SOS 的机型该命令可能无回包，10 秒看门狗回 -1（与 Android 一致）。
 */
UNI_EXPORT_METHOD(@selector(readSOSCallTimes:callback:))
- (void)readSOSCallTimes:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        NSDictionary *d = @{ @"ok": @NO, @"timeout": @YES, @"message": @"读取紧急呼叫次数超时：当前设备可能不支持 SOS" };
        [weakSelf sendEvent:@"sosCallTimes" data:d];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    });

    [pm veepooSDKSettingDeviceContactsSOSInfoWithOpCode:VPSOSOperationTypeRead
                                                 times:0
                                           resultBlock:^(VPDeviceContactsOpState state, int times, int timesMin, int timesMax) {
        if (state != VPDeviceContactsOpStateComplete || done) return;
        done = YES;
        NSDictionary *d = @{ @"times": @(times), @"minTimes": @(timesMin), @"maxTimes": @(timesMax) };
        [weakSelf sendEvent:@"sosCallTimes" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

// ==================== 批次 5：闹钟 / 提醒 / 女性 / 血压读回 ====================
// 对应 Android 的 readTextAlarm / modifyTextAlarm / deleteTextAlarm / readFemale /
// readHeartAlarm / readLongSeat / readHealthRemind / readBpModel / readBpFunction /
// settingBp / readFindDeviceSetting。
//
// iOS 的「读」几乎都是「同一个 settingMode 传 2/Read」拿回模型，所以这里都是
// 一次调用 + 模型转事件；只有健康提醒是一次读全部类型、逐条回调。

/** iOS 8 位重复串（十进制字符串）-> Android/JS 的 7 位「周一..周日」串 */
- (NSString *)androidRepeatFromIOSState:(NSString *)state {
    NSInteger v = [state isKindOfClass:[NSString class]] ? [state integerValue] : 0;
    NSMutableString *out = [NSMutableString string];
    // b[7]=周一 … b[1]=周日（头文件：开头一位恒 0，最后一位是周一）
    for (NSInteger bit = 7; bit >= 1; bit--) {
        [out appendString:((v >> bit) & 1) ? @"1" : @"0"];
    }
    return out;
}

/** Android/JS 的 7 位「周一..周日」串 -> iOS 8 位重复串（十进制字符串） */
- (NSString *)iosRepeatStateFromAndroid:(NSString *)repeat {
    if (![repeat isKindOfClass:[NSString class]] || repeat.length < 7) return @"0";
    NSInteger v = 0;
    for (NSInteger i = 0; i < 7; i++) {
        unichar c = [repeat characterAtIndex:i];
        if (c == '1') v |= (1 << (7 - i));
    }
    return [NSString stringWithFormat:@"%ld", (long)v];
}

/** 文本闹钟模型数组 -> 事件 list（字段与 Android textAlarmData 完全一致） */
- (NSArray *)textAlarmListFromModels:(NSArray *)alarmArray {
    NSMutableArray *list = [NSMutableArray array];
    for (VPDeviceTextAlarmModel *m in alarmArray) {
        if (![m isKindOfClass:[VPDeviceTextAlarmModel class]]) continue;
        NSInteger hour = [m.alarmHour integerValue];
        NSInteger minute = [m.alarmMinute integerValue];
        [list addObject:@{
            @"alarmId": m.alarmID ?: @"1",
            @"hour": @(hour),
            @"minute": @(minute),
            @"repeat": [self androidRepeatFromIOSState:m.repeatState],
            @"unRepeatDate": m.alarmDate ?: @"0000-00-00",
            @"isOpen": @([m.alarmState integerValue] == 1),
            @"content": m.alarmText ?: @""
        }];
    }
    // 与 Android 一致按时/分升序（设备回包顺序按 ID，页面直接渲染会跳）
    [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        NSInteger va = [a[@"hour"] integerValue] * 60 + [a[@"minute"] integerValue];
        NSInteger vb = [b[@"hour"] integerValue] * 60 + [b[@"minute"] integerValue];
        if (va == vb) return NSOrderedSame;
        return va < vb ? NSOrderedAscending : NSOrderedDescending;
    }];
    return list;
}

/** 从 options 构造 iOS 文本闹钟模型（增/改/删共用） */
- (VPDeviceTextAlarmModel *)textAlarmModelFromOptions:(NSDictionary *)options {
    NSMutableDictionary *dict = [NSMutableDictionary dictionary];
    dict[@"alarmHour"] = [NSString stringWithFormat:@"%ld", (long)(options[@"hour"] ? [options[@"hour"] integerValue] : 0)];
    dict[@"alarmMinute"] = [NSString stringWithFormat:@"%ld", (long)(options[@"minute"] ? [options[@"minute"] integerValue] : 0)];
    dict[@"alarmState"] = [NSString stringWithFormat:@"%d", options[@"enable"] ? ([options[@"enable"] boolValue] ? 1 : 0) : 1];
    id alarmId = options[@"alarmId"] ?: options[@"id"];
    dict[@"alarmID"] = alarmId ? [NSString stringWithFormat:@"%@", alarmId] : @"1";
    dict[@"repeatState"] = [self iosRepeatStateFromAndroid:options[@"repeat"]];
    dict[@"alarmText"] = [options[@"content"] isKindOfClass:[NSString class]] ? options[@"content"] : @"";
    dict[@"alarmDate"] = [options[@"unRepeatDate"] isKindOfClass:[NSString class]] ? options[@"unRepeatDate"] : @"0000-00-00";
    return [[VPDeviceTextAlarmModel alloc] initWithAlarmDict:dict];
}

/**
 读取文字闹钟（一次读整表）。
 iOS SDK：veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:settingMode:（Read=3，模型不能为 nil）
 Android：readTextAlarm；JS：joemeWatch.readTextAlarm() -> on('textAlarm')
 事件：on('textAlarm') -> { ok, oprate, list, message }
   oprate：READ_SUCCESS / READ_SUCCESS_NULL（设备上没有闹钟）/ READ_FAIL
 */
UNI_EXPORT_METHOD(@selector(readTextAlarm:callback:))
- (void)readTextAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:[[VPDeviceTextAlarmModel alloc] init]
                                              settingMode:VPDeviceTextAlarmSettingModelRead
                                            successResult:^(NSArray *alarmArray) {
        NSArray *list = [weakSelf textAlarmListFromModels:alarmArray];
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(list.count > 0);
        d[@"oprate"] = list.count > 0 ? @"READ_SUCCESS" : @"READ_SUCCESS_NULL";
        d[@"list"] = list;
        if (list.count == 0) d[@"message"] = @"设备上没有闹钟";
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        NSDictionary *d = @{ @"ok": @NO, @"oprate": @"READ_FAIL", @"list": @[] };
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 修改文字闹钟（开关/时间/标签/重复），必须带 alarmId。
 iOS SDK：同上，settingMode=AddOrChange(2)
 JS：joemeWatch.modifyTextAlarm({...}) -> on('textAlarm') { ok, oprate, list }
 */
UNI_EXPORT_METHOD(@selector(modifyTextAlarm:callback:))
- (void)modifyTextAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    id alarmId = options[@"alarmId"] ?: options[@"id"];
    if (!alarmId) {
        callback(@{ @"code": @(-1), @"message": @"modifyTextAlarm 需要 alarmId" }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPDeviceTextAlarmModel *m = [self textAlarmModelFromOptions:options];
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:m
                                              settingMode:VPDeviceTextAlarmSettingModelAddOrChange
                                            successResult:^(NSArray *alarmArray) {
        NSArray *list = [weakSelf textAlarmListFromModels:alarmArray];
        NSDictionary *d = @{ @"ok": @YES, @"oprate": @"SETTING_SUCCESS", @"list": list };
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        NSDictionary *d = @{ @"ok": @NO, @"oprate": @"SETTING_FAIL", @"list": @[] };
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 删除文字闹钟（按 alarmId）。
 iOS SDK：同上，settingMode=Delete(1)
 JS：joemeWatch.deleteTextAlarm({ alarmId }) -> on('textAlarm') { ok, oprate, list }
 */
UNI_EXPORT_METHOD(@selector(deleteTextAlarm:callback:))
- (void)deleteTextAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    id alarmId = options[@"alarmId"] ?: options[@"id"];
    if (!alarmId) {
        callback(@{ @"code": @(-1), @"message": @"deleteTextAlarm 需要 alarmId" }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPDeviceTextAlarmModel *m = [self textAlarmModelFromOptions:options];
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:m
                                              settingMode:VPDeviceTextAlarmSettingModelDelete
                                            successResult:^(NSArray *alarmArray) {
        NSArray *list = [weakSelf textAlarmListFromModels:alarmArray];
        NSDictionary *d = @{ @"ok": @YES, @"oprate": @"CLEAR_SUCCESS", @"list": list };
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        NSDictionary *d = @{ @"ok": @NO, @"oprate": @"CLEAR_FAIL", @"list": @[] };
        [weakSelf sendEvent:@"textAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 读取女性生理状态。
 iOS SDK：veepooSDKSettingDeviceFemaleWithFemaleModel:settingMode:2（读）
 Android：readWomenState；JS：joemeWatch.readFemale() -> on('female')
 事件：on('female') -> { ok, femaleState, lastMenstrualDate, menstrualCircle, menstrualDays,
                          expectedDateOfChildbirth, babyBirthday, isGirl, summary }
 说明：为兼容页面既有的 CustomSettingData 文本解析口径，额外带 summary
      （形如 WomenData{femaleState=...}）—— 当前页面只用结构化字段。
 */
UNI_EXPORT_METHOD(@selector(readFemale:callback:))
- (void)readFemale:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    VPDeviceFemaleModel *m = [[VPDeviceFemaleModel alloc] init];
    [pm veepooSDKSettingDeviceFemaleWithFemaleModel:m settingMode:2 successResult:^(VPDeviceFemaleModel *fm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(fm != nil);
        if (fm) {
            d[@"femaleState"] = [weakSelf femaleStateName:fm.femaleState];
            d[@"lastMenstrualDate"] = fm.lastMenstrualDate ?: @"";
            d[@"menstrualCircle"] = @(fm.menstrualCircle);
            d[@"menstrualDays"] = @(fm.menstrualDays);
            d[@"currentMenstrualDays"] = @(fm.currentMenstrualDays);
            d[@"expectedDateOfChildbirth"] = fm.expectedDateOfChildbirth ?: @"";
            d[@"babyBirthday"] = fm.babyBirthday ?: @"";
            d[@"isGirl"] = @(fm.isGirl);
            d[@"summary"] = [NSString stringWithFormat:@"WomenData{femaleState=%@, lastMenstrualDate=%@, menstrualCircle=%ld, menstrualDays=%ld}",
                             d[@"femaleState"], d[@"lastMenstrualDate"],
                             (long)fm.menstrualCircle, (long)fm.menstrualDays];
        }
        [weakSelf sendEvent:@"female" data:d];
        NSMutableDictionary *r = [resultWithCode(fm ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        [weakSelf sendEvent:@"female" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

- (NSString *)femaleStateName:(VPDeviceFemaleState)state {
    switch (state) {
        case VPDeviceFemaleStateMenstrual: return @"menstrual";
        case VPDeviceFemaleStatePregnancy: return @"pregnancy";
        case VPDeviceFemaleStateGestation: return @"gestation";
        case VPDeviceFemaleStateBaoma: return @"baoma";
        default: return @"none";
    }
}

/**
 读取心率报警阈值。
 iOS SDK：veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:settingMode:2
 Android：readHeartWarning；JS：joemeWatch.readHeartAlarm() -> on('heartAlarm')
 事件：on('heartAlarm') -> { ok, isOpen, heartHigh, heartLow, data }
 data 是与 Android HeartWaringData.toString() 同形的文本，
 页面（heart.vue / monitor.vue）正则解析 isOpen / heartHigh / heartLow。
 */
UNI_EXPORT_METHOD(@selector(readHeartAlarm:callback:))
- (void)readHeartAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:[[VPDeviceHeartAlarmModel alloc] init]
                                                settingMode:2
                                              successResult:^(VPDeviceHeartAlarmModel *hm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(hm != nil);
        if (hm) {
            d[@"isOpen"] = @(hm.isOpen);
            d[@"heartHigh"] = @(hm.heartMaxValue);
            d[@"heartLow"] = @(hm.heartMinValue);
            d[@"data"] = [NSString stringWithFormat:@"HeartWaringData{isOpen=%@, heartHigh=%lu, heartLow=%lu}",
                          hm.isOpen ? @"true" : @"false",
                          (unsigned long)hm.heartMaxValue, (unsigned long)hm.heartMinValue];
        }
        [weakSelf sendEvent:@"heartAlarm" data:d];
        NSMutableDictionary *r = [resultWithCode(hm ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        [weakSelf sendEvent:@"heartAlarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取久坐提醒。
 iOS SDK：veepooSDKSettingDeviceLongSeatWithLongSeatModel:settingMode:2
 Android：readLongSeat；JS：joemeWatch.readLongSeat() -> on('longSeat')
 事件：on('longSeat') -> { ok, isOpen, startHour, startMinute, endHour, endMinute, interval, data }
 */
UNI_EXPORT_METHOD(@selector(readLongSeat:callback:))
- (void)readLongSeat:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceLongSeatWithLongSeatModel:[[VPDeviceLongSeatModel alloc] init]
                                            settingMode:2
                                          successResult:^(VPDeviceLongSeatModel *lm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(lm != nil);
        if (lm) {
            d[@"isOpen"] = @(lm.longSeatState == 1);
            d[@"startHour"] = @(lm.longSeatStartHour);
            d[@"startMinute"] = @(lm.longSeatStartMinute);
            d[@"endHour"] = @(lm.longSeatEndHour);
            d[@"endMinute"] = @(lm.longSeatEndMinute);
            d[@"interval"] = @(lm.longSeatGateValue);
            d[@"data"] = [NSString stringWithFormat:@"LongSeatData{isOpen=%@, startHour=%lu, startMinute=%lu, endHour=%lu, endMinute=%lu, gateValue=%lu}",
                          lm.longSeatState == 1 ? @"true" : @"false",
                          (unsigned long)lm.longSeatStartHour, (unsigned long)lm.longSeatStartMinute,
                          (unsigned long)lm.longSeatEndHour, (unsigned long)lm.longSeatEndMinute,
                          (unsigned long)lm.longSeatGateValue];
        }
        [weakSelf sendEvent:@"longSeat" data:d];
        NSMutableDictionary *r = [resultWithCode(lm ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        [weakSelf sendEvent:@"longSeat" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取健康提醒（一次读全部类型，逐条回调）。
 iOS SDK：veepooSDKSettingHealthRemindWithRemindType:VPD…All opCode:2
 Android：readHealthRemind；JS：joemeWatch.readHealthRemind()
 事件：on('healthRemindRead') -> { type, on, startHour, startMinute, endHour, endMinute, interval, raw }
       on('healthRemindReadComplete') -> { complete:true }
 type 用 Android 的枚举名（SEDENTARY / DRINK_WATER / …），页面按它匹配卡片。
 iOS 的 resultBlock 只回单条（带 complete 标记表示整轮结束），所以逐条发事件。
 */
UNI_EXPORT_METHOD(@selector(readHealthRemind:callback:))
- (void)readHealthRemind:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block NSInteger count = 0;
    __block BOOL finished = NO;

    void (^emitComplete)(void) = ^{
        if (finished) return;
        finished = YES;
        [weakSelf sendEvent:@"healthRemindReadComplete" data:@{ @"complete": @YES, @"count": @(count) }];
        callback(resultWithCode(200), NO);
    };

    [pm veepooSDKSettingHealthRemindWithRemindType:VPDeviceHealthRemindTypeAll
                                            opCode:2
                                       remindModel:nil
                                       resultBlock:^(BOOL success, BOOL complete, VPDeviceHealthRemindModel *m) {
        if (success && m) {
            count++;
            NSString *name = [weakSelf healthRemindTypeName:m.type];
            [weakSelf sendEvent:@"healthRemindRead" data:@{
                @"type": name,
                @"on": @(m.open),
                @"startHour": @(m.startHour),
                @"startMinute": @(m.startMinute),
                @"endHour": @(m.endHour),
                @"endMinute": @(m.endMinute),
                @"interval": @(m.remindInterval),
                @"raw": [NSString stringWithFormat:@"HealthRemind{type=%@, open=%@, startHour=%u, startMinute=%u, endHour=%u, endMinute=%u, interval=%u}",
                         name, m.open ? @"true" : @"false",
                         m.startHour, m.startMinute, m.endHour, m.endMinute, m.remindInterval]
            }];
        }
        if (complete) emitComplete();
    } deviceInfoDidChangeBlock:^(VPDeviceHealthRemindModel *changeModel) {}];

    // 设备不回包时 15 秒兜底收尾，页面不会一直转圈
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        emitComplete();
    });
}

/** VPDeviceHealthRemindType -> Android HealthRemindType 名 */
- (NSString *)healthRemindTypeName:(VPDeviceHealthRemindType)type {
    switch (type) {
        case VPDeviceHealthRemindTypeLongSeat: return @"SEDENTARY";
        case VPDeviceHealthRemindTypeDrinkWater: return @"DRINK_WATER";
        case VPDeviceHealthRemindTypeLookFarAway: return @"OVERLOOK";
        case VPDeviceHealthRemindTypeSport: return @"SPORTS";
        case VPDeviceHealthRemindTypeTakeMedicine: return @"TAKE_MEDICINE";
        case VPDeviceHealthRemindTypeRead: return @"READING";
        case VPDeviceHealthRemindTypeTrip: return @"GOING_OUT";
        case VPDeviceHealthRemindTypeWashHands: return @"WASH";
        case VPDeviceHealthRemindTypeAll: return @"ALL";
        default: return @"UNKNOWN";
    }
}

/**
 读取血压私人模式设置（基准高低压 + 模式）。
 iOS SDK：veepooSDKSettingPersonalBloodWithModel:settingMode:（VPReadFunctionState=0 读取）
 Android：readDetectBP；JS：joemeWatch.readBpModel() -> on('bpModel')
 事件：on('bpModel') -> { ok, systolic, diastolic, privateMode, dynamicCalibration, data }
 */
UNI_EXPORT_METHOD(@selector(readBpModel:callback:))
- (void)readBpModel:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingPersonalBloodWithModel:[[VPDevicePrivateBloodModel alloc] init]
                                    settingMode:VPReadFunctionState
                                  successResult:^(VPDevicePrivateBloodModel *bm) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(bm != nil);
        if (bm) {
            d[@"systolic"] = @(bm.systolicPressure);
            d[@"diastolic"] = @(bm.diastolicPressure);
            d[@"privateMode"] = @(bm.privateMode);
            d[@"dynamicCalibration"] = @(bm.dynamicCalibration);
            d[@"data"] = [NSString stringWithFormat:@"BpSettingData{systolic=%lu, diastolic=%lu, privateMode=%lu}",
                          (unsigned long)bm.systolicPressure,
                          (unsigned long)bm.diastolicPressure,
                          (unsigned long)bm.privateMode];
        }
        [weakSelf sendEvent:@"bpModel" data:d];
        NSMutableDictionary *r = [resultWithCode(bm ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        [weakSelf sendEvent:@"bpModel" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取血压功能状态（能力位）。
 iOS 没有 BpFunctionData；这里用 peripheralModel.bloodPressureType 与若干能力位组装。
 Android：readBpFunctionState；JS：joemeWatch.readBpFunction() -> on('bpFunction')
 事件：on('bpFunction') -> { ok, supported, bloodPressureType, supportPrivate, data }
 */
UNI_EXPORT_METHOD(@selector(readBpFunction:callback:))
- (void)readBpFunction:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    BOOL supported = (m.bloodPressureType > 0);
    NSDictionary *d = @{
        @"ok": @YES,
        @"supported": @(supported),
        @"bloodPressureType": @(m.bloodPressureType),
        @"supportPrivate": @(supported),
        @"data": [NSString stringWithFormat:@"BpFunctionData{supported=%@, bloodPressureType=%lu}",
                  supported ? @"true" : @"false", (unsigned long)m.bloodPressureType]
    };
    [self sendEvent:@"bpFunction" data:d];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    [r addEntriesFromDictionary:d];
    callback(r, NO);
}

/**
 血压测量前置：下发基准高/低压（对齐 Android settingDetectBP）。
 options: { high, low, private? }
 iOS SDK：veepooSDKSettingPersonalBloodWithModel:settingMode:VPSettingFunction
 JS：joemeWatch.settingBp(high, low) -> on('bpSetting') { ok }
 说明：iOS 没有独立的「气囊基准值」接口，私人模式模型就是设备侧的血压基准；
      private 传 true 时按私人模式写入（血压测量 startMeasure('bp', {model:'private'}) 配套）。
 */
UNI_EXPORT_METHOD(@selector(settingBp:callback:))
- (void)settingBp:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPDevicePrivateBloodModel *m = [[VPDevicePrivateBloodModel alloc] init];
    m.systolicPressure = options[@"high"] ? [options[@"high"] unsignedIntegerValue] : 120;
    m.diastolicPressure = options[@"low"] ? [options[@"low"] unsignedIntegerValue] : 80;
    m.privateMode = [options[@"private"] boolValue] ? 1 : 0;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingPersonalBloodWithModel:m
                                    settingMode:VPSettingFunction
                                  successResult:^(VPDevicePrivateBloodModel *bm) {
        BOOL ok = (bm.settingState == 1 || bm.settingState == 8);
        NSDictionary *d = @{ @"ok": @(ok), @"state": @(bm.settingState) };
        [weakSelf sendEvent:@"bpSetting" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    } failureResult:^{
        [weakSelf sendEvent:@"bpSetting" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 读取查找设备功能开关/能力。
 iOS 没有「查找设备开关回读」接口，能力位在 peripheralModel.searchDeviceFunction。
 Android：readFindDevice；JS：joemeWatch.readFindDeviceSetting() -> on('findDeviceSet')
 事件：on('findDeviceSet') -> { ok, supported }
 */
UNI_EXPORT_METHOD(@selector(readFindDeviceSetting:callback:))
- (void)readFindDeviceSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSDictionary *d = @{ @"ok": @YES, @"supported": @(m.searchDeviceFunction > 0) };
    [self sendEvent:@"findDeviceSet" data:d];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    [r addEntriesFromDictionary:d];
    callback(r, NO);
}

// ==================== 批次 6：个性化设置 / 单位 / 天气 ====================
// 对应 Android 的 readCustomSetting / changeCustomSetting / readUnitSetting /
// readWeatherStatus / setWeatherStatus / setWeatherData / setVolume / musicControl。
//
// iOS 没有 CustomSettingData（整包读写）这个模型，开关分散在两类接口里：
//   ① veepooSDKSettingBaseFunctionType:settingsState:  —— 基本功能开关（含各单位、体温/HRV 自动检测）
//   ② peripheralModel.deviceSwitchData / deviceSwitchTwoData —— 握手时下发的开关快照
// 所以 readCustomSetting 走「读一组基本开关 → 拼出 Android 同形的 CustomSettingData{...} 文本」，
// 页面那套正则解析器（monitor.vue 的 _field）不用改；changeCustomSetting 则逐字段下发对应的
// 基本开关命令（iOS 没有整包写接口，只能一条条发）。

/** 单个基本开关的读取结果（Open/Close/其它） */
- (void)readBaseSwitch:(VPSettingBaseFunctionSwitchType)type done:(void(^)(VPSettingFunctionCompleteState state))done {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingBaseFunctionType:type settingState:VPReadFunctionState completeBlock:^(VPSettingFunctionCompleteState state) {
        if (done) done(state);
    }];
}

/**
 读取个性化设置（拼成 Android CustomSettingData 同形文本）。
 JS：joemeWatch.readCustomSetting() -> on('customSettingRead') { data }
 事件：on('customSettingRead') -> { data: "CustomSettingData{isOpenAutoHeartDetect=..., 自动检测HRV=..., ...}" }
 说明：Android 页面正则按英文/中文混合键取值，这里的键名与 SDK 的 toString 完全一致：
   isOpenAutoHeartDetect  心率自动检测（bool）
   自动检测HRV / 低氧报警 / 体温自动检测 / 血糖监测 / 压力 / 血液成分开关 / 跌倒检测（EFunctionStatus 名）
   血糖单位 / 尿 酸单位 / 血脂单位（枚举名）
 各字段是串行读取（SDK 不支持并发命令），全部读完才发一次事件。
 */
UNI_EXPORT_METHOD(@selector(readCustomSetting:callback:))
- (void)readCustomSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    __weak typeof(self) weakSelf = self;

    // 采集结果（读到什么写什么，读不到的字段从文本里省略，页面按 '' 处理）
    NSMutableDictionary *v = [NSMutableDictionary dictionary];

    // 待读的开关列表：顺序即下发顺序（串行）
    NSArray<NSNumber *> *types = @[
        @(VPSettingAutomaticHRTest),          // 心率自动检测（bool）
        @(VPSettingAutomaticHRVTest),         // 自动检测HRV
        @(VPSettingOxygenLowerRemind),        // 低氧报警
        @(VPSettingAutomaticTemperatureTest), // 体温自动检测
        @(VPSettingAutomaticBloodGlucoseTest),// 血糖监测
        @(VPSettingStress),                   // 压力
        @(VPSettingAutomaticBloodCompTest),   // 血液成分开关
        @(VPSettingFallDetection),            // 跌倒检测
        @(VPSettingBloodGlucoseUnit),         // 血糖单位
        @(VPSettingUricAcidUnit),             // 尿酸单位
        @(VPSettingLipidUnit)                 // 血脂单位
    ];
    NSArray<NSString *> *keys = @[
        @"isOpenAutoHeartDetect", @"自动检测HRV", @"低氧报警", @"体温自动检测",
        @"血糖监测", @"压力", @"血液成分开关", @"跌倒检测",
        @"血糖单位", @"尿酸单位", @"血脂单位"
    ];

    __block NSUInteger idx = 0;
    __block void (^next)(void);

    void (^emit)(void) = ^{
        NSMutableString *text = [NSMutableString stringWithString:@"CustomSettingData{"];
        NSUInteger n = 0;
        for (NSString *key in keys) {
            id val = v[key];
            if (!val) continue;
            if (n++ > 0) [text appendString:@", "];
            [text appendFormat:@"%@=%@", key, val];
        }
        [text appendString:@"}"];
        NSDictionary *d = @{ @"data": text };
        [weakSelf sendEvent:@"customSettingRead" data:d];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    };

    next = ^{
        if (idx >= types.count) { emit(); return; }
        NSUInteger i = idx++;
        VPSettingBaseFunctionSwitchType t = (VPSettingBaseFunctionSwitchType)[types[i] integerValue];
        [weakSelf readBaseSwitch:t done:^(VPSettingFunctionCompleteState state) {
            NSString *key = keys[i];
            if ([key isEqualToString:@"isOpenAutoHeartDetect"]) {
                // 心率自动检测在 Android toString 里是布尔（不是 EFunctionStatus）
                if (state == VPFunctionCompleteOpen) v[key] = @"true";
                else if (state == VPFunctionCompleteClose) v[key] = @"false";
            } else {
                NSString *name = [weakSelf functionStateName:state];
                if (name) v[key] = name;
            }
            next();
        }];
    };
    next();
}

/** VPSettingFunctionCompleteState -> Android EFunctionStatus 名（页面按 SUPPORT_OPEN 判断） */
- (NSString *)functionStateName:(VPSettingFunctionCompleteState)state {
    switch (state) {
        case VPFunctionCompleteOpen: return @"SUPPORT_OPEN";
        case VPFunctionCompleteClose: return @"SUPPORT_CLOSE";
        case VPFunctionCompleteUnknown: return @"UNSUPPORT";
        case VPFunctionCompleteFailure: return nil;   // 读失败：不写字段，页面保留本地值
        default: return nil;
    }
}

/**
 写入个性化设置（逐字段下发对应的基本开关）。
 options 与 Android changeCustomSetting 完全一致：
   { heart, temperature, unit:'C'|'F', glucose, glucoseUnit:'mmol'|'mgdl',
     hrv, spo2Low, bloodComponent, sleep, stress, fall, metric }
 JS：joemeWatch.setCustomSetting({...}) -> on('customSettingRead')（写完后回读一次）
 说明：iOS 没有整包写接口，也只能逐条下发；写完后自动调一次 readCustomSetting 回读，
      这样页面的「回显」逻辑与 Android 一致（写完即拿到设备真实状态）。
 未支持的键：sleep（精准睡眠 VPSettingAccurateSleep 头文件注明「暂时无效，用 PPG 控制」）、
            metric（公英制在 VPSettingMetric，已支持）；其余键均映射到对应枚举。
 */
UNI_EXPORT_METHOD(@selector(changeCustomSetting:callback:))
- (void)changeCustomSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;

    // 组装待下发命令（保持顺序，串行执行）
    NSMutableArray<NSDictionary *> *cmds = [NSMutableArray array];
    void (^add)(NSString *, VPSettingFunctionState) = ^(NSString *key, VPSettingFunctionState state) {
        if (options[key] == nil) return;
        [cmds addObject:@{ @"key": key, @"state": @(state) }];
    };

    add(@"heart", [options[@"heart"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"temperature", [options[@"temperature"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"glucose", [options[@"glucose"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"hrv", [options[@"hrv"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"spo2Low", [options[@"spo2Low"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"bloodComponent", [options[@"bloodComponent"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"stress", [options[@"stress"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"fall", [options[@"fall"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    add(@"metric", [options[@"metric"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);
    // 睡眠（科学睡眠）：iOS 用 VPSettingAutomaticPPGTest 控制（头文件：关闭 PPG 同时关闭精准睡眠）
    add(@"sleep", [options[@"sleep"] boolValue] ? VPSettingFunctionOpen : VPSettingFunctionClose);

    // 单位不是开关，单独按枚举下发（Open=第一档：摄氏 / mmol/L / μmol/L）
    NSString *unit = options[@"unit"];
    if ([unit isKindOfClass:[NSString class]]) {
        BOOL celsius = !([unit caseInsensitiveCompare:@"F"] == NSOrderedSame
                         || [unit caseInsensitiveCompare:@"FAHRENHEIT"] == NSOrderedSame);
        [cmds addObject:@{ @"type": @(VPSettingTemperatureUnit), @"state": @(celsius ? VPSettingFunctionOpen : VPSettingFunctionClose) }];
    }
    NSString *gu = options[@"glucoseUnit"];
    if ([gu isKindOfClass:[NSString class]]) {
        BOOL mgdl = ([gu caseInsensitiveCompare:@"mgdl"] == NSOrderedSame
                     || [gu caseInsensitiveCompare:@"mg_dl"] == NSOrderedSame
                     || [gu caseInsensitiveCompare:@"mg/dl"] == NSOrderedSame);
        [cmds addObject:@{ @"type": @(VPSettingBloodGlucoseUnit), @"state": @(mgdl ? VPSettingFunctionClose : VPSettingFunctionOpen) }];
    }
    NSString *uu = options[@"uricAcidUnit"];
    if ([uu isKindOfClass:[NSString class]]) {
        BOOL mgdl = ([uu caseInsensitiveCompare:@"mgdl"] == NSOrderedSame
                     || [uu caseInsensitiveCompare:@"mg_dl"] == NSOrderedSame);
        [cmds addObject:@{ @"type": @(VPSettingUricAcidUnit), @"state": @(mgdl ? VPSettingFunctionClose : VPSettingFunctionOpen) }];
    }
    NSString *fu = options[@"bloodFatUnit"];
    if ([fu isKindOfClass:[NSString class]]) {
        BOOL mgdl = ([fu caseInsensitiveCompare:@"mgdl"] == NSOrderedSame
                     || [fu caseInsensitiveCompare:@"mg_dl"] == NSOrderedSame);
        [cmds addObject:@{ @"type": @(VPSettingLipidUnit), @"state": @(mgdl ? VPSettingFunctionClose : VPSettingFunctionOpen) }];
    }

    if (cmds.count == 0) {
        callback(@{ @"code": @(-1), @"message": @"没有可下发的设置项" }, NO);
        return;
    }

    __block NSUInteger idx = 0;
    __block void (^next)(void);
    next = ^{
        if (idx >= cmds.count) {
            // 写完回读一次，页面靠 customSettingRead 回显（与 Android echo 同口径）
            [weakSelf readCustomSetting:@{} callback:callback];
            return;
        }
        NSDictionary *cmd = cmds[idx++];
        VPSettingBaseFunctionSwitchType type;
        if (cmd[@"type"]) {
            type = (VPSettingBaseFunctionSwitchType)[cmd[@"type"] integerValue];
        } else {
            type = [weakSelf baseFunctionTypeForKey:cmd[@"key"]];
        }
        VPSettingFunctionState state = (VPSettingFunctionState)[cmd[@"state"] integerValue];
        [pm veepooSDKSettingBaseFunctionType:type settingState:state completeBlock:^(VPSettingFunctionCompleteState s) {
            next();
        }];
    };
    next();
}

/** JS 字段名 -> 基本开关枚举 */
- (VPSettingBaseFunctionSwitchType)baseFunctionTypeForKey:(NSString *)key {
    if ([key isEqualToString:@"heart"]) return VPSettingAutomaticHRTest;
    if ([key isEqualToString:@"temperature"]) return VPSettingAutomaticTemperatureTest;
    if ([key isEqualToString:@"glucose"]) return VPSettingAutomaticBloodGlucoseTest;
    if ([key isEqualToString:@"hrv"]) return VPSettingAutomaticHRVTest;
    if ([key isEqualToString:@"spo2Low"]) return VPSettingOxygenLowerRemind;
    if ([key isEqualToString:@"bloodComponent"]) return VPSettingAutomaticBloodCompTest;
    if ([key isEqualToString:@"stress"]) return VPSettingStress;
    if ([key isEqualToString:@"fall"]) return VPSettingFallDetection;
    if ([key isEqualToString:@"metric"]) return VPSettingMetric;
    if ([key isEqualToString:@"sleep"]) return VPSettingAutomaticPPGTest;
    return VPSettingAutomaticHRTest;
}

/**
 读取单位设置（结构化）。
 JS：joemeWatch.readUnitSetting() -> resolve + on('unitSetting')
   { code, metricSystem:boolean, metricSystemSupport:boolean, metricSystemRaw,
     temperatureUnit:'CELSIUS'|'FAHRENHEIT'|'', bloodGlucoseUnit, uricAcidUnit, bloodFatUnit,
     supportWeather:boolean, supportTemperatureUnit:boolean }
 说明：与 readCustomSetting 读的是同一组基本开关，只是按单位字段单独输出；
      index/unitFrame 保留 Android 的字段（iOS 一次读完，恒为 1/true）。
 */
UNI_EXPORT_METHOD(@selector(readUnitSetting:callback:))
- (void)readUnitSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;

    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    NSArray<NSNumber *> *types = @[
        @(VPSettingMetric),
        @(VPSettingTemperatureUnit),
        @(VPSettingBloodGlucoseUnit),
        @(VPSettingUricAcidUnit),
        @(VPSettingLipidUnit)
    ];
    NSArray<NSString *> *keys = @[ @"metric", @"temperature", @"glucose", @"uricAcid", @"bloodFat" ];
    __block NSUInteger idx = 0;
    __block void (^next)(void);

    void (^emit)(void) = ^{
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        NSString *metric = v[@"metric"];
        r[@"metricSystem"] = @([metric isEqualToString:@"SUPPORT_OPEN"]);
        r[@"metricSystemSupport"] = @(metric != nil && ![metric isEqualToString:@"UNSUPPORT"]);
        r[@"metricSystemRaw"] = metric ?: @"";
        r[@"temperatureUnit"] = [weakSelf unitNameOf:v[@"temperature"] celsius:@"CELSIUS" other:@"FAHRENHEIT"];
        r[@"bloodGlucoseUnit"] = [weakSelf unitNameOf:v[@"glucose"] celsius:@"mmol_L" other:@"mg_dl"];
        r[@"uricAcidUnit"] = [weakSelf unitNameOf:v[@"uricAcid"] celsius:@"umol_L" other:@"mg_dl"];
        r[@"bloodFatUnit"] = [weakSelf unitNameOf:v[@"bloodFat"] celsius:@"mmol_L" other:@"mg_dl"];
        // 能力位（iOS 用握手字段；weatherType==1 才有天气）
        r[@"supportWeather"] = @(model.weatherType == 1);
        r[@"supportTemperatureUnit"] = @(model.temperatureType > 0);
        r[@"index"] = @1;
        r[@"unitFrame"] = @YES;
        [weakSelf sendEvent:@"unitSetting" data:r];
        callback(r, NO);
    };

    next = ^{
        if (idx >= types.count) { emit(); return; }
        NSUInteger i = idx++;
        VPSettingBaseFunctionSwitchType t = (VPSettingBaseFunctionSwitchType)[types[i] integerValue];
        [weakSelf readBaseSwitch:t done:^(VPSettingFunctionCompleteState state) {
            NSString *name = [weakSelf functionStateName:state];
            if (name) v[keys[i]] = name;
            next();
        }];
    };
    next();
}

/** Open/Close -> 单位枚举名（Open 为第一档：摄氏 / mmol/L / μmol/L） */
- (NSString *)unitNameOf:(NSString *)state celsius:(NSString *)first other:(NSString *)second {
    if ([state isEqualToString:@"SUPPORT_OPEN"]) return first;
    if ([state isEqualToString:@"SUPPORT_CLOSE"]) return second;
    return @"";
}

/**
 读取天气开关与单位。
 iOS SDK：VPWeatherHandle readWeatherInfo:（回 VPWeatherConfigModel：switchState / weatherUnit）
 JS：joemeWatch.readWeatherStatus() -> resolve + on('weather') { isOpen, weatherType, ok, raw }
 说明：weatherType 输出 'C' / 'F'（页面只认这两个字母）；
      iOS 的 weatherType（能力位）为 0 时也照常下发（与 Android 的「软提示」同口径）。
 */
UNI_EXPORT_METHOD(@selector(readWeatherStatus:callback:))
- (void)readWeatherStatus:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    __weak typeof(self) weakSelf = self;
    [[VPWeatherHandle share] readWeatherInfo:^(VPWeatherSettingState state, VPWeatherConfigModel *cfg) {
        BOOL ok = (state == VPWeatherSettingStateSuccess) && cfg != nil;
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(ok);
        if (cfg) {
            d[@"isOpen"] = @(cfg.switchState == 1);
            d[@"weatherType"] = (cfg.weatherUnit == 1) ? @"F" : @"C";
            d[@"raw"] = [NSString stringWithFormat:@"WeatherStatusData{isOpen=%@, weatherType=%@}",
                         cfg.switchState == 1 ? @"true" : @"false", d[@"weatherType"]];
        } else {
            d[@"message"] = @"设备不支持天气或读取失败";
        }
        [weakSelf sendEvent:@"weather" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 设置天气开关与单位。options: { isOpen, unit:'C'|'F' }
 iOS SDK：VPWeatherHandle settingWeatherInfo:（VPWeatherConfigModel）
 JS：joemeWatch.setWeatherStatus({...}) -> on('weather') { isOpen, weatherType, ok }
 */
UNI_EXPORT_METHOD(@selector(setWeatherStatus:callback:))
- (void)setWeatherStatus:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL open = options[@"isOpen"] ? [options[@"isOpen"] boolValue] : YES;
    NSString *u = options[@"unit"];
    BOOL celsius = !([u isKindOfClass:[NSString class]]
                     && ([u caseInsensitiveCompare:@"F"] == NSOrderedSame
                         || [u caseInsensitiveCompare:@"FAHRENHEIT"] == NSOrderedSame));
    VPWeatherConfigModel *cfg = [[VPWeatherConfigModel alloc] init];
    cfg.switchState = open ? 1 : 0;
    cfg.weatherUnit = celsius ? 0 : 1;
    __weak typeof(self) weakSelf = self;
    [[VPWeatherHandle share] settingWeatherInfo:cfg result:^(VPWeatherSettingState state) {
        BOOL ok = (state == VPWeatherSettingStateSuccess);
        NSDictionary *d = @{
            @"ok": @(ok),
            @"isOpen": @(open),
            @"weatherType": celsius ? @"C" : @"F"
        };
        [weakSelf sendEvent:@"weather" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 推送天气数据。options: { cityName, timestamp, source, temp, temp2, weatherId, crc }
 iOS SDK：VPWeatherHandle syncWeatherDataToDeviceWithWeatherServerModel:result:
 Android：settingWeatherData；JS：joemeWatch.setWeatherData({...}) -> on('weather')
 说明：iOS 的天气推送模型是 VPWeatherServerModel（含逐小时/逐天数组），比 Android 的
      WeatherData 复杂得多；这里用最小可用模型：城市 + 更新时间 + 当前温度（一次逐小时项）。
      页面当前只传 cityName/timestamp/source（天气列表数据由业务侧提供），
      温度缺省 0，设备端会显示「--」。完整逐小时/逐天推送需业务侧补齐 hourly/forecast。
 */
UNI_EXPORT_METHOD(@selector(setWeatherData:callback:))
- (void)setWeatherData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPWeatherServerModel *m = [[VPWeatherServerModel alloc] init];
    m.city = [options[@"cityName"] isKindOfClass:[NSString class]] ? options[@"cityName"] : @"";
    m.type = options[@"source"] ? [options[@"source"] intValue] : 0;
    double tsMs = options[@"timestamp"] ? [options[@"timestamp"] doubleValue] : [[NSDate date] timeIntervalSince1970] * 1000.0;
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm";
    m.update = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:tsMs / 1000.0]];

    // 当前温度：页面若提供 temp（摄氏）就放进一个逐小时项，否则留空
    if (options[@"temp"] != nil) {
        VPWeatherServerHourlyModel *h = [[VPWeatherServerHourlyModel alloc] init];
        h.time = m.update;
        double celsius = [options[@"temp"] doubleValue];
        h.temp = celsius * 9.0 / 5.0 + 32.0;   // 模型字段是华氏度
        h.code = options[@"weatherId"] ? [options[@"weatherId"] intValue] : 0;
        m.hourly = @[ h ];
    }
    m.forecast = @[];

    __weak typeof(self) weakSelf = self;
    [[VPWeatherHandle share] syncWeatherDataToDeviceWithWeatherServerModel:m result:^(VPWeatherSettingState state) {
        BOOL ok = (state == VPWeatherSettingStateSuccess);
        NSDictionary *d = @{ @"ok": @(ok), @"setWeatherData": @(ok), @"cityName": m.city ?: @"" };
        [weakSelf sendEvent:@"weather" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 设置音量。options: { volume: 0-100 }
 iOS 端没有独立音量接口（音乐音量随 veepooSDKSettingMessageType 的 VPSettingMusicControl 开关走），
 与 Android settingVolume 不等价 → 回 unsupported（页面当前无调用方）。
 */
UNI_EXPORT_METHOD(@selector(setVolume:callback:))
- (void)setVolume:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSInteger vol = options[@"volume"] ? [options[@"volume"] integerValue] : 50;
    [self sendEvent:@"volume" data:@{ @"fail": @YES, @"message": @"iOS SDK 无独立音量设置接口", @"volume": @(vol), @"unsupported": @YES }];
    NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
    r[@"unsupported"] = @YES;
    r[@"message"] = @"iOS SDK 无独立音量设置接口";
    callback(r, NO);
}

/**
 推送当前播放信息到手表。
 iOS 端没有 MusicData 推送接口（只有 VPSettingMusicControl 这个「音乐控制」开关，
 设备侧按系统媒体控制走；iOS 上手表控手机音乐靠系统 ANCS/媒体键，不经 SDK）。
 Android：settingMusicData；JS：joemeWatch.musicControl({...}) -> on('music')
 这里回 unsupported，避免调用方以为推送成功。
 */
UNI_EXPORT_METHOD(@selector(musicControl:callback:))
- (void)musicControl:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self sendEvent:@"music" data:@{ @"fail": @YES, @"message": @"iOS SDK 无音乐信息推送接口", @"unsupported": @YES }];
    NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
    r[@"unsupported"] = @YES;
    r[@"message"] = @"iOS SDK 无音乐信息推送接口";
    callback(r, NO);
}

// ==================== 批次 7：表盘 / 相机 / 其它 ====================
// 对应 Android 的 dialCapability / dialOnline / downloadDial / openCameraScreen /
// closeCameraScreen / setReportGps / modifyPwd / bleRename / pushTextImage /
// magneticTherapy / read4gServerInfo / readProductionInfo。

/**
 查询表盘能力（进入表盘页前调用）。
 JS：joemeWatch.dialCapability() -> resolve
   { code, platform:'jl'|'nordic'|'zk', jl, serverUi, customUi, serverCount, customCount,
     photoDialCount, cpuType }
 判定：iOS 用 peripheralModel.CPUType 区分平台（1=杰理 K 系，3/4=中科，其余按 Nordic/公版）；
      表盘数量取 peripheralModel.dialCount / marketDialCount / photoDialCount。
 */
UNI_EXPORT_METHOD(@selector(dialCapability:callback:))
- (void)dialCapability:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSInteger cpu = (NSInteger)m.CPUType;
    BOOL jl = (cpu == 1);
    BOOL zk = (cpu == 3 || cpu == 4);
    NSString *platform = jl ? @"jl" : (zk ? @"zk" : @"nordic");

    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"platform"] = platform;
    r[@"jl"] = @(jl);
    r[@"zk"] = @(zk);
    r[@"cpuType"] = @(cpu);
    r[@"serverUi"] = @(m.marketDialCount > 0);
    r[@"customUi"] = @(m.photoDialCount > 0);
    r[@"agpsUi"] = @(m.agpsFunction > 0);
    r[@"serverCount"] = @(m.marketDialCount);
    r[@"customCount"] = @(m.photoDialCount);
    r[@"photoDialCount"] = @(m.photoDialCount);
    r[@"defaultCount"] = @(m.dialCount);
    callback(r, NO);
}

/**
 拉取线上表盘市场（Veepoo 服务器）。
 JS：joemeWatch.dialOnline() -> on('dial') { kind:'online', ok, count, list:[{crc,name,fileUrl,previewUrl,...}] }
 实现：先用 veepooSDK_dialChannelWithChannelModel:Read 拿设备侧市场表盘信息（VPDeviceMarketDialModel），
      再调 VPMarketDialManager.getVeepooServerAllMarketDialsWithDeviceInfo: 拉服务器列表。
 */
UNI_EXPORT_METHOD(@selector(dialOnline:callback:))
- (void)dialOnline:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPMarketDialManager *mgr = [VPMarketDialManager share];
    __weak typeof(self) weakSelf = self;

    [self sendEvent:@"dial" data:@{ @"loading": @YES }];
    [pm veepooSDK_dialChannelWithChannelModel:VPDialChannelModelRead
                                    dialType:VPDeviceDialTypeMarket
                              photoDialModel:nil
                                      result:^(VPPhotoDialModel *photoDialModel,
                                               VPDeviceMarketDialModel *deviceMarketDialModel,
                                               NSError *error) {
        if (error || !deviceMarketDialModel) {
            [weakSelf sendEvent:@"dial" data:@{
                @"kind": @"online", @"fail": @YES,
                @"message": error.localizedDescription ?: @"读取设备表盘信息失败"
            }];
            callback(resultWithCode(-1), NO);
            return;
        }
        [mgr getVeepooServerAllMarketDialsWithDeviceInfo:deviceMarketDialModel
                                                 success:^(NSArray<VPServerMarketDialModel *> *response) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPServerMarketDialModel *s in response) {
                [list addObject:@{
                    @"crc": @(s.crc),
                    @"name": [NSString stringWithFormat:@"表盘 %d", s.crc],
                    @"fileUrl": s.fileUrl ?: @"",
                    @"previewUrl": s.previewUrl ?: @"",
                    @"dialShape": @(s.dialShape),
                    @"binProtocol": @(s.binProtocol)
                }];
            }
            NSDictionary *d = @{ @"kind": @"online", @"ok": @YES,
                                 @"count": @(list.count), @"total": @(list.count), @"list": list };
            [weakSelf sendEvent:@"dial" data:d];
            NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
            [r addEntriesFromDictionary:d];
            callback(r, NO);
        } failure:^(NSError *err, NSInteger code) {
            [weakSelf sendEvent:@"dial" data:@{
                @"kind": @"online", @"fail": @YES,
                @"message": err.localizedDescription ?: [NSString stringWithFormat:@"服务器返回错误(%ld)", (long)code]
            }];
            callback(resultWithCode(-1), NO);
        }];
    } transformProgress:nil];
}

/**
 下载线上表盘并推送到设备。
 options: { url, name?, crc?, imageId?, address?, length? }
 JS：joemeWatch.downloadDial({...}) -> on('dial') { downloading } → { downloadProgress } → { downloaded }
                                                         → { progress }（推送）→ { complete }
 实现：VPMarketDialManager.downloadMarketDialBinFileWithModel: → startTransferWithFilePath:
      上游的 VPDeviceMarketDialModel 需要设备侧信息（校验用），这里用页面回传的 crc/imageId/address/length
      组装一个最小模型；缺省时用 0（部分固件只校验 crc）。
 */
UNI_EXPORT_METHOD(@selector(downloadDial:callback:))
- (void)downloadDial:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *url = options[@"url"];
    if (![url isKindOfClass:[NSString class]] || url.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"url 不能为空" }, NO);
        return;
    }
    VPServerMarketDialModel *server = [[VPServerMarketDialModel alloc] init];
    server.fileUrl = url;
    server.crc = options[@"crc"] ? [options[@"crc"] intValue] : 0;
    server.dialShape = options[@"dialShape"] ? [options[@"dialShape"] intValue] : 0;
    server.binProtocol = options[@"binProtocol"] ? [options[@"binProtocol"] intValue] : 0;

    VPDeviceMarketDialModel *device = [[VPDeviceMarketDialModel alloc] init];
    device.imageId = options[@"imageId"] ? [options[@"imageId"] integerValue] : 0;
    device.address = options[@"address"] ? [options[@"address"] integerValue] : 0;
    device.length = options[@"length"] ? [options[@"length"] integerValue] : 0;

    VPMarketDialManager *mgr = [VPMarketDialManager share];
    __weak typeof(self) weakSelf = self;

    [self sendEvent:@"dial" data:@{ @"downloading": @YES }];
    [mgr downloadMarketDialBinFileWithModel:server deviceMarketDialModel:device success:^(NSURL *filePath) {
        [weakSelf sendEvent:@"dial" data:@{ @"downloaded": @YES, @"path": filePath.path ?: @"" }];
        [mgr startTransferWithFilePath:filePath transformProgress:^(double progress) {
            [weakSelf sendEvent:@"dial" data:@{ @"progress": @(progress * 100.0) }];
        } failure:^(NSError *error) {
            [weakSelf sendEvent:@"dial" data:@{
                @"fail": @YES,
                @"message": error.localizedDescription ?: @"表盘推送失败"
            }];
            callback(resultWithCode(-1), NO);
        }];
        // startTransfer 没有成功回调（只有 failure），下发成功即视为完成；
        // 严格校验需要设备端 readScreenStyle 回读，页面已有 setDial 的 complete 收尾。
        [weakSelf sendEvent:@"dial" data:@{ @"complete": @YES, @"name": options[@"name"] ?: @"" }];
        callback(resultWithCode(200), NO);
    } failure:^(NSError *error, NSInteger code) {
        [weakSelf sendEvent:@"dial" data:@{
            @"fail": @YES,
            @"message": error.localizedDescription ?: [NSString stringWithFormat:@"表盘下载失败(%ld)", (long)code]
        }];
        callback(resultWithCode(-1), NO);
    }];
}

/**
 打开 App 内相机页（手表遥控拍照）。
 iOS 端未实现原生相机预览页（需要 AVCaptureSession + 自定义 UI，超出 SDK 桥接范围），
 Android 的 openCameraScreen 承担的是「App 内预览 + 手表快门」这条链路，iOS 没有等价实现。
 JS：joemeWatch.openCameraScreen()
 返回：{ code:-2, supported:false, message }，调用方需回退到 startCamera + 系统相机。
 */
UNI_EXPORT_METHOD(@selector(openCameraScreen:callback:))
- (void)openCameraScreen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSMutableDictionary *r = [resultWithCode(-2) mutableCopy];
    r[@"supported"] = @NO;
    r[@"message"] = @"iOS 端未实现 App 内相机预览，请用 startCamera + 系统相机";
    callback(r, NO);
}

/** 关闭 App 内相机页（iOS 无该页面）：顺手让手表退出拍照模式，接口保持幂等。 */
UNI_EXPORT_METHOD(@selector(closeCameraScreen:callback:))
- (void)closeCameraScreen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if ([VPBleCentralManage sharedBleManager].peripheralManage) {
        [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSettingCameraType:VPCameraTypeExit
                                                                 settingAndMonitorResult:^(VPCameraType cameraType) {}];
    }
    [self sendEvent:@"cameraScreen" data:@{ @"open": @NO, @"count": @0, @"closedByWatch": @NO }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @NO;
    callback(r, NO);
}

/**
 GPS 实时上报开关（运动中手表每秒回报定位点）。
 iOS SDK：veepooSDK_readDeviceRTGPSDataWithState:result:（KAABA 系列 GPS 项目）
 Android：setReportGps；JS：joemeWatch.startGpsReport() / stopGpsReport()
 事件：on('reportGps') -> { open, lat, lon, altitude }
 说明：非 KAABA GPS 项目调用无回调，此时回 -1 + unsupported，页面按「无 GPS」处理。
 */
UNI_EXPORT_METHOD(@selector(setReportGps:callback:))
- (void)setReportGps:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL open = options[@"open"] ? [options[@"open"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_readDeviceRTGPSDataWithState:open result:^(BOOL start, VPDeviceKAABAGPSModel *model) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"open"] = @(start);
        if (model) {
            d[@"lat"] = @(model.latitude / 100000.0);
            d[@"lon"] = @(model.longitude / 100000.0);
            d[@"altitude"] = @(model.altitude);
        }
        [weakSelf sendEvent:@"reportGps" data:d];
        NSMutableDictionary *r = [resultWithCode(start == open ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        if (!start && open) {
            r[@"unsupported"] = @YES;
            r[@"message"] = @"当前设备不支持 GPS 实时上报（或不属于 KAABA 项目）";
        }
        callback(r, NO);
    }];
}

/**
 修改设备密码。options: { oldPwd }
 iOS SDK：veepooSDKSynchronousPasswordWithType:SettingPasswordType password:
          （iOS 的「设置密码」就是改密，oldPwd 不参与，SDK 内部用当前已验密会话）
 Android：modifyDevicePwd；JS：joemeWatch.modifyPwd(oldPwd) -> on('pwdModify') { ok }
 事件：on('pwdModify') -> { ok, result }
 */
UNI_EXPORT_METHOD(@selector(modifyPwd:callback:))
- (void)modifyPwd:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *pwd = options[@"pwd"] ?: options[@"newPwd"] ?: options[@"oldPwd"];
    if (![pwd isKindOfClass:[NSString class]] || pwd.length != 4) {
        callback(@{ @"code": @(-1), @"message": @"密码必须是 4 位数字" }, NO);
        return;
    }
    __weak typeof(self) weakSelf = self;
    [[VPBleCentralManage sharedBleManager] veepooSDKSynchronousPasswordWithType:SettingPasswordType
                                                                       password:pwd
                                                          SynchronizationResult:^(PasswordSynchronTpye result) {
        BOOL ok = (result == PasswordResetSuccess);
        NSDictionary *d = @{ @"ok": @(ok), @"result": @(result) };
        [weakSelf sendEvent:@"pwdModify" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 蓝牙重命名（改广播名）。
 iOS 没有独立的 BLE 重命名接口：veepooSDKSettingDeviceNameWithString 改的就是设备名
 （杰理平台 18 字节 / 其它 8 字节上限），这里与 setDeviceName 走同一底层，事件名对齐 Android 的 rename。
 JS：joemeWatch.bleRename(name) -> on('rename') { ok } / { fail }
 */
UNI_EXPORT_METHOD(@selector(bleRename:callback:))
- (void)bleRename:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *name = options[@"name"];
    if (![name isKindOfClass:[NSString class]] || name.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"name 不能为空" }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceNameWithString:name resultBlock:^(NSUInteger state) {
        BOOL ok = (state == 0);
        NSDictionary *d = ok ? @{ @"ok": @YES, @"name": name }
                             : @{ @"fail": @YES, @"state": @(state),
                                  @"message": (state == 2 ? @"名称过长" : (state == 3 ? @"名称过短" : @"重命名失败")) };
        [weakSelf sendEvent:@"rename" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 图文推送（文本）。
 iOS SDK：veepooSDKSendStartTransmissionMessage:AndResult:（图文传输通道）
 Android：pushTextMsg；JS：joemeWatch.pushTextImage({text}) -> on('pushText') { ok }
 说明：iOS 的图文传输是设备支持的独立功能（peripheralModel.textAndImageTransmissionType != 0），
      图片传输（veepooSDKSendStartTransmissionImage）需要 UIImage，本桥未开放。
 */
UNI_EXPORT_METHOD(@selector(pushTextImage:callback:))
- (void)pushTextImage:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *text = [options[@"text"] isKindOfClass:[NSString class]] ? options[@"text"] : @"";
    if (text.length == 0) {
        callback(@{ @"code": @(-1), @"message": @"text 不能为空" }, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSendStartTransmissionMessage:text AndResult:^(NSError *error) {
        BOOL ok = (error == nil);
        NSDictionary *d = @{ @"ok": @(ok), @"message": error.localizedDescription ?: @"" };
        [weakSelf sendEvent:@"pushText" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 磁疗（脉冲磁疗）开关。
 options: { on, type:0脉冲/1常规, minute:1-15, level:1-7 }
 iOS SDK：veepooSDK_setPulseAction:type:minute:level:，结果由 veepooSDK_pulseResultSubscribe: 回调
 Android：open/closeMagneticTherapy；JS：joemeWatch.magneticTherapy({...}) -> on('magnetic')
 事件：on('magnetic') -> { ok, state, respType, type, level, isDeviceChange }
 说明：回调只在支持的设备上触发；这里订阅一次并把结果转成事件（多次调用重复订阅，
      由 SDK 内部覆盖，不会叠加）。
 */
UNI_EXPORT_METHOD(@selector(magneticTherapy:callback:))
- (void)magneticTherapy:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    int type = options[@"type"] ? [options[@"type"] intValue] : 0;
    int minute = options[@"minute"] ? [options[@"minute"] intValue] : ([options[@"duration"] intValue] ?: 1);
    int level = options[@"level"] ? [options[@"level"] intValue] : 1;
    if (minute < 1 || minute > 15) minute = 1;
    if (level < 1 || level > 7) level = 1;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_pulseResultSubscribe:^(VPDevicePulseState state, BOOL isDeviceChange,
                                         VPDevicePulseResponceType respType, int t, int lv) {
        BOOL ok = (respType == VPDevicePulseResponceTypeSuccess) && (state != VPDevicePulseStateNoFunction);
        NSDictionary *d = @{
            @"ok": @(ok),
            @"state": @(state),
            @"respType": @(respType),
            @"type": @(t),
            @"level": @(lv),
            @"isDeviceChange": @(isDeviceChange)
        };
        [weakSelf sendEvent:@"magnetic" data:d];
    }];
    [pm veepooSDK_setPulseAction:on type:type minute:minute level:level];
    callback(resultWithCode(200), NO);
}

/**
 读取 4G 服务器配置信息。
 iOS SDK：veepooSDK_read4GDeviceConfigInfoSubscribe:（回调带 isReadAckInfo + 配置模型）
 Android：read4gServerInfo；JS：joemeWatch.read4gServerInfo() -> on('4gServer')
 事件：on('4gServer') -> { host, port, account, password, g4Switch, syncSwitch, interval, raw }
 */
UNI_EXPORT_METHOD(@selector(read4gServerInfo:callback:))
- (void)read4gServerInfo:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_read4GDeviceConfigInfoSubscribe:^(BOOL isReadAckInfo,
                                                    VP4GFunctionConfigurationInfoModel *info) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(info != nil);
        d[@"isReadAckInfo"] = @(isReadAckInfo);
        if (info) {
            d[@"host"] = info.deviceHost ?: @"";
            d[@"port"] = @(info.devicePort);
            d[@"account"] = info.account ?: @"";
            d[@"password"] = info.password ?: @"";
            d[@"g4Switch"] = @(info.is4GSwitchEnable);
            d[@"syncSwitch"] = @(info.isSyncDataSwitchEnable);
            d[@"interval"] = @(info.intervalTime);
            d[@"raw"] = [NSString stringWithFormat:
                         @"NetServer4gConfigInfo{host=%@, port=%u, account=%@, g4Switch=%@, syncSwitch=%@, interval=%u}",
                         d[@"host"], info.devicePort, d[@"account"],
                         info.is4GSwitchEnable ? @"true" : @"false",
                         info.isSyncDataSwitchEnable ? @"true" : @"false",
                         info.intervalTime];
        }
        [weakSelf sendEvent:@"4gServer" data:d];
        NSMutableDictionary *r = [resultWithCode(info ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 读取生产信息 / IMEI。
 iOS SDK：veepooSDK_readIMEIInfo:（只有 IMEI，没有 Android ProductionInfo 那套产测字段）
 Android：readProductionInfo；JS：joemeWatch.readProductionInfo() -> on('production')
 事件：on('production') -> { ok, imei, raw }
 */
UNI_EXPORT_METHOD(@selector(readProductionInfo:callback:))
- (void)readProductionInfo:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_readIMEIInfo:^(NSString *imei) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(imei.length > 0);
        d[@"imei"] = imei ?: @"";
        d[@"raw"] = [NSString stringWithFormat:@"ProductionInfo{imei=%@}", imei ?: @""];
        [weakSelf sendEvent:@"production" data:d];
        NSMutableDictionary *r = [resultWithCode(imei.length > 0 ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

// ==================== 批次 8：快捷测量入口 / 校准读取 ====================
// 对应 Android 的 fatigueDetect / hrvDetect / temperatureDetect（老的单类型快捷入口）、
// readBloodComponentCalibration / setBloodComponentCalibration / readGlucoseCalibration、
// readBodyComponentId。

/**
 疲劳度测量开关（老快捷入口）。
 iOS SDK：veepooSDKTestFatigueStart:（YES 开 / NO 关）
 Android：start/stopDetectFatigue；JS：joemeWatch.fatigueDetect(on) -> on('fatigue')
 事件：on('fatigue') -> { state, progress, value, message }
 说明：与 startMeasure('fatigue') 是同一底层接口的两个入口；两者共用 measuringType 状态，
      这里不占用该字段（老入口页面自行管理）。
 */
UNI_EXPORT_METHOD(@selector(fatigueDetect:callback:))
- (void)fatigueDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKTestFatigueStart:on testResult:^(VPTestFatigueState state, NSUInteger progress, NSUInteger value) {
        NSDictionary *d = @{
            @"state": @(state),
            @"progress": @(progress),
            @"value": @(value),
            @"message": [weakSelf fatigueLevelText:value]
        };
        [weakSelf sendEvent:@"fatigue" data:d];
    }];
    callback(resultWithCode(200), NO);
}

/**
 HRV 测量开关（老快捷入口）。
 iOS SDK：veepooSDK_HRVTest:callBack:
 Android：start/stopDetectHrv；JS：joemeWatch.hrvDetect(on) -> on('hrv')
 事件：on('hrv') -> { value, state, message }（设备持续回值，没有「完成」回调）
 */
UNI_EXPORT_METHOD(@selector(hrvDetect:callback:))
- (void)hrvDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_HRVTest:on callBack:^(int con, VPTestHRVState ack, int hrvValue) {
        BOOL ok = (ack == VPTestHRVStateTesting);
        NSDictionary *d = @{
            @"value": @(hrvValue),
            @"state": @(ack),
            @"con": @(con),
            @"message": ok ? @"HRV 测量中" : [weakSelf hrvFailText:ack]
        };
        [weakSelf sendEvent:@"hrv" data:d];
    }];
    callback(resultWithCode(200), NO);
}

/**
 体温测量开关（老快捷入口）。
 iOS SDK：veepooSDK_temperatureTestStart:result:
 Android：start/stopDetectTempture；JS：joemeWatch.temperatureDetect(on) -> on('tempDetect')
 事件：on('tempDetect') -> { state, progress, temperature, originalTemperature, message }
 单位：体温/体表温度都已 ÷10 换成 ℃。
 */
UNI_EXPORT_METHOD(@selector(temperatureDetect:callback:))
- (void)temperatureDetect:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options[@"on"] ? [options[@"on"] boolValue] : YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDK_temperatureTestStart:on result:^(VPTemperatureTestState state, BOOL enable,
                                                    NSInteger progress, NSInteger tempValue,
                                                    NSInteger originalTempValue) {
        NSDictionary *d = @{
            @"state": @(state),
            @"busy": @(enable),
            @"progress": @(progress),
            @"temperature": @(tempValue / 10.0),
            @"originalTemperature": @(originalTempValue / 10.0)
        };
        [weakSelf sendEvent:@"tempDetect" data:d];
    }];
    callback(resultWithCode(200), NO);
}

/**
 读取血液成分校准基准值。
 iOS SDK：veepooSDKBloodAnalysisPersonalWithOpCode:open:model:result:（opCode=2 读取）
 Android：readBloodComponentCalibration；JS：joemeWatch.readBloodComponentCalibration()
 事件：on('bloodComponentCalib') -> { ok, isOpen, uricAcid, tcho, tag, hdl, ldl, summary }
 单位：尿酸 μmol/L，血脂四项 mmol/L（模型本身就是该单位，不做换算）。
 */
UNI_EXPORT_METHOD(@selector(readBloodComponentCalibration:callback:))
- (void)readBloodComponentCalibration:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKBloodAnalysisPersonalWithOpCode:2
                                            open:NO
                                           model:nil
                                          result:^(BOOL success, BOOL open, VPBloodAnalysisResultModel *model) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(success);
        d[@"isOpen"] = @(open);
        if (model) {
            d[@"uricAcid"] = @(model.uricAcidValue);
            d[@"tcho"] = @(model.totalCholesterolValue);
            d[@"tag"] = @(model.triglycerideValue);
            d[@"hdl"] = @(model.highDensityLipoproteinValue);
            d[@"ldl"] = @(model.lowDensityLipoproteinValue);
            d[@"summary"] = [NSString stringWithFormat:
                             @"BloodComponent{uricAcid=%.1f, tcho=%.2f, tag=%.2f, hdl=%.2f, ldl=%.2f}",
                             model.uricAcidValue, model.totalCholesterolValue,
                             model.triglycerideValue, model.highDensityLipoproteinValue,
                             model.lowDensityLipoproteinValue];
        } else {
            d[@"message"] = success ? @"设备没有校准数据" : @"读取血液成分校准失败";
        }
        [weakSelf sendEvent:@"bloodComponentCalib" data:d];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 写入血液成分校准基准值。
 options: { isOpen, uricAcid, tcho, tag, hdl, ldl }
 iOS SDK：同上，opCode=1 设置（open + 基准值）
 JS：joemeWatch.setBloodComponentCalibration({...}) -> on('bloodComponentCalib') { ok, isOpen, ... }
 */
UNI_EXPORT_METHOD(@selector(setBloodComponentCalibration:callback:))
- (void)setBloodComponentCalibration:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL isOpen = options[@"isOpen"] ? [options[@"isOpen"] boolValue] : NO;
    VPBloodAnalysisResultModel *model = [[VPBloodAnalysisResultModel alloc] init];
    // 模型属性都是 assign double，直接赋值即可；SDK 内部用 getSendData 组包
    model.uricAcidValue = options[@"uricAcid"] ? [options[@"uricAcid"] doubleValue] : 0;
    model.totalCholesterolValue = options[@"tcho"] ? [options[@"tcho"] doubleValue] : 0;
    model.triglycerideValue = options[@"tag"] ? [options[@"tag"] doubleValue] : 0;
    model.highDensityLipoproteinValue = options[@"hdl"] ? [options[@"hdl"] doubleValue] : 0;
    model.lowDensityLipoproteinValue = options[@"ldl"] ? [options[@"ldl"] doubleValue] : 0;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKBloodAnalysisPersonalWithOpCode:1
                                            open:isOpen
                                           model:model
                                          result:^(BOOL success, BOOL open, VPBloodAnalysisResultModel *m) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(success);
        d[@"isOpen"] = @(open);
        if (m) {
            d[@"uricAcid"] = @(m.uricAcidValue);
            d[@"tcho"] = @(m.totalCholesterolValue);
            d[@"tag"] = @(m.triglycerideValue);
            d[@"hdl"] = @(m.highDensityLipoproteinValue);
            d[@"ldl"] = @(m.lowDensityLipoproteinValue);
        }
        if (!success) d[@"message"] = @"写入血液成分校准失败";
        [weakSelf sendEvent:@"bloodComponentCalib" data:d];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 读取血糖多校准（三餐餐前/餐后 + 开关）。
 iOS SDK：veepooSDKBloodGlucoseMultiPersonalWithOpCode:model:result:（opCode=2 读取）
 Android：readMultipleCalibrationBGValue；JS：joemeWatch.readGlucoseCalibration()
 事件：on('glucoseCalibRead') -> { ok, isOpen, breakfastBefore, breakfastAfter, lunchBefore,
                                   lunchAfter, dinnerBefore, dinnerAfter, summary }
 单位：模型 value 是 ×100 的整数（[300,1500] 对应 [3.0,15.0] mmol/L），÷100 后给页面。
 */
UNI_EXPORT_METHOD(@selector(readGlucoseCalibration:callback:))
- (void)readGlucoseCalibration:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKBloodGlucoseMultiPersonalWithOpCode:2 model:nil result:^(BOOL success, VPMultiBloodGlucoseModel *m) {
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"ok"] = @(success);
        d[@"isOpen"] = @(m ? m.open : NO);
        if (m) {
            // 六餐点：模型没给的项回 0（页面按 >0 判断是否已填）
            VPMultiBloodGlucoseItemModel *items[6] = {
                m.beforeBreakfast, m.afterBreakfast, m.beforeLunch,
                m.afterLunch, m.beforeDinner, m.afterDinner
            };
            NSArray<NSString *> *keys = @[ @"breakfastBefore", @"breakfastAfter", @"lunchBefore",
                                           @"lunchAfter", @"dinnerBefore", @"dinnerAfter" ];
            NSMutableString *summary = [NSMutableString stringWithString:@"MultiBloodGlucose{"];
            for (NSInteger i = 0; i < 6; i++) {
                VPMultiBloodGlucoseItemModel *it = items[i];
                double v = it ? it.value / 100.0 : 0;
                d[keys[i]] = @(v);
                [summary appendFormat:@"%@=%02u:%02u/%.2f%@",
                 keys[i], it ? it.hour : 0, it ? it.minute : 0, v, i == 5 ? @"" : @", "];
            }
            [summary appendString:@"}"];
            d[@"summary"] = summary;
        } else {
            d[@"message"] = success ? @"设备没有血糖校准数据" : @"读取血糖多校准失败";
        }
        [weakSelf sendEvent:@"glucoseCalibRead" data:d];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 读取身体成分历史 ID 列表（仅 Android 有 ID 概念）。
 iOS 的机身成分存在 SQLite 表里、以「日期 + 测量时间」为主键，没有 ID；
 这里回空列表 + unsupported，页面（body.vue）只把它当调试日志用。
 JS：joemeWatch.readBodyComponentId() -> on('bodyComponentId') { list: [], unsupported:true }
 */
UNI_EXPORT_METHOD(@selector(readBodyComponentId:callback:))
- (void)readBodyComponentId:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSDictionary *d = @{ @"list": @[], @"unsupported": @YES,
                         @"message": @"iOS 身体成分按日期+时间存储，没有 ID 概念" };
    [self sendEvent:@"bodyComponentId" data:d];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    [r addEntriesFromDictionary:d];
    callback(r, NO);
}

@end
