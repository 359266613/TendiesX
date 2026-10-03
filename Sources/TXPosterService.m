#import "TXPosterService.h"
#import "TXLogger.h"

//  用协议声明（而不是 import dump 头）：dump 头里有一堆 @protocol / @class 引用，
//  直接 include 会编译不过。这里只声明我们真正调用的三个方法。
@protocol TXPRSService <NSObject>
- (void)refreshPosterDescriptorsForExtension:(id)extension
                                 sessionInfo:(id)sessionInfo
                                  completion:(void (^)(id result))completion;
- (void)refreshPosterDescriptorsForExtension:(id)extension
                                  completion:(void (^)(id result))completion;
- (void)fetchPosterDescriptorsForExtension:(id)extension
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

@implementation TXPosterService

+ (instancetype)sharedService {
    static TXPosterService *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[TXPosterService alloc] init];
    });
    return shared;
}

- (void)refreshExtension:(NSString *)extensionIdentifier
              completion:(void (^)(NSUInteger, NSArray *))completion {
    if (!extensionIdentifier.length) {
        if (completion) {
            completion(0, nil);
        }
        return;
    }

    // XPC 连接建立与调用都放后台，避免万一卡住影响 SpringBoard 主线程
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        id service = TXPRSServiceInstance();
        if (!service) {
            TXLog(@"[PRS] 本系统没有 PRSService，跳过重扫 —— 需要手动 respring 才会看到新壁纸");
            if (completion) {
                completion(0, nil);
            }
            return;
        }

        BOOL canRefresh = [service respondsToSelector:
                           NSSelectorFromString(@"refreshPosterDescriptorsForExtension:completion:")];
        if (!canRefresh) {
            TXLog(@"[PRS] PRSService 不支持 refreshPosterDescriptorsForExtension:completion:");
            [self tx_fetchExtension:extensionIdentifier completion:completion];
            return;
        }

        TXLog(@"[PRS] 请求 PosterBoard 重扫扩展 %@", extensionIdentifier);
        [(id<TXPRSService>)service refreshPosterDescriptorsForExtension:extensionIdentifier
                                                            completion:^(id result) {
            TXLog(@"[PRS] 重扫回调: %@", result);
            [self tx_fetchExtension:extensionIdentifier completion:completion];
        }];
    });
}

/// 回读该扩展当前的 descriptor 列表 —— 用来验证我们装进去的到底注册上没有
- (void)tx_fetchExtension:(NSString *)extensionIdentifier
               completion:(void (^)(NSUInteger, NSArray *))completion {
    id service = TXPRSServiceInstance();
    if (!service || ![service respondsToSelector:
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

@end
