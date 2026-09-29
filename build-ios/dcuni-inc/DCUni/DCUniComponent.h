//
//  DCUniNativeComponent.h
//
//  Created by DCloud on 2020/10/12.
//  Copyright © 2020 DCloud. All rights reserved.
//

#import "DCUniBasePlugin.h"

NS_ASSUME_NONNULL_BEGIN

@interface DCUniComponent : DCUniBaseCompenent

/**
 *
 *
 *  @param ref          组件的标识
 *  @param type         组件的类型
 *  @param styles       组件的样式
 *  @param attributes   组件的属性
 *  @param events       组件的事件
 *  @param uniInstance  与组件关联的uniInstance
 *
 */


-(void)onCreateComponentWithRef:(NSString *)ref type:(NSString *)type
                    styles:(NSDictionary *)styles
                    attributes:(NSDictionary *)attributes
                    events:(NSArray *)events uniInstance:(DCUniSDKInstance *)uniInstance;

/**
 * @abstract The component's supercomponent.
 */
@property (nonatomic, readonly, weak, nullable) DCUniSDKInstance * uniInstance;


/**
 * @abstract 该组件的子组件
 */
@property (nonatomic, readonly, strong, nullable) NSArray<DCUniComponent *> * uniSubcomponents;


/**
 * @abstract 该组件的父组件
 */
@property (nonatomic, readonly, weak, nullable) DCUniComponent * uniSupercomponent;


/**
 * @abstract 组件的视图
 */
@property(nonatomic, readonly, strong) UIView *view;


//View 层级相关
/**
 * @abstract 从父视图中删除该组件的视图。
 *
 * @discussion 该方法在主线程上调用。
 */
- (void)removeFromSuperview;



// 生命周期 相关函数
/**
 * @abstract 创建组件管理的视图
 *
 * @return 返回创建的视图
 *
 * @discussion 此方法加载或创建视图，并将其分配给view属性。 子类应在此处创建其自定义视图层次结构。不要直接调用该方法。
 *
 * @warning 对此方法的自定义实现 不要调用super
 */

- (UIView *)loadView;

/**
 * @abstract 返回一个布尔值，标识视图是否加载完毕。
 */

- (BOOL)isViewLoaded;

/**
 * @abstract 在加载组件视图之前调用
 *
 * @discussion 这是在-loadView之前。 该方法在主线程上调用。
 */
- (void)viewWillLoad;

/**
 * @abstract 在加载并设置组件的视图之后调用。
 *
 * @discussion 这是在-loadView之后。 这是执行额外初始化的最佳时间，例如向视图添加手势识别器。该方法在主线程上调用。
 */

- (void)viewDidLoad;

/**
 * @abstract 在释放组件的视图之前调用。方法在主线程上调用。
 */


- (void)viewWillUnload;

/**
 * @abstract 在释放组件的视图时调用。在主线程上调用该方法。
 */
- (void)viewDidUnload;


// 向JS发消息

/**
 * @abstract 向JS 中的组件触发事件。
 *
 * @param eventName 要触发的事件的名称
 * @param params 要触发的参数
 **/
- (void)fireEvent:(NSString *)eventName params:(nullable NSDictionary *)params;

/**
 * @abstract 向组件触发事件，并告诉JS哪个值已更改。
 * 用于双向数据绑定。
 *
 * @param eventName 要触发的事件的名称
 * @param params 要触发的参数
 * @param domChanges 值已更改，用于双向数据绑定。
 **/

- (void)fireEvent:(NSString *)eventName params:(nullable NSDictionary *)params domChanges:(nullable NSDictionary *)domChanges;


// 样式相关函数
/**
 * @abstract 组件样式更新时调用
 *
 * @param styles 更新的样式字典
 * @discussion 重写来处理特定的样式更新。 该方法在主线程上调用。
 **/
- (void)updateStyles:(NSDictionary *)styles;

/**
 * @abstract 重置组件样式时调用
 *
 * @param styles 重置样式的元素
 * @discussion 可以重写它来处理特定的样式重置。 该方法在主线程上调用。
 **/
- (void)resetStyles:(NSArray *)styles;


// 属性相关函数

/**
 * @abstract 组件属性更新时调用
 *
 * @param attributes 更新的属性字典
 * @discussion 可以覆盖它以处理特定的属性更新。 该方法在主线程上调用。
 **/
- (void)updateAttributes:(NSDictionary *)attributes;


/**
 * @abstract 在向组件添加事件时调用
 *
 * @param eventName 添加的事件的名称
 * @discussion 可以覆盖它以处理特定事件的添加。 该方法在主线程上调用。
 **/
- (void)addEvent:(NSString *)eventName;

/**
 * @abstract 从组件中删除事件时调用
 *
 * @param eventName 删除的事件的名称
 * @discussion 可以重写它来处理特定的事件删除。 该方法在主线程上调用。
 **/
- (void)removeEvent:(NSString *)eventName;


@end
NS_ASSUME_NONNULL_END
