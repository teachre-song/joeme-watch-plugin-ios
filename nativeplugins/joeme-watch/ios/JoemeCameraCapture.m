//
//  JoemeCameraCapture.m
//  joeme-watch
//

#import "JoemeCameraCapture.h"
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>

NSString *const JoemeCameraCaptureErrorDomain = @"joeme.camera.capture";

static NSError *JoemeCaptureError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:JoemeCameraCaptureErrorDomain
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: (message ?: @"拍照失败") }];
}

/** 拍照互斥：摄像头是独占资源，并发配置 AVCaptureSession 会直接失败 */
static NSLock *JoemeCaptureLock(void) {
    static NSLock *lock;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        lock = [[NSLock alloc] init];
    });
    return lock;
}

static BOOL JoemeCaptureBusy = NO;

/** session 必须跑在自己的串行队列上（AVFoundation 的 startRunning 是阻塞调用） */
static dispatch_queue_t JoemeCaptureQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("joeme.camera.capture", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

/**
 进行中的 delegate 容器。
 AVCapturePhotoOutput 不保证强引用 delegate，本地变量在方法返回后就可能被释放，
 一旦释放回调再也不会来（表现是「手表按了快门，App 一直不出片」）。
 */
static NSMutableArray *JoemeActiveDelegates(void) {
    static NSMutableArray *arr;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        arr = [NSMutableArray array];
    });
    return arr;
}

/**
 把连接设成竖屏 + 按需镜像（详见头文件注释）。
 */
void JoemeApplyPortraitOrientation(AVCaptureConnection *_Nullable connection, BOOL mirrored) {
    if (!connection) return;
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 170000
    if (@available(iOS 17.0, *)) {
        if ([connection isVideoRotationAngleSupported:90]) {
            connection.videoRotationAngle = 90;   // 竖屏
        }
    } else
#endif
    {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
        if ([connection isVideoOrientationSupported]) {
            connection.videoOrientation = AVCaptureVideoOrientationPortrait;
        }
#pragma clang diagnostic pop
    }
    if (connection.isVideoMirroringSupported) {
        connection.automaticallyAdjustsVideoMirroring = NO;
        connection.videoMirrored = mirrored;
    }
}

@interface JoemeCameraCaptureSessionDelegate : NSObject <AVCapturePhotoCaptureDelegate>
@property (nonatomic, copy) JoemeCameraCaptureCompletion completion;
@property (nonatomic, strong) AVCaptureSession *session;
@property (nonatomic, strong) NSData *jpegData;
@property (nonatomic, strong) NSError *error;
@end

@implementation JoemeCameraCaptureSessionDelegate
- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishProcessingPhoto:(AVCapturePhoto *)photo
                error:(NSError *)error {
    if (error) {
        self.error = error;
        return;
    }
    self.jpegData = [photo fileDataRepresentation];
    if (!self.jpegData.length) {
        self.error = JoemeCaptureError(-1, @"未获取到图像数据");
    }
}

- (void)captureOutput:(AVCapturePhotoOutput *)output
didFinishCaptureForResolvedSettings:(AVCaptureResolvedPhotoSettings *)resolvedSettings
                error:(NSError *)error {
    if (error && !self.error) self.error = error;
    // startRunning 在串行队列上，这里也回到该队列停，避免跨线程操作 session
    dispatch_async(JoemeCaptureQueue(), ^{
        [self.session stopRunning];
    });

    JoemeCameraCaptureCompletion cb = self.completion;
    self.completion = nil;
    NSData *data = self.jpegData;
    NSError *err = self.error;

    // 释放对自己的持有：否则 delegate 永远留在容器里
    @synchronized (JoemeActiveDelegates()) {
        [JoemeActiveDelegates() removeObject:self];
    }

    dispatch_async(dispatch_get_main_queue(), ^{
        if (cb) cb(err ? nil : data, err);
    });
}

@end

@implementation JoemeCameraCapture

+ (BOOL)hasCameraPermission {
    return [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo]
            == AVAuthorizationStatusAuthorized;
}

+ (BOOL)isCapturing {
    [JoemeCaptureLock() lock];
    BOOL busy = JoemeCaptureBusy;
    [JoemeCaptureLock() unlock];
    return busy;
}

+ (void)requestCameraAccess:(void (^)(BOOL))completion {
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    // 统一在主线程回调：调用方要拿这个结果去 present 相机页（UI 操作）
    if (status == AVAuthorizationStatusAuthorized) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(YES);
        });
        return;
    }
    if (status != AVAuthorizationStatusNotDetermined) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(NO);
        });
        return;
    }
    [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^(BOOL granted) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(granted);
        });
    }];
}

+ (void)captureJPEGFront:(BOOL)front completion:(JoemeCameraCaptureCompletion)completion {
    // 权限：未决 -> 申请；拒绝 -> 直接回 -3（无权限），让 JS 侧去申请/引导设置
    AVAuthorizationStatus status = [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo];
    if (status == AVAuthorizationStatusNotDetermined) {
        [AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo
                                 completionHandler:^(BOOL granted) {
            if (granted) {
                [self captureJPEGFront:front completion:completion];
            } else {
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (completion) completion(nil, JoemeCaptureError(-3, @"缺少相机权限"));
                });
            }
        }];
        return;
    }
    if (status != AVAuthorizationStatusAuthorized) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, JoemeCaptureError(-3, @"缺少相机权限"));
        });
        return;
    }

    [JoemeCaptureLock() lock];
    if (JoemeCaptureBusy) {
        [JoemeCaptureLock() unlock];
        dispatch_async(dispatch_get_main_queue(), ^{
            if (completion) completion(nil, JoemeCaptureError(-4, @"上一次拍照尚未完成"));
        });
        return;
    }
    JoemeCaptureBusy = YES;
    [JoemeCaptureLock() unlock];

    dispatch_async(JoemeCaptureQueue(), ^{
        [self runCaptureFront:front completion:^(NSData *data, NSError *error) {
            [JoemeCaptureLock() lock];
            JoemeCaptureBusy = NO;
            [JoemeCaptureLock() unlock];
            // runCaptureFront 的错误分支直接在采集队列上回调，这里统一挪回主线程
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(data, error);
            });
        }];
    });
}

/** 真正的拍照流程，跑在 JoemeCaptureQueue 上；completion 已在主线程 */
+ (void)runCaptureFront:(BOOL)front completion:(JoemeCameraCaptureCompletion)completion {
    AVCaptureDevice *device = [self deviceForFront:front];
    if (!device) {
        completion(nil, JoemeCaptureError(-1, @"未找到可用摄像头"));
        return;
    }

    NSError *error = nil;
    AVCaptureDeviceInput *input = [AVCaptureDeviceInput deviceInputWithDevice:device error:&error];
    if (!input) {
        completion(nil, error ?: JoemeCaptureError(-1, @"打开摄像头失败"));
        return;
    }

    AVCaptureSession *session = [[AVCaptureSession alloc] init];
    [session beginConfiguration];
    // photo 预设：出的是全尺寸照片，不是预览尺寸（不支持时保持默认，避免抛异常）
    if ([session canSetSessionPreset:AVCaptureSessionPresetPhoto]) {
        session.sessionPreset = AVCaptureSessionPresetPhoto;
    }
    if (![session canAddInput:input]) {
        [session commitConfiguration];
        completion(nil, JoemeCaptureError(-1, @"无法配置摄像头输入"));
        return;
    }
    [session addInput:input];

    AVCapturePhotoOutput *output = [[AVCapturePhotoOutput alloc] init];
    if (![session canAddOutput:output]) {
        [session commitConfiguration];
        completion(nil, JoemeCaptureError(-1, @"无法配置拍照输出"));
        return;
    }
    [session addOutput:output];
    [session commitConfiguration];

    // 方向：静默拍照没有预览，必须显式设置连接方向，否则照片按传感器原始方向存下来
    // （表现是相册里躺着的横图）。App 锁定竖屏，这里直接按竖屏处理，与相机页一致。
    JoemeApplyPortraitOrientation([output connectionWithMediaType:AVMediaTypeVideo], front);

    JoemeCameraCaptureSessionDelegate *delegate = [[JoemeCameraCaptureSessionDelegate alloc] init];
    delegate.completion = completion;
    delegate.session = session;
    @synchronized (JoemeActiveDelegates()) {
        [JoemeActiveDelegates() addObject:delegate];
    }

    @try {
        [session startRunning];
    } @catch (NSException *exception) {
        @synchronized (JoemeActiveDelegates()) {
            [JoemeActiveDelegates() removeObject:delegate];
        }
        completion(nil, JoemeCaptureError(-1, exception.reason ?: @"启动摄像头失败"));
        return;
    }

    AVCapturePhotoSettings *settings = [AVCapturePhotoSettings photoSettings];
    // 后摄有闪光灯时默认自动闪光（与 Android 静默拍照的默认行为一致）。
    // 必须先确认该模式在 supportedFlashModes 里，赋不支持的值会抛异常。
    if (!front && [output.supportedFlashModes containsObject:@(AVCaptureFlashModeAuto)]) {
        settings.flashMode = AVCaptureFlashModeAuto;
    }

    @try {
        [output capturePhotoWithSettings:settings delegate:delegate];
    } @catch (NSException *exception) {
        [session stopRunning];
        @synchronized (JoemeActiveDelegates()) {
            [JoemeActiveDelegates() removeObject:delegate];
        }
        completion(nil, JoemeCaptureError(-1, exception.reason ?: @"拍照失败"));
    }
}

+ (AVCaptureDevice *)deviceForFront:(BOOL)front {
    AVCaptureDevicePosition position = front ? AVCaptureDevicePositionFront
                                             : AVCaptureDevicePositionBack;
    AVCaptureDeviceDiscoverySession *discovery = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                  mediaType:AVMediaTypeVideo
                                   position:position];
    for (AVCaptureDevice *d in discovery.devices) {
        if (d.position == position) return d;
    }
    // 单摄机型 / 模拟器：退回第一个可用摄像头
    AVCaptureDeviceDiscoverySession *all = [AVCaptureDeviceDiscoverySession
            discoverySessionWithDeviceTypes:@[ AVCaptureDeviceTypeBuiltInWideAngleCamera ]
                                  mediaType:AVMediaTypeVideo
                                   position:AVCaptureDevicePositionUnspecified];
    return all.devices.firstObject;
}

@end
