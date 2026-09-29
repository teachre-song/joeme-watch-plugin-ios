//
//  UniPluginProtocol.h
//  libWeex
//
//  Created by 4Ndf on 2018/11/30.
//  Copyright © 2018年 DCloud. All rights reserved.
//
#import <UIKit/UIApplication.h>
@protocol UniPluginProtocol <NSObject>

@optional

-(void)onCreateUniPlugin;

- (BOOL)application:(UIApplication *_Nullable)application didFinishLaunchingWithOptions:(NSDictionary *_Nullable)launchOptions;
- (void)application:(UIApplication *_Nullable)application didRegisterForRemoteNotificationsWithDeviceToken:(NSData *_Nullable)deviceToken;
- (void)application:(UIApplication *_Nullable)application didFailToRegisterForRemoteNotificationsWithError:(NSError *_Nullable)err;
- (void)application:(UIApplication *_Nullable)application didReceiveRemoteNotification:(NSDictionary *_Nullable)userInfo;
- (void)application:(UIApplication *_Nullable)application didReceiveLocalNotification:(UILocalNotification *_Nullable)notification;
- (BOOL)application:(UIApplication *_Nullable)application handleOpenURL:(NSURL *_Nullable)url;
- (BOOL)application:(UIApplication *_Nullable)app openURL:(NSURL *_Nonnull)url options:(NSDictionary<UIApplicationOpenURLOptionsKey, id> *_Nullable)options NS_AVAILABLE_IOS(9_0);

- (void)applicationWillResignActive:(UIApplication *_Nullable)application;
- (void)applicationDidBecomeActive:(UIApplication *_Nullable)application;
- (void)applicationDidEnterBackground:(UIApplication *_Nullable)application;
- (void)applicationWillEnterForeground:(UIApplication *_Nullable)application;


- (void)applicationMain:(int)argc argv:(char * _Nullable [_Nonnull])argv;

- (BOOL)application:(UIApplication *_Nullable)application continueUserActivity:(NSUserActivity *_Nullable)userActivity restorationHandler:(void(^_Nullable)(NSArray * __nullable restorableObjects))restorationHandler API_AVAILABLE(ios(8.0));

@end
