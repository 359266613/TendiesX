#import "TXPosterService.h"
#import "TXLogger.h"

//  用协议声明（而不是 import dump 头）：dump 头里有一堆 @protocol / @class 引用，
//  直接 include 会编译不过。这里只声明我们真正调用的方法。
//
//  completion 一律声明成 (void (^)(id))：dump 里全是 id /* block */，参数个数未知；
//  声明成 1 个参数时，即使真实回调传了 2 个，我们也只看第一个（多传的参数被忽略），
//  而第一个参数到底是结果还是 NSError，用 isKindOfClass 判。
@protocol TXPRSService <NSObject>
- (void)refreshPosterDescriptorsForExtension:(id)extension
                                  completion:(void (^)(id result))completion;
- (void)fetchPosterDescriptorsForExtension:(id)extension
                                completion:(void (^)(id result))completion;
- (void)createPosterConfigurationForProviderIdentifier:(id)providerIdentifier
                           posterDescriptorIdentifier:(id)descriptorIdentifier
                                            completion:(void (^)(id result))completion;
- (void)updateToSelectedConfiguration:(id)configuration
                           completion:(void (^)(id result))completion;
- (void)fetchSelectedConfiguration:(void (^)(id result))configuration;
- (void)refreshSnapshotForGalleryItemsMatchingDescriptorIdentifier:(id)descriptorIdentifier
                                                extensionIdentifier:(id)extensionIdentifier
                                                         completion:(void (^)(id result))completion;
@end

/// PRSService 的经典取法：有 sharedInstance 就用，没有就 alloc/init
/// （dump 里只看到 -init，所以两条都兜着）
@protocol TXPRSServiceFactory <NSObject>
+ (id)sharedInstance;
@end

static id TXPRSServiceInstance(void) {
    Class cls = NSClassFromString(@"PRSService");
    if (!cls) {
        return nil;
    }
    if ([cls respondsToSelector:@selector(sharedInstance)]) {
        return [(id<TXPRSServiceFactory>)cls sharedInstance];
    }
    return [[cls alloc] init];
}

static BOOL TXIsPosterConfiguration(id object) {
    Class cls = NSClassFromString(@"PRSPosterConfiguration");
    return cls && [object isKindOfClass:cls];
}

@implementation TXPosterService

+ (instancetype)sharedService {
    static TXPosterService *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[TXPosterService alloc] init];
    });
    return shared;
}

#pragma mark - 重扫 + 回读列表

- (void)refreshExtension:(NSString *)extensionIdentifier
              completion:(void (^)(NSUInteger, NSArray *))completion {
    if (!extensionIdentifier.length) {
        if (completion) {
            completion(0, nil);
        }
        return;
    }

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id service = TXPRSServiceInstance();
        if (!service) {
            TXLog(@"[PRS] 本系统没有 PRSService，跳过重扫 —— 需要手动 respring 才会看到新壁纸");
            if (completion) {
                completion(0, nil);
            }
            return;
        }

        if (![service respondsToSelector:
              NSSelectorFromString(@"refreshPosterDescriptorsForExtension:completion:")]) {
            TXLog(@"[PRS] PRSService 不支持 refreshPosterDescriptorsForExtension:completion:");
            [self tx_fetchExtension:service extension:extensionIdentifier completion:completion];
            return;
        }

        TXLog(@"[PRS] 请求 PosterBoard 重扫扩展 %@", extensionIdentifier);
        [(id<TXPRSService>)service refreshPosterDescriptorsForExtension:extensionIdentifier
                                                            completion:^(id result) {
            TXLog(@"[PRS] 重扫回调: %@", result);
            [self tx_fetchExtension:service extension:extensionIdentifier completion:completion];
        }];
    });
}

/// 回读该扩展当前的 descriptor 列表 —— 用来验证我们装进去的到底注册上没有
- (void)tx_fetchExtension:(id)service
                extension:(NSString *)extensionIdentifier
               completion:(void (^)(NSUInteger, NSArray *))completion {
    if (![service respondsToSelector:
          NSSelectorFromString(@"fetchPosterDescriptorsForExtension:completion:")]) {
        TXLog(@"[PRS] 无法拉取 descriptor 列表");
        if (completion) {
            completion(0, nil);
        }
        return;
    }

    [(id<TXPRSService>)service fetchPosterDescriptorsForExtension:extensionIdentifier
                                                      completion:^(id result) {
        NSArray *list = [result isKindOfClass:NSArray.class] ? result : nil;
        TXLog(@"[PRS] 扩展 %@ 当前 descriptor 数量=%lu",
              extensionIdentifier, (unsigned long)list.count);

        NSMutableArray *identifiers = [NSMutableArray array];
        for (id one in list) {
            NSString *identifier = [one respondsToSelector:@selector(identifier)]
                ? [one identifier] : nil;
            if (identifier.length) {
                [identifiers addObject:identifier];
            }
            TXLog(@"[PRS]   - %@ identifier=%@", NSStringFromClass([one class]),
                  identifier ?: @"(无)");
        }
        if (completion) {
            completion(list.count, [identifiers copy]);
        }
    }];
}

#pragma mark - 装完自动生效

- (void)applyDescriptor:(NSString *)descriptorIdentifier
              extension:(NSString *)extensionIdentifier
             completion:(void (^)(BOOL, NSString *))completion {
    if (!descriptorIdentifier.length || !extensionIdentifier.length) {
        if (completion) {
            completion(NO, @"缺少 descriptor identifier 或扩展 ID");
        }
        return;
    }

    // 整条链路的结束状态用串行队列保护，保证 completion 只回调一次
    dispatch_queue_t stateQueue =
        dispatch_queue_create("com.axs.tendiesx.prs.apply", DISPATCH_QUEUE_SERIAL);
    __block BOOL finished = NO;
    void (^finish)(BOOL, NSString *) = ^(BOOL applied, NSString *detail) {
        dispatch_async(stateQueue, ^{
            if (finished) {
                return;
            }
            finished = YES;
            TXLog(@"[PRS] 生效链路结束: %@（%@）", applied ? @"成功" : @"失败", detail ?: @"");
            if (completion) {
                completion(applied, detail);
            }
        });
    };

    // 看门狗：PRS 不回调也要给用户一个结果，不能一直等
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(12.0 * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        finish(NO, @"PRS 无响应（12 秒超时）");
    });

    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id service = TXPRSServiceInstance();
        if (!service) {
            finish(NO, @"本系统没有 PRSService");
            return;
        }
        [self tx_rescan:service
             identifier:descriptorIdentifier
              extension:extensionIdentifier
                 finish:finish];
    });
}

- (void)tx_rescan:(id)service
       identifier:(NSString *)identifier
        extension:(NSString *)extension
           finish:(void (^)(BOOL, NSString *))finish {
    if (![service respondsToSelector:
          NSSelectorFromString(@"refreshPosterDescriptorsForExtension:completion:")]) {
        [self tx_create:service identifier:identifier extension:extension finish:finish];
        return;
    }

    TXLog(@"[PRS] 生效：先重扫扩展 %@，确保新 descriptor 已被看见", extension);
    [(id<TXPRSService>)service refreshPosterDescriptorsForExtension:extension
                                                        completion:^(id result) {
        TXLog(@"[PRS] 生效：重扫回调 %@", result);
        [self tx_create:service identifier:identifier extension:extension finish:finish];
    }];
}

- (void)tx_create:(id)service
       identifier:(NSString *)identifier
        extension:(NSString *)extension
           finish:(void (^)(BOOL, NSString *))finish {
    if (![service respondsToSelector:
          NSSelectorFromString(@"createPosterConfigurationForProviderIdentifier:"
                               @"posterDescriptorIdentifier:completion:")]) {
        finish(NO, @"PRSService 不支持创建配置");
        return;
    }

    TXLog(@"[PRS] 生效：创建配置（扩展=%@ descriptor=%@）", extension, identifier);
    [(id<TXPRSService>)service createPosterConfigurationForProviderIdentifier:extension
                                                  posterDescriptorIdentifier:identifier
                                                                   completion:^(id result) {
        if (TXIsPosterConfiguration(result)) {
            TXLog(@"[PRS] 生效：配置已创建 %@", result);
            [self tx_select:service
              configuration:result
                 identifier:identifier
                  extension:extension
                     finish:finish];
        } else {
            finish(NO, [NSString stringWithFormat:@"创建配置失败（返回 %@：%@）",
                        NSStringFromClass([result class]), result ?: @"nil"]);
        }
    }];
}

- (void)tx_select:(id)service
    configuration:(id)configuration
       identifier:(NSString *)identifier
        extension:(NSString *)extension
           finish:(void (^)(BOOL, NSString *))finish {
    if (![service respondsToSelector:NSSelectorFromString(@"updateToSelectedConfiguration:completion:")]) {
        finish(NO, @"PRSService 不支持选中配置");
        return;
    }

    TXLog(@"[PRS] 生效：设为当前壁纸…");
    [(id<TXPRSService>)service updateToSelectedConfiguration:configuration
                                                 completion:^(id result) {
        TXLog(@"[PRS] 生效：选中回调 %@ (%@)", result, NSStringFromClass([result class]));
        [self tx_refreshSnapshot:service identifier:identifier extension:extension];
        [self tx_verify:service extension:extension finish:finish];
    }];
}

/// 刷图库预览图（best-effort，失败只打日志）
- (void)tx_refreshSnapshot:(id)service
                identifier:(NSString *)identifier
                 extension:(NSString *)extension {
    if (![service respondsToSelector:
          NSSelectorFromString(@"refreshSnapshotForGalleryItemsMatchingDescriptorIdentifier:"
                               @"extensionIdentifier:completion:")]) {
        return;
    }
    TXLog(@"[PRS] 生效：刷新图库预览图");
    [(id<TXPRSService>)service refreshSnapshotForGalleryItemsMatchingDescriptorIdentifier:identifier
                                                                   extensionIdentifier:extension
                                                                            completion:^(id result) {
        TXLog(@"[PRS] 预览图刷新回调: %@", result);
    }];
}

/// 回读当前选中的配置，确认真的换过去了
- (void)tx_verify:(id)service
        extension:(NSString *)extension
           finish:(void (^)(BOOL, NSString *))finish {
    if (![service respondsToSelector:NSSelectorFromString(@"fetchSelectedConfiguration:")]) {
        finish(YES, @"已请求生效（本系统无法回读确认）");
        return;
    }

    [(id<TXPRSService>)service fetchSelectedConfiguration:^(id configuration) {
        NSString *provider = nil;
        if ([configuration respondsToSelector:@selector(providerBundleIdentifier)]) {
            provider = [configuration providerBundleIdentifier];
        }
        BOOL matched = [provider isEqualToString:extension];
        TXLog(@"[PRS] 生效：回读当前配置 %@ provider=%@ 匹配=%@",
              configuration, provider ?: @"(无)", matched ? @"是" : @"否");

        finish(matched,
               matched
                   ? [NSString stringWithFormat:@"已自动设为当前壁纸（%@）", extension]
                   : [NSString stringWithFormat:@"已请求生效，但回读到的 provider=%@（请到墙纸里确认）",
                      provider ?: @"(无)"]);
    }];
}

@end
