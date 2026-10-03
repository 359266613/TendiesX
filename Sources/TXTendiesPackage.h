//
//  TXTendiesPackage.h
//  .tendies 容器模型
//
//  重要：.tendies 不是 Apple 系统格式，是 Nugget 自定义的 zip 容器，
//  解包后内部为 PosterBoard 风格的 versions/<n>/contents/ 结构 + 描述 plist + 视频。
//  系统不认这个格式，解析必须自己实现。
//

#import <Foundation/Foundation.h>

@interface TXTendiesPackage : NSObject

@property (nonatomic, copy,   readonly) NSString *path;         // 容器/目录路径
@property (nonatomic, copy,   readonly) NSString *displayName;  // 展示名
@property (nonatomic, copy,   readonly) NSURL *videoURL;        // 主视频
@property (nonatomic, copy,   readonly) NSURL *thumbnailURL;    // 可选缩略图
@property (nonatomic, copy,   readonly) NSDictionary *descriptor; // 描述 plist
@property (nonatomic, assign, readonly) NSTimeInterval stillTime;
@property (nonatomic, assign, readonly) BOOL looping;
@property (nonatomic, assign, readonly) BOOL unpackedFromZip;   // 是否由 zip 解包而来

/// 路径以 .tendies 结尾即认为是容器
+ (BOOL)isTendiesURL:(NSURL *)url;

/// 支持两种输入：已解包目录 / .tendies zip 文件（zip 会解到缓存目录）
+ (instancetype)packageAtPath:(NSString *)path;

#pragma mark - 目录约定（设置面板也用它）

/// 扫描目录：/var/mobile/Library/TendiesX、/var/mobile/Media/TendiesX、解包缓存目录
+ (NSArray<NSString *> *)searchDirectories;

/// 扫描目录里所有可用的 .tendies（zip 文件或已解包目录），按路径排序
+ (NSArray<NSString *> *)availablePackagePaths;

/// 第一个可用项（未配置 ActivePackagePath 时的自动发现）
+ (NSString *)firstAvailablePackagePath;

@end
