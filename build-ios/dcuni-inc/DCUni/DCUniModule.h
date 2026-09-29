//
//  DCUniNativeModule.h
//
//  Created by DCloud on 2020/10/12.
//  Copyright © 2020 DCloud. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DCUniBasePlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface DCUniModule : NSObject

/**
 *  @abstract 可选 如果要在特殊队列中执行Module操作，请自己实现。
 *  默认调度队列将为主队列。
 *
 */
@property (nonatomic, strong)dispatch_queue_t uniExecuteQueue;

/**
 *  @abstract 可选 如果要在特殊线程中执行模块动作，可以创建一个。
    如果实现了“ targetExecuteQueue”，则首先考虑返回的队列。
 *  默认是主线程。
 *
 */
@property (nonatomic, strong)NSThread * uniExecuteThread;


/**
 *  @abstract 实例绑定到此模块。 它可以帮助您获得许多与实例相关的有用属性。
 */
@property (nonatomic, weak) DCUniSDKInstance * uniInstance;

@end

NS_ASSUME_NONNULL_END
