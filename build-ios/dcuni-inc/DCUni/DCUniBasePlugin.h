//
//  DCUniBasePlugin.h
//
//  Created by DCloud on 2020/11/2.
//  Copyright © 2020 DCloud. All rights reserved.
//

#import <Foundation/Foundation.h>
#import "DCUniDefine.h"
#import "WXComponent.h"
#import "WXSDKInstance.h"


NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DCUniState) {//state.code
    DCUniInstanceAppear = 100,
    DCUniInstanceDisappear,
    DCUniInstanceForeground,
    DCUniInstanceBackground,
    DCUniInstanceMemoryWarning,
    DCUniInstanceBindChanged,
    DCUniInstanceDestroy
};



@interface DCUniBaseCompenent : WXComponent

@end

@interface DCUniSDKInstance : WXSDKInstance


/**
 * DCUni 所呈现的viewControler。
 **/
@property (nonatomic, weak) UIViewController *viewController;

/**
 * 用于承载vue文件呈现的视图。
 * rootView由DCUniSDKInstance 控制，因此只能获取它，而不能更改它
 **/
@property (nonatomic, strong) UIView *rootView;


/**
 * The scriptURL of vue.
 **/

@property (nonatomic, strong) NSURL *scriptURL;

/**
 * 父 实例
 **/
@property (nonatomic, weak) DCUniSDKInstance *parentInstance;


/**
 * 父 节点
 **/

@property (nonatomic, weak) NSString *parentNodeRef;

/**
 * 标识当前DCUni 实例的唯一ID。
 **/
@property (nonatomic, strong) NSString *instanceId;

/**
 * 自定义的一些信息.
 **/
@property (nonatomic, strong) NSDictionary* containerInfo;


@property (nonatomic, assign) DCUniState uniState;

/**
 *  实例完成创建body时触发的回调。
 *
 *  @return 带有UIView参数的block，它是根视图
 **/
@property (nonatomic, copy) void (^onCreate)(UIView *);
/**
 *  根容器的框架发生更改时触发的回调。
 *
 *  @return 带有UIView参数的block，它是根视图
 **/
@property (nonatomic, copy) void (^onLayoutChange)(UIView *);
/**
 *  实例完成渲染后触发的回调。
 *
 *  @return 带有UIView参数的block，它是根视图
 **/
@property (nonatomic, copy) void (^renderFinish)(UIView *);
/**
 *  实例完成刷新视图时触发的回调。
 *
 *  @return 带有UIView参数的block，它是根视图
 **/
@property (nonatomic, copy) void (^refreshFinish)(UIView *);
/**
 *  实例渲染失败时触发的回调。
 *
 *  @return 带有NSError参数的块，即发生的错误
 **/
@property (nonatomic, copy) void (^onFailed)(NSError *error);


/**
 *  当前实例的框架。
 **/

@property (nonatomic, assign) CGRect frame;

/**
 * 用户存储的信息。
 */
@property (atomic, strong) NSMutableDictionary *userInfo;


- (void)renderWithURL:(NSURL *)url;
- (void)renderWithURL:(NSURL *)url options:(NSDictionary * _Nullable)options data:(id _Nullable)data;

/**
 * 从当前URL重新加载js包并重新呈现。
 *
 * @param forcedReload 当此参数为true时，将始终从服务器重新加载js捆绑包。 如果为false，则实例可以从其缓存中重新加载js捆绑包。 默认为false。
 *
 **/

- (void)reload:(BOOL)forcedReload;

/**
 * 设置自定义视图端口/设备宽度后，刷新当前实例组件的布局。
 **/
- (void)reloadLayout;

/**
 * 用数据刷新当前实例。
 *
 * @param data 捆绑包呈现时需要的数据。
 **/

- (void)refreshInstance:(id)data;

/**
 * 销毁当前实例。 销毁的实例不应再次用于渲染，请创建另一个实例。
 **/
- (void)destroyInstance;


/**
 * 发送全局事件
 */
- (void)fireGlobalEvent:(NSString *)eventName params:(NSDictionary *)params;

@end

NS_ASSUME_NONNULL_END
