//
//  JoemeCameraViewController.m
//  joeme-watch
//

#import "JoemeCameraViewController.h"
#import "JoemeCameraStore.h"
#import "JoemeCameraCapture.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - 单张照片的拍摄代理

/** AVCapturePhotoOutput 的 delegate：把一次拍摄的结果收成 (jpegData, error) */
@interface JoemeCameraPhotoCapture : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, copy) void (^completion)(NSData *data, NSError *error);
@property (nonatomic, strong) NSData *jpegData;
@property (nonatomic, strong) NSError *captureError;
@end

@implementation JoemeCameraPhotoCapture

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
    if (error) {
        self.captureError = error;
        return;
    }
    self.jpegData = [photo fileDataRepresentation];
    if (!self.jpegData.length && !self.captureError) {
        self.captureError = [NSError errorWithDomain:@"joeme.camera"
                                                code:-1
                                            userInfo:@{ NSLocalizedDescriptionKey: @"未获取到图像数据" }];
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
                error:(NSError *)error {
    if (error && !self.captureError) self.captureError = error;
    void (^cb)(NSData *, NSError *) = self.completion;
    self.completion = nil;
    if (cb) cb(self.captureError ? nil : self.jpegData, self.captureError);
}

@end

#pragma mark - 相机页

/** 页面实例：手表事件需要从任意线程判断「相机页是否在、预览是否就绪」 */
static JoemeCameraViewController *sInstance = nil;
static void (^sCloseHandler)(NSInteger count) = nil;
static void (^sCaptureHandler)(NSString *path) = nil;
/** 本次关闭是手表发起的（手表已退出拍照模式）→ 不再回发「退出拍照」 */
static BOOL sClosedByWatch = NO;

/**
 上面几个静态状态会被两边同时碰：
 主线程（present / 关闭）和 SDK 回调线程（handleCameraType 里判断页面是否在）。
 全部用这把锁保护，避免读到写了一半的 handler block（ARC 下跨线程读写 __strong
 全局变量不是原子操作，崩起来是 EXC_BAD_ACCESS）。
 */
static NSLock *JoemeCameraStateLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

/** 预览没就绪时手表就按了快门：挂起，等会话起来后补拍（与 Android 的 8 秒窗口一致） */
static const NSTimeInterval JoemePendingShotWindow = 8;

@interface JoemeCameraViewController () {
    dispatch_queue_t _sessionQueue;
}

@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) AVCapturePhotoOutput *photoOutput;
@property (nonatomic, strong) AVCaptureDeviceInput *videoInput;
@property (nonatomic, strong) AVCaptureVideoPreviewLayer *previewLayer;

@property (nonatomic, strong) UIView *previewContainer;
@property (nonatomic, strong) UIButton *closeButton;
@property (nonatomic, strong) UIButton *flashButton;
@property (nonatomic, strong) UIButton *flipButton;
@property (nonatomic, strong) UIButton *shutterButton;
@property (nonatomic, strong) UIImageView *thumbView;
@property (nonatomic, strong) UILabel *toastLabel;
/** 点缩略图时的 App 内大图预览（iOS 没有公开的「打开系统相册」接口） */
@property (nonatomic, strong) UIView *previewOverlay;
@property (nonatomic, strong) UIImageView *previewImageView;

@property (nonatomic, assign) AVCaptureDevicePosition position;
@property (nonatomic, assign) BOOL flashOn;

/** 会话已 startRunning（手表事件线程要跨线程读，保持 atomic） */
@property (nonatomic, assign) BOOL sessionRunning;
/** photoOutput 已配好（跨线程读的原子标记，避免直接读 nonatomic 的 photoOutput 造成 retain/release 竞争） */
@property (nonatomic, assign) BOOL outputConfigured;
/** 一次拍摄尚未结束（手表连按快门时的互斥，跨线程读写，保持 atomic） */
@property (nonatomic, assign) BOOL capturing;
/** 拍照代号：兜底定时器只在「还是同一次拍照」时才放开互斥 */
@property (nonatomic, assign) NSInteger captureGen;
@property (nonatomic, assign) NSInteger captureCount;
@property (nonatomic, assign) BOOL closedNotified;

@property (nonatomic, assign) BOOL pendingShot;
@property (nonatomic, assign) NSTimeInterval pendingShotAt;

/** 拍摄代理必须持有到回调结束（AVCapturePhotoOutput 不保证强引用） */
@property (nonatomic, strong) NSMutableArray<JoemeCameraPhotoCapture *> *activeCaptures;
/** 最近一张照片的原始数据（缩略图点击预览用） */
@property (nonatomic, strong) NSData *lastJPEGData;

// 私有方法声明：这些方法在下方实现，类方法/通知回调里有前向调用，
// 显式声明可以避免 "instance method not found" 告警
+ (JoemeCameraViewController *)currentInstance;
- (void)buildUI;
- (UIButton *)circleButtonWithGlyph:(NSString *)glyph;
- (UIButton *)squareButtonWithGlyph:(NSString *)glyph;
- (UIButton *)makeShutterButton;
- (void)setupSession;
- (void)configureSessionForPosition:(AVCaptureDevicePosition)position;
- (AVCaptureDevice *)deviceForPosition:(AVCaptureDevicePosition)position;
- (void)updatePreviewOrientation;
- (void)startSessionIfNeeded;
- (void)stopSession;
- (void)appWillResignActive;
- (void)appDidBecomeActive;
- (void)takePicture;
- (void)finishCaptureWithData:(NSData *)data error:(NSError *)error;
- (void)handleCapturedJPEG:(NSData *)data;
- (void)consumePendingShotIfNeeded;
- (void)onCloseTapped;
- (void)onFlashTapped;
- (void)onFlipTapped;
- (void)onThumbTapped;
- (void)onShutterTapped;
- (void)hidePhotoPreview;
- (void)showToast:(NSString *)text;
- (void)closeSelf;
- (void)notifyClosedIfNeeded;

@end

@implementation JoemeCameraViewController

#pragma mark - 类方法

+ (BOOL)isOpen {
    [JoemeCameraStateLock() lock];
    BOOL open = (sInstance != nil);
    [JoemeCameraStateLock() unlock];
    return open;
}

+ (BOOL)isReady {
    [JoemeCameraStateLock() lock];
    JoemeCameraViewController *vc = sInstance;
    [JoemeCameraStateLock() unlock];
    return vc != nil && vc.sessionRunning && vc.outputConfigured;
}

+ (void)setCloseHandler:(void (^_Nullable)(NSInteger))handler {
    void (^copied)(NSInteger) = [handler copy];
    [JoemeCameraStateLock() lock];
    sCloseHandler = copied;
    [JoemeCameraStateLock() unlock];
}

+ (void)setCaptureHandler:(void (^_Nullable)(NSString *))handler {
    void (^copied)(NSString *) = [handler copy];
    [JoemeCameraStateLock() lock];
    sCaptureHandler = copied;
    [JoemeCameraStateLock() unlock];
}

+ (BOOL)consumeClosedByWatch {
    [JoemeCameraStateLock() lock];
    BOOL v = sClosedByWatch;
    sClosedByWatch = NO;
    [JoemeCameraStateLock() unlock];
    return v;
}

+ (JoemeCameraViewController *)currentInstance {
    [JoemeCameraStateLock() lock];
    JoemeCameraViewController *vc = sInstance;
    [JoemeCameraStateLock() unlock];
    return vc;
}

+ (void)takePictureNow {
    JoemeCameraViewController *vc = [self currentInstance];
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc takePicture];
    });
}

+ (void)retryOpen {
    JoemeCameraViewController *vc = [self currentInstance];
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        // input/output 没配成过（首次配置失败、切镜头失败）时，光 startRunning 没用，
        // 要按当前镜头重新配一遍会话。
        if (!vc.outputConfigured) {
            [vc configureSessionForPosition:vc.position];
        } else {
            [vc startSessionIfNeeded];
        }
    });
}

+ (void)finishIfOpen {
    JoemeCameraViewController *vc = [self currentInstance];
    if (!vc) return;
    dispatch_async(dispatch_get_main_queue(), ^{
        [vc closeSelf];
    });
}

+ (void)finishFromWatch {
    // 没有实例时不要置标记：没人消费，下次打开会被误判成「手表关闭」
    [JoemeCameraStateLock() lock];
    if (!sInstance) {
        [JoemeCameraStateLock() unlock];
        return;
    }
    sClosedByWatch = YES;
    [JoemeCameraStateLock() unlock];
    [self finishIfOpen];
}

/** 找到当前最上层控制器（uni-app 基座可能是 UINavigationController / UITabBarController） */
+ (UIViewController *)topViewController {
    UIWindow *window = nil;
    if (@available(iOS 13.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (![scene isKindOfClass:[UIWindowScene class]]) continue;
            UIWindowScene *ws = (UIWindowScene *)scene;
            if (ws.activationState != UISceneActivationStateForegroundActive) continue;
            for (UIWindow *w in ws.windows) {
                if (w.isKeyWindow) { window = w; break; }
            }
            if (window) break;
        }
    }
    if (!window) {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        window = [UIApplication sharedApplication].keyWindow;
#pragma clang diagnostic pop
    }
    UIViewController *vc = window.rootViewController;
    while (vc) {
        if (vc.presentedViewController) {
            vc = vc.presentedViewController;
        } else if ([vc isKindOfClass:[UINavigationController class]]) {
            vc = ((UINavigationController *)vc).visibleViewController;
        } else if ([vc isKindOfClass:[UITabBarController class]]) {
            vc = ((UITabBarController *)vc).selectedViewController;
        } else {
            break;
        }
    }
    return vc;
}

+ (BOOL)presentNew {
    // 已在显示：不重复叠一层（与 Android 的 REORDER_TO_FRONT 语义一致）
    if ([self currentInstance]) return YES;
    if (![NSThread isMainThread]) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [self presentNew];
        });
        return YES;
    }
    UIViewController *top = [self topViewController];
    if (!top) return NO;

    JoemeCameraViewController *vc = [[JoemeCameraViewController alloc] init];
    vc.modalPresentationStyle = UIModalPresentationFullScreen;
    vc.modalTransitionStyle = UIModalTransitionStyleCoverVertical;
    // 先登记再 present：连点两次时上一次的 viewDidLoad 可能还没跑，
    // 不等它设 sInstance，否则会叠出两个相机页。
    [JoemeCameraStateLock() lock];
    sInstance = vc;
    [JoemeCameraStateLock() unlock];
    [top presentViewController:vc animated:YES completion:^{
        // present 被系统静默拒掉时（极少数：上层还有未完成的转场）把登记撤回，
        // 否则后续手表快门会被误判成「页面在、只是没就绪」，永远不落静默拍照。
        if (!vc.presentingViewController) {
            [JoemeCameraStateLock() lock];
            if (sInstance == vc) sInstance = nil;
            [JoemeCameraStateLock() unlock];
        }
    }];
    return YES;
}

#pragma mark - 生命周期

- (instancetype)init {
    if (self = [super init]) {
        _sessionQueue = dispatch_queue_create("joeme.camera.session", DISPATCH_QUEUE_SERIAL);
        _position = AVCaptureDevicePositionBack;
        _activeCaptures = [NSMutableArray array];
    }
    return self;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    [JoemeCameraStateLock() lock];
    sInstance = self;
    sClosedByWatch = NO;
    [JoemeCameraStateLock() unlock];
    // 相机页期间保持屏幕常亮（与 Android 的 FLAG_KEEP_SCREEN_ON 一致）
    [UIApplication sharedApplication].idleTimerDisabled = YES;

    self.view.backgroundColor = [UIColor blackColor];
    [self buildUI];
    [self setupSession];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appWillResignActive)
                                                 name:UIApplicationWillResignActiveNotification
                                               object:nil];
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(appDidBecomeActive)
                                                 name:UIApplicationDidBecomeActiveNotification
                                               object:nil];
}

- (void)viewWillLayoutSubviews {
    [super viewWillLayoutSubviews];
    // 预览层是 CALayer，不参与 Auto Layout，尺寸要靠这里同步
    self.previewLayer.frame = self.previewContainer.bounds;
}

- (void)viewDidDisappear:(BOOL)animated {
    [super viewDidDisappear:animated];
    // 被系统手势/父页面 dismiss 时也要收尾（正常关闭走 closeSelf → dismiss → 这里）
    [self notifyClosedIfNeeded];
}

- (void)dealloc {
    [[NSNotificationCenter defaultCenter] removeObserver:self];
    // 不再在这里调 stopSession：它会把 self 捕获进异步 block，
    // 在 dealloc 期间强引用正在析构的对象是未定义行为。session 随对象一起释放即可。
}

- (void)closeSelf {
    void (^done)(void) = ^{ [self notifyClosedIfNeeded]; };
    if (self.presentingViewController) {
        [self dismissViewControllerAnimated:YES completion:done];
    } else if (self.navigationController) {
        [self.navigationController popViewControllerAnimated:YES];
        done();
    } else {
        done();
    }
}

- (void)notifyClosedIfNeeded {
    if (self.closedNotified) return;
    self.closedNotified = YES;

    // 恢复系统自动锁屏（见 viewDidLoad 里的 idleTimerDisabled）
    [UIApplication sharedApplication].idleTimerDisabled = NO;
    [self stopSession];

    [JoemeCameraStateLock() lock];
    void (^close)(NSInteger) = sCloseHandler;
    sCloseHandler = nil;
    sCaptureHandler = nil;
    if (sInstance == self) sInstance = nil;
    [JoemeCameraStateLock() unlock];

    if (close) close(self.captureCount);
}

#pragma mark - UI

- (void)buildUI {
    UIView *root = self.view;
    root.backgroundColor = [UIColor blackColor];

    self.previewContainer = [[UIView alloc] initWithFrame:root.bounds];
    self.previewContainer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    self.previewContainer.backgroundColor = [UIColor blackColor];
    self.previewContainer.clipsToBounds = YES;
    [root addSubview:self.previewContainer];

    // ---- 顶部：左关闭 / 右闪光灯 ----
    UIButton *close = [self circleButtonWithGlyph:@"✕"];
    [close addTarget:self action:@selector(onCloseTapped) forControlEvents:UIControlEventTouchUpInside];
    close.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:close];
    self.closeButton = close;

    UIButton *flash = [self circleButtonWithGlyph:@"⚡"];
    [flash addTarget:self action:@selector(onFlashTapped) forControlEvents:UIControlEventTouchUpInside];
    flash.translatesAutoresizingMaskIntoConstraints = NO;
    flash.hidden = YES;
    [root addSubview:flash];
    self.flashButton = flash;

    // ---- 底部：左相册缩略图 / 中快门 / 右前后摄切换 ----
    UIView *bottom = [[UIView alloc] init];
    bottom.translatesAutoresizingMaskIntoConstraints = NO;
    [root addSubview:bottom];

    UIImageView *thumb = [[UIImageView alloc] init];
    thumb.translatesAutoresizingMaskIntoConstraints = NO;
    thumb.contentMode = UIViewContentModeScaleAspectFill;
    thumb.clipsToBounds = YES;
    thumb.layer.cornerRadius = 10;
    thumb.backgroundColor = [UIColor colorWithWhite:1 alpha:0.2];
    thumb.userInteractionEnabled = YES;
    [thumb addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                       action:@selector(onThumbTapped)]];
    [bottom addSubview:thumb];
    self.thumbView = thumb;

    UIButton *shutter = [self makeShutterButton];
    shutter.translatesAutoresizingMaskIntoConstraints = NO;
    [shutter addTarget:self action:@selector(onShutterTapped) forControlEvents:UIControlEventTouchUpInside];
    [bottom addSubview:shutter];
    self.shutterButton = shutter;

    UIButton *flip = [self squareButtonWithGlyph:@"⇄"];
    flip.translatesAutoresizingMaskIntoConstraints = NO;
    [flip addTarget:self action:@selector(onFlipTapped) forControlEvents:UIControlEventTouchUpInside];
    [bottom addSubview:flip];
    self.flipButton = flip;

    UILabel *toast = [[UILabel alloc] init];
    toast.translatesAutoresizingMaskIntoConstraints = NO;
    toast.textColor = [UIColor whiteColor];
    toast.font = [UIFont systemFontOfSize:14];
    toast.textAlignment = NSTextAlignmentCenter;
    toast.numberOfLines = 0;
    toast.alpha = 0;
    toast.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
    toast.layer.cornerRadius = 10;
    toast.clipsToBounds = YES;
    [root addSubview:toast];
    self.toastLabel = toast;

    UILayoutGuide *safe = root.safeAreaLayoutGuide;
    [NSLayoutConstraint activateConstraints:@[
        [close.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor constant:20],
        [close.topAnchor constraintEqualToAnchor:safe.topAnchor constant:16],
        [close.widthAnchor constraintEqualToConstant:44],
        [close.heightAnchor constraintEqualToConstant:44],

        [flash.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor constant:-20],
        [flash.centerYAnchor constraintEqualToAnchor:close.centerYAnchor],
        [flash.widthAnchor constraintEqualToConstant:44],
        [flash.heightAnchor constraintEqualToConstant:44],

        [bottom.leadingAnchor constraintEqualToAnchor:safe.leadingAnchor],
        [bottom.trailingAnchor constraintEqualToAnchor:safe.trailingAnchor],
        [bottom.bottomAnchor constraintEqualToAnchor:safe.bottomAnchor constant:-28],
        [bottom.heightAnchor constraintEqualToConstant:80],

        [thumb.leadingAnchor constraintEqualToAnchor:bottom.leadingAnchor constant:24],
        [thumb.centerYAnchor constraintEqualToAnchor:bottom.centerYAnchor],
        [thumb.widthAnchor constraintEqualToConstant:52],
        [thumb.heightAnchor constraintEqualToConstant:52],

        [shutter.centerXAnchor constraintEqualToAnchor:bottom.centerXAnchor],
        [shutter.centerYAnchor constraintEqualToAnchor:bottom.centerYAnchor],
        [shutter.widthAnchor constraintEqualToConstant:76],
        [shutter.heightAnchor constraintEqualToConstant:76],

        [flip.trailingAnchor constraintEqualToAnchor:bottom.trailingAnchor constant:-24],
        [flip.centerYAnchor constraintEqualToAnchor:bottom.centerYAnchor],
        [flip.widthAnchor constraintEqualToConstant:48],
        [flip.heightAnchor constraintEqualToConstant:48],

        [toast.centerXAnchor constraintEqualToAnchor:root.centerXAnchor],
        [toast.bottomAnchor constraintEqualToAnchor:bottom.topAnchor constant:-16],
        [toast.widthAnchor constraintLessThanOrEqualToAnchor:root.widthAnchor constant:-64],
        [toast.heightAnchor constraintGreaterThanOrEqualToConstant:36]
    ]];
}

- (UIButton *)circleButtonWithGlyph:(NSString *)glyph {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:glyph forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:20];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    b.layer.cornerRadius = 22;
    return b;
}

- (UIButton *)squareButtonWithGlyph:(NSString *)glyph {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    [b setTitle:glyph forState:UIControlStateNormal];
    [b setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    b.titleLabel.font = [UIFont systemFontOfSize:20];
    b.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
    b.layer.cornerRadius = 12;
    return b;
}

/** 快门：白色圆环 + 白色实心圆（图层叠加，不引图片资源） */
- (UIButton *)makeShutterButton {
    UIButton *b = [UIButton buttonWithType:UIButtonTypeCustom];
    b.layer.cornerRadius = 38;
    b.layer.borderColor = [UIColor whiteColor].CGColor;
    b.layer.borderWidth = 4;

    UIView *inner = [[UIView alloc] init];
    inner.translatesAutoresizingMaskIntoConstraints = NO;
    inner.userInteractionEnabled = NO;
    inner.backgroundColor = [UIColor whiteColor];
    inner.layer.cornerRadius = 30;
    [b addSubview:inner];
    [NSLayoutConstraint activateConstraints:@[
        [inner.centerXAnchor constraintEqualToAnchor:b.centerXAnchor],
        [inner.centerYAnchor constraintEqualToAnchor:b.centerYAnchor],
        [inner.widthAnchor constraintEqualToConstant:60],
        [inner.heightAnchor constraintEqualToConstant:60]
    ]];
    return b;
}

#pragma mark - 会话

- (void)setupSession {
    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    self.session = session;

    AVCaptureVideoPreviewLayer *layer = [AVCaptureVideoPreviewLayer layerWithSession:session];
    // aspect（而不是 aspectFill）：与 Android 的 AutoFitTextureView 一致 ——
    // 预览按摄像头比例完整显示，上下留出的黑边正好放顶部/底部控件。
    layer.videoGravity = AVLayerVideoGravityResizeAspect;
    layer.frame = self.previewContainer.bounds;
    [self.previewContainer.layer addSublayer:layer];
    self.previewLayer = layer;
    [self updatePreviewOrientation];

    [self configureSessionForPosition:self.position];
}

/** 按前后摄重建 input / output（首次打开与切换摄像头共用） */
- (void)configureSessionForPosition:(AVCaptureDevicePosition)position {
    dispatch_async(_sessionQueue, ^{
        AVCaptureDevice *device = [self deviceForPosition:position];
        if (!device) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:@"未找到可用摄像头"];
            });
            return;
        }

        NSError *error = nil;
        AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
        if (!input) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:error.localizedDescription ?: @"打开摄像头失败"];
            });
            return;
        }

        BOOL wasRunning = self.session.isRunning;
        if (wasRunning) [self.session stopRunning];

        [self.session beginConfiguration];
        if (self.videoInput) [self.session removeInput:self.videoInput];

        if (![self.session canAddInput:input]) {
            [self.session commitConfiguration];
            if (wasRunning) [self.session startRunning];
            self.sessionRunning = self.session.isRunning;
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:@"无法配置摄像头"];
            });
            return;
        }
        [self.session addInput:input];
        self.videoInput = input;

        // photo 预设：出的是全尺寸照片，不是预览尺寸。
        // 必须先确认设备支持，直接赋不支持的值会抛 NSInvalidArgumentException。
        if ([self.session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
            self.session.sessionPreset = AVCaptureSessionPresetPhoto;
        }

        if (!self.photoOutput) {
            AVCapturePhotoOutput *output = [[AVCapturePhotoOutput alloc] init];
            if (![self.session canAddOutput:output]) {
                [self.session commitConfiguration];
                dispatch_async(dispatch_get_main_queue(), ^{
                    [self showToast:@"无法配置拍照输出"];
                });
                return;
            }
            [self.session addOutput:output];
            self.photoOutput = output;
            self.outputConfigured = YES;
        }
        BOOL hasFlash = device.hasFlash && device.isFlashAvailable;
        [self.session commitConfiguration];

        // 拍照连接也要设方向：只设预览层的话照片会按传感器原始方向存下来
        // （相册里是横的）。镜像与预览保持一致，前置自拍才不会左右反。
        JoemeApplyPortraitOrientation([self.photoOutput connectionWithMediaType:AVMediaTypeVideo],
                                     position == AVCaptureDevicePositionFront);
        [self.session startRunning];
        self.sessionRunning = self.session.isRunning;

        dispatch_async(dispatch_get_main_queue(), ^{
            self.flashButton.hidden = !hasFlash;
            self.flashOn = NO;
            self.flashButton.alpha = 0.45;
            [self updatePreviewOrientation];
        });
        // pendingShot 在 _sessionQueue 上读写，补拍也必须留在同一个队列里判断，
        // 否则主线程读到的是可能还没落地的旧值（漏拍）
        [self consumePendingShotIfNeeded];
    });
}

- (AVCaptureDevice *)deviceForPosition:(AVCaptureDevicePosition)position {
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                  mediaType:AVMediaTypeVideo
                                   position:position];
    for (AVCaptureDevice *d in discovery.devices) {
        if (d.position == position) return d;
    }
    // 目标镜头不存在（单摄机型/模拟器）时退回第一个可用设备
    AVCaptureDeviceDiscoverySession *all = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                  mediaType:AVMediaTypeVideo
                                   position:AVCaptureDevicePositionUnspecified];
    return all.devices.firstObject;
}

- (void)updatePreviewOrientation {
    // 前置预览镜像，与系统相机一致；方向和镜像的写法统一交给 JoemeApplyPortraitOrientation
    // （iOS 17 的 videoRotationAngle 与旧 SDK 的兼容处理都在那里）
    JoemeApplyPortraitOrientation(self.previewLayer.connection,
                                 self.position == AVCaptureDevicePositionFront);
}

- (void)startSessionIfNeeded {
    dispatch_async(_sessionQueue, ^{
        if (!self.session.isRunning) [self.session startRunning];
        self.sessionRunning = self.session.isRunning;
        [self consumePendingShotIfNeeded];
    });
}

- (void)stopSession {
    dispatch_async(_sessionQueue, ^{
        if (self.session.isRunning) [self.session stopRunning];
        self.sessionRunning = NO;
    });
}

- (void)appWillResignActive {
    // 退到后台时摄像头会被系统回收；回来时由 appDidBecomeActive 重建
    [self stopSession];
}

- (void)appDidBecomeActive {
    if (self.closedNotified) return;
    [self startSessionIfNeeded];
}

#pragma mark - 拍照

- (void)onShutterTapped {
    [self takePicture];
}

- (void)takePicture {
    dispatch_async(_sessionQueue, ^{
        if (!self.session.isRunning || !self.photoOutput) {
            // 会话没起来（刚打开/切前后摄/从后台回来）：挂起，起来后补拍。
            // 手表快门经常正好落在页面刚打开的那一瞬间。
            self.pendingShot = YES;
            self.pendingShotAt = [[NSDate date] timeIntervalSince1970];
            return;
        }
        if (self.capturing) return;
        self.capturing = YES;

        AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
        // 必须确认该闪光模式在 supportedFlashModes 里，否则赋一个不支持的值会抛异常
        if (self.flashOn && [self.photoOutput.supportedFlashModes containsObject:@(AVCaptureFlashModeOn)]) {
            // 与 Android 一致：闪光灯开关作用在拍照闪光上（不是常亮手电）
            settings.flashMode = AVCaptureFlashModeOn;
        }

        __weak typeof(self) weakSelf = self;
        JoemeCameraPhotoCapture *capture = [[JoemeCameraPhotoCapture alloc] init];
        capture.completion = ^(NSData *data, NSError *error) {
            // 这里不能强引用 capture：delegate 自己持有这个 block，会形成循环
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf) return;
            [strongSelf finishCaptureWithData:data error:error];
        };
        [self.activeCaptures addObject:capture];

        // 兜底：底层既不回调成功也不回调失败时（摄像头被系统抢占/会话中止），
        // 不复位 capturing 会让之后每一次快门都被静默吞掉（同 Android 的兜底）。
        // 用代号判断：期间若已开始新的一次拍照，就不要把新那次的互斥清掉。
        NSInteger gen = ++self.captureGen;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                       _sessionQueue, ^{
            __strong typeof(weakSelf) strongSelf = weakSelf;
            if (!strongSelf || strongSelf.captureGen != gen || !strongSelf.capturing) return;
            strongSelf.capturing = NO;
            [strongSelf.activeCaptures removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
                [strongSelf showToast:@"拍照超时，请重试"];
            });
        });

        @try {
            [self.photoOutput capturePhotoWithSettings:settings delegate:capture];
        } @catch (NSException *exception) {
            self.capturing = NO;
            [self.activeCaptures removeAllObjects];
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:exception.reason ?: @"拍照失败"];
            });
        }
    });
}

/** 一次拍摄落地：清互斥标志、释放 delegate、进入保存流程（跑在 sessionQueue） */
- (void)finishCaptureWithData:(NSData *)data error:(NSError *)error {
    dispatch_async(_sessionQueue, ^{
        self.capturing = NO;
        // capturing 互斥保证同一时刻最多一个 delegate，这里整表清空即可
        // （逐个按对象删还要把 capture 传进 block，会和 delegate 形成循环引用）
        [self.activeCaptures removeAllObjects];
        if (data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self showToast:error.localizedDescription ?: @"拍照失败"];
            });
            return;
        }
        [self handleCapturedJPEG:data];
    });
}

/** 落地一张照片：存相册 + 沙盒副本 + 更新缩略图 + 通知模块 */
- (void)handleCapturedJPEG:(NSData *)data {
    self.lastJPEGData = data;
    [JoemeCameraStore saveJPEGData:data completion:^(NSString *path, BOOL albumSaved, NSError *error) {
        if (!path) {
            [self showToast:error.localizedDescription ?: @"保存失败"];
            return;
        }
        self.captureCount++;

        UIImage *thumb = [JoemeCameraStore thumbnailForJPEGData:data maxPixel:256];
        if (thumb) self.thumbView.image = thumb;
        [self showToast:albumSaved ? @"已保存到相册" : @"已拍照（未获得相册权限）"];

        [JoemeCameraStateLock() lock];
        void (^capture)(NSString *) = sCaptureHandler;
        [JoemeCameraStateLock() unlock];
        if (capture) {
            @try { capture(path); } @catch (__unused NSException *e) { }
        }
    }];
}

- (void)consumePendingShotIfNeeded {
    if (!self.pendingShot) return;
    NSTimeInterval elapsed = [[NSDate date] timeIntervalSince1970] - self.pendingShotAt;
    self.pendingShot = NO;
    // 超窗口不补拍：手表按下快门的那一刻早就过了，补拍只会莫名其妙多出一张
    if (elapsed > JoemePendingShotWindow) return;
    [self takePicture];
}

#pragma mark - 控件动作

- (void)onCloseTapped {
    [self closeSelf];
}

- (void)onFlashTapped {
    self.flashOn = !self.flashOn;
    self.flashButton.alpha = self.flashOn ? 1.0 : 0.45;
}

- (void)onFlipTapped {
    if (self.capturing) return;
    self.position = (self.position == AVCaptureDevicePositionBack)
            ? AVCaptureDevicePositionFront
            : AVCaptureDevicePositionBack;
    [self configureSessionForPosition:self.position];
}

/**
 点左下角缩略图：在 App 内大图预览。
 iOS 没有公开的「打开系统相册」接口（只有私有的 photos-redirect://，上架会被拒），
 所以这里退化成页面内全屏预览，点任意处关闭。
 */
- (void)onThumbTapped {
    if (!self.lastJPEGData) return;
    if (!self.previewOverlay) {
        UIView *overlay = [[UIView alloc] initWithFrame:self.view.bounds];
        overlay.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        overlay.backgroundColor = [UIColor blackColor];
        overlay.hidden = YES;
        overlay.userInteractionEnabled = YES;
        [overlay addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self
                                                                            action:@selector(hidePhotoPreview)]];

        UIImageView *iv = [[UIImageView alloc] initWithFrame:overlay.bounds];
        iv.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        iv.contentMode = UIViewContentModeScaleAspectFit;
        [overlay addSubview:iv];

        [self.view addSubview:overlay];
        self.previewOverlay = overlay;
        self.previewImageView = iv;
    }
    // 预览大图按 EXIF 转正显示，与相册、左下角缩略图方向一致
    self.previewImageView.image = [JoemeCameraStore thumbnailForJPEGData:self.lastJPEGData maxPixel:2000];
    self.previewOverlay.hidden = NO;
}

- (void)hidePhotoPreview {
    self.previewOverlay.hidden = YES;
}

#pragma mark - 提示

- (void)showToast:(NSString *)text {
    if (!text.length) return;
    self.toastLabel.text = [NSString stringWithFormat:@"  %@  ", text];
    [UIView animateWithDuration:0.15 animations:^{
        self.toastLabel.alpha = 1;
    } completion:^(BOOL finished) {
        [UIView animateWithDuration:0.25 delay:1.2 options:0 animations:^{
            self.toastLabel.alpha = 0;
        } completion:nil];
    }];
}

@end
