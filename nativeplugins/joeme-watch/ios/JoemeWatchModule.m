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

@end
