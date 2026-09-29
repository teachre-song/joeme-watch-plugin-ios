//
//  DCUniComponent+Support.h
//
//  Created by DCloud on 2020/11/2.
//  Copyright © 2020 DCloud. All rights reserved.
//

#import <Foundation/Foundation.h>
#import <UIkit/UIkit.h>

NS_ASSUME_NONNULL_BEGIN

@interface DCUniComponent(Support)


@property (nonatomic, readonly, strong) NSString *ref;
@property (nonatomic, readonly, copy) NSString *type;
@property (nonatomic, readonly, strong) NSDictionary *styles;
@property (nonatomic, readonly, strong) NSDictionary *attributes;
@property (nonatomic, readonly, strong) NSArray *events;


@end

NS_ASSUME_NONNULL_END
