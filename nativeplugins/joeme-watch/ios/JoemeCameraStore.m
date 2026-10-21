//
//  JoemeCameraStore.m
//  joeme-watch
//

#import "JoemeCameraStore.h"
#import <Photos/Photos.h>
#import <ImageIO/ImageIO.h>

/** 照片写入的串行队列：写文件 + 请求相册权限都在这里，避免阻塞主线程 */
static dispatch_queue_t JoemeCameraStoreQueue(void) {
    static dispatch_queue_t q;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        q = dispatch_queue_create("joeme.camera.store", DISPATCH_QUEUE_SERIAL);
    });
    return q;
}

static NSError *JoemeCameraStoreError(NSInteger code, NSString *message) {
    return [NSError errorWithDomain:@"joeme.camera.store"
                               code:code
                           userInfo:@{ NSLocalizedDescriptionKey: (message ?: @"拍照保存失败") }];
}

/** tmp/joeme_camera：放最新拍的照片，供页面立刻预览（长期留存在系统相册里） */
static NSString *JoemeCameraCachePath(NSString *fileName) {
    NSString *dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"joeme_camera"];
    [[NSFileManager defaultManager] createDirectoryAtPath:dir
                              withIntermediateDirectories:YES
                                               attributes:nil
                                                    error:NULL];
    return [dir stringByAppendingPathComponent:fileName];
}

/** 写系统相册是内部实现，只在 .m 里用，故放到类扩展 */
@interface JoemeCameraStore ()
+ (void)addToAlbum:(NSData *)data completion:(void (^)(BOOL saved, NSError *error))completion;
@end

@implementation JoemeCameraStore

+ (void)saveJPEGData:(NSData *)data
          completion:(void (^)(NSString *, BOOL, NSError *))completion {
    dispatch_async(JoemeCameraStoreQueue(), ^{
        if (data.length == 0) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, NO, JoemeCameraStoreError(-1, @"图像数据为空"));
            });
            return;
        }

        NSString *name = [NSString stringWithFormat:@"joeme_%.0f.jpg",
                          [[NSDate date] timeIntervalSince1970] * 1000.0];
        NSString *path = JoemeCameraCachePath(name);
        NSError *writeError = nil;
        if (![data writeToFile:path options:NSDataWritingAtomic error:&writeError]) {
            NSString *message = writeError.localizedDescription ?: @"照片写入失败";
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(nil, NO, JoemeCameraStoreError(-1, message));
            });
            return;
        }

        [self addToAlbum:data completion:^(BOOL saved, NSError *albumError) {
            dispatch_async(dispatch_get_main_queue(), ^{
                if (completion) completion(path, saved, saved ? nil : albumError);
            });
        }];
    });
}

/** 写入系统相册（Camera Roll）。只申请 add-only 权限，不读用户已有照片。 */
+ (void)addToAlbum:(NSData *)data completion:(void (^)(BOOL, NSError *))completion {
    void (^performAdd)(void) = ^{
        [[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
            PHAssetCreationRequest *request = [PHAssetCreationRequest creationRequestForAsset];
            [request addResourceWithType:PHAssetResourceTypePhoto data:data options:nil];
        } completionHandler:^(BOOL success, NSError *error) {
            if (completion) completion(success, error);
        }];
    };

    // add-only 权限与 PBHAccessLevel 都是 iOS 14 才有的符号：
    // 运行时 @available 之外还要编译期 #if，否则用旧 SDK 打包会编译失败。
#if __IPHONE_OS_VERSION_MAX_ALLOWED >= 140000
    if (@available(iOS 14.0, *)) {
        [PHPhotoLibrary requestAuthorizationForAccessLevel:PHAccessLevelAddOnly
                                                  handler:^(PHAuthorizationStatus status) {
            if (status == PHAuthorizationStatusAuthorized || status == PHAuthorizationStatusLimited) {
                performAdd();
            } else {
                if (completion) completion(NO, JoemeCameraStoreError(-2, @"没有相册写入权限"));
            }
        }];
        return;
    }
#endif
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
    // iOS 13 及以下只有这个整体授权接口，用户允许「读取+写入」才能写相册
    [PHPhotoLibrary requestAuthorization:^(PHAuthorizationStatus status) {
        if (status == PHAuthorizationStatusAuthorized) {
            performAdd();
        } else {
            if (completion) completion(NO, JoemeCameraStoreError(-2, @"没有相册写入权限"));
        }
    }];
#pragma clang diagnostic pop
}

+ (UIImage *)thumbnailForJPEGData:(NSData *)data maxPixel:(CGFloat)maxPixel {
    if (data.length == 0) return nil;
    CGImageSourceRef source = CGImageSourceCreateWithData((__bridge CFDataRef)data, NULL);
    if (!source) return nil;

    NSDictionary *options = @{
        (__bridge NSString *)kCGImageSourceCreateThumbnailFromImageAlways: @YES,
        (__bridge NSString *)kCGImageSourceCreateThumbnailWithTransform: @YES,
        (__bridge NSString *)kCGImageSourceThumbnailMaxPixelSize: @(MAX(1.0, maxPixel))
    };
    CGImageRef image = CGImageSourceCreateThumbnailAtIndex(source, 0, (__bridge CFDictionaryRef)options);
    CFRelease(source);
    if (!image) return nil;

    UIImage *result = [UIImage imageWithCGImage:image];
    CGImageRelease(image);
    return result;
}

@end
