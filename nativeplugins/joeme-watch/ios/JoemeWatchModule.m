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
//   6. 同步个人信息传 birth（出生年份），不是 age
//   7. 健康测量没有独立 stop 接口，统一是把对应 start 接口的参数传 NO（startMeasure/stopMeasure 已封装）
//   8. 血糖上报值是 100 倍、体温上报值是 ℃ 的 10 倍，模块内已换算成 mmol/L、℃ 再给 JS
//
//  方法签名已对照 VeepooBleSDK.framework/Headers 逐一核对。
//  JS 侧契约见 utils/joeme-watch.js，方法名与事件名均不可随意改动。
//

#import "JoemeWatchModule.h"
#import <VeepooBleSDK/VeepooBleSDK.h>
// 这三个模型在 VPPeripheralBaseManage.h 里只有 @class 前置声明，
// 直接用它们的属性必须单独引入头文件（umbrella header 没有 import）。
#import <VeepooBleSDK/VPBodyCompositionValueModel.h>
#import <VeepooBleSDK/VPGSRResultModel.h>
#import <VeepooBleSDK/VPECGTestDataModel.h>
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
    NSUInteger sex = options ? [options[@"sex"] unsignedIntegerValue] : 1;
    NSUInteger height = options ? [options[@"height"] unsignedIntegerValue] : 170;
    NSUInteger weight = options ? [options[@"weight"] unsignedIntegerValue] : 60;
    NSInteger age = options ? [options[@"age"] integerValue] : 25;
    NSUInteger targetStep = options ? [options[@"targetStep"] unsignedIntegerValue] : 8000;
    if (height <= 0) height = 170;
    if (weight <= 0) weight = 60;
    if (age <= 0) age = 25;
    if (targetStep <= 0) targetStep = 8000;

    // iOS 传出生年份，需由年龄换算
    NSDateComponents *comp = [[NSCalendar currentCalendar] components:NSCalendarUnitYear fromDate:[NSDate date]];
    NSUInteger birth = (NSUInteger)(comp.year - age);

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSynchronousPersonalInformationWithStature:height
                                                    weight:weight
                                                     birth:birth
                                                       sex:sex
                                                targetStep:targetStep
                                                    result:^(NSUInteger settingResult) {
        [self sendEvent:@"personInfo" data:@{ @"success": @(settingResult == 1) }];
        callback(resultWithCode(200), NO);
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
    NSMutableDictionary *extra = [NSMutableDictionary dictionary];
    if (model) {
        extra[@"aveHeart"] = model.aveHeart ?: @"";
        extra[@"aveHrv"] = model.aveHrv ?: @"";
        extra[@"aveResRate"] = model.aveResRate ?: @"";
        extra[@"aveQT"] = model.aveQT ?: @"";
        extra[@"avePWV"] = model.avePWV ?: @"";
        extra[@"duration"] = model.duration ?: @"";
        extra[@"frequency"] = model.frequency ?: @"";
        extra[@"ecgType"] = model.ecgType ?: @"";
        extra[@"lead"] = model.lead ?: @"";
        extra[@"wavePoints"] = @(model.filterSignals.count);
        extra[@"gain"] = @([model getGainValue]);
    }
    d[@"extra"] = extra;
    [self sendEvent:@"measure" data:d];
    if (isDone) [self endMeasuring];
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
    [self sendEvent:@"funcSupport" data:@{ @"watchDataDay": @(pm.saveDays) }];
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
 Android：readWorldClock(...)；JS：joemeWatch.readWorldClock() -> resolve { list }
 事件：on('worldClock') -> { list }
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
                @"city": wc.cityName ?: @"",
                @"offset": wc.standardTimeZoneDiffer ?: @0
            }];
        }
        NSDictionary *d = @{ @"list": list };
        [self sendEvent:@"worldClock" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        callback(res, NO);
    }];
}

/**
 新增世界时钟。options: { city, id?, offset? }（offset 为相对 GMT 的 15 分钟数）。
 iOS SDK：veepooSDKWorldClockAddWithModel:result:
 Android：addWorldClock(...)；JS：joemeWatch.addWorldClock({...})
 事件：on('worldClockOp') -> { ok, op:'add' }
 */
UNI_EXPORT_METHOD(@selector(addWorldClock:callback:))
- (void)addWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPWorldClockModel *m = [[VPWorldClockModel alloc] init];
    m.cityName = options[@"city"] ?: @"";
    m.dataID = [options[@"id"] unsignedCharValue];
    m.standardTimeZoneDiffer = options[@"offset"] ?: options[@"hourOffset"] ?: @0;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockAddWithModel:m result:^(BOOL success) {
        [self sendEvent:@"worldClockOp" data:@{ @"ok": @(success), @"op": @"add" }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 删除世界时钟。options: { id }（dataID，1 起）。
 iOS SDK：veepooSDKWorldClockDeleteWithID:result:
 Android：deleteWorldClock(...)；JS：joemeWatch.deleteWorldClock({ id })
 事件：on('worldClockOp') -> { ok, op:'delete' }
 */
UNI_EXPORT_METHOD(@selector(deleteWorldClock:callback:))
- (void)deleteWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    uint8_t delID = [options[@"id"] unsignedCharValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKWorldClockDeleteWithID:delID result:^(BOOL success) {
        [self sendEvent:@"worldClockOp" data:@{ @"ok": @(success), @"op": @"delete" }];
        callback(resultWithCode(200), NO);
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
 单条消息推送开关。options: { type, on }
   type: 'call' | 'sms' | 'wechat' | 'qq' | 'whatsapp' | 'line' | 'instagram' | 'other'
 iOS SDK：veepooSDKSettingMessageType:settingState:completeBlock:
          （VPSettingMessageSwitchType；VPSettingFunctionState 1=开 2=关）
 Android：setFunctionSocailMsgData + settingSocialMsg；JS：joemeWatch.setMessageType(type, on)
 事件：on('messageType') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setMessageType:callback:))
- (void)setMessageType:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *type = options[@"type"];
    BOOL on = [options[@"on"] boolValue];
    VPSettingMessageSwitchType mt = VPSettingCall;
    if ([type isEqualToString:@"call"]) mt = VPSettingCall;
    else if ([type isEqualToString:@"sms"]) mt = VPSettingSMS;
    else if ([type isEqualToString:@"wechat"]) mt = VPSettingWechat;
    else if ([type isEqualToString:@"qq"]) mt = VPSettingQQ;
    else if ([type isEqualToString:@"whatsapp"]) mt = VPSettingwhatsapp;
    else if ([type isEqualToString:@"line"]) mt = VPSettingLine;
    else if ([type isEqualToString:@"instagram"]) mt = VPSettingInstagram;
    else if ([type isEqualToString:@"other"]) mt = VPSettingOtherPlatform;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKSettingMessageType:mt settingState:(on ? VPSettingFunctionOpen : VPSettingFunctionClose) completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        [self sendEvent:@"messageType" data:@{ @"ok": @(ok) }];
        callback(resultWithCode(200), NO);
    }];
}

/**
 批量消息推送开关。options: { items: [{ type, on }] }
 iOS SDK：契约点名的 veepooSDKSettingMessageWithData: 入参为预编码 NSData（格式不公开），
          这里改用同模块类型安全的批量接口 veepooSDKBatchSettingWithMessageTypeModels:completeBlock:
          （VPDeviceMessageTypeModel.messageType/open），语义等价。
 Android：settingSocialMsg(..., FunctionSocailMsgData)；JS：joemeWatch.setSocialMsg(data)
 事件：on('socialMsg') -> { ok }
 */
UNI_EXPORT_METHOD(@selector(setSocialMsg:callback:))
- (void)setSocialMsg:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSArray *items = options[@"items"];
    NSMutableArray<VPDeviceMessageTypeModel *> *models = [NSMutableArray array];
    if ([items isKindOfClass:[NSArray class]]) {
        for (NSDictionary *it in items) {
            if (![it isKindOfClass:[NSDictionary class]]) continue;
            VPDeviceMessageTypeModel *m = [[VPDeviceMessageTypeModel alloc] init];
            NSString *t = it[@"type"];
            VPSettingMessageSwitchType mt = VPSettingCall;
            if ([t isEqualToString:@"call"]) mt = VPSettingCall;
            else if ([t isEqualToString:@"sms"]) mt = VPSettingSMS;
            else if ([t isEqualToString:@"wechat"]) mt = VPSettingWechat;
            else if ([t isEqualToString:@"qq"]) mt = VPSettingQQ;
            else if ([t isEqualToString:@"whatsapp"]) mt = VPSettingwhatsapp;
            else if ([t isEqualToString:@"line"]) mt = VPSettingLine;
            else if ([t isEqualToString:@"instagram"]) mt = VPSettingInstagram;
            else if ([t isEqualToString:@"other"]) mt = VPSettingOtherPlatform;
            m.messageType = mt;
            m.open = [it[@"on"] boolValue];
            [models addObject:m];
        }
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDKBatchSettingWithMessageTypeModels:models completeBlock:^(VPSettingFunctionCompleteState state) {
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteComplete);
        [self sendEvent:@"socialMsg" data:@{ @"ok": @(ok) }];
        callback(resultWithCode(200), NO);
    }];
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
                @"id": @(c.contactID),
                @"name": c.nickName ?: @"",
                @"phone": c.phoneNumber ?: @"",
                @"isSOS": @(c.isSOS)
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
    m.nickName = options[@"name"] ?: @"";
    m.phoneNumber = options[@"phone"] ?: @"";
    m.isSOS = [options[@"isSOS"] boolValue];
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
    m.contactID = [options[@"id"] intValue];
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
            [self sendEvent:@"sos" data:@{ @"ok": @(state == VPDeviceContactsOpStateComplete) }];
            callback(resultWithCode(200), NO);
        }];
    } else {
        VPDeviceContactsModel *m = [[VPDeviceContactsModel alloc] init];
        m.contactID = [options[@"id"] intValue];
        m.nickName = options[@"name"] ?: @"";
        m.phoneNumber = options[@"phone"] ?: @"";
        m.isSOS = [options[@"on"] boolValue];
        [pm veepooSDKSettingDeviceContactsWithOpCode:VPDeviceContactsOpCodeEdit opModel:m toID:0 resultBlock:^(VPDeviceContactsOpState state, NSArray<VPDeviceContactsModel *> *contactModels) {
            [self sendEvent:@"sos" data:@{ @"ok": @(state == VPDeviceContactsOpStateComplete) }];
            callback(resultWithCode(200), NO);
        }];
    }
}

// ---------- 7. 相机遥控（camera） ----------

/**
 进入相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:settingAndMonitorResult:（VPCameraTypeEnter=1）
          回调里 VPCameraTypePhoto(2) 表示用户按下拍照，App 应据此调用系统相机拍照。
 Android：startCamera(...)；JS：joemeWatch.startCamera()
 事件：on('camera') -> { state }
 */
UNI_EXPORT_METHOD(@selector(startCamera:callback:))
- (void)startCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingCameraType:VPCameraTypeEnter settingAndMonitorResult:^(VPCameraType cameraType) {
        [weakSelf sendEvent:@"camera" data:@{ @"state": @(cameraType) }];
    }];
    callback(resultWithCode(200), NO);
}

/**
 退出相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:...（VPCameraTypeExit=0）
 Android：stopCamera(...)；JS：joemeWatch.stopCamera()
 事件：on('camera') -> { state }
 */
UNI_EXPORT_METHOD(@selector(stopCamera:callback:))
- (void)stopCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDKSettingCameraType:VPCameraTypeExit settingAndMonitorResult:^(VPCameraType cameraType) {}];
    [self sendEvent:@"camera" data:@{ @"state": @(VPCameraTypeExit) }];
    callback(resultWithCode(200), NO);
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

@end
