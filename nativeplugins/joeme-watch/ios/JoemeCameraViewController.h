//
//  JoemeCameraViewController.h
//  joeme-watch
//
//  App 内全屏相机（AVCaptureSession 实时预览 + 快门），对应 Android 的 JoemeCameraActivity。
//
//  为什么必须自己写相机页面，而不是 UIImagePickerController / uni.chooseImage：
//  系统相机是独立进程/独立 UI，手表按快门时既抢不到摄像头也调不动它的快门；
//  只有预览在本进程内，手表上报的 VPCameraTypePhoto 才能立刻出片（官方 App 同款）。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JoemeCameraViewController : UIViewController

/** 相机页是否在显示（手表事件用它判断走「界面快门」还是「静默拍照」） */
+ (BOOL)isOpen;

/** 预览会话是否就绪（能接收快门） */
+ (BOOL)isReady;

/** 立刻拍一张（可从任意线程调用） */
+ (void)takePictureNow;

/** 重新拉起会话（页面在但会话没起来时用） */
+ (void)retryOpen;

/** 主动关闭 */
+ (void)finishIfOpen;

/** 手表已退出拍照页时关闭：关闭回调不再回发「退出拍照」命令 */
+ (void)finishFromWatch;

/** 读取并清空「本次关闭是手表发起的」标记 */
+ (BOOL)consumeClosedByWatch;

/** 关闭回调（参数为本次拍了几张），每次打开前设置 */
+ (void)setCloseHandler:(void (^_Nullable)(NSInteger count))handler;

/** 每拍成一张回调一次（参数为可预览的本地路径） */
+ (void)setCaptureHandler:(void (^_Nullable)(NSString *path))handler;

/** 从当前最上层控制器全屏拉起相机页；返回是否成功发起 present */
+ (BOOL)presentNew;

@end

NS_ASSUME_NONNULL_END
