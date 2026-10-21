//
//  JoemeCameraCapture.h
//  joeme-watch
//
//  无界面（静默）拍照：对应 Android 的 capturePhoto / doCapturePhoto。
//
//  为什么不用 UIImagePickerController / uni.chooseImage：手表遥控场景要求 App 收到
//  手表快门后立刻出片，不能再让用户按一次快门；UIImagePickerController 是独立 UI，
//  而静默拍照只需要 AVCapturePhotoOutput 拍一帧。
//

#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^JoemeCameraCaptureCompletion)(NSData *_Nullable jpegData, NSError *_Nullable error);

/**
 把连接的视频方向设成竖屏，并按 mirrored 决定是否镜像。

 相机页的预览层和静默拍照的输出都要用同一套设置，所以抽成公共函数：
 iOS 17 起 videoOrientation 被废弃、改用 videoRotationAngle，而旧 SDK（iOS 16 及更早）
 里根本没有 videoRotationAngle 这个符号 —— 光写 @available 不够，还要编译期 #if，
 否则用旧 SDK 打包会直接编译失败。
 */
void JoemeApplyPortraitOrientation(AVCaptureConnection *_Nullable connection, BOOL mirrored);

/** 错误码（与 Android 的 capturePhoto 返回码对齐）：-1 失败 / -3 无权限 / -4 上一次还没拍完 */
extern NSString *const JoemeCameraCaptureErrorDomain;

@interface JoemeCameraCapture : NSObject

/**
 立刻拍一张 JPEG（不显示任何界面）。
 内部自己申请相机权限、自己开关 AVCaptureSession，拍完即释放摄像头。
 可从任意线程调用，completion 在主线程回调。

 @param front YES 用前置摄像头
 */
+ (void)captureJPEGFront:(BOOL)front completion:(JoemeCameraCaptureCompletion)completion;

/** 是否有相机权限（不触发申请）。用于手表快门到来时先做一次同步判断。 */
+ (BOOL)hasCameraPermission;

/**
 申请相机权限（未决时弹系统授权框；已决定则直接回报结果）。
 completion 一定在主线程回调。打开相机页前调用，避免页面起来了却是黑屏。
 */
+ (void)requestCameraAccess:(void (^)(BOOL granted))completion;

/** 当前是否正在拍照（手表连按快门时的互斥） */
+ (BOOL)isCapturing;

@end

NS_ASSUME_NONNULL_END
