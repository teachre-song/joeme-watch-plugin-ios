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
#import "JoemeCameraCapture.h"
#import "JoemeCameraStore.h"
#import "JoemeCameraViewController.h"
#import <UIKit/UIKit.h>
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
#import <VeepooBleSDK/VPDeviceSportWithGPSModel.h>
#import <VeepooBleSDK/VPDeviceSportModel.h>

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

/** 运动记录读取会话号；每次 readDeviceRunningData 自增，旧会话的迟到回调按它丢弃 */
@property (nonatomic, assign) NSInteger sportReadSeq;

/** 最近一次拿到的文本闹钟整表（新增时用它挑空闲 alarmId，避免覆盖已有闹钟） */
@property (nonatomic, strong) NSArray<NSDictionary *> *lastTextAlarms;

/** 世界时钟本地缓存（对齐 Android mWorldClockCache）：add 挑空闲 id、delete/move 校验用。
    懒加载 getter 在 @implementation 里手写，所以这里只声明，不自动合成。 */
- (NSMutableArray<VPWorldClockModel *> *)worldClockCache;
/** 是否成功读过一次世界时钟列表。用标志而不是 cache.isEmpty ——
    设备上 0 个时钟时读成功缓存也是空的，按 isEmpty 判断会让第一次添加永远走不下去。 */
@property (nonatomic, assign) BOOL worldClockRead;
/** 设备端删除订阅是否已安装（断连后 SDK 槽位会丢，重连要重装） */
@property (nonatomic, assign) BOOL worldClockSubInstalled;

/** 相机遥控是否已进入（避免重复下发 Enter/Exit 让手表闪屏） */
@property (nonatomic, assign) BOOL cameraEntered;
/** listenCamera 是否已注册常驻相机 block（SDK 只有一个槽位，装一次即可） */
@property (nonatomic, assign) BOOL cameraMonitorInstalled;
/** 常驻相机监听 block：SDK 只存一个槽位，Enter/Exit 必须复用它 */
@property (nonatomic, copy) void (^cameraMonitor)(VPCameraType type);
/** 本模块主动下发、尚未收到回执的 Exit 条数（用于过滤自己发的 Exit 回执） */
@property (nonatomic, assign) NSInteger pendingSelfExit;
/** 最近一次主动下发 Exit 的时间；超出窗口就认为对端没回包，不再过滤 */
@property (nonatomic, assign) NSTimeInterval pendingSelfExitAt;

/** 表盘列表会话号：每次 dialList 自增，迟到的 BLE 回调与看门狗按它丢弃 */
@property (nonatomic, assign) NSInteger dialSeq;
/** 表盘切换/传输会话号：每次推送自增，用于「完成回调」与「看门狗」互斥 */
@property (nonatomic, assign) NSInteger dialSwitchSeq;
/** JL 表盘缓存：[{name, group:'sys'|'server'|'pic', index?}]。
    页面切盘只回传设备路径（/WATCH026），靠它反查分组与系统表盘序号。 */
@property (nonatomic, strong) NSArray<NSDictionary *> *jlDialCache;
/** 设备当前照片表盘文件名（由 describe 元数据读回，切 kind:'pic' 时用） */
@property (nonatomic, copy) NSString *jlCurrentPicName;
/** 非 JL：最近一次读到的设备侧市场表盘信息（imageId/address/length…）。
    下载 bin 时 SDK 要用它做 CRC 校验与容量判断，页面拿不到这些字段，只能由原生缓存。 */
@property (nonatomic, strong) VPDeviceMarketDialModel *dialDeviceInfo;

/** 最近一次**实时读成功**的天气状态（isOpen / unit / crc）。
    用途有两个：
      1) 页面没读到状态时 setWeatherStatus 靠它保住设备原开关；
      2) 下发设置时带上设备回过的 crc（官方 Demo WeatherActivity 就是
         `setting.crc = crc`，crc 来自上一次读回；iOS SDK 的模型里也有 crc 字段）。
    只在读到真模型时更新，写回执不写这里 —— 否则回读验证会自己证明自己成功。 */
@property (nonatomic, strong) NSDictionary *lastWeatherStatus;
/** 天气读取进行中的回调队列：SDK 的 readWeatherInfo 无并发保护，同一时刻只允许一次。 */
@property (nonatomic, strong) NSMutableArray *weatherReadQueue;

// 相机相关内部方法（第 7 节实现）：显式声明，避免后向调用产生
// "instance method not found" 告警
- (void (^)(VPCameraType))cameraMonitorBlock;
- (void)sendCameraExitCommand;
- (void)installCameraMonitorIfNeeded;
- (void)enterCameraMode;
- (void)exitCameraMode;
- (void)handleCameraType:(VPCameraType)type;
- (void)capturePhotoSilentlyInto:(NSMutableDictionary *)cameraEvent;
- (BOOL)presentCameraScreenNotifyWatch:(BOOL)notifyWatch;

// 个性化设置 / 单位 / 天气（第 6 节实现）：显式声明，避免后向调用告警
- (void)readBaseSwitch:(VPSettingBaseFunctionSwitchType)type
                  done:(void (^)(VPSettingFunctionCompleteState state))done;
- (NSString *)functionStateName:(VPSettingFunctionCompleteState)state;
- (NSString *)unitNameOf:(NSString *)state first:(NSString *)first second:(NSString *)second;
- (VPSettingBaseFunctionSwitchType)baseFunctionTypeForKey:(NSString *)key;

// 世界时钟（第 5 节实现）：内部辅助，先声明避免后向调用告警
- (BOOL)worldClockSupported;
- (uint8_t)nextWorldClockId;
- (NSDictionary *)worldClockDict:(VPWorldClockModel *)wc;
- (void)installWorldClockDeleteSubIfNeeded;
- (void)removeCachedWorldClock:(uint8_t)clockID;
- (VPWorldClockModel *)cachedWorldClockWithID:(uint8_t)clockID;
- (void)deleteWorldClockIDs:(NSArray<NSNumber *> *)ids
                      index:(NSUInteger)index
                      state:(NSMutableDictionary *)state
                       done:(void (^)(void))done;

// 文本闹钟能力位（funcSupport 用）：读 deviceFuctionData[17]
- (NSString *)textAlarmCapabilityName;

// 表盘（第 7 节实现）：内部拆分较多，先声明避免后向调用告警
- (BOOL)isJLDevice;                                       // 平台判定（CPUType == 1）
- (NSString *)dialPlatformName;                            // jl / zk / nordic
- (void)dialListJL:(NSInteger)seq;                         // JL：打开文件系统 → 三组表盘
- (void)dialListNordic:(NSInteger)seq;                     // 非 JL：默认表盘 + 屏幕样式
- (void)readScreenStyleEvent:(NSInteger)seq;               // 非 JL：读当前屏幕样式 → on('dial')
- (void)setDialDefault:(NSInteger)index;                   // 非 JL：按序号切默认表盘
- (void)switchJLSystemDialAtIndex:(NSInteger)index;        // JL：按 sys 组序号切盘
- (void)switchJLDialByName:(NSString *)name;               // JL：按文件名切盘
- (void)setDialFile:(NSString *)filePath;                  // 非 JL：推送本地表盘文件
- (void)pushDialFileAndActivate:(NSURL *)filePath name:(NSString *)name;  // 下载后的 bin 推送 + 切盘
- (void)emitDialFail:(NSString *)code;                     // 统一的失败事件
- (NSArray<NSString *> *)watchNamesFromFileNames:(NSArray *)names;
- (void)classifyJLDialNames:(NSArray<NSString *> *)names
                      index:(NSInteger)index
                     result:(NSMutableDictionary *)result
                        seq:(NSInteger)seq;
- (void)finishJLClassification:(NSArray<NSString *> *)names
                        result:(NSMutableDictionary *)result
                           seq:(NSInteger)seq;
- (void)emitJLListWithSys:(NSArray *)sys
                   server:(NSArray *)server
                      pic:(NSDictionary *)pic
                      seq:(NSInteger)seq;

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

// ==================== 表盘：SDK 未公开类的声明 ====================
// 表盘能力分散在几个 SDK 内部类里：
//   VPMarketDialManager  —— 有公开头文件（列表/下载/传输/JL 文件系统开关都在它上面）
//   VPDialTransformManager —— 无公开头文件，只有二进制符号 + DWARF 里的方法类型编码
//   VPJLFileSystemManager  —— 同上
// 下面只补真正需要、且公开头文件里没有的那两个方法；其余一律走 VPMarketDialManager。
// ⚠ 若日后厂商把头文件公开出来，删掉本节即可（重复声明会编译报错）。
@interface VPDialTransformManager : NSObject
+ (instancetype)share;                                            // @16@0:8
/** 切换表盘（内部 = cmdWatchFlashPath:Flag:1，路径自动补 "/"）。block 均无参:
    v32@0:8@16@?24@?32 */
- (void)switchToCustomWatchWithName:(NSString *)name
                            success:(void (^)(void))success
                            failure:(void (^)(void))failure;
@end

@interface VPJLFileSystemManager : NSObject
+ (instancetype)shareInstance;                                   // @16@0:8
/** 读单个表盘文件的元数据（cmdWatchFlashPath:Flag:3）。
    action: v32@0:8@16@?24 —— 两个参数只会有一个非 nil：
      照片表盘 → (文件名, nil)；市场表盘 → (nil, 文件名)；其余（内置表盘）→ (nil, nil) */
- (void)getWatchFaceWithAssist:(id)assist
                     watchName:(NSString *)watchName
                        action:(void (^)(NSString *photoWatchName, NSString *marketWatchName))action;
@end

@implementation JoemeWatchModule {
    // 世界时钟缓存：getter 在下面手写（懒加载），ivar 必须显式声明
    NSMutableArray<VPWorldClockModel *> *_worldClockCache;
}

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

// 相机相关的前置声明：实现放在第 7 节（相机遥控）里，但 initWatch 里要先注册前后台通知
static void JoemeStartAppStateTracking(void);

// ---------- 库/字典取值小工具（C 函数必须先声明再用，所以放在最前） ----------

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

    // 前后台标记（相机静默拍照要判断 App 是否在前台）
    JoemeStartAppStateTracking();

    // 经典蓝牙（通话通道）自动配对/自动连接。
    // SDK 默认即 YES，但显式写一行防止未来版本默认值变更导致 iOS 上 BT 不自动连。
    // iOS 13 以下 SDK 不支持自动连 BT，届时由 VPBTConnectStateChangeBlock 上报 disconnected，
    // 电话页据此提示用户去系统蓝牙手动配对。
    if (@available(iOS 13.0, *)) {
        manager.isAutoConnectBT = YES;
    }
    manager.isAutoShowPair = YES;

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
 波形给两种口径：filterSignals 是 ADC 原值（保留原样，排查用），
 waveMv 是已按 ecgType/testType/gain 换算好的 mV —— 页面只认 waveMv。
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
    // 逐秒数组（Android 叫 detectHeart/detectHrv/detectQT，这里给同名键）。
    // 详情页的「心率分布 / 最高最低心率」只认这三项；不映射的话 iOS 上永远是占位。
    extra[@"detectHeart"] = [self ecgNumArrayFrom:model.hearts];
    extra[@"detectHrv"]   = [self ecgNumArrayFrom:model.hrvs];
    extra[@"detectQT"]    = [self ecgNumArrayFrom:model.qts];
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

/**
 逐秒数组 -> NSNumber 数组。
 Android 的 detectHeart/detectHrv/detectQT 是 int[]，iOS 这边 hearts/hrvs/qts 是 NSArray（元素可能是 NSNumber 也可能是 NSString）。
 页面只认数字，这里统一转一遍；非数字元素丢掉。
 */
- (NSArray<NSNumber *> *)ecgNumArrayFrom:(NSArray *)arr {
    if (!arr || ![arr isKindOfClass:[NSArray class]]) return @[];
    NSMutableArray<NSNumber *> *out = [NSMutableArray arrayWithCapacity:arr.count];
    for (id v in arr) {
        if ([v isKindOfClass:[NSNumber class]]) {
            [out addObject:v];
        } else if ([v isKindOfClass:[NSString class]]) {
            NSNumber *n = @([(NSString *)v doubleValue]);
            [out addObject:n];
        }
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
 发送的是 mV（与 Android 的 ecgWave 同口径，页面直接用，不再自己换算）。
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
            // 断连后手表已经不在拍照模式，手机上的预览页留着只会卡在最后一帧
            // （与 Android 的 onConnectStatusChanged 一致）
            [JoemeCameraViewController finishIfOpen];
            self.cameraEntered = NO;
            self.pendingSelfExit = 0;
            // 重连后要重新装一次监听：SDK 的 block 槽位可能随连接重建被清掉
            self.cameraMonitorInstalled = NO;
            // 世界时钟缓存属于「上一台设备」，断连即失效；重连后要重新读一次再增删
            [_worldClockCache removeAllObjects];
            self.worldClockRead = NO;
            self.worldClockSubInstalled = NO;
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @NO }];
            break;
        case VPDeviceConnectStateConnect:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @YES }];
            break;
        case VPDeviceConnectStateVerifyPasswordSuccess:
            [self sendEvent:@"status" data:@{ @"mac": [self currentMac], @"connected": @YES }];
            [self emitDeviceInfo];
            // 对齐 Android：连上就占住相机监听槽位，手表上报的相机状态/快门
            // 即使 App 相机页没开也能被原生接住。
            // iOS 没有「只注册不下发」的接口，这里靠一条 Exit 装监听（回执会被
            // pendingSelfExit 过滤掉，不会当成「手表退出拍照页」抛给 JS）。
            [self installCameraMonitorIfNeeded];
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
    // 对应 Android 的 funcSupport 事件（JS 侧映射为 'func'），携带数据保存天数与能力位。
    //
    // 为什么要把能力位补齐：Android 的 funcSupport 里带 summary（SDK 的中文 toString 文本，
    // 形如「ECG=SUPPORT，身体成分=UNSUPPORT」），页面从这段文本里正则抠能力位；iOS 没有这种
    // 文本，能力全在 VPPeripheralModel 的属性上。不补的话页面在 iOS 上拿不到任何能力位 →
    // 对身体不支持的功能（心电图/身体成分/运动记录/HRV）照样下发读取，白等一轮超时。
    //
    // 所以这里把 VPPeripheralModel 的属性映射成与 summary 同义的**结构化字段**，
    // 页面同时认这两种来源（见 watch/health/index.vue 的 CAP_ALIAS / _capOk）。
    // 每个字段的判定口径都以 VPPeripheralModel.h 的属性注释为准：
    //   ecgType            0=没有该功能，1=E 系列，2=G 系列
    //   runningSaveTimes   非 0 代表有运动模式（头文件明写「判断是否有运动模式用这个字段」）
    //   hrvType            非 0 代表有 hrv 功能
    //   oxygenType         非 0 代表有血氧功能
    //   temperatureType    0=没有，1=有但不自动测，2/4/5=有且自动测
    //   stressType/metType 0/1 为不支持，>1 才支持
    //   bloodGlucoseType   0=没有，其余各档都代表有（2 校准 / 3 仅校准 / 4 多校准 / 5 风险等级…）
    //   bloodAnalysisType / bodyCompositionType / bloodPressureType / heartRateType / worldClockType
    //                     非 0 代表有该功能（worldClockType 注释明写 0 表示不支持）
    // 布尔字段用 @(条件) 直接给 YES/NO，页面按「false = 明确不支持」处理；
    // 数值字段（体温/血糖/压力/梅脱）保留原始档位，页面需要时还能细分。
    [self sendEvent:@"funcSupport" data:@{
        @"watchDataDay": @(pm.saveDays),
        @"contactType": @(pm.contactType),
        // SOS：contactType==2 才支持（与 Android 同口径，见 android JoemeWatchModule 同名分支）；
        // 另外给一个布尔位，联系页优先读它（f.sosContactSupported），缺失时退回 contactType
        @"sosContactSupported": @(pm.contactType == 2),
        // 协议版本：与 Android 的 originProtocolVersion 同义（3/5 → 数据挂在 5 分钟原始点上）
        @"originProtocolVersion": @(pm.fiveProtocolType),
        @"ecg": @(pm.ecgType != 0),
        @"bodyComposition": @(pm.bodyCompositionType != 0),
        @"sportModel": @(pm.runningSaveTimes != 0),
        @"sportModelDay": @(pm.runningSaveTimes),
        @"hrv": @(pm.hrvType != 0 || pm.isSupportHRVTest),
        @"spo2": @(pm.oxygenType != 0),
        @"spo2Type": @(pm.oxygenType),
        // 体温：给布尔（是否具备体温功能）+ 原始档位（2/5 走 origin 通路，页面用得上）
        @"temperature": @(pm.temperatureType != 0),
        @"temperatureType": @(pm.temperatureType),
        // 压力/梅脱：0/1 不支持，>1 支持；梅脱另外还有 isSupportMetTest 这个显式能力位
        @"stress": @(pm.stressType > 1),
        @"stressType": @(pm.stressType),
        @"met": @(pm.metType > 1 || pm.isSupportMetTest),
        @"metType": @(pm.metType),
        @"bloodGlucose": @(pm.bloodGlucoseType != 0),
        @"bloodGlucoseType": @(pm.bloodGlucoseType),
        @"bloodAnalysis": @(pm.bloodAnalysisType != 0),
        @"bp": @(pm.bloodPressureType != 0 || pm.isSupportBPTest),
        @"heartRate": @(pm.heartRateType != 0),
        @"worldClock": @(pm.worldClockType != 0),
        // 文本闹钟（带标签）能力位：iOS 的 VPPeripheralModel 没有独立属性，
        // 只能按 Demo 的做法读 deviceFuctionData[17]（「新的闹钟功能」字节）：
        //   0xFE  → 手环彻底没有闹钟功能
        //   <0x05 → 没有文字闹钟功能
        // 缺失该字节时给 'unknown'，不臆断为「不支持」（页面按 unknown 走普通超时文案）。
        @"textAlarm": [self textAlarmCapabilityName],
        // 没有 summary 文本：页面遇到 iOS 只会走结构化字段分支
        @"summary": @""
    }];
}

/**
 文本闹钟能力位（对齐 iOS Demo VPTextAlarmClockSettingController 的判定）：
 返回 'support' / 'unsupport' / 'unknown'，与 Android funcSupport 里 textAlarm 的取值同名。
 */
- (NSString *)textAlarmCapabilityName {
    VPPeripheralModel *pm = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSData *data = pm.deviceFuctionData;
    // 功能字节表：下标 1=血压 … 17=新的闹钟功能（见 VPPeripheralModel.h 的注释）
    if (![data isKindOfClass:[NSData class]] || data.length <= 17) return @"unknown";
    const uint8_t *bytes = (const uint8_t *)data.bytes;
    uint8_t v = bytes[17];
    if (v == 0xFE) return @"unsupport";   // 彻底没有闹钟功能
    if (v < 0x05) return @"unsupport";    // 没有文字闹钟功能
    return @"support";
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
 事件：on('allDayOxygen') -> { ok, isOpen, data }
 说明：关闭时设备回的是 VPFunctionCompleteClose，不能只认 Open/Complete 判成功
      （否则关血氧永远被当成失败）。
 */
UNI_EXPORT_METHOD(@selector(setAllDayOxygen:callback:))
- (void)setAllDayOxygen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = [options[@"on"] boolValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL fired = NO;
    void (^finish)(VPSettingFunctionCompleteState) = ^(VPSettingFunctionCompleteState state) {
        if (fired) return;
        fired = YES;
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        NSMutableDictionary *d = [@{ @"ok": @(ok), @"isOpen": @(on) } mutableCopy];
        if (ok) {
            d[@"data"] = [NSString stringWithFormat:
                          @"AllSetData{type=SPO2H_NIGHT_AUTO_DETECT, isOpen=%d}", on ? 1 : 0];
        }
        [weakSelf sendEvent:@"allDayOxygen" data:d];
        // 设备拒绝/不支持时回 -1，页面 onSwitchChange 的 catch 会回滚开关并提示
        callback(resultWithCode(ok ? 200 : -1), NO);
    };
    [pm veepooSDKSettingAllDayOxygenTest:(on ? VPSettingFunctionOpen : VPSettingFunctionClose) result:^(VPSettingFunctionCompleteState state) {
        finish(state);
    }];

    // 设备不回包时 6 秒兜底：否则页面开关一直停在忙碌态（Promise 永不结束）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(VPFunctionCompleteFailure); });
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
   type: 'longSeat' | 'drink' | 'sports' | 'medicine' | 'reading' | 'out' | 'wash' | 'overlook'
         （同时兼容 iOS 旧别名: sport/read/trip/washHands/lookFar）
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
    BOOL typeValid = YES;
    if ([type isEqualToString:@"longSeat"]) rt = VPDeviceHealthRemindTypeLongSeat;
    else if ([type isEqualToString:@"drink"]) rt = VPDeviceHealthRemindTypeDrinkWater;
    else if ([type isEqualToString:@"sports"] || [type isEqualToString:@"sport"]) rt = VPDeviceHealthRemindTypeSport;
    else if ([type isEqualToString:@"medicine"]) rt = VPDeviceHealthRemindTypeTakeMedicine;
    else if ([type isEqualToString:@"reading"] || [type isEqualToString:@"read"]) rt = VPDeviceHealthRemindTypeRead;
    else if ([type isEqualToString:@"out"] || [type isEqualToString:@"trip"]) rt = VPDeviceHealthRemindTypeTrip;
    else if ([type isEqualToString:@"wash"] || [type isEqualToString:@"washHands"]) rt = VPDeviceHealthRemindTypeWashHands;
    else if ([type isEqualToString:@"overlook"] || [type isEqualToString:@"lookFar"]) rt = VPDeviceHealthRemindTypeLookFarAway;
    else typeValid = NO;

    if (!typeValid) {
        callback(@{ @"code": @(-1), @"message": [NSString stringWithFormat:@"不支持的健康提醒类型：%@", type ?: @""] }, NO);
        return;
    }

    // on 缺省与 Android 一致（默认开）；时间/间隔缺省给 0，由 SDK 处理
    BOOL on = (options[@"on"] == nil) ? YES : [options[@"on"] boolValue];
    VPDeviceHealthRemindModel *m = [[VPDeviceHealthRemindModel alloc] init];
    m.type = rt;
    m.open = on;
    m.startHour = [options[@"startHour"] unsignedCharValue];
    m.startMinute = [options[@"startMinute"] unsignedCharValue];
    m.endHour = [options[@"endHour"] unsignedCharValue];
    m.endMinute = [options[@"endMinute"] unsignedCharValue];
    m.remindInterval = [options[@"interval"] unsignedCharValue];

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL cbFired = NO;
    void (^fireCb)(BOOL ok) = ^(BOOL ok) {
        if (cbFired) return;
        cbFired = YES;
        [weakSelf sendEvent:@"healthRemind" data:@{ @"ok": @(ok), @"type": type ?: @"" }];
        callback(resultWithCode(200), NO);
    };

    [pm veepooSDKSettingHealthRemindWithRemindType:rt opCode:1 remindModel:m resultBlock:^(BOOL success, BOOL complete, VPDeviceHealthRemindModel *successModel) {
        fireCb(success);
    } deviceInfoDidChangeBlock:^(VPDeviceHealthRemindModel *changeModel) {}];

    // 设备不回包时 10 秒兜底，避免 JS Promise 永久挂起
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ fireCb(NO); });
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
 事件：on('textAlarm') -> { ok, oprate, list }（与 Android 一致，成功时回整表）

 关于 alarmID（之前固定传 1 会把设备上已有的 1 号闹钟静默覆盖）：
   ① 调用方显式给了 id → 用它（改单条复用不到这条路径，但保留兼容）。
   ② 已读过整表 → 取最小空闲 ID；一个空位都没有时明确回 ALARM_FULL。
   ③ 从没读过整表（列表页读取超时等）→ 不写 alarmID，让 SDK 用它自己的
      已存列表（VPDeviceTextAlarmModel init 里就调 getMinimumAlarmID）分配，
      这跟官方 Demo 新增闹钟的做法一致，不会瞎猜。
 */
UNI_EXPORT_METHOD(@selector(setTextAlarm:callback:))
- (void)setTextAlarm:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSString *alarmId = nil;
    id given = options[@"id"] ?: options[@"alarmID"];
    if (given) {
        alarmId = [NSString stringWithFormat:@"%@", given];
    } else if (self.lastTextAlarms) {
        alarmId = [self nextTextAlarmId];
        if (!alarmId) {
            NSDictionary *d = @{
                @"ok": @NO, @"oprate": @"ALARM_FULL",
                @"list": self.lastTextAlarms,
                @"message": @"闹钟已满（最多添加十个）"
            };
            [self sendEvent:@"textAlarm" data:d];
            NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
            [r addEntriesFromDictionary:d];
            callback(r, NO);
            return;
        }
    }
    // 用 init 而不是 initWithAlarmDict：只有 init 会走 SDK 的默认 ID 分配，
    // 也避免字典缺字段时把属性刷成 nil。
    VPDeviceTextAlarmModel *m = [[VPDeviceTextAlarmModel alloc] init];
    m.alarmHour   = [NSString stringWithFormat:@"%ld", (long)(options[@"hour"] ? [options[@"hour"] integerValue] : 0)];
    m.alarmMinute = [NSString stringWithFormat:@"%ld", (long)(options[@"minute"] ? [options[@"minute"] integerValue] : 0)];
    m.alarmState  = [NSString stringWithFormat:@"%d", options[@"enable"] ? ([options[@"enable"] boolValue] ? 1 : 0) : 1];
    if (alarmId) m.alarmID = alarmId;
    // repeat 是 7 位「周日..周一」串，必须换算成 SDK 的 8 位十进制串（与 modify 同一条路径）
    m.repeatState = [self iosRepeatStateFromAndroid:options[@"repeat"]];
    m.alarmText   = [options[@"content"] isKindOfClass:[NSString class]] ? options[@"content"] : @"";
    m.alarmDate   = [options[@"unRepeatDate"] isKindOfClass:[NSString class]] ? options[@"unRepeatDate"] : @"0000-00-00";
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKSettingDeviceTextAlarmWithTextAlarmModel:m settingMode:VPDeviceTextAlarmSettingModelAddOrChange successResult:^(NSArray *alarmArray) {
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

/** 世界时钟上限（SDK 协议 dataID 1~10） */
static const NSInteger kWorldClockMax = 10;

/** 世界时钟本地缓存（懒加载；断连时清空，避免拿旧设备的列表当依据） */
- (NSMutableArray<VPWorldClockModel *> *)worldClockCache {
    if (!_worldClockCache) _worldClockCache = [NSMutableArray array];
    return _worldClockCache;
}

/** 世界时钟能力位：VPPeripheralModel.worldClockType 非 0 才支持（头文件明写 0 表示不支持） */
- (BOOL)worldClockSupported {
    VPPeripheralModel *pm = [VPBleCentralManage sharedBleManager].peripheralModel;
    return pm != nil && pm.worldClockType != 0;
}

/** 挑最小空闲 dataID（1~10），对齐 Demo WorldClockActivity.genNewId；满了返回 0 */
- (uint8_t)nextWorldClockId {
    for (uint8_t i = 1; i <= kWorldClockMax; i++) {
        BOOL used = NO;
        for (VPWorldClockModel *wc in self.worldClockCache) {
            if (wc.dataID == i) { used = YES; break; }
        }
        if (!used) return i;
    }
    return 0;
}

/** 世界时钟模型 -> JS 事件项（字段与 Android buildWorldClockList 一致） */
- (NSDictionary *)worldClockDict:(VPWorldClockModel *)wc {
    return @{
        @"id": @(wc.dataID),
        @"timeZone": wc.standardTimeZoneDiffer ?: @0,
        @"timeZoneName": wc.cityName ?: @"",
        // iOS 模型没有「时区名称」字段，保持空串与 Android 字段对齐（页面用本地城市表补）
        @"genericTimeZoneName": @"",
        @"open": @YES
    };
}

/**
 安装「设备端删除世界时钟」订阅（用户在手表上删掉时钟时通知 JS）。
 SDK 只存一个槽位，断连后可能被清掉，所以按标志重装。
 */
- (void)installWorldClockDeleteSubIfNeeded {
    if (self.worldClockSubInstalled) return;
    self.worldClockSubInstalled = YES;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKWorldClockDeviceDeleteSubscribe:^(uint8_t deleteID) {
        // 设备端删除：同步本地缓存，并把新列表发给页面（页面收到 deleteByDevice 会重读）
        [weakSelf removeCachedWorldClock:deleteID];
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @YES, @"op": @"deleteByDevice", @"id": @(deleteID)
        }];
    }];
}

/** 从本地缓存移除一条（按 dataID） */
- (void)removeCachedWorldClock:(uint8_t)clockID {
    for (NSInteger i = (NSInteger)self.worldClockCache.count - 1; i >= 0; i--) {
        if (self.worldClockCache[(NSUInteger)i].dataID == clockID) {
            [self.worldClockCache removeObjectAtIndex:(NSUInteger)i];
        }
    }
}

/**
 逐条串行删除世界时钟（clearWorldClocks 用）。
 SDK 内部本身就是 30ms 间隔串行下发，这里保证「上一条回包后再发下一条」，
 避免并发把协议打乱；失败条数记在 state[@"failed"] 里，删完调 done。
 */
- (void)deleteWorldClockIDs:(NSArray<NSNumber *> *)ids
                      index:(NSUInteger)index
                      state:(NSMutableDictionary *)state
                       done:(void (^)(void))done {
    if (index >= ids.count) { done(); return; }
    uint8_t delID = (uint8_t)[ids[index] integerValue];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    [pm veepooSDKWorldClockDeleteWithID:delID result:^(BOOL success) {
        if (!success) state[@"failed"] = @([state[@"failed"] integerValue] + 1);
        [weakSelf removeCachedWorldClock:delID];
        [weakSelf deleteWorldClockIDs:ids index:index + 1 state:state done:done];
    }];
}

/** 按 dataID 找缓存里的完整模型（删除时 SDK 需要整条，Android 侧同样做法） */
- (VPWorldClockModel *)cachedWorldClockWithID:(uint8_t)clockID {
    for (VPWorldClockModel *wc in self.worldClockCache) {
        if (wc.dataID == clockID) return wc;
    }
    return nil;
}

/**
 读取世界时钟。一次性读取：callback 与事件都带 list。
 iOS SDK：veepooSDKWorldClockReadWithModels:result:
          models 传本地缓存，SDK 内部会校验缓存是否需要更新（避免重复读取）
          VPWorldClockModel：dataID(1-10)、cityName、standardTimeZoneDiffer(相对 GMT 的 15 分钟数)
 Android：readWorldClock(...)；JS：joemeWatch.readWorldClock() -> resolve { list, count, supported }
 事件：on('worldClock') -> { list, count }
 超时：设备不回包时 10 秒兜底，reject 带 message（页面用空态里的「重新读取」兜）
 */
UNI_EXPORT_METHOD(@selector(readWorldClock:callback:))
- (void)readWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL supported = [self worldClockSupported];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    // 看门狗：不支持世界时钟的机型上 SDK 可能静默 return，不能让页面干等
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = supported ? @"读取世界时钟超时，请靠近手表重试"
                                  : @"该手表不支持世界时钟";
        r[@"supported"] = @(supported);
        r[@"list"] = @[];
        r[@"count"] = @0;
        callback(r, NO);
    });

    // 传副本：回调里会 rebuild 这个缓存，直接传同一个可变数组等于边读边改
    [pm veepooSDKWorldClockReadWithModels:[self.worldClockCache copy] result:^(BOOL success, NSArray<VPWorldClockModel *> *models) {
        if (done) return;
        done = YES;
        if (!success) {
            NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
            r[@"message"] = @"读取世界时钟失败";
            r[@"supported"] = @(supported);
            r[@"list"] = @[];
            r[@"count"] = @0;
            callback(r, NO);
            return;
        }
        // 用设备回包重建缓存（设备才是真源）
        [weakSelf.worldClockCache removeAllObjects];
        NSMutableArray *list = [NSMutableArray array];
        for (VPWorldClockModel *wc in models) {
            if (![wc isKindOfClass:[VPWorldClockModel class]]) continue;
            [weakSelf.worldClockCache addObject:wc];
            [list addObject:[weakSelf worldClockDict:wc]];
        }
        // 空列表也算「读过了」：设备上 0 个时钟正是第一次添加的场景
        weakSelf.worldClockRead = YES;
        [weakSelf installWorldClockDeleteSubIfNeeded];

        NSDictionary *d = @{ @"list": list, @"count": @(list.count) };
        [weakSelf sendEvent:@"worldClock" data:d];
        NSMutableDictionary *res = [resultWithCode(200) mutableCopy];
        [res addEntriesFromDictionary:d];
        res[@"supported"] = @(supported);
        callback(res, NO);
    }];
}

/**
 新增世界时钟。options: { timeZone, timeZoneName, genericTimeZoneName?, id? }
 iOS SDK：veepooSDKWorldClockAddWithModel:result:
 Android：addWorldClock(...)；JS：joemeWatch.addWorldClock({...})
 事件：on('worldClockOp') -> { ok, op:'add', count, id }
 id 不传时按「当前缓存里的占用情况」取最小空闲 id（对齐 Demo genNewId）。
 未读过列表时回 needRead，由页面补一次读取再重试（与 Android 同口径）。
 */
UNI_EXPORT_METHOD(@selector(addWorldClock:callback:))
- (void)addWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    id tz = options[@"timeZone"] ?: options[@"offset"];
    if (tz == nil) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"需要 timeZone（15 分钟为单位的时区偏移）";
        callback(r, NO);
        return;
    }
    // id 显式给的才用它；传 0 / 负数等同于没传（页面重试时可能算不出来传 0）
    NSInteger explicitID = options[@"id"] ? [options[@"id"] integerValue] : 0;
    // 没显式给 id 时必须先读过列表：否则生成的 id 可能和手表上已有的时钟冲突
    if (explicitID <= 0 && !self.worldClockRead) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"请先读取一次世界时钟列表，再添加";
        r[@"needRead"] = @YES;
        callback(r, NO);
        return;
    }
    uint8_t clockID = explicitID > 0 ? (uint8_t)explicitID : [self nextWorldClockId];
    if (clockID < 1 || clockID > kWorldClockMax) {
        NSMutableDictionary *r = [resultWithCode(-2) mutableCopy];
        r[@"message"] = [NSString stringWithFormat:@"世界时钟已满（最多 %ld 个）", (long)kWorldClockMax];
        callback(r, NO);
        return;
    }

    VPWorldClockModel *m = [[VPWorldClockModel alloc] init];
    m.dataID = clockID;
    m.cityName = options[@"timeZoneName"] ?: options[@"city"] ?: @"";
    // SDK 属性是 NSNumber；JS 侧可能传来字符串（如从 query 带过来），统一转成数值
    m.standardTimeZoneDiffer = [tz isKindOfClass:[NSNumber class]] ? tz : @([tz integerValue]);
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        [weakSelf sendEvent:@"worldClockOp" data:@{ @"ok": @NO, @"op": @"add", @"id": @(clockID) }];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"添加世界时钟超时，请重试";
        r[@"id"] = @(clockID);
        callback(r, NO);
    });

    [pm veepooSDKWorldClockAddWithModel:m result:^(BOOL success) {
        if (done) return;
        done = YES;
        if (success) {
            // SDK 缓存里没有名称，手动补进本地缓存，供后续挑空闲 id 判断占用
            if (![weakSelf cachedWorldClockWithID:clockID]) {
                [weakSelf.worldClockCache addObject:m];
            }
        }
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @(success), @"op": @"add", @"count": @(weakSelf.worldClockCache.count), @"id": @(clockID)
        }];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        r[@"id"] = @(clockID);
        r[@"op"] = @"add";
        if (!success) r[@"message"] = @"新增世界时钟失败";
        callback(r, NO);
    }];
}

/**
 删除世界时钟。options: { id }（dataID，1 起）。
 iOS SDK：veepooSDKWorldClockDeleteWithID:result:
 Android：deleteWorldClock(...)；JS：joemeWatch.deleteWorldClock({ id })
 事件：on('worldClockOp') -> { ok, op:'delete', count, id }
 */
UNI_EXPORT_METHOD(@selector(deleteWorldClock:callback:))
- (void)deleteWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSInteger rawID = options[@"id"] ? [options[@"id"] integerValue] : 0;
    if (rawID < 1 || rawID > kWorldClockMax) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = [NSString stringWithFormat:@"需要 id（1~%ld）", (long)kWorldClockMax];
        callback(r, NO);
        return;
    }
    uint8_t delID = (uint8_t)rawID;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        [weakSelf sendEvent:@"worldClockOp" data:@{ @"ok": @NO, @"op": @"delete", @"id": @(delID) }];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"删除世界时钟超时，请重试";
        r[@"id"] = @(delID);
        callback(r, NO);
    });

    [pm veepooSDKWorldClockDeleteWithID:delID result:^(BOOL success) {
        if (done) return;
        done = YES;
        if (success) [weakSelf removeCachedWorldClock:delID];
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @(success), @"op": @"delete", @"count": @(weakSelf.worldClockCache.count), @"id": @(delID)
        }];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        r[@"id"] = @(delID);
        r[@"op"] = @"delete";
        if (!success) r[@"message"] = @"删除世界时钟失败";
        callback(r, NO);
    }];
}

/**
 清空世界时钟。iOS SDK 没有「批量删除」接口，这里按 list 逐条串行删除。
 options: { list?: [{ id }] }（不传时用本地缓存；都没有则回 -1）
 Android：clearWorldClocks(...)；JS：joemeWatch.clearWorldClocks()
 事件：on('worldClockOp') -> { ok, op:'deleteAll', count, failed }
 注意：逐条串行下发（上一条回包后再发下一条），SDK 内部本身也是间隔 30ms 串行。
 */
UNI_EXPORT_METHOD(@selector(clearWorldClocks:callback:))
- (void)clearWorldClocks:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    // 优先用页面传来的 list（缓存丢失时兜底），否则用本地缓存
    NSMutableArray<NSNumber *> *ids = [NSMutableArray array];
    NSArray *list = options[@"list"];
    if ([list isKindOfClass:[NSArray class]] && list.count > 0) {
        for (NSDictionary *item in list) {
            if (![item isKindOfClass:[NSDictionary class]]) continue;
            NSInteger v = [item[@"id"] integerValue];
            if (v >= 1 && v <= kWorldClockMax) [ids addObject:@(v)];
        }
    } else {
        for (VPWorldClockModel *wc in self.worldClockCache) {
            [ids addObject:@(wc.dataID)];
        }
    }
    if (ids.count == 0) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"列表为空，请先读取世界时钟";
        callback(r, NO);
        return;
    }

    __weak typeof(self) weakSelf = self;
    NSInteger total = (NSInteger)ids.count;
    // 用可变字典做计数盒：block 会持有它，不存在栈指针悬空/block 自持循环
    NSMutableDictionary *state = [NSMutableDictionary dictionary];
    state[@"failed"] = @0;
    __block BOOL finished = NO;

    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        NSInteger failed = [state[@"failed"] integerValue];
        BOOL allOk = (failed == 0);
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @(allOk), @"op": @"deleteAll",
            @"count": @(total), @"failed": @(failed)
        }];
        NSMutableDictionary *r = [resultWithCode(allOk ? 200 : -1) mutableCopy];
        r[@"op"] = @"deleteAll";
        r[@"count"] = @(total);
        r[@"failed"] = @(failed);
        if (!allOk) r[@"message"] = [NSString stringWithFormat:@"有 %ld 个删除失败", (long)failed];
        callback(r, NO);
    };

    [self deleteWorldClockIDs:ids index:0 state:state done:finish];

    // 看门狗：每条按 5 秒估，至少 10 秒
    NSTimeInterval wait = MAX(10.0, 5.0 * (double)total);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(wait * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (finished) return;
        finished = YES;
        NSInteger failed = [state[@"failed"] integerValue];
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @NO, @"op": @"deleteAll", @"count": @(total), @"failed": @(failed)
        }];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"清空世界时钟超时，请重试";
        r[@"failed"] = @(failed);
        callback(r, NO);
    });
}

/**
 调整世界时钟顺序（SDK 语义是「交换两个位置」，不是插入）。
 options: { from, to } 1-based（同 Android）或 { fromIndex, toIndex } 0-based。
 iOS SDK：veepooSDKWorldClockAdjustOrderFromArrIndex:toArrIndex:result:（内部按 0-based 数组下标）
 Android：moveWorldClock(...)；JS：joemeWatch.moveWorldClock({...})
 事件：on('worldClockOp') -> { ok, op:'move', count }
 */
UNI_EXPORT_METHOD(@selector(moveWorldClock:callback:))
- (void)moveWorldClock:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    // from/to 是 1-based；fromIndex/toIndex 是 0-based。缺省一律按 0-based 处理，
    // 不能先赋 0 再判断（0 是合法下标，会被误当成「没传」）。
    BOOL oneBased = (options[@"from"] != nil || options[@"to"] != nil);
    NSInteger from = oneBased ? [options[@"from"] integerValue] - 1
                              : [options[@"fromIndex"] integerValue];
    NSInteger to = oneBased ? [options[@"to"] integerValue] - 1
                            : [options[@"toIndex"] integerValue];
    NSInteger size = (NSInteger)self.worldClockCache.count;
    if (size < 2 || from < 0 || to < 0 || from >= size || to >= size) {
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"顺序参数越界（需先读取列表，from/to 从 1 开始）";
        callback(r, NO);
        return;
    }
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (done) return;
        done = YES;
        [weakSelf sendEvent:@"worldClockOp" data:@{ @"ok": @NO, @"op": @"move" }];
        NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
        r[@"message"] = @"调整顺序超时，请重试";
        callback(r, NO);
    });

    [pm veepooSDKWorldClockAdjustOrderFromArrIndex:(uint8_t)from
                                        toArrIndex:(uint8_t)to
                                            result:^(BOOL success) {
        if (done) return;
        done = YES;
        if (success && from != to) {
            // 同步本地缓存顺序，后续 move 的下标才对得上
            [weakSelf.worldClockCache exchangeObjectAtIndex:(NSUInteger)from
                                          withObjectAtIndex:(NSUInteger)to];
        }
        [weakSelf sendEvent:@"worldClockOp" data:@{
            @"ok": @(success), @"op": @"move", @"count": @(weakSelf.worldClockCache.count)
        }];
        NSMutableDictionary *r = [resultWithCode(success ? 200 : -1) mutableCopy];
        r[@"op"] = @"move";
        if (!success) r[@"message"] = @"调整顺序失败";
        callback(r, NO);
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
 读取消息推送开关（主动逐类型读，不再只读 ANCS 缓存快照）。
 SDK 头文件 VPPeripheralBaseManage.h 写明 veepooSDKSettingMessageType:settingState:
   同时支持「设置」和「读取」：settingState 传 VPReadFunctionState(0) 即读该类型。
   回 completeBlock(state)：0=设备无此功能(UNSUPPORT)，1=已开，2=已关，3=读取失败。
 注意：completeBlock 只回 state、不回 messageType，无法并发对应到 key，
   所以这里**串行下发**（读一个、回包、再读下一个），保证回包顺序=发送顺序。
 JS: joemeWatch.readSocialMsg() -> resolve { sms:'SUPPORT_OPEN', smsOpen:@YES, ... }
 事件：on('socialMsg') -> 同上（整包）
 超时：总时长 6 秒兜底（与页面 load() 的 6s toast 对齐），超时后用已读结果 + ANCS 快照合并回调。
 */
UNI_EXPORT_METHOD(@selector(readSocialMsg:callback:))
- (void)readSocialMsg:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;

    // 页面 notify.vue ROWS 涉及的 key；call 顺手带上，与 Android socialMsgObj 结构对齐
    NSArray<NSString *> *keys = @[
        @"call", @"sms", @"wechat", @"qq", @"sina", @"facebook", @"twitter",
        @"flickr", @"linkin", @"whatsapp", @"line", @"instagram", @"snapchat",
        @"skype", @"gmail", @"dingding", @"wxwork", @"other",
        @"tiktok", @"telegram", @"connected2", @"kakao", @"shieldPolice", @"messenger"
    ];

    // 兜底打底：先用 ANCS 缓存快照填一遍，主动读失败/超时的项不至于全空
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    [result addEntriesFromDictionary:[self socialMsgFromPeripheral]];

    NSMutableArray<NSString *> *queue = [NSMutableArray array];
    for (NSString *key in keys) {
        VPSettingMessageSwitchType mt;
        if (JoemeMessageTypeFromKey(key, &mt)) [queue addObject:key];
    }

    __weak typeof(self) weakSelf = self;
    __block BOOL finished = NO;
    void (^finish)(void) = ^{
        if (finished) return;
        finished = YES;
        NSMutableDictionary *r = [result mutableCopy];
        r[@"code"] = @200;
        r[@"readActive"] = @YES;
        [weakSelf sendEvent:@"socialMsg" data:r];
        callback(r, NO);
    };

    // 总超时：6 秒没读完就用已读结果回调（页面自己也有 6s toast 兜底）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(); });

    // 串行递归：读 queue.firstObject，回包后取下一个
    void (^__block next)(void);
    next = ^void(void) {
        if (finished || queue.count == 0) { finish(); return; }
        NSString *key = queue.firstObject;
        [queue removeObjectAtIndex:0];
        VPSettingMessageSwitchType mt;
        if (!JoemeMessageTypeFromKey(key, &mt)) { next(); return; }

        [pm veepooSDKSettingMessageType:mt settingState:VPReadFunctionState completeBlock:^(VPSettingFunctionCompleteState state) {
            // state: 0=Unknown(无此功能) 1=Open 2=Close 3=Failure
            // Failure(3) 不覆盖快照值；Unknown/Open/Close 用主动读结果
            if (state != VPFunctionCompleteFailure) {
                NSString *st;
                BOOL open;
                switch (state) {
                    case VPFunctionCompleteOpen:  st = @"SUPPORT_OPEN";  open = YES;  break;
                    case VPFunctionCompleteClose: st = @"SUPPORT_CLOSE"; open = NO;   break;
                    case VPFunctionCompleteUnknown:
                    default:                     st = @"UNSUPPORT";     open = NO;   break;
                }
                result[key] = st;
                result[[key stringByAppendingString:@"Open"]] = @(open);
            }
            next();
        }];
    };
    next();
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
 JS：joemeWatch.readBTInfo() -> resolve { state, connected, btOpen, audioOpen, pending? }
 事件：on('btInfo')
 差异：若 block 还没上报过任何状态（lastBTInfo==nil），不回默认 disconnected，
      而是回 pending:YES —— 电话页据此保持上次 UI，等 block 真正回调再刷新，
      避免刚进页面时把"已配对但状态未同步"误显示成"未连接"。
 */
UNI_EXPORT_METHOD(@selector(readBTInfo:callback:))
- (void)readBTInfo:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    if (self.lastBTInfo) {
        [r addEntriesFromDictionary:self.lastBTInfo];
        [self sendEvent:@"btInfo" data:self.lastBTInfo];
    } else {
        // 还没拿到任何状态：不发 btInfo 事件、不回 disconnected，只回 pending
        r[@"pending"] = @YES;
        r[@"state"] = @"unknown";
        r[@"connected"] = @(NO);
    }
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
 差异：iOS 无按 mac 连接/断开的接口。
   - on=true：调 veepooSDK_openDeviceBTSwitch 触发系统配对，返回 sent:true。
   - on=false：iOS 不允许 App 主动断开经典蓝牙（系统蓝牙配对由用户在
     「设置 → 蓝牙」里管理），这里返回 unsupported:YES + reason:@"system"，
     电话页据此弹引导让用户去系统蓝牙忽略设备，而不是静默 no-op。
 */
UNI_EXPORT_METHOD(@selector(connectBT:callback:))
- (void)connectBT:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    BOOL on = options && options[@"on"] ? [options[@"on"] boolValue] : YES;
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    if (on) {
        [[VPBleCentralManage sharedBleManager].peripheralManage veepooSDK_openDeviceBTSwitch];
        r[@"sent"] = @(YES);
        r[@"ok"] = @(YES);
    } else {
        // iOS 无法在 App 内断开经典蓝牙
        r[@"sent"] = @(NO);
        r[@"ok"] = @(NO);
        r[@"unsupported"] = @(YES);
        r[@"reason"] = @"system";
        r[@"message"] = @"iOS 需在系统蓝牙设置中断开";
    }
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
 取常驻相机监听 block（只建一次，之后复用）。

 iOS SDK 与 Android 的关键差异：没有独立的 setCameraListener，
 拍照回调只能随 veepooSDKSettingCameraType:settingAndMonitorResult: 一起注册。
 所以本模块把所有相机状态都收口到这一个 block 上，Enter/Exit 也复用它 ——
 否则每次 startCamera/stopCamera 都会新建一个 block 覆盖掉上一个，
 手表上报的 Photo 回调（以及相机页关闭时的收尾）就会丢。

 插件方法跑在 uni 工作线程、SDK 回调跑在自己的线程，所以创建用 @synchronized
 包一层，避免并发调用各建一个 block（后者覆盖前者，先注册的回调就再也收不到）。
 */
- (void (^)(VPCameraType))cameraMonitorBlock {
    @synchronized (self) {
        if (!self.cameraMonitor) {
            __weak typeof(self) weakSelf = self;
            self.cameraMonitor = ^(VPCameraType type) {
                [weakSelf handleCameraType:type];
            };
        }
        return self.cameraMonitor;
    }
}

/** 装一次常驻监听：SDK 只存一个槽位，装过就不再重复下发 */
- (void)installCameraMonitorIfNeeded {
    if (self.cameraMonitorInstalled) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (!pm) return;
    self.cameraMonitorInstalled = YES;
    if (!self.cameraEntered) {
        // iOS 没有「只监听不下发」的接口，只能用 Exit 把 block 装进去。
        // 手表本来就不在拍照模式时这条命令无副作用（回执由 pendingSelfExit 过滤掉）。
        [self sendCameraExitCommand];
    }
}

/**
 下发 Exit 并登记一条「自己发的 Exit」，用于过滤随之而来的回执。
 必须成对维护计数：设备不回包时计数会挂住，所以另加时间窗（见 handleCameraType）。
 */
- (void)sendCameraExitCommand {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (!pm) return;
    self.pendingSelfExit++;
    self.pendingSelfExitAt = [[NSDate date] timeIntervalSince1970];
    [pm veepooSDKSettingCameraType:VPCameraTypeExit settingAndMonitorResult:self.cameraMonitorBlock];
}

- (void)enterCameraMode {
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    if (!pm) return;
    self.cameraEntered = YES;
    self.cameraMonitorInstalled = YES;
    // 不清 pendingSelfExit：占槽位那条 Exit 的回执可能是在 Enter 之后才到的，
    // 清掉就会被误当成「手表退出拍照页」把刚打开的相机页关掉。
    // 计数由回执自己消耗，设备不回包时由 handleCameraType 的 10 秒窗口兜底。
    [pm veepooSDKSettingCameraType:VPCameraTypeEnter settingAndMonitorResult:self.cameraMonitorBlock];
}

- (void)exitCameraMode {
    self.cameraEntered = NO;
    self.cameraMonitorInstalled = YES;
    // 断连时（peripheralModel 已被清掉）不要再下发：SDK 会走到写特征值失败的分支，
    // 且手表已经不在拍照模式，发过去只会换来一条失败回执。
    // 相机页关闭时要走到这里，所以判断放在方法内部而不是调用处。
    if (![VPBleCentralManage sharedBleManager].peripheralModel) return;
    [self sendCameraExitCommand];
}

/**
 相机状态的统一处理（对齐 Android 的 ICameraDataListener）。

 iOS 的 VPCameraType 只有 Exit(0)/Enter(1)/Photo(2)，没有 Android 的
 DEVICE_OPEN_SUCCESS 语义，所以 deviceInitiated 恒为 NO、也不会触发
 「手表自己进拍照页 → 手机自动开相机」这条链路。

 事件 camera 同时给两个字段：
   state   —— 原始 VPCameraType 数值（历史字段，保持兼容）
   status  —— 与 Android 同名的字符串（OPEN_SUCCESS / CLOSE_SUCCESS / TAKEPHOTO_CAN）
   handled —— Photo 的处理方式：activity / activity-not-ready / silent
   capture —— 静默拍照的不做原因：busy / permission-required / background

 注意 Exit 回执的过滤：installCameraMonitorIfNeeded / exitCameraMode 会主动下发 Exit，
 这些回执不该当成「手表退出了拍照页」抛给 JS（Android 那条是纯注册，没有对应事件）。
 用 pendingSelfExit 计数扣掉自己发的 Exit；设备不回包时计数会一直挂着，
 所以另加 10 秒时间窗（见下面的判断），过期后不再过滤，保证真正的手表退出不会被吞。
 */
- (void)handleCameraType:(VPCameraType)type {
    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"state"] = @(type);
    d[@"deviceInitiated"] = @NO;

    if (type == VPCameraTypePhoto) {
        d[@"status"] = @"TAKEPHOTO_CAN";
        // 与 Android 一致：手表按快门时尽量不依赖 JS 页面是否存活
        if ([JoemeCameraViewController isReady]) {
            d[@"handled"] = @"activity";
            [JoemeCameraViewController takePictureNow];
        } else if ([JoemeCameraViewController isOpen]) {
            // 相机页在但会话没起来（切后台/刚打开/切镜头中）：
            // takePictureNow 会把这次快门挂起到会话就绪后补拍，同时补开一次会话
            d[@"handled"] = @"activity-not-ready";
            [JoemeCameraViewController takePictureNow];
            [JoemeCameraViewController retryOpen];
        } else {
            [self capturePhotoSilentlyInto:d];
        }
    } else if (type == VPCameraTypeEnter) {
        d[@"status"] = @"OPEN_SUCCESS";
        self.cameraEntered = YES;
        // 不在这里清 pendingSelfExit：占槽位那条 Exit 的回执可能晚于 Enter 到达，
        // 清掉之后它会被误判成「手表退出拍照页」而把刚打开的相机页关掉。
    } else {
        // 超过 10 秒还没回包的自己发的 Exit 视为丢失，不再占着配额，
        // 否则设备不回包时会把之后真正的「手表退出拍照页」误吞。
        if (self.pendingSelfExit > 0
            && [[NSDate date] timeIntervalSince1970] - self.pendingSelfExitAt > 10) {
            self.pendingSelfExit = 0;
        }
        if (self.pendingSelfExit > 0) {
            // 这条 Exit 是我们自己下发的（占槽位 / 关页），不是手表退出的
            self.pendingSelfExit--;
            self.cameraEntered = NO;
            return;
        }
        d[@"status"] = @"CLOSE_SUCCESS";
        self.cameraEntered = NO;
        // 手表退出拍照页 → 手机预览页也收掉，否则留下一个控制不了的界面。
        // finishFromWatch 让关闭回调跳过回发 Exit（手表已经退出了）
        if ([JoemeCameraViewController isOpen]) {
            [JoemeCameraViewController finishFromWatch];
        }
    }

    [self sendEvent:@"camera" data:d];
}

/** App 是否在前台的缓存标记（由 JoemeStartAppStateTracking 维护） */
static BOOL JoemeAppActiveFlag = YES;

/**
 维护前后台标记：相机 block 可能在非主线程回调，不能在那里读 UIApplication。
 初值取 YES（能调到插件时 App 基本就在前台），之后完全由通知驱动，
 这样不必在非主线程读 applicationState。
 */
static void JoemeStartAppStateTracking(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        JoemeAppActiveFlag = YES;
        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserverForName:UIApplicationDidBecomeActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            JoemeAppActiveFlag = YES;
        }];
        [nc addObserverForName:UIApplicationWillResignActiveNotification
                        object:nil
                         queue:[NSOperationQueue mainQueue]
                    usingBlock:^(NSNotification *note) {
            JoemeAppActiveFlag = NO;
        }];
    });
}

/** App 是否在前台：iOS 在后台会挂起进程，拿不到摄像头 */
static BOOL JoemeAppIsActive(void) {
    // 读缓存标记而不是 dispatch_sync 主队列：相机 block 可能就在主线程之外被调用，
    // 一旦主线程正等 SDK 回调就会死锁。
    return JoemeAppActiveFlag;
}

/**
 手表按了快门但相机页没开：静默拍一张存相册（对齐 Android 的 capturePhotoSilently）。
 结果通过 photoCapture 事件告知 JS；camera 事件里带上 capture 字段便于排查。
 */
- (void)capturePhotoSilentlyInto:(NSMutableDictionary *)cameraEvent {
    if (!JoemeAppIsActive()) {
        cameraEvent[@"capture"] = @"background";
        return;
    }
    if (![JoemeCameraCapture hasCameraPermission]) {
        cameraEvent[@"capture"] = @"permission-required";
        return;
    }
    if ([JoemeCameraCapture isCapturing]) {
        cameraEvent[@"capture"] = @"busy";
        return;
    }
    cameraEvent[@"capture"] = @"silent";

    __weak typeof(self) weakSelf = self;
    [JoemeCameraCapture captureJPEGFront:NO completion:^(NSData *data, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        if (!data.length) {
            NSMutableDictionary *r = [resultWithCode(-1) mutableCopy];
            r[@"ok"] = @NO;
            r[@"source"] = @"silent";
            r[@"message"] = error.localizedDescription ?: @"拍照失败";
            [strongSelf sendEvent:@"photoCapture" data:r];
            return;
        }
        [JoemeCameraStore saveJPEGData:data completion:^(NSString *path, BOOL albumSaved, NSError *saveError) {
            NSMutableDictionary *r = [resultWithCode(path ? 200 : -1) mutableCopy];
            r[@"ok"] = @(path != nil);
            r[@"source"] = @"silent";
            r[@"albumSaved"] = @(albumSaved);
            if (path) r[@"path"] = path;
            else r[@"message"] = saveError.localizedDescription ?: @"保存失败";
            [strongSelf sendEvent:@"photoCapture" data:r];
        }];
    }];
}

/**
 注册常驻相机监听（不下发拍照指令，但要走一次 SDK 调用才能占到 block 槽位）。
 装好之后，只要手表处在拍照模式（App 发过 Enter），上报的快门都会由原生处理，
 即使 App 相机页没开也会静默拍照。
 Android：setCameraListener（只占监听槽位）—— 那条是纯注册，不写 0xB6。
 iOS：没有纯注册接口，这里用一条 Exit 占槽位（手表若本就在拍照模式才会受影响，
      相机页没开时也不会误关用户的拍照模式，因为 iOS 没有「手表主动进入」语义）。
 JS：joemeWatch.listenCamera()
 返回：{ code, supported }
 */
UNI_EXPORT_METHOD(@selector(listenCamera:callback:))
- (void)listenCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self installCameraMonitorIfNeeded];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 静默拍照：不开任何界面，直接拍一张存进相册（AVCapturePhotoOutput）。
 手表遥控场景要求收到快门后立刻出片，不能再让用户按一次快门。
 Android：Camera2 静默拍照；JS：joemeWatch.capturePhoto()
 事件：photoCapture -> { ok, path, source:'silent', albumSaved }
 返回：{ code, path }（成功）/ -3 无权限 / -4 上一次未完成
 */
UNI_EXPORT_METHOD(@selector(capturePhoto:callback:))
- (void)capturePhoto:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    NSString *camera = options[@"camera"];
    BOOL front = [camera isKindOfClass:[NSString class]] && [camera isEqualToString:@"front"];

    // 相机页开着时不能另起一个 AVCaptureSession —— 摄像头是独占资源，
    // 第二个 session 必然 startRunning 失败。这时直接转成页面的快门，
    // 结果仍走 photoCapture 事件（source:'screen'）。
    if ([JoemeCameraViewController isOpen]) {
        [JoemeCameraViewController takePictureNow];
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        r[@"ok"] = @YES;
        r[@"source"] = @"screen";
        r[@"deferred"] = @YES;   // 真正结果走 photoCapture 事件
        callback(r, NO);
        return;
    }

    __weak typeof(self) weakSelf = self;
    [JoemeCameraCapture captureJPEGFront:front completion:^(NSData *data, NSError *error) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!data.length) {
            // 采集层已经按 Android 的口径返回 -1 / -3（无权限）/ -4（忙）
            NSInteger code = error ? error.code : -1;
            if (code != -3 && code != -4) code = -1;
            NSMutableDictionary *r = [resultWithCode(code) mutableCopy];
            r[@"ok"] = @NO;
            r[@"message"] = error.localizedDescription ?: @"拍照失败";
            if (code == -3) r[@"permission"] = @"camera";
            [strongSelf sendEvent:@"photoCapture" data:r];
            callback(r, NO);
            return;
        }
        [JoemeCameraStore saveJPEGData:data completion:^(NSString *path, BOOL albumSaved, NSError *saveError) {
            NSMutableDictionary *r;
            if (path) {
                r = [resultWithCode(200) mutableCopy];
                r[@"ok"] = @YES;
                r[@"path"] = path;
            } else {
                r = [resultWithCode(-1) mutableCopy];
                r[@"ok"] = @NO;
                r[@"message"] = saveError.localizedDescription ?: @"保存失败";
            }
            r[@"albumSaved"] = @(albumSaved);
            r[@"source"] = @"silent";
            [strongSelf sendEvent:@"photoCapture" data:r];
            callback(r, NO);
        }];
    }];
}

/**
 打开 App 内的全屏相机页（AVCaptureSession 实时预览 + 快门），
 同时命令手表进入拍照模式（这样手表按快门才会把 Photo 上报上来）。
 Android：JoemeCameraActivity；JS：joemeWatch.openCameraScreen()
 事件：cameraScreen -> { open:false, count, closedByWatch }（关闭时）
       photoCapture -> { ok, path, source:'screen' }（每拍一张）
 返回：{ code, supported }；-3 表示没有相机权限
 */
UNI_EXPORT_METHOD(@selector(openCameraScreen:callback:))
- (void)openCameraScreen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    // 先把相机权限拿到，否则页面起来了也是黑屏（iOS 不会像 Android 一样抛异常）
    [JoemeCameraCapture requestCameraAccess:^(BOOL granted) {
        if (!granted) {
            NSMutableDictionary *r = [resultWithCode(-3) mutableCopy];
            r[@"message"] = @"缺少相机权限";
            r[@"permission"] = @"camera";
            r[@"supported"] = @YES;
            callback(r, NO);
            return;
        }
        BOOL opened = [self presentCameraScreenNotifyWatch:YES];
        NSMutableDictionary *r = [resultWithCode(opened ? 200 : -1) mutableCopy];
        r[@"supported"] = @YES;
        if (!opened) r[@"message"] = @"无法打开相机界面";
        callback(r, NO);
    }];
}

/**
 拉起相机页（JS 主动打开与手表快门兜底两条链路共用）。
 @param notifyWatch YES 时先给手表下发 Enter —— 手表不在拍照模式就不会上报快门
 */
- (BOOL)presentCameraScreenNotifyWatch:(BOOL)notifyWatch {
    // 重复打开：presentNew 内部会判重，但 Enter 不能重复下发（手表会闪一下）
    if (notifyWatch && !self.cameraEntered) [self enterCameraMode];

    __weak typeof(self) weakSelf = self;
    [JoemeCameraViewController setCloseHandler:^(NSInteger count) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        // 关闭相机页 → 让手表也退出拍照模式；手表自己退出的那次不再回发
        BOOL closedByWatch = [JoemeCameraViewController consumeClosedByWatch];
        if (!closedByWatch) [strongSelf exitCameraMode];
        [strongSelf sendEvent:@"cameraScreen" data:@{
            @"open": @NO,
            @"count": @(count),
            @"closedByWatch": @(closedByWatch)
        }];
    }];
    [JoemeCameraViewController setCaptureHandler:^(NSString *path) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf) return;
        NSMutableDictionary *d = [resultWithCode(200) mutableCopy];
        d[@"ok"] = @YES;
        d[@"path"] = path;
        d[@"source"] = @"screen";
        [strongSelf sendEvent:@"photoCapture" data:d];
    }];

    BOOL opened = [JoemeCameraViewController presentNew];
    if (!opened) {
        // 页面没起来（拿不到 window/rootViewController）：把刚下发的 Enter 撤回，
        // 否则手表会一直停在拍照页，用户退出 App 前都退不出来。
        // 回调也一并清掉，避免下次打开时被上一次的闭包误触发。
        [JoemeCameraViewController setCloseHandler:nil];
        [JoemeCameraViewController setCaptureHandler:nil];
        if (notifyWatch && self.cameraEntered) [self exitCameraMode];
    }
    return opened;
}

/** 关闭 App 相机页（关闭回调里会给手表下发 Exit） */
UNI_EXPORT_METHOD(@selector(closeCameraScreen:callback:))
- (void)closeCameraScreen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if ([JoemeCameraViewController isOpen]) {
        [JoemeCameraViewController finishIfOpen];
    }
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 进入相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:settingAndMonitorResult:（VPCameraTypeEnter=1）
          回调里 VPCameraTypePhoto(2) 表示用户按下快门，由原生直接出片（见 handleCameraType）。
 Android：startCamera(...)；JS：joemeWatch.startCamera()
 事件：on('camera') -> { state, status, deviceInitiated, handled?, capture? }
 说明：iOS 的 VPCameraType 只有 Exit/Enter/Photo，没有「设备主动进入」语义，
       deviceInitiated 恒为 false。
 */
UNI_EXPORT_METHOD(@selector(startCamera:callback:))
- (void)startCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [self enterCameraMode];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"supported"] = @YES;
    callback(r, NO);
}

/**
 退出相机遥控模式。
 iOS SDK：veepooSDKSettingCameraType:...（VPCameraTypeExit=0）
 Android：stopCamera(...)；JS：joemeWatch.stopCamera()
 事件：on('camera') -> { state, status, deviceInitiated }
 */
UNI_EXPORT_METHOD(@selector(stopCamera:callback:))
- (void)stopCamera:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    [self exitCameraMode];
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
    __weak typeof(self) weakSelf = self;
    __block BOOL fired = NO;
    void (^finish)(BOOL) = ^(BOOL ok) {
        if (fired) return;
        fired = YES;
        [weakSelf sendEvent:@"heartAlarm" data:@{ @"ok": @(ok) }];
        // 负向回 -1：页面（monitor.vue / heart.vue）靠 catch 回滚界面并提示，
        // 回 200 会让「保存失败」也弹「已保存」。
        callback(resultWithCode(ok ? 200 : -1), NO);
    };
    [pm veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:m settingMode:(on ? 1 : 0) successResult:^(VPDeviceHeartAlarmModel *hm) {
        finish(YES);
    } failureResult:^{
        finish(NO);
    }];

    // 设备不回包时 6 秒兜底：否则 onSaveHighHr 的 await 永远不返回，弹窗关掉后没有任何提示
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(NO); });
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
 读取运动模式（历史）数据，带进度 + head 摘要 + 逐分钟明细。
 JS：joemeWatch.readDeviceRunningData({ days: 3 } / { day: 0 }) -> on('runningData')
 事件（与 Android 完全同形，页面不用分端）：
   { progress: 0~1 }                     已读天数 / 总天数
   { head: {...} }                       一条运动的头部摘要（带 day 日索引）
   { items: [{...}], day }               该次运动的逐分钟明细
   { complete: true, days, startDay }    全部读完
   { day: 'crc', summary: [...] }        CRC 列表（去重用的指纹，页面可忽略）

 实现路径（iOS 与 Android 不同）：
   ① veepooSDKStartReadDeviceRunningData —— 让设备把存着的运动记录同步进 SDK 本地库；
      这个回调只有进度/完成，没有数据体。
   ② 读完后用 VPDataBaseOperation 按「每一天」查库：
      veepooSDKGetDeviceRunningDataWithDate:andTableID:（queryDate 传 yyyy-MM-dd）。
      按天查的好处是日索引由我们确定（day 是查询参数），不依赖设备 RTC 写进记录里的日期
      —— 设备时钟错时 head.date 会整年偏差。head 同时带 day 和 date：页面优先用 date，
      只在 date 不可信（年份 < 2000 / 与手机今天差超过 -1~180 天）时才退回 day 推出的日期。
 单位换算（库 → Android 口径）：
   totalDis 是米 → distance 给公里；totalCal 是 cal → kcal 要 ÷1000；
   oneMinuteData 里 disValue 仍是米、calValue 仍是 cal（页面逐分钟那侧自己 ÷1000）。
 */
UNI_EXPORT_METHOD(@selector(readDeviceRunningData:callback:))
- (void)readDeviceRunningData:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPBleCentralManage *manager = [VPBleCentralManage sharedBleManager];
    VPPeripheralBaseManage *pm = manager.peripheralManage;
    NSString *mac = manager.peripheralModel.deviceAddress ?: @"";

    // 日索引区间：{ day: n } 只读那天；{ days: n } 从今天起连读 n 天（默认/上限 3）
    NSInteger deviceDays = manager.peripheralModel.runningSaveTimes > 0
        ? manager.peripheralModel.runningSaveTimes : 3;
    NSInteger maxDays = MAX(1, MIN(3, deviceDays));
    BOOL hasDay = (options[@"day"] != nil);
    NSInteger firstDay = 0, endDay;
    if (hasDay) {
        firstDay = MAX(0, MIN([options[@"day"] integerValue], maxDays - 1));
        endDay = firstDay + 1;
    } else {
        NSInteger reqDays = options[@"days"] ? [options[@"days"] integerValue] : maxDays;
        if (reqDays <= 0) reqDays = maxDays;
        endDay = MAX(1, MIN(reqDays, maxDays));
    }
    NSInteger totalDays = endDay - firstDay;

    // 会话号：新一次读取让上一场的迟到回调失效
    NSInteger seq = ++self.sportReadSeq;
    __weak typeof(self) weakSelf = self;
    __block BOOL started = NO;

    // 读设备 + 查库 + 发事件，只跑一次（SDK 的完成回调与看门狗都可能触发）
    void (^collect)(void) = ^{
        if (started) return;
        started = YES;
        if (weakSelf.sportReadSeq != seq) return;

        [weakSelf sendEvent:@"runningData" data:@{ @"progress": @0 }];
        NSInteger done = 0;
        NSInteger recordTotal = 0;
        for (NSInteger day = firstDay; day < endDay; day++) {
            if (weakSelf.sportReadSeq != seq) return;
            NSString *date = [weakSelf dateStrForDay:day];
            NSArray *arr = [VPDataBaseOperation veepooSDKGetDeviceRunningDataWithDate:date andTableID:mac];
            for (id it in arr) {
                if (![it isKindOfClass:[NSDictionary class]]) continue;
                NSDictionary *rec = (NSDictionary *)it;
                NSDictionary *head = [weakSelf sportHeadFromDBRecord:rec day:day];
                if (!head) continue;
                recordTotal++;
                [weakSelf sendEvent:@"runningData" data:@{ @"head": head }];
                NSArray *items = [weakSelf sportItemsFromDBRecord:rec head:head day:day];
                if (items.count > 0) {
                    [weakSelf sendEvent:@"runningData" data:@{ @"items": items, @"day": @(day) }];
                }
            }
            done++;
            [weakSelf sendEvent:@"runningData" data:@{
                @"progress": totalDays > 0 ? @((double)done / (double)totalDays) : @1
            }];
        }

        // GPS 运动表：老接口 veepooSDKStartReadDeviceRunningData 只读普通运动，
        // GPS 表（isHasGpsInfo=true 的那些）要走 readDeviceSportCRCArr + readDeviceSportWithCRC。
        // 对应 Android 的 onGPSWatchSportModeHeadChange 回调。两条事件同一次读取里发，
        // 页面按 day 归属到同一条记录。
        if (weakSelf.sportReadSeq == seq) {
            [pm readDeviceSportCRCArr:^(bool success, NSArray<NSNumber *> *crcArr) {
                if (!success || crcArr.count == 0) return;
                if (weakSelf.sportReadSeq != seq) return;
                [pm readDeviceSportWithCRC:crcArr result:^(NSArray<VPDeviceSportModel *> *normalArr, NSArray<VPDeviceSportWithGPSModel *> *gpsArr) {
                    if (weakSelf.sportReadSeq != seq) return;
                    for (VPDeviceSportWithGPSModel *m in gpsArr) {
                        NSInteger day = [weakSelf dayIndexFromTimestamp:m.startTimestamp];
                        if (day == NSNotFound || day < firstDay || day >= endDay) continue;
                        NSDictionary *head = [weakSelf gpsHeadFromGPSModel:m day:day];
                        if (!head) continue;
                        [weakSelf sendEvent:@"runningData" data:@{ @"head": head }];
                        NSArray *items = [weakSelf gpsItemsFromGPSModel:m head:head day:day];
                        if (items.count > 0) {
                            [weakSelf sendEvent:@"runningData" data:@{ @"items": items, @"day": @(day) }];
                        }
                    }
                }];
            }];
        }

        // CRC 列表：页面不需要，保留给排查「设备上到底存了几组」
        if (weakSelf.sportReadSeq == seq) {
            [pm veepooSDK_readDeviceRunningCrcResult:^(NSArray *crcValues) {
                [weakSelf sendEvent:@"runningData" data:@{ @"day": @"crc", @"summary": crcValues ?: @[] }];
            }];
        }
        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        d[@"complete"] = @YES;
        d[@"days"] = @(totalDays);
        d[@"startDay"] = @(firstDay);
        d[@"count"] = @(recordTotal);
        [weakSelf sendEvent:@"runningData" data:d];

        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        r[@"days"] = @(totalDays);
        r[@"startDay"] = @(firstDay);
        r[@"count"] = @(recordTotal);
        callback(r, NO);
    };

    // 25 秒看门狗：设备无响应时直接读库（库里是上次同步的数据，比空手而归有用）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        collect();
    });

    [pm veepooSDKStartReadDeviceRunningData:^(VPReadDeviceBaseDataState state, NSUInteger totalTimes,
                                              NSUInteger currentReadTimes, NSUInteger progress) {
        if (weakSelf.sportReadSeq != seq) return;
        if (state == VPReadDeviceBaseDataComplete) {
            collect();
        }
    }];
}

/** 库里一条运动记录 -> Android 同形 head（字段单位已换算：distance 公里、kcal 千卡） */
- (NSDictionary *)sportHeadFromDBRecord:(NSDictionary *)rec day:(NSInteger)day {
    if (![rec isKindOfClass:[NSDictionary class]]) return nil;
    // 隐藏记录（用户删掉的）不下发
    if (JoemeInt(rec[@"isHide"]) == 1) return nil;

    NSString *begin = rec[@"beginTime"] ?: @"";
    NSString *end = rec[@"endTime"] ?: @"";
    NSDictionary *b = [self hourMinuteSecondFromString:begin];
    NSDictionary *e = [self hourMinuteSecondFromString:end];

    double totalDisM = JoemeDouble(rec[@"totalDis"]);
    double totalCalCal = JoemeDouble(rec[@"totalCal"]);
    NSInteger recordCount = JoemeInt(rec[@"recordCount"]);
    if (recordCount <= 0) {
        NSArray *minutes = rec[@"oneMinuteData"];
        recordCount = [minutes isKindOfClass:[NSArray class]] ? (NSInteger)minutes.count : 0;
    }

    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    h[@"day"] = @(day);
    h[@"sportType"] = @(JoemeInt(rec[@"type"]));
    h[@"date"] = begin.length >= 10 ? [begin substringToIndex:10] : @"";
    h[@"startHour"] = b[@"hour"] ?: @0;
    h[@"startMinute"] = b[@"minute"] ?: @0;
    h[@"startSecond"] = b[@"second"] ?: @0;
    h[@"stopHour"] = e[@"hour"] ?: @0;
    h[@"stopMinute"] = e[@"minute"] ?: @0;
    h[@"stopSecond"] = e[@"second"] ?: @0;
    h[@"stepCount"] = @(JoemeInt(rec[@"totalStep"]));
    h[@"sportTime"] = @(JoemeInt(rec[@"totalTime"]));
    // 库里的 totalDis 单位是米，Android/页面都用公里（保留 3 位，与 Android 的 round3 一致）
    h[@"distance"] = @(round(totalDisM) / 1000.0);
    // 库里的 totalCal 单位是 cal，Android 的 head.kcal 是千卡
    h[@"kcal"] = @(round(totalCalCal) / 1000.0);
    h[@"recordCount"] = @(recordCount);
    h[@"pauseCount"] = @(JoemeInt(rec[@"pauseCount"]));
    h[@"pauseTime"] = @(JoemeInt(rec[@"pauseTotalTime"]));
    h[@"peisu"] = @(JoemeInt(rec[@"averPace"]));
    h[@"averRate"] = @(JoemeInt(rec[@"averHeart"]));
    h[@"sportCount"] = @(JoemeInt(rec[@"totalSport"]));
    // 有氧运动时长（秒）：Android 叫 oxsporttimes；iOS 库里有 aerobTime，直接透出
    h[@"oxsporttimes"] = @(JoemeInt(rec[@"aerobTime"]));
    h[@"raw"] = [NSString stringWithFormat:
                 @"SportModel{type=%ld, begin=%@, end=%@, step=%ld, dis=%f m, cal=%f cal, time=%ld s}",
                 (long)JoemeInt(rec[@"type"]), begin, end,
                 (long)JoemeInt(rec[@"totalStep"]), totalDisM, totalCalCal,
                 (long)JoemeInt(rec[@"totalTime"])];
    return h;
}

/** 库里一条运动记录的 oneMinuteData -> Android 同形 items */
- (NSArray *)sportItemsFromDBRecord:(NSDictionary *)rec head:(NSDictionary *)head day:(NSInteger)day {
    NSArray *minutes = rec[@"oneMinuteData"];
    if (![minutes isKindOfClass:[NSArray class]] || minutes.count == 0) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:minutes.count];
    NSInteger allMinute = (NSInteger)minutes.count;
    for (NSInteger i = 0; i < allMinute; i++) {
        NSDictionary *m = minutes[i];
        if (![m isKindOfClass:[NSDictionary class]]) continue;
        [out addObject:@{
            @"day": @(day),
            @"date": head[@"date"] ?: @"",
            @"startHour": head[@"startHour"] ?: @0,
            @"startMinute": head[@"startMinute"] ?: @0,
            @"startSecond": head[@"startSecond"] ?: @0,
            // iOS 的逐分钟包没有「第几分钟」字段，按数组下标（每分钟一条）
            @"minute": @(i),
            @"allMinute": @(allMinute),
            @"rate": @(JoemeInt(m[@"heartValue"])),
            @"stepCount": @(JoemeInt(m[@"stepValue"])),
            @"sportCount": @(JoemeInt(m[@"sportValue"])),
            @"distance": @(JoemeInt(m[@"disValue"])),   // 米
            @"kcal": @(JoemeInt(m[@"calValue"])),       // cal（页面 ÷1000）
            @"beathPause": @(JoemeInt(m[@"isPause"]))
        }];
    }
    return out;
}

#pragma mark - GPS 运动表（VPDeviceSportWithGPSModel）

/**
 * 时间戳（秒）-> day 索引（0=今天，1=昨天…）。超出设备存储范围返回 NSNotFound。
 * 与 dateStrForDay 同口径：按本地日历的年月日差算，不涉及时区换算。
 */
- (NSInteger)dayIndexFromTimestamp:(NSTimeInterval)ts {
    if (ts <= 0) return NSNotFound;
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSCalendar *cal = [NSCalendar currentCalendar];
    NSDateComponents *diff = [cal components:(NSCalendarUnitDay) fromDate:[NSDate date] toDate:date options:0];
    NSInteger day = -diff.day;   // ts 在过去 -> diff.day 为负 -> day 为正
    if (day < 0) return NSNotFound;
    return day;
}

/**
 * 时间戳（秒）-> "yyyy-MM-dd HH:mm:ss"。
 */
- (NSString *)dateTimeStringFromTimestamp:(NSTimeInterval)ts {
    if (ts <= 0) return @"";
    NSDate *date = [NSDate dateWithTimeIntervalSince1970:ts];
    NSDateFormatter *fmt = [[NSDateFormatter alloc] init];
    fmt.dateFormat = @"yyyy-MM-dd HH:mm:ss";
    return [fmt stringFromDate:date];
}

/**
 * VPDeviceSportWithGPSModel -> Android 同形 head（含 GPS 表独有的心率/配速/速度/步频极值、
 * 海拔、累计爬升/下降）。单位换算：
 *   dis      m -> distance(km) + distanceM(m)
 *   cal      cal -> kcal(千卡)
 *   altitude/cm -> m
 *   cumulativeClimb/Decline/cm -> m
 * showType: 1/2/5/6 有 GPS；5/6/7 有海拔（见 VPDeviceSportWithGPSModel.h）。
 */
- (NSDictionary *)gpsHeadFromGPSModel:(VPDeviceSportWithGPSModel *)m day:(NSInteger)day {
    if (!m) return nil;
    BOOL hasGps = (m.showType == 1 || m.showType == 2 || m.showType == 5 || m.showType == 6);
    BOOL haveAlt = (m.showType == 5 || m.showType == 6 || m.showType == 7);

    NSString *begin = [self dateTimeStringFromTimestamp:m.startTimestamp];
    NSString *end = [self dateTimeStringFromTimestamp:m.stopTimestamp];
    NSDictionary *b = [self hourMinuteSecondFromString:begin];
    NSDictionary *e = [self hourMinuteSecondFromString:end];

    NSMutableDictionary *h = [NSMutableDictionary dictionary];
    h[@"day"] = @(day);
    h[@"sportType"] = @(m.sportType);
    h[@"date"] = begin.length >= 10 ? [begin substringToIndex:10] : @"";
    h[@"startHour"] = b[@"hour"] ?: @0;
    h[@"startMinute"] = b[@"minute"] ?: @0;
    h[@"startSecond"] = b[@"second"] ?: @0;
    h[@"stopHour"] = e[@"hour"] ?: @0;
    h[@"stopMinute"] = e[@"minute"] ?: @0;
    h[@"stopSecond"] = e[@"second"] ?: @0;
    h[@"stepCount"] = @(m.step);
    h[@"sportTime"] = @(m.duration);
    h[@"distanceM"] = @(m.dis);
    h[@"distance"] = @(round(m.dis) / 1000.0);
    h[@"kcal"] = @(round(m.cal) / 1000.0);
    h[@"recordCount"] = @(m.recordCount);
    h[@"pauseCount"] = @(m.pauseCount);
    h[@"pauseTime"] = @(m.pauseDuration);
    h[@"peisu"] = @(m.avePace);
    h[@"averRate"] = @(m.aveHeart);
    h[@"sportCount"] = @(m.sport);
    h[@"oxsporttimes"] = @(m.aerobicCount);
    h[@"hasGpsInfo"] = @(hasGps);
    // 心率 / 配速 / 速度 / 步频 整场极值与均值
    h[@"maxHeartRate"] = @(m.maxHeart);
    h[@"minHeartRate"] = @(m.minHeart);
    h[@"avgHeartRate"] = @(m.aveHeart);
    h[@"maxPace"] = @(m.maxPace);
    h[@"minPace"] = @(m.minPace);
    h[@"avgPace"] = @(m.avePace);
    h[@"maxSpeed"] = @(m.maxSpeed);
    h[@"minSpeed"] = @(m.minSpeed);
    h[@"avgSpeed"] = @(m.aveSpeed);
    h[@"maxCadence"] = @(m.maxCadence);
    h[@"minCadence"] = @(m.minCadence);
    h[@"avgCadence"] = @(m.aveCadence);
    // 海拔：cm -> m
    h[@"haveAltitude"] = @(haveAlt);
    h[@"maxAltitude"] = @(m.maxAltitude / 100.0);
    h[@"minAltitude"] = @(m.minAltitude / 100.0);
    h[@"avgAltitude"] = @(m.aveAltitude / 100.0);
    h[@"cumulativeClimb"] = @(m.cumulativeClimb / 100.0);
    h[@"cumulativeDecline"] = @(m.cumulativeDecline / 100.0);
    h[@"dataType"] = @(m.showType);
    // a7ProtectSportType：Android SDK 特有字段（A7 芯片保护的子运动类型），iOS 无对应属性，
    // 用 showType 顶上（页面主要拿 dataType 判断有无海拔/GPS）
    h[@"a7ProtectSportType"] = @(m.showType);
    h[@"raw"] = [NSString stringWithFormat:
                 @"SportWithGPSModel{type=%d, begin=%@, end=%@, step=%u, dis=%u m, cal=%u cal, time=%u s, showType=%d}",
                 m.sportType, begin, end, m.step, m.dis, m.cal, m.duration, m.showType];
    return h;
}

/**
 * VPDeviceSportWithGPSModel.minutes -> items 数组（含逐分钟海拔与抽稀后的 GPS 轨迹点）。
 * GPS 轨迹点每分钟最多保留 12 个（≈5 秒一个），与 Android GPS_POINTS_PER_MINUTE 一致，
 * 避免整场几千个点把 JS 存储撑爆。
 */
- (NSArray *)gpsItemsFromGPSModel:(VPDeviceSportWithGPSModel *)m head:(NSDictionary *)head day:(NSInteger)day {
    if (!m.minutes) return @[];
    NSMutableArray *out = [NSMutableArray arrayWithCapacity:m.minutes.count];
    NSInteger allMinute = (NSInteger)m.minutes.count;
    for (NSInteger i = 0; i < allMinute; i++) {
        VPDSOneMinuteModel *mm = m.minutes[i];
        if (![mm isKindOfClass:[VPDSOneMinuteModel class]]) continue;
        NSMutableDictionary *item = [NSMutableDictionary dictionary];
        item[@"day"] = @(day);
        item[@"date"] = head[@"date"] ?: @"";
        item[@"startHour"] = head[@"startHour"] ?: @0;
        item[@"startMinute"] = head[@"startMinute"] ?: @0;
        item[@"startSecond"] = head[@"startSecond"] ?: @0;
        item[@"minute"] = @(i);
        item[@"allMinute"] = @(allMinute);
        item[@"rate"] = @(mm.heart);
        item[@"stepCount"] = @(mm.step);
        item[@"sportCount"] = @(mm.sport);
        item[@"distance"] = @(mm.dis);   // 米
        item[@"kcal"] = @(mm.cal);       // cal（页面 ÷1000）
        item[@"beathPause"] = @(mm.pause);
        // 逐分钟海拔（cm -> m）
        if (mm.altitude != 0) item[@"altitude"] = @(mm.altitude / 100.0);

        // GPS 轨迹点抽稀
        if (mm.gpsDatas.count > 0) {
            NSMutableArray *lats = [NSMutableArray array];
            NSMutableArray *lngs = [NSMutableArray array];
            NSUInteger total = mm.gpsDatas.count;
            NSUInteger keep = MIN(total, 12);
            for (NSUInteger k = 0; k < keep; k++) {
                NSUInteger idx = (total <= 1) ? 0 : (NSUInteger)round(k * (total - 1) / (double)(keep - 1));
                VPDSMinuteGPSModel *g = mm.gpsDatas[idx];
                [lats addObject:@(g.latitude)];
                [lngs addObject:@(g.longitude)];
            }
            item[@"hasGpsInfo"] = @YES;
            item[@"latArray"] = lats;
            item[@"lngArray"] = lngs;
        }
        [out addObject:item];
    }
    return out;
}

/** "yyyy-MM-dd HH:mm:ss" -> { hour, minute, second }（解析不到给 0） */
- (NSDictionary *)hourMinuteSecondFromString:(NSString *)str {
    if (![str isKindOfClass:[NSString class]]) return @{ @"hour": @0, @"minute": @0, @"second": @0 };
    NSArray *parts = [str componentsSeparatedByString:@" "];
    NSString *t = parts.count >= 2 ? parts.lastObject : str;
    NSArray *hms = [t componentsSeparatedByString:@":"];
    return @{
        @"hour": hms.count >= 1 ? @([hms[0] integerValue]) : @0,
        @"minute": hms.count >= 2 ? @([hms[1] integerValue]) : @0,
        @"second": hms.count >= 3 ? @([hms[2] integerValue]) : @0
    };
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

// 注：dialList / setDial 的实现放在「批次 7：表盘」里（与 dialCapability / dialOnline /
// downloadDial 相邻）。UNI_EXPORT_METHOD 重复注册同一个 selector 会互相覆盖，
// 所以这里只留一行说明，不要再补一份实现。

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
        // 压力（手动测量通道）。页面 index.vue 按 Android 的 toString 文本解析
        // （正则抠 pressure / timeStamp），所以这里给同形文本 + 结构化 list 两份。
        if (m.stressArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            NSMutableString *text = [NSMutableString stringWithString:@"["];
            for (VPManualStressModel *r in m.stressArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"pressure": @(r.value)
                }];
                [text appendFormat:@"PressureManualData{timeStamp=%u, pressure=%d}, ",
                 r.timestamp, r.value];
            }
            [text appendString:@"]"];
            [weakSelf sendEvent:@"manualData.stress" data:@{ @"list": list, @"data": text }];
        }
        // 梅脱（手动测量通道）。同上：页面按 'meto' 和 'timeStamp' 两个字段名抠值。
        if (m.metArr.count > 0) {
            NSMutableArray *list = [NSMutableArray array];
            NSMutableString *text = [NSMutableString stringWithString:@"["];
            for (VPManualMetModel *r in m.metArr) {
                [list addObject:@{
                    @"ts": @((long long)r.timestamp * 1000LL),
                    @"meto": @(r.value)
                }];
                [text appendFormat:@"MetoManualData{timeStamp=%u, meto=%d}, ", r.timestamp, r.value];
            }
            [text appendString:@"]"];
            [weakSelf sendEvent:@"manualData.met" data:@{ @"list": list, @"data": text }];
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

    __block BOOL emitted = NO;   // 防重入：超时兜底与正常收尾只允许 emit 一次

    void (^emit)(void) = ^{
        if (emitted) return;
        emitted = YES;
        [weakSelf sendEvent:@"tempSetting" data:r];
        callback(r, NO);
    };

    // 超时兜底：两个开关串行读，设备不回包时回调永不触发、页面 Promise 会一直 pending。
    // 5 秒后先回一次已读到的部分（缺的字段页面按 null 处理，保留本地值）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (emitted) return;
        r[@"timeout"] = @YES;
        emit();
    });

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

    __block BOOL emitted = NO;
    void (^finish)(VPSettingFunctionCompleteState) = ^(VPSettingFunctionCompleteState state) {
        if (emitted) return;
        emitted = YES;
        NSInteger open = -1;
        if (state == VPFunctionCompleteOpen) open = 1;
        else if (state == VPFunctionCompleteClose) open = 0;
        else if (model.oxygenAutoDetectType > 0) open = (model.oxygenAutoDetectType == 1 ? 1 : 0);

        NSDictionary *d = @{ @"isOpen": @(open), @"openState": @(state), @"ok": @(open >= 0) };
        [weakSelf sendEvent:@"spo2Auto" data:d];
        NSMutableDictionary *r = [resultWithCode(open >= 0 ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    };

    [pm veepooSDKSettingBaseFunctionType:VPSettingAutomaticOxygenTest
                            settingState:VPReadFunctionState
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        finish(state);
    }];

    // 设备不回包时 6 秒兜底：否则页面 readAutoMonitor 的 Promise 永久 pending，
    // 血氧页开关一直停在初值。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(VPFunctionCompleteFailure); });
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
    __block BOOL fired = NO;
    void (^finish)(VPSettingFunctionCompleteState) = ^(VPSettingFunctionCompleteState state) {
        if (fired) return;
        fired = YES;
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose
                   || state == VPFunctionCompleteComplete);
        NSDictionary *d = @{ @"isOpen": @(on ? 1 : 0), @"openState": @(state), @"ok": @(ok) };
        [weakSelf sendEvent:@"spo2Auto" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    };
    [pm veepooSDKSettingAllDayOxygenTest:(on ? VPSettingFunctionOpen : VPSettingFunctionClose)
                                  result:^(VPSettingFunctionCompleteState state) {
        finish(state);
    }];

    // 设备不回包时 6 秒兜底：否则血氧页开关一直停在 busy 态（Promise 永不结束）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(VPFunctionCompleteFailure); });
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

    __block BOOL fired = NO;
    void (^finish)(NSArray<VPAutoMonitTestModel *> *) = ^(NSArray<VPAutoMonitTestModel *> *models) {
        if (fired) return;
        fired = YES;
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
    };

    [pm veepooSDKReadAutoMonitSwitchInfo:^(NSArray<VPAutoMonitTestModel *> *models) {
        finish(models);
    }];

    // 设备不回包时 6 秒兜底：heart.vue 进页面就 await 它，不兜底会一直挂在 pending。
    // 回空列表（不发事件）：页面按「没读到」处理，保留本地值而不是把开关翻成关。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(@[]); });
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
 JS：joemeWatch.readAllDayOxygen() -> resolve + on('allDayOxygen')
   { ok, isOpen, openState, data: "AllSetData{type=SPO2H_NIGHT_AUTO_DETECT, isOpen=1}" }
 说明：iOS 没有 AllSetData 回包，这里读基本开关 VPSettingAutomaticOxygenTest，
      与 readSpo2AutoDetect 共用同一能力位（只是事件名不同，页面各自监听）。
      **data 必须给**：monitor.vue 的 applyAllDayOxygen 先找 'AllSetData' 前缀，
      找不到直接 return，allDayOxygenLoaded 永远为 false，血氧自动监测开关就一直是灰的。
      读取失败（无回包/设备不支持）时故意不带 data，让页面保持「未读到」而不是显示成「关」。
 */
UNI_EXPORT_METHOD(@selector(readAllDayOxygen:callback:))
- (void)readAllDayOxygen:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;

    __block BOOL emitted = NO;
    void (^finish)(VPSettingFunctionCompleteState) = ^(VPSettingFunctionCompleteState state) {
        if (emitted) return;
        emitted = YES;
        BOOL ok = (state == VPFunctionCompleteOpen || state == VPFunctionCompleteClose);
        BOOL isOpen = (state == VPFunctionCompleteOpen);
        // 读失败时退回握手拿到能力位（1=开，其它=未知），与 readSpo2AutoDetect 同口径
        if (!ok && model.oxygenAutoDetectType > 0) {
            isOpen = (model.oxygenAutoDetectType == 1);
            ok = YES;
        }
        NSMutableDictionary *d = [@{ @"ok": @(ok),
                                     @"isOpen": @(isOpen),
                                     @"openState": @(state) } mutableCopy];
        if (ok) {
            // Android AllSetData.toString() 同形：页面按 isOpen=1/0 判断开/关。
            // 同时给 data 与 summary：Android 的读接口用的是 summary 键，
            // 页面的 _payload 对两者都能兜住。
            NSString *text = [NSString stringWithFormat:
                              @"AllSetData{type=SPO2H_NIGHT_AUTO_DETECT, isOpen=%d}", isOpen ? 1 : 0];
            d[@"data"] = text;
            d[@"summary"] = text;
        }
        [weakSelf sendEvent:@"allDayOxygen" data:d];
        NSMutableDictionary *r = [resultWithCode(ok ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    };

    [pm veepooSDKSettingBaseFunctionType:VPSettingAutomaticOxygenTest
                            settingState:VPReadFunctionState
                           completeBlock:^(VPSettingFunctionCompleteState state) {
        finish(state);
    }];

    // 设备不回包时 6 秒兜底：否则 JS Promise 永久 pending，页面开关一直是灰的
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(VPFunctionCompleteFailure); });
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
 来电监听开关（仅 Android）。
 iOS 的来电提醒由系统 ANCS 在收到真实来电时直接转发给手表，
 App 既不需要也不允许监听通话状态（无 CallKit 观察者时拿不到话单），
 因此这里回 unsupported，`active` 恒为 NO —— 页面据此不会误报"监听已生效"。
 */
UNI_EXPORT_METHOD(@selector(startCallMonitor:callback:))
- (void)startCallMonitor:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    [self sendEvent:@"callMonitor" data:@{ @"active": @NO, @"unsupported": @YES }];
    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
    r[@"active"] = @NO;
    r[@"granted"] = @NO;
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

/** iOS 8 位重复串（十进制字符串）-> Android/JS 的 7 位「周日..周一」串 */
- (NSString *)androidRepeatFromIOSState:(NSString *)state {
    NSInteger v = [state isKindOfClass:[NSString class]] ? [state integerValue] : 0;
    NSMutableString *out = [NSMutableString string];
    // 头文件：bit0=周一 … bit6=周日，bit7 恒 0（示例 00000011=周一+周二=3）。
    // JS 的 7 位串是 charAt(0)=周日 … charAt(6)=周一，即 charAt(i) 取 bit(6-i)，
    // 所以从 bit6 往 bit0 依次追加，共 7 位。
    for (NSInteger bit = 6; bit >= 0; bit--) {
        [out appendString:((v >> bit) & 1) ? @"1" : @"0"];
    }
    return out;
}

/** Android/JS 的 7 位「周日..周一」串 -> iOS 8 位重复串（十进制字符串） */
- (NSString *)iosRepeatStateFromAndroid:(NSString *)repeat {
    if (![repeat isKindOfClass:[NSString class]] || repeat.length < 7) return @"0";
    NSInteger v = 0;
    for (NSInteger i = 0; i < 7; i++) {
        unichar c = [repeat characterAtIndex:i];
        // charAt(6)=周一=bit0 … charAt(0)=周日=bit6
        if (c == '1') v |= (1 << (6 - i));
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
    // 留一份快照：新增闹钟时据此挑空闲 ID（否则固定传 1 会覆盖已有闹钟）。
    // 只有拿到数组才更新，避免失败路径把缓存冲成空表导致下次新增又用回 ID 1。
    if ([alarmArray isKindOfClass:[NSArray class]]) self.lastTextAlarms = list;
    return list;
}

/**
 下一个可用的闹钟 ID：取已用 ID 里最小的空缺（1~10）；一个空位都没有时返回 nil。
 设备侧 ID 范围是 1-10（ALARM_FULL），所以按这个区间找空位。
 返回 nil 而不是「退回 1」：满了还传 1 会覆盖已存在的闹钟。
 */
- (NSString *)nextTextAlarmId {
    NSMutableSet<NSNumber *> *used = [NSMutableSet set];
    for (NSDictionary *a in self.lastTextAlarms) {
        NSInteger v = [a[@"alarmId"] integerValue];
        if (v > 0) [used addObject:@(v)];
    }
    for (NSInteger i = 1; i <= 10; i++) {
        if (![used containsObject:@(i)]) return [NSString stringWithFormat:@"%ld", (long)i];
    }
    return nil;
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
    // successResult / failureResult / 超时兜底三选一，避免回调重入
    __block BOOL fired = NO;
    void (^fail)(void) = ^{
        if (fired) return;
        fired = YES;
        [weakSelf sendEvent:@"heartAlarm" data:@{ @"ok": @NO }];
        callback(resultWithCode(-1), NO);
    };
    [pm veepooSDKSettingDeviceHeartAlarmWithHeartAlarmModel:[[VPDeviceHeartAlarmModel alloc] init]
                                                settingMode:2
                                              successResult:^(VPDeviceHeartAlarmModel *hm) {
        if (fired) return;
        fired = YES;
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
        fail();
    }];

    // 设备不回包时 6 秒兜底，否则 JS Promise 永久 pending
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ fail(); });
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
   ppg                    科学睡眠（Android toString 键名就是 ppg，对应 CustomSettingData.ppg）
   血糖单位 / 尿酸单位 / 血脂单位（枚举名）
 各字段是串行读取（SDK 不支持并发命令），全部读完才发一次事件。
 11+1 条命令串行下发，任一命令无回包会把整条链卡死、页面永远「未读到设备设置」，
 所以有 10 秒看门狗：到点就把已读到的字段先发出去。
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
        @(VPSettingAutomaticPPGTest),         // 科学睡眠（头文件：精准睡眠由 PPG 控制）
        @(VPSettingBloodGlucoseUnit),         // 血糖单位
        @(VPSettingUricAcidUnit),             // 尿酸单位
        @(VPSettingLipidUnit)                 // 血脂单位
    ];
    NSArray<NSString *> *keys = @[
        @"isOpenAutoHeartDetect", @"自动检测HRV", @"低氧报警", @"体温自动检测",
        @"血糖监测", @"压力", @"血液成分开关", @"跌倒检测",
        @"ppg",
        @"血糖单位", @"尿酸单位", @"血脂单位"
    ];

    __block NSUInteger idx = 0;
    __block BOOL emitted = NO;
    __block void (^next)(void);

    void (^emit)(void) = ^{
        if (emitted) return;
        emitted = YES;
        if (v.count == 0) {
            // 一个字段都没读到（设备未连接/全部超时）：不发 customSettingRead，
            // 页面就不会把 customSettingLoaded 置 true，也就不会拿界面默认值去写设备。
            callback(resultWithCode(-1), NO);
            return;
        }
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

    // 看门狗：12 条命令串行，单条无回包会卡死整条链（页面据此判定「已读到」，
    // 卡住就永远不允许改开关）。10 秒到点先发已读到的部分，字段缺失的开关页面保留原值。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ emit(); });

    next = ^{
        // 看门狗已经发过结果就不再继续下发命令，省掉无意义的 BLE 往返
        if (emitted || idx >= types.count) { emit(); return; }
        NSUInteger i = idx++;
        VPSettingBaseFunctionSwitchType t = (VPSettingBaseFunctionSwitchType)[types[i] integerValue];
        // 单条命令 3 秒不回包就跳过：否则一条卡住会把后面所有开关都拖成「未读到」
        __block BOOL stepped = NO;
        void (^step)(VPSettingFunctionCompleteState) = ^(VPSettingFunctionCompleteState state) {
            if (stepped) return;
            stepped = YES;
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
        };
        [weakSelf readBaseSwitch:t done:^(VPSettingFunctionCompleteState state) {
            step(state);
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ step(VPFunctionCompleteFailure); });
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
     uricAcidUnit:'umol'|'mgdl', bloodFatUnit:'mmol'|'mgdl',
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
            // 写完回读一次，页面靠 customSettingRead 回显（与 Android echo 同口径）。
            // ⚠ 回读失败不能当成写入失败：命令已经下发到设备了，回 -1 会让页面把开关回滚，
            // 界面和设备反而对不上。所以回读失败时改回 200 + echoFailed。
            [weakSelf readCustomSetting:@{} callback:^(id res, BOOL keepAlive) {
                NSDictionary *rr = [res isKindOfClass:[NSDictionary class]] ? res : @{};
                if ([rr[@"code"] integerValue] == 200) {
                    callback(res, NO);
                } else {
                    NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
                    r[@"ok"] = @YES;
                    r[@"echoFailed"] = @YES;
                    callback(r, NO);
                }
            }];
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
        // 单条命令的设备回包兜底：某条不回包时不能把整条链卡死，
        // 否则 JS 侧 Promise 永远 pending、页面开关一直转圈。
        __block BOOL stepped = NO;
        void (^step)(void) = ^{
            if (stepped) return;
            stepped = YES;
            next();
        };
        [pm veepooSDKSettingBaseFunctionType:type settingState:state completeBlock:^(VPSettingFunctionCompleteState s) {
            step();
        }];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ step(); });
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
   { code, index, metricSystem?:boolean, metricSystemSupport, metricSystemRaw,
     temperatureUnit:'CELSIUS'|'FAHRENHEIT'|'', bloodGlucoseUnit, uricAcidUnit, bloodFatUnit,
     supportWeather:boolean, supportTemperatureUnit:boolean, temperatureType, weatherFunction }
 说明：与 readCustomSetting 读的是同一组基本开关，只是按单位字段单独输出。
 iOS 没有 Android 那种「B8 两帧」结构，一次串行读完就齐了，所以正常情况下 index=1。
 但读失败（VPFunctionCompleteFailure）**不等于设备不支持**：
   - Unknown（设备没有此功能）→ 字段给 'UNSUPPORT'，页面据此置灰，是可信结论；
   - Failure（命令失败/超时）→ 该字段缺失，此时把 index 降为 0，
     页面就不会把空值当「不支持」，保存时也不会用界面默认值覆盖设备。
 */
UNI_EXPORT_METHOD(@selector(readUnitSetting:callback:))
- (void)readUnitSetting:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    __weak typeof(self) weakSelf = self;

    NSMutableDictionary *v = [NSMutableDictionary dictionary];
    __block NSUInteger failed = 0;   // 读取失败（非「设备没有此功能」）的次数
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
    __block BOOL emitted = NO;         // 防重入：超时兜底与正常收尾只允许 emit 一次
    __block NSUInteger timeoutCount = 0;

    void (^emit)(void) = ^{
        if (emitted) return;
        emitted = YES;
        NSMutableDictionary *r = [resultWithCode(200) mutableCopy];
        NSString *metric = v[@"metric"];
        // metricSystem 只在读到确定值时给：读失败时缺省，页面保留原值而不是当成「非公制」
        if (metric != nil) {
            r[@"metricSystem"] = @([metric isEqualToString:@"SUPPORT_OPEN"]);
        }
        // 只有明确 UNSUPPORT 才算不支持；读失败不能当成不支持（否则整组被置灰）
        r[@"metricSystemSupport"] = @(![metric isEqualToString:@"UNSUPPORT"]);
        r[@"metricSystemRaw"] = metric ?: @"";
        r[@"temperatureUnit"] = [weakSelf unitNameOf:v[@"temperature"] first:@"CELSIUS" second:@"FAHRENHEIT"];
        r[@"bloodGlucoseUnit"] = [weakSelf unitNameOf:v[@"glucose"] first:@"mmol_L" second:@"mg_dl"];
        r[@"uricAcidUnit"] = [weakSelf unitNameOf:v[@"uricAcid"] first:@"umol_L" second:@"mg_dl"];
        r[@"bloodFatUnit"] = [weakSelf unitNameOf:v[@"bloodFat"] first:@"mmol_L" second:@"mg_dl"];
        // index=1 表示「单位字段可信」；任一读取失败/超时就降为 0（与 Android 的帧语义对齐）
        BOOL frameOk = (failed == 0 && timeoutCount == 0);
        r[@"index"] = @(frameOk ? 1 : 0);
        r[@"unitFrame"] = @(frameOk);
        if (timeoutCount > 0) r[@"timeout"] = @YES;
        // 能力位（iOS 用握手字段；weatherType==1 才有天气）。仅作诊断，页面不据此置灰。
        r[@"supportWeather"] = @(model.weatherType == 1);
        r[@"supportTemperatureUnit"] = @(model.temperatureType > 0);
        r[@"temperatureType"] = @(model.temperatureType);
        r[@"weatherFunction"] = (model.weatherType == 1) ? @"SUPPORT" : @"UNSUPPORT";
        [weakSelf sendEvent:@"unitSetting" data:r];
        callback(r, NO);
    };

    // 超时兜底：5 个开关串行读，任一命令无回包会让整条链卡死、页面 Promise 永远 pending。
    // 6 秒后无论如何先回一次已读到的部分（index 降为 0，页面就不会据此置灰/写回）。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (emitted) return;
        timeoutCount = MAX(timeoutCount, 1);
        emit();
    });

    next = ^{
        if (idx >= types.count) { emit(); return; }
        NSUInteger i = idx++;
        VPSettingBaseFunctionSwitchType t = (VPSettingBaseFunctionSwitchType)[types[i] integerValue];
        [weakSelf readBaseSwitch:t done:^(VPSettingFunctionCompleteState state) {
            NSString *name = [weakSelf functionStateName:state];
            if (name) v[keys[i]] = name;
            else failed++;          // Failure：读失败，字段缺失
            next();
        }];
    };
    next();
}

/** Open/Close -> 单位枚举名（Open 为第一档：摄氏 / mmol/L / μmol/L；其它给空串） */
- (NSString *)unitNameOf:(NSString *)state first:(NSString *)first second:(NSString *)second {
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
        // live = 这次回调真的带了模型。注意必须在用缓存兜底**之前**判断，
        // 否则「state=Success + 只有缓存」会被误当成实时读到 → 保存后的回读
        // 用缓存证明缓存（真机上就是「提示已保存、实际没写进设备」的来源）。
        BOOL live = (state == VPWeatherSettingStateSuccess) && cfg != nil;
        // 兜底：SDK 自己的缓存（VPWeatherHandle 会保留上次读写的 cofigModel）
        if (!cfg) cfg = [VPWeatherHandle share].cofigModel;

        NSMutableDictionary *d = [NSMutableDictionary dictionary];
        if (cfg) {
            d[@"isOpen"] = @(cfg.switchState == 1);
            d[@"weatherType"] = (cfg.weatherUnit == 1) ? @"F" : @"C";
            d[@"crc"] = @(cfg.crc);
            d[@"ok"] = @YES;
            d[@"oprate"] = @"READ_SUCCESS";
            if (!live) d[@"cached"] = @YES;   // 来自缓存而非本次实时读
            d[@"raw"] = [NSString stringWithFormat:@"WeatherStatusData{isOpen=%@, weatherType=%@}",
                         cfg.switchState == 1 ? @"true" : @"false", d[@"weatherType"]];
            // 只有实时读到的才更新快照；缓存帧不能再写回快照（否则缓存自我延续）
            if (live) {
                weakSelf.lastWeatherStatus = @{
                    @"isOpen": @(cfg.switchState == 1),
                    @"weatherType": d[@"weatherType"],
                    @"crc": @(cfg.crc)
                };
            }
        } else if (weakSelf.lastWeatherStatus) {
            d[@"isOpen"] = weakSelf.lastWeatherStatus[@"isOpen"];
            d[@"weatherType"] = weakSelf.lastWeatherStatus[@"weatherType"];
            if (weakSelf.lastWeatherStatus[@"crc"]) d[@"crc"] = weakSelf.lastWeatherStatus[@"crc"];
            d[@"ok"] = @YES;
            d[@"oprate"] = @"READ_SUCCESS";
            d[@"cached"] = @YES;
        } else {
            // 真的没有状态：不给 isOpen，避免页面把开关误翻成「关」
            d[@"ok"] = @NO;
            d[@"oprate"] = (state == VPWeatherSettingStateNone) ? @"UNKONW" : @"READ_FAIL";
            d[@"noData"] = @YES;
            d[@"message"] = @"设备不支持天气或读取失败";
        }
        [weakSelf sendEvent:@"weather" data:d];
        NSMutableDictionary *r = [resultWithCode([d[@"ok"] boolValue] ? 200 : -1) mutableCopy];
        [r addEntriesFromDictionary:d];
        callback(r, NO);
    }];
}

/**
 设置天气开关与单位。options: { isOpen, unit:'C'|'F' }
 iOS SDK：VPWeatherHandle settingWeatherInfo:（VPWeatherConfigModel）
 JS：joemeWatch.setWeatherStatus({...}) -> on('weather') { isOpen, weatherType, ok, oprate }
 说明：oprate 固定 SETTING_STATUS_SUCCESS / SETTING_STATUS_FAIL（与 Android 同名），
      页面据此判断写入是否真的成功，而不是只看命令已下发。
 */
UNI_EXPORT_METHOD(@selector(setWeatherStatus:callback:))
- (void)setWeatherStatus:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    // isOpen 不传 = 保持设备当前开关不动（用上次读到的状态，拿不到就当开启）。
    // 页面在「没读到天气状态」时只传 unit，靠这条分支保住设备原开关，
    // 而不是因为读不到状态就整段跳过单位写入。
    BOOL open;
    if (options[@"isOpen"] != nil) {
        open = [options[@"isOpen"] boolValue];
    } else if (self.lastWeatherStatus[@"isOpen"] != nil) {
        open = [self.lastWeatherStatus[@"isOpen"] boolValue];
    } else {
        open = YES;
    }
    NSString *u = options[@"unit"];
    BOOL celsius = !([u isKindOfClass:[NSString class]]
                     && ([u caseInsensitiveCompare:@"F"] == NSOrderedSame
                         || [u caseInsensitiveCompare:@"FAHRENHEIT"] == NSOrderedSame));
    VPWeatherConfigModel *cfg = [[VPWeatherConfigModel alloc] init];
    cfg.switchState = open ? 1 : 0;
    cfg.weatherUnit = celsius ? 0 : 1;
    // crc：官方 Demo WeatherActivity 下发前是 `setting.crc = crc`（crc 来自上一次读回）。
    // 不带 crc 时部分固件会把这条设置当成「版本不匹配」而静默丢弃 ——
    // 表现就是 App 说已保存、手表上单位没变。
    id crcVal = options[@"crc"] ?: self.lastWeatherStatus[@"crc"];
    if (crcVal != nil) cfg.crc = (uint16_t)[crcVal unsignedIntValue];
    __weak typeof(self) weakSelf = self;
    [[VPWeatherHandle share] settingWeatherInfo:cfg result:^(VPWeatherSettingState state) {
        BOOL ok = (state == VPWeatherSettingStateSuccess);
        NSDictionary *d = @{
            @"ok": @(ok),
            @"oprate": ok ? @"SETTING_STATUS_SUCCESS" : @"SETTING_STATUS_FAIL",
            @"isOpen": @(open),
            @"weatherType": celsius ? @"C" : @"F"
        };
        // 写回执只代表「设备收到了这条设置命令」，不代表值已经落盘。
        // 这里**不**更新 lastWeatherStatus：否则保存后的回读验证会读到刚写进来的
        // 缓存值，自己证明自己成功（真机上就是这样谎报成功的）。
        // 快照只由真实读成功（readWeatherInfo 拿到 configModel）更新。
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
        // oprate 与 Android 的 SETTING_CONTENT_SUCCESS/FAIL 对齐，页面据此判同步结果
        NSDictionary *d = @{
            @"ok": @(ok),
            @"oprate": ok ? @"SETTING_CONTENT_SUCCESS" : @"SETTING_CONTENT_FAIL",
            @"setWeatherData": @(ok),
            @"cityName": m.city ?: @""
        };
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
// 对应 Android 的 dialList / setDial / dialCapability / dialOnline / downloadDial /
// openCameraScreen / closeCameraScreen / setReportGps / modifyPwd / bleRename /
// pushTextImage / magneticTherapy / read4gServerInfo / readProductionInfo。
//
// 表盘有两条完全独立的链路，平台由 peripheralModel.CPUType 判定（1=杰理 K 系）：
//   JL：设备 fatfs 里的表盘文件，读列表 = 开文件系统 + 遍历文件名，
//       切盘 = VPDialTransformManager.switchToCustomWatchWithName（内部 cmdWatchFlashPath Flag:1）
//   非 JL：设备内置默认表盘（按序号切）+ HTTP 市场（下载 bin 后 startTransferWithFilePath）
// 两套的 path 语义不同：JL 是**设备上的文件名**，非 JL 是**手机本地文件路径**。

/**
 判断是否杰理（JL）平台。
 iOS 没有 Android 的 isJLDevice()，但 SDK 内部（VPDialTransformManager.isJLAC7013）
 用的就是 CPUType == 1 这一条判据，这里保持一致。
 */
- (BOOL)isJLDevice {
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    return m != nil && (NSInteger)m.CPUType == 1;
}

/** 表盘链路名：jl / zk / nordic。zk（中科）与 nordic 走同一条非 JL 链路，
    但事件里如实上报，免得页面日志/统计把中科设备记成 nordic。 */
- (NSString *)dialPlatformName {
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSInteger cpu = m ? (NSInteger)m.CPUType : 0;
    if (cpu == 1) return @"jl";
    if (cpu == 3 || cpu == 4) return @"zk";
    return @"nordic";
}

/** 统一的表盘失败事件：设备侧 notify 走这里，页面靠 fail:YES 结束 loading */
- (void)emitDialFail:(NSString *)code {
    [self sendEvent:@"dial" data:@{ @"ok": @NO, @"fail": @YES, @"message": code ?: @"unknown" }];
}

/**
 读取表盘列表。
 JL：打开文件系统 → 取 WATCH* 文件名 → 逐个读 describe 元数据分类 → 三组下发
     事件 on('dial')：{ platform:'jl', init } → { platform:'jl', ok, sys, server, pic?, list,
                      currentServerName, currentPicName }
 非 JL：能力头 → 设备内置默认表盘 → 当前屏幕样式
     事件 on('dial')：{ platform:'nordic', ok, serverUi, customUi, serverCount, customCount }
                    → { kind:'default', defaultCount, list:[{index,name,kind}] }
                    → { screenType, screenIndex, style, dialType, ok }
 与 Android 一致：方法本身立即回 200，结果全部走事件（页面已按事件驱动）。
 */
UNI_EXPORT_METHOD(@selector(dialList:callback:))
- (void)dialList:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    callback(resultWithCode(200), NO);
    self.dialSeq++;
    if ([self isJLDevice]) {
        [self dialListJL:self.dialSeq];
    } else {
        [self dialListNordic:self.dialSeq];
    }
}

// ---------- 表盘列表：JL ----------

- (void)dialListJL:(NSInteger)seq {
    __weak typeof(self) weakSelf = self;
    // 开文件系统要先做 rcsp 认证 + 遍历 fatfs，几秒起步；先给页面一个可读状态
    [self sendEvent:@"dial" data:@{ @"platform": @"jl", @"init": @YES }];

    // 开文件系统没有超时回调（SDK 只给 BOOL success），认证卡住时整页会一直转。
    // 45s 上限 + seq/settled 判重：真拿到结果后这条不会再把页面拉回失败态。
    __block BOOL settled = NO;
    void (^failOnce)(NSString *) = ^(NSString *code) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        if (settled) return;
        settled = YES;
        [self emitDialFail:code];
    };
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        failOnce(@"timeout");
    });

    // 这两个接口 VPMarketDialManager 有公开声明（内部只是转发给 VPDialTransformManager），
    // 走公开层可以少依赖一个未公开类；getWatchNames 未过滤，WATCH 前缀由下面自己筛。
    VPMarketDialManager *mgr = [VPMarketDialManager share];
    [mgr openJLDialFileSystemWithAction:^(BOOL success) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        if (!success) {
            failOnce(@"jlFileSystemFail");
            return;
        }
        [mgr getJLWatchNamesWithAction:^(NSArray<NSString *> *names) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || seq != self.dialSeq) return;
            settled = YES;   // 拿到清单就不再让看门狗报错（后续逐文件分类有自己的超时）
            NSArray<NSString *> *watchNames = [self watchNamesFromFileNames:names];
            if (watchNames.count == 0) {
                // 文件系统里一个 WATCH* 都没有：要么设备固件把表盘烧在代码区，
                // 要么还没装过市场/照片表盘。给空态而不是错误，页面显示「暂无表盘」。
                [self emitJLListWithSys:@[] server:@[] pic:nil seq:seq];
                return;
            }
            [self classifyJLDialNames:watchNames
                                index:0
                               result:[NSMutableDictionary dictionary]
                                  seq:seq];
        }];
    }];
}

/** 从文件系统清单里挑表盘文件：杰理的约定是 WATCH 前缀（大小写不敏感） */
- (NSArray<NSString *> *)watchNamesFromFileNames:(NSArray *)names {
    NSMutableArray *out = [NSMutableArray array];
    for (id n in names) {
        if (![n isKindOfClass:[NSString class]]) continue;
        NSString *name = [(NSString *)n lastPathComponent];
        if (name.length == 0) continue;
        if ([[name uppercaseString] hasPrefix:@"WATCH"]) [out addObject:name];
    }
    return out;
}

/**
 逐个文件读 describe 元数据，判断它是照片表盘 / 市场表盘 / 内置表盘。

 SDK 的 VPJLFileSystemManager.getWatchFaceWithAssist:watchName:action: 每次命令会回调
 **两次**（cmdWatchFlashPath 的「开始」包 + 「结束」包），这一点是从二进制反汇编确认的：
   开始包（flag != 0）→ action(nil, nil)
   结束包（flag == 0）→ 把 describe 按 "," 切开，比对第 2 段的 UUID：
        "1111-..." → action(文件名, nil)   照片表盘
        "2222-..." → action(nil, 文件名)   市场表盘
        都不是      → action(nil, nil)     内置（系统）表盘
 所以「(nil,nil)」既可能是开始包也可能是系统表盘，**不能**一收到就往下走：
 这里对非 nil 结果立即前进，对 (nil,nil) 先静默 0.7s（等结束包），
 期间要是来了非 nil 结果就作废重来；每个文件另有 4s 硬上限。
 */
- (void)classifyJLDialNames:(NSArray<NSString *> *)names
                      index:(NSInteger)index
                     result:(NSMutableDictionary *)result
                        seq:(NSInteger)seq {
    __weak typeof(self) weakSelf = self;
    if (index >= (NSInteger)names.count) {
        [self finishJLClassification:names result:result seq:seq];
        return;
    }
    NSString *name = names[index];
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPJLFileSystemManager *fs = [VPJLFileSystemManager shareInstance];

    __block BOOL advanced = NO;
    __block NSUInteger tick = 0;   // 静默期代次：新包到达就作废上一个静默期
    void (^advance)(void) = ^{
        if (advanced) return;
        advanced = YES;
        [weakSelf classifyJLDialNames:names index:index + 1 result:result seq:seq];
    };
    void (^advanceAfterQuiet)(void) = ^{
        NSUInteger mine = ++tick;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.7 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (advanced || mine != tick) return;
            advance();
        });
    };

    [fs getWatchFaceWithAssist:pm.mAssist
                     watchName:name
                        action:^(NSString *photoWatchName, NSString *marketWatchName) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        if (photoWatchName.length) result[@"photo"] = name;
        if (marketWatchName.length) result[name] = @"server";
        if (photoWatchName.length || marketWatchName.length) {
            advance();          // 类型已确定，不用再等
        } else {
            advanceAfterQuiet(); // 可能是开始包，等结束包
        }
    }];

    // 硬上限：设备不回包时不能让整页卡死，按内置表盘处理继续下一个
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(4.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        advance();
    });
}

/** 分类完成：拼三组列表并下发。sys=其余、server=市场标记、pic=照片标记 */
- (void)finishJLClassification:(NSArray<NSString *> *)names
                        result:(NSMutableDictionary *)result
                           seq:(NSInteger)seq {
    if (seq != self.dialSeq) return;

    NSMutableArray *sys = [NSMutableArray array];
    NSMutableArray *server = [NSMutableArray array];
    NSDictionary *pic = nil;
    NSString *photoFile = result[@"photo"];

    NSInteger sysIndex = 0;
    for (NSString *name in names) {
        if ([name isEqualToString:photoFile]) {
            pic = @{ @"name": name, @"path": [@"/" stringByAppendingString:name] };
        } else if ([result[name] isEqualToString:@"server"]) {
            [server addObject:@{ @"name": name, @"path": [@"/" stringByAppendingString:name] }];
        } else {
            [sys addObject:@{ @"name": name,
                              @"path": [@"/" stringByAppendingString:name],
                              @"index": @(sysIndex) }];
            sysIndex++;
        }
    }
    [self emitJLListWithSys:sys server:server pic:pic seq:seq];
}

/** 三组列表落缓存 + 下发事件。marketName/photoName 从入参推，不再单独传一遍 */
- (void)emitJLListWithSys:(NSArray *)sys
                   server:(NSArray *)server
                      pic:(NSDictionary *)pic
                      seq:(NSInteger)seq {
    if (seq != self.dialSeq) return;

    NSString *marketName = server.count ? server.firstObject[@"name"] : @"";
    NSString *photoName = pic[@"name"] ?: @"";

    // 缓存一份，setDial 只拿到路径时靠它反查分组（照片表盘没有 path 可传）
    NSMutableArray *cache = [NSMutableArray array];
    for (NSDictionary *o in sys) [cache addObject:@{ @"name": o[@"name"], @"group": @"sys", @"index": o[@"index"] }];
    for (NSDictionary *o in server) [cache addObject:@{ @"name": o[@"name"], @"group": @"server" }];
    if (photoName.length) [cache addObject:@{ @"name": photoName, @"group": @"pic" }];
    self.jlDialCache = cache;
    self.jlCurrentPicName = photoName;

    NSMutableDictionary *d = [NSMutableDictionary dictionary];
    d[@"platform"] = @"jl";
    d[@"ok"] = @YES;
    d[@"sys"] = sys;
    d[@"server"] = server;
    d[@"list"] = server;                          // 老调用方的别名，与 Android 一致
    d[@"currentServerName"] = marketName;         // SDK 的权威值只覆盖市场表盘这一组
    d[@"currentPicName"] = photoName;
    if (pic) d[@"pic"] = pic;

    [self sendEvent:@"dial" data:d];
}

// ---------- 表盘列表：非 JL ----------

- (void)dialListNordic:(NSInteger)seq {
    VPPeripheralModel *m = [VPBleCentralManage sharedBleManager].peripheralModel;
    NSInteger dialCount = (NSInteger)m.dialCount;
    NSString *pf = [self dialPlatformName];

    [self sendEvent:@"dial" data:@{
        @"platform": pf,
        @"ok": @YES,
        @"serverUi": @(m.marketDialCount > 0),
        @"customUi": @(m.photoDialCount > 0),
        @"serverCount": @(m.marketDialCount),
        @"customCount": @(m.photoDialCount),
        @"defaultCount": @(dialCount)
    }];

    // 设备内置表盘：数量来自握手回包（Android 读 COUNT_SCREEN_STYLE_TYPE，iOS 是 dialCount），
    // 名称设备不上报，按「默认表盘N」生成。这条路径不依赖服务器，必定有数据。
    NSMutableArray *arr = [NSMutableArray array];
    for (NSInteger i = 0; i < dialCount; i++) {
        [arr addObject:@{ @"index": @(i), @"name": [NSString stringWithFormat:@"默认表盘%ld", (long)(i + 1)], @"kind": @"default" }];
    }
    [self sendEvent:@"dial" data:@{
        @"platform": pf,
        @"kind": @"default",
        @"ok": @YES,
        @"defaultCount": @(dialCount),
        @"list": arr
    }];

    [self readScreenStyleEvent:seq];
}

/**
 读当前屏幕样式（表盘位）。settingMode 2 = 读，dialType 传 default 时回包带实际类型。
 与 Android 的 readScreenStyle 事件字段对齐：screenType / screenIndex / style / dialType。
 screenIndex 只在「当前是内置默认表盘」时才有意义（默认表盘 0 基），其余置 -1，
 避免页面把市场表盘的 1 基序号套到默认表盘上标错「使用中」。
 */
- (void)readScreenStyleEvent:(NSInteger)seq {
    __weak typeof(self) weakSelf = self;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    NSString *pf = [self dialPlatformName];
    __block BOOL done = NO;
    void (^emit)(BOOL, VPDeviceDialType, int) = ^(BOOL ok, VPDeviceDialType dt, int style) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        if (done) return;
        done = YES;
        NSString *type = @"DEFAULT";
        if (dt == VPDeviceDialTypeMarket) type = @"MARKET";
        else if (dt == VPDeviceDialTypePhoto) type = @"PHOTO";
        [self sendEvent:@"dial" data:@{
            @"platform": pf,
            @"ok": @(ok),
            @"screenType": type,
            @"screenIndex": @(dt == VPDeviceDialTypeDefault ? style : -1),
            @"style": @(style),
            @"dialType": @((NSInteger)dt)
        }];
    };

    [pm veepooSDKSettingDeviceScreenStyle:0
                              settingMode:2
                                 dialType:VPDeviceDialTypeDefault
                                   result:^(VPDeviceDialType dt, int screenStyle, BOOL settingSuccess) {
        emit(settingSuccess, dt, screenStyle);
    }];

    // 个别固件对「读样式」不回包：10s 后按失败收尾，页面已有内置表盘时不会弹错
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(10.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSeq) return;
        if (done) return;
        done = YES;
        [self sendEvent:@"dial" data:@{ @"fail": @YES, @"message": @"timeout" }];
    });
}

// ---------- 切换表盘 ----------

/**
 应用表盘。options 与 Android 完全一致：
   { kind:'default', index }        → 切内置默认表盘（JL 走 sys 组，非 JL 走 settingScreenStyle）
   { kind:'pic' }                   → 切照片表盘（仅 JL；设备上还没有该文件时回 noPicDial）
   { path, source:'device' }        → 切设备上已有的表盘（JL 取 lastPathComponent 作为文件名）
   { path }                         → 推送本机表盘文件（仅非 JL：startTransferWithFilePath + 切市场表盘）
 进度/结果全部走 on('dial')：{ start } / { progress } / { complete, name } / { fail, message }
 */
UNI_EXPORT_METHOD(@selector(setDial:callback:))
- (void)setDial:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    callback(resultWithCode(200), NO);
    self.dialSwitchSeq++;

    NSString *kind = [options[@"kind"] isKindOfClass:[NSString class]] ? options[@"kind"] : @"";
    NSString *path = [options[@"path"] isKindOfClass:[NSString class]] ? options[@"path"] : @"";
    NSString *dialId = [options[@"dialId"] isKindOfClass:[NSString class]] ? options[@"dialId"] : @"";
    NSString *filePath = path.length ? path : dialId;

    if ([kind isEqualToString:@"default"] ||
        (options[@"index"] != nil && filePath.length == 0)) {
        NSInteger index = [options[@"index"] integerValue];
        if ([self isJLDevice]) {
            [self switchJLSystemDialAtIndex:index];
        } else {
            [self setDialDefault:index];
        }
        return;
    }
    if ([kind isEqualToString:@"pic"]) {
        if (![self isJLDevice]) { [self emitDialFail:@"notSupported"]; return; }
        if (self.jlCurrentPicName.length == 0) { [self emitDialFail:@"noPicDial"]; return; }
        [self switchJLDialByName:self.jlCurrentPicName];
        return;
    }
    if (filePath.length == 0) { [self emitDialFail:@"emptyDialPath"]; return; }

    if ([self isJLDevice]) {
        BOOL deviceDial = [options[@"source"] isEqualToString:@"device"];
        if (!deviceDial) {
            // 本机文件上传到 JL 设备 = enterDataTransformStateWithFileUrl → 写 fatfs → 切盘，
            // SDK 这条链路没有公开头文件也没有成功回调。页面当前不会走这里（在线市场只对非 JL 开放），
            // 与其猜一条可能写坏表盘的路径，不如明确回不支持。
            [self emitDialFail:@"uploadNotSupported"];
            return;
        }
        [self switchJLDialByName:[filePath lastPathComponent]];
        return;
    }
    [self setDialFile:filePath];
}

/** JL：按 sys 组缓存序号切内置表盘 */
- (void)switchJLSystemDialAtIndex:(NSInteger)index {
    NSString *name = nil;
    for (NSDictionary *o in self.jlDialCache) {
        if ([o[@"group"] isEqualToString:@"sys"] && [o[@"index"] integerValue] == index) {
            name = o[@"name"];
            break;
        }
    }
    if (name.length == 0) {
        // 缓存没建立（用户没进过表盘页）时只能回失败：sys 文件清单必须现读，代价太高
        [self emitDialFail:@"badIndex"];
        return;
    }
    [self switchJLDialByName:name];
}

/**
 JL：按文件名切盘。
 SDK 的 switchToCustomWatchWithName:success:failure: 内部就是
   cmdWatchFlashPath:("/"+name) Flag:JL_DialSettingSetDial(1)，
 与 Android 的 WatchManager.setCurrentWatchInfo 等价；flag==0 为成功。
 注意必须传**纯文件名**（WATCH026），SDK 会自己补前导 "/"。
 */
- (void)switchJLDialByName:(NSString *)name {
    if (name.length == 0) { [self emitDialFail:@"emptyDialPath"]; return; }
    NSInteger seq = self.dialSwitchSeq;
    __weak typeof(self) weakSelf = self;

    [self sendEvent:@"dial" data:@{ @"start": @YES }];

    __block BOOL done = NO;
    void (^finish)(NSDictionary *) = ^(NSDictionary *d) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSwitchSeq) return;
        if (done) return;
        done = YES;
        [self sendEvent:@"dial" data:d];
    };

    [[VPDialTransformManager share] switchToCustomWatchWithName:name
                                                        success:^{
        finish(@{ @"ok": @YES, @"complete": @YES, @"name": name });
    } failure:^{
        finish(@{ @"ok": @NO, @"fail": @YES, @"name": name, @"message": @"switchDialFailed" });
    }];

    // rcsp 只给成功/失败回调，设备不回包时两个都不触发：15s 看门狗兜底
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(@{ @"ok": @NO, @"fail": @YES, @"name": name, @"message": @"timeout" });
    });
}

/** 非 JL：按序号切内置默认表盘（0 基，与 default 列表的 index 对应） */
- (void)setDialDefault:(NSInteger)index {
    if (index < 0) { [self emitDialFail:@"badIndex"]; return; }
    NSInteger seq = self.dialSwitchSeq;
    __weak typeof(self) weakSelf = self;
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;

    [self sendEvent:@"dial" data:@{ @"start": @YES }];
    [pm veepooSDKSettingDeviceScreenStyle:(int)index
                              settingMode:1
                                 dialType:VPDeviceDialTypeDefault
                                   result:^(VPDeviceDialType dt, int screenStyle, BOOL settingSuccess) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSwitchSeq) return;
        if (settingSuccess) {
            [self sendEvent:@"dial" data:@{
                @"ok": @YES,
                @"complete": @YES,
                @"kind": @"default",
                @"screenType": @"DEFAULT",
                @"screenIndex": @(screenStyle),
                @"style": @(screenStyle)
            }];
        } else {
            [self emitDialFail:@"uiUpdateFailed"];
        }
    }];
}

/**
 非 JL：把本机表盘文件推送到设备并切过去（setDial 的 { path } 分支）。
 实际动作见 pushDialFileAndActivate:name:，这里只做文件存在性检查。
 */
- (void)setDialFile:(NSString *)filePath {
    if (![[NSFileManager defaultManager] fileExistsAtPath:filePath]) {
        [self emitDialFail:@"fileNotExist"];
        return;
    }
    [self pushDialFileAndActivate:[NSURL fileURLWithPath:filePath] name:@""];
}

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
 JL 设备没有 HTTP 市场（表盘都在设备 fatfs 里）→ 与 Android 一样回 jlUseDialList，
 页面据此把「在线市场」页签的失败文案换成「请用已装表盘列表」。
 */
UNI_EXPORT_METHOD(@selector(dialOnline:callback:))
- (void)dialOnline:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    callback(resultWithCode(200), NO);

    if ([self isJLDevice]) {
        [self sendEvent:@"dial" data:@{ @"kind": @"online", @"fail": @YES, @"message": @"jlUseDialList" }];
        return;
    }
    VPPeripheralModel *model = [VPBleCentralManage sharedBleManager].peripheralModel;
    if (model.marketDialCount == 0) {
        [self sendEvent:@"dial" data:@{ @"kind": @"online", @"fail": @YES, @"message": @"serverUiNotSupported" }];
        return;
    }

    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    VPMarketDialManager *mgr = [VPMarketDialManager share];
    __weak typeof(self) weakSelf = self;

    [self sendEvent:@"dial" data:@{ @"kind": @"online", @"loading": @YES }];
    [pm veepooSDK_dialChannelWithChannelModel:VPDialChannelModelRead
                                    dialType:VPDeviceDialTypeMarket
                              photoDialModel:nil
                                      result:^(VPPhotoDialModel *photoDialModel,
                                               VPDeviceMarketDialModel *deviceMarketDialModel,
                                               NSError *error) {
        if (error || !deviceMarketDialModel) {
            [weakSelf sendEvent:@"dial" data:@{
                @"kind": @"online", @"fail": @YES,
                @"message": error.localizedDescription ?: @"readDeviceDialFail"
            }];
            return;
        }
        // 缓存下来：downloadDial 要用同一份模型做 crc 校验与容量判断
        weakSelf.dialDeviceInfo = deviceMarketDialModel;
        [mgr getVeepooServerAllMarketDialsWithDeviceInfo:deviceMarketDialModel
                                                 success:^(NSArray<VPServerMarketDialModel *> *response) {
            NSMutableArray *list = [NSMutableArray array];
            for (VPServerMarketDialModel *s in response) {
                [list addObject:@{
                    @"crc": @(s.crc),
                    // 服务器模型里没有展示名，只有 crc；用 crc 当名字，页面至少能区分卡片
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
        } failure:^(NSError *err, NSInteger code) {
            [weakSelf sendEvent:@"dial" data:@{
                @"kind": @"online", @"fail": @YES,
                @"message": err.localizedDescription ?: [NSString stringWithFormat:@"服务器返回错误(%ld)", (long)code]
            }];
        }];
    } transformProgress:nil];
}

/**
 下载线上表盘并推送到设备。
 options: { url, name?, crc, dialShape?, binProtocol?, imageId?, address?, length? }
 JS：joemeWatch.downloadDial({...}) -> on('dial') { downloading } → { downloaded }
                                                         → { progress }（推送）→ { complete }
 实现：VPMarketDialManager.downloadMarketDialBinFileWithModel: → startTransferWithFilePath:

 关键点：downloadMarketDialBinFileWithModel 的第二个参数（设备侧市场表盘信息）不是可选的 ——
 SDK 会拿 imageId 跟本地已下载 bin 的 crc 比对，并在文件存在时直接复用/删除缓存。
 页面上没有 addr/length 这些字段，所以这里用 dialOnline 时读到的那份缓存；
 缓存缺失时先补一次 Read（与 dialOnline 同一条命令），再下载。
 ⚠ crc 必须由页面传（服务器列表里的 crc），缺省 0 时 SDK 的「同 crc 直接复用」判断会失效。
 */
UNI_EXPORT_METHOD(@selector(downloadDial:callback:))
- (void)downloadDial:(NSDictionary *)options callback:(UniModuleKeepAliveCallback)callback {
    if (![self checkReady:callback]) return;
    callback(resultWithCode(200), NO);

    NSString *url = [options[@"url"] isKindOfClass:[NSString class]] ? options[@"url"] : @"";
    if (url.length == 0) { [self emitDialFail:@"emptyUrl"]; return; }
    if ([self isJLDevice]) { [self emitDialFail:@"jlUseDialList"]; return; }

    VPServerMarketDialModel *server = [[VPServerMarketDialModel alloc] init];
    server.fileUrl = url;
    server.crc = options[@"crc"] ? [options[@"crc"] intValue] : 0;
    server.dialShape = options[@"dialShape"] ? [options[@"dialShape"] intValue] : 0;
    server.binProtocol = options[@"binProtocol"] ? [options[@"binProtocol"] intValue] : 0;

    __weak typeof(self) weakSelf = self;
    NSString *displayName = [options[@"name"] isKindOfClass:[NSString class]] ? options[@"name"] : @"";

    void (^startDownload)(VPDeviceMarketDialModel *) = ^(VPDeviceMarketDialModel *device) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        self.dialSwitchSeq++;
        NSInteger seq = self.dialSwitchSeq;
        VPMarketDialManager *mgr = [VPMarketDialManager share];

        // 页面已经 showLoading，这里只发事件；下载阶段没有进度回调（NSURLSession 整包下载）
        [self sendEvent:@"dial" data:@{ @"downloading": @YES }];
        [mgr downloadMarketDialBinFileWithModel:server deviceMarketDialModel:device success:^(NSURL *filePath) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || seq != self.dialSwitchSeq) return;
            [self sendEvent:@"dial" data:@{ @"downloaded": @YES, @"path": filePath.path ?: @"" }];
            [self pushDialFileAndActivate:filePath name:displayName];
        } failure:^(NSError *error, NSInteger code) {
            __strong typeof(weakSelf) self = weakSelf;
            if (!self || seq != self.dialSwitchSeq) return;
            // message 用固定标识（页面据此查中文文案），原始错误串放 detail 里
            NSMutableDictionary *d = [@{ @"ok": @NO, @"fail": @YES,
                                         @"message": @"downloadFail" } mutableCopy];
            if (error.localizedDescription.length) d[@"detail"] = error.localizedDescription;
            else d[@"detail"] = [NSString stringWithFormat:@"code=%ld", (long)code];
            [self sendEvent:@"dial" data:d];
        }];
    };

    if (self.dialDeviceInfo) {
        startDownload(self.dialDeviceInfo);
        return;
    }
    // 没进过表盘页/没拉过在线市场：先读一次设备侧信息
    VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
    [pm veepooSDK_dialChannelWithChannelModel:VPDialChannelModelRead
                                    dialType:VPDeviceDialTypeMarket
                              photoDialModel:nil
                                      result:^(VPPhotoDialModel *p, VPDeviceMarketDialModel *device, NSError *error) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self) return;
        if (error || !device) {
            [self emitDialFail:@"readDeviceDialFail"];
            return;
        }
        self.dialDeviceInfo = device;
        startDownload(device);
    } transformProgress:nil];
}

/**
 把 bin 文件推给设备并切过去（downloadDial 的第二步，setDialFile 也走这里）。
 官方链路 = VPMarketDialManager.startTransferWithFilePath:（内部 → VPDialTransformManager
 enterDataTransformStateWithFileUrl，先发 20 字节通道头再分片），完成后
 veepooSDKSettingDeviceScreenStyle(1, MARKET) 让设备真正显示这个新表盘。
 ⚠ startTransfer 只有 failure 和进度，没有成功回调：进度到 1 视为传输完成。
 不能提前发 complete —— 否则页面刚显示「已应用」就收到失败/超时。
 */
- (void)pushDialFileAndActivate:(NSURL *)filePath name:(NSString *)name {
    if (!filePath) { [self emitDialFail:@"fileNotExist"]; return; }
    NSInteger seq = self.dialSwitchSeq;
    __weak typeof(self) weakSelf = self;
    __block BOOL done = NO;

    void (^finish)(NSDictionary *) = ^(NSDictionary *d) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSwitchSeq) return;
        if (done) return;
        done = YES;
        [self sendEvent:@"dial" data:d];
    };

    [[VPMarketDialManager share] startTransferWithFilePath:filePath
                                         transformProgress:^(double progress) {
        __strong typeof(weakSelf) self = weakSelf;
        if (!self || seq != self.dialSwitchSeq) return;
        [self sendEvent:@"dial" data:@{ @"progress": @(progress * 100.0) }];
        if (progress >= 0.999 && !done) {
            VPPeripheralBaseManage *pm = [VPBleCentralManage sharedBleManager].peripheralManage;
            [pm veepooSDKSettingDeviceScreenStyle:1
                                      settingMode:1
                                         dialType:VPDeviceDialTypeMarket
                                           result:^(VPDeviceDialType dt, int screenStyle, BOOL ok) {
                if (ok) {
                    finish(@{ @"ok": @YES, @"complete": @YES, @"name": name ?: @"",
                              @"kind": @"server", @"screenType": @"MARKET",
                              @"screenIndex": @(screenStyle), @"style": @(screenStyle) });
                } else {
                    finish(@{ @"ok": @NO, @"fail": @YES, @"message": @"uiUpdateFailed" });
                }
            }];
        }
    } failure:^(NSError *error) {
        NSMutableDictionary *d = [@{ @"ok": @NO, @"fail": @YES, @"message": @"uploadFailed" } mutableCopy];
        if (error.localizedDescription.length) d[@"detail"] = error.localizedDescription;
        finish(d);
    }];

    // 表盘 bin 1~2MB，BLE 下 30~60s；90s 上限避免页面永远停在「正在同步」
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(90.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        finish(@{ @"ok": @NO, @"fail": @YES, @"message": @"timeout" });
    });
}

// 注：openCameraScreen / closeCameraScreen 与 capturePhoto 一起放在第 7 节「相机遥控」，
// 避免两处重复定义同一个 selector（UNI_EXPORT_METHOD 重复注册会互相覆盖）。

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
    __block BOOL fired = NO;
    void (^finish)(BOOL, BOOL, VPBloodAnalysisResultModel *) = ^(BOOL success, BOOL open, VPBloodAnalysisResultModel *model) {
        if (fired) return;
        fired = YES;
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
    };
    [pm veepooSDKBloodAnalysisPersonalWithOpCode:2
                                            open:NO
                                           model:nil
                                          result:^(BOOL success, BOOL open, VPBloodAnalysisResultModel *model) {
        finish(success, open, model);
    }];

    // 设备不回包时 6 秒兜底，否则 JS Promise 永久 pending。
    // 不支持血液成分的机型根本不会回调，超时太长会把页面后续的读取一起拖慢。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(NO, NO, nil); });
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
    __block BOOL fired = NO;
    void (^finish)(BOOL, BOOL, VPBloodAnalysisResultModel *) = ^(BOOL success, BOOL open, VPBloodAnalysisResultModel *m) {
        if (fired) return;
        fired = YES;
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
    };
    [pm veepooSDKBloodAnalysisPersonalWithOpCode:1
                                            open:isOpen
                                           model:model
                                          result:^(BOOL success, BOOL open, VPBloodAnalysisResultModel *m) {
        finish(success, open, m);
    }];

    // 设备不回包时 6 秒兜底：blood/calibrate.vue 的开关和保存都 await 它，
    // 不兜底会永远停在「保存中」且无法回滚。
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(NO, isOpen, nil); });
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
    __block BOOL fired = NO;
    void (^finish)(BOOL, VPMultiBloodGlucoseModel *) = ^(BOOL success, VPMultiBloodGlucoseModel *m) {
        if (fired) return;
        fired = YES;
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
    };
    [pm veepooSDKBloodGlucoseMultiPersonalWithOpCode:2 model:nil result:^(BOOL success, VPMultiBloodGlucoseModel *m) {
        finish(success, m);
    }];

    // 设备不回包时 6 秒兜底，否则 JS Promise 永久 pending
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{ finish(NO, nil); });
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
