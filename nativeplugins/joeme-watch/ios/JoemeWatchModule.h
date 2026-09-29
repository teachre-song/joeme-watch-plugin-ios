//
//  JoemeWatchModule.h
//  joeme-watch
//
//  JOEMEFIT 手表（维普沃 Veepoo BLE SDK）uni-app iOS 原生插件模块
//  对应 Android 端 nativeplugins/joeme-watch/android/JoemeWatchModule.java
//
//  调用链：pages/watch/connect.vue -> utils/joeme-watch.js -> 本模块 -> VeepooBleSDK.framework
//  完整流程：初始化 -> 扫描 -> 连接(含自动密码验证) -> 同步个人信息 -> 业务操作
//

#import <Foundation/Foundation.h>
#import "DCUniModule.h"

@interface JoemeWatchModule : DCUniModule

@end
