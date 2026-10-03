//
//  TXPosterService.h
//  与 PosterBoard 的 PRS 服务通信（best-effort：全部异步，失败只打日志）。
//
//  依据 Reference/Private/PRSService.h（iOS 16.5 dump）用到这些：
//    -refreshPosterDescriptorsForExtension:completion:          让 PosterBoard 重扫某扩展
//    -fetchPosterDescriptorsForExtension:completion:            回读该扩展注册的 descriptor 列表
//    -createPosterConfigurationForProviderIdentifier:posterDescriptorIdentifier:completion:  按扩展+descriptor 建配置
//    -updateToSelectedConfiguration:completion:                 设为当前壁纸
//    -fetchSelectedConfiguration:                               回读当前壁纸配置（用来确认真的生效了）
//    -refreshSnapshotForGalleryItemsMatchingDescriptorIdentifier:extensionIdentifier:completion:  刷图库预览
//
//  注意：
//  1) PRSService 是 XPC 客户端，会建连接，所以一律在后台队列执行，绝不阻塞 SpringBoard 主线程；
//  2) dump 里所有 completion 都是 id /* block */，参数个数未知，所以一律只读回调的**第一个参数**，
//     再用 isKindOfClass 判断它到底是结果对象还是 NSError —— 这样无论真实签名是什么都不会误判。
//

#import <Foundation/Foundation.h>

@interface TXPosterService : NSObject

+ (instancetype)sharedService;

/// 请求重扫指定扩展，并回读它当前的 descriptor 数量/标识。
/// completion 在后台队列回调，可能不会触发（服务不可用时），所以主流程必须有兜底。
- (void)refreshExtension:(NSString *)extensionIdentifier
              completion:(void (^)(NSUInteger count, NSArray *identifiers))completion;

/// 装完自动生效：重扫 → 按 identifier 建配置 → 设为当前壁纸 → 刷预览 → 回读确认。
/// 全链路 best-effort，每一步都写 [PRS] 日志；带 12 秒看门狗，PRS 不回调也会给出结果。
- (void)applyDescriptor:(NSString *)descriptorIdentifier
              extension:(NSString *)extensionIdentifier
             completion:(void (^)(BOOL applied, NSString *detail))completion;

@end
