//
//  TXTendiesPackage.h
//  .tendies 容器模型
//
//  重要：.tendies 不是 Apple 系统格式，是 Nugget 打包的 PosterBoard 海报描述包（zip）。
//  实测两种形态：
//    1) video 型：contents/ 下有 mp4/mov，可直接用 AVPlayer 播放
//    2) ca 型   ：contents/<name>.wallpaper/ 下是若干 .ca 包
//                （CoreAnimation CAAML + JS + 图片资源，**没有视频**），
//                需要按 CoreAnimation 的资源格式渲染，目前仅能取静态兜底图
//
//  所以解析不做任何「固定目录」假设，一律递归扫描后按内容判定类型。
//

#import <Foundation/Foundation.h>

/// 壁纸类型
extern NSString *const TXWallpaperKindVideo;    // 含视频，可循环播放
extern NSString *const TXWallpaperKindCA;       // CoreAnimation .ca 包
extern NSString *const TXWallpaperKindImage;    // 只有静态图
extern NSString *const TXWallpaperKindUnknown;

@interface TXTendiesPackage : NSObject

@property (nonatomic, copy,   readonly) NSString *path;         // 原始容器/目录路径
@property (nonatomic, copy,   readonly) NSString *rootDirectory;// 实际解析根目录（解包后）
@property (nonatomic, copy,   readonly) NSString *displayName;  // 展示名
@property (nonatomic, copy,   readonly) NSString *kind;         // 见上方 TXWallpaperKind*
@property (nonatomic, copy,   readonly) NSURL *videoURL;        // 主视频（kind=video）
@property (nonatomic, copy,   readonly) NSURL *fallbackImageURL;// 静态兜底图（kind=ca/image）
@property (nonatomic, copy,   readonly) NSDictionary *descriptor; // 描述 plist
@property (nonatomic, copy,   readonly) NSArray<NSString *> *caBundlePaths; // .ca 包目录
@property (nonatomic, assign, readonly) NSTimeInterval stillTime;
@property (nonatomic, assign, readonly) BOOL looping;
@property (nonatomic, assign, readonly) BOOL unpackedFromZip;   // 是否由 zip 解包而来

/// 路径以 .tendies 结尾即认为是容器
+ (BOOL)isTendiesURL:(NSURL *)url;

/// 支持两种输入：已解包目录 / .tendies zip 文件（zip 会解到缓存目录）
+ (instancetype)packageAtPath:(NSString *)path;

#pragma mark - 目录约定（设置面板也用它）
//
//  投放目录  /var/mobile/Library/TendiesX   ← 用 Filza 把 .tendies 丢进来
//  素材库    /var/mobile/Library/TendiesX/Library/<名字>/  ← 自动解压结果，长期保留
//  备用投放  /var/mobile/Media/TendiesX
//

/// 素材库目录（导入后的解压结果）
+ (NSString *)libraryDirectory;

/// 投放目录列表
+ (NSArray<NSString *> *)inboxDirectories;

/// 扫描投放目录里的 .tendies：解压到素材库，成功后删除源文件。
/// 返回「源文件路径 -> 素材库目录」映射（用于把偏好改指到解压目录）。
+ (NSDictionary<NSString *, NSString *> *)importPendingPackagesWithSourceRemoval:(BOOL)removeSource;

/// 扫描目录（素材库 → 投放目录 → Media 素材库 → 旧版缓存）
+ (NSArray<NSString *> *)searchDirectories;

/// 扫描目录里所有可用的 .tendies（zip 文件或已解包目录），按路径排序
+ (NSArray<NSString *> *)availablePackagePaths;

/// 第一个可用项（未配置 ActivePackagePath 时的自动发现）
+ (NSString *)firstAvailablePackagePath;

@end
