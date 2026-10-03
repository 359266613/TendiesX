//
//  TXPosterService.h
//  与 PosterBoard 的 PRS 服务通信（best-effort：全部异步，失败只打日志）。
//
//  依据 Reference/Private/PRSService.h（iOS 16.5 dump）：
//    -refreshPosterDescriptorsForExtension:completion:   让 PosterBoard 重扫某扩展的 descriptors
//    -fetchPosterDescriptorsForExtension:completion:     拉取该扩展当前注册的 descriptor 列表
//
//  这两件事的价值：
//  1) 重扫比 killall PosterBoard 正规、也快得多（不用等进程重启）；
//  2) 拉取列表能**直接确认**我们装进去的 descriptor 有没有被 PosterBoard 收录 ——
//     这是"PosterBoard 到底会不会扫描 descriptors 目录"这个问题的答案。
//
//  注意：PRSService 会建 XPC 连接，所以一律在后台队列执行，绝不阻塞 SpringBoard 主线程。
//

#import <Foundation/Foundation.h>

@interface TXPosterService : NSObject

+ (instancetype)sharedService;

/// 请求重扫指定扩展，并回读它当前的 descriptor 数量/标识。
/// completion 在后台队列回调，可能不会触发（服务不可用时），所以主流程必须有兜底。
- (void)refreshExtension:(NSString *)extensionIdentifier
              completion:(void (^)(NSUInteger count, NSArray *identifiers))completion;

@end
