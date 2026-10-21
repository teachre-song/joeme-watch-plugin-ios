//
//  JoemeCameraStore.h
//  joeme-watch
//
//  拍照结果落盘。对应 Android 的 JoemeCameraStore。
//
//  iOS 没有「公共 Pictures 目录」这种可直接写的公共路径：照片统一写入系统相册
//  （只需 add-only 权限），同时在沙盒 tmp 留一份 jpg 供页面立即预览 ——
//  相册里的资源没有能被 <image> 直接渲染的路径。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface JoemeCameraStore : NSObject

/**
 保存一张 JPEG。completion 一定在主线程回调。

 @param data        JPEG 数据
 @param completion  path 为沙盒 tmp 里的绝对路径（数据为空时为 nil）；
                    albumSaved 表示是否成功写入系统相册（权限被拒时为 NO，但 path 仍然有效）；
                    error 仅用于排查，path 存在时调用方可以不提示。
 */
+ (void)saveJPEGData:(NSData *)data
          completion:(void (^)(NSString *_Nullable path, BOOL albumSaved, NSError *_Nullable error))completion;

/**
 从 JPEG 数据取缩略图：只解码缩略图、不解全图，并按 EXIF Orientation 转正
 （手机相册/相机页左下角都按 EXIF 显示，这样两边方向一致）。
 */
+ (nullable UIImage *)thumbnailForJPEGData:(NSData *)data maxPixel:(CGFloat)maxPixel;

@end

NS_ASSUME_NONNULL_END
