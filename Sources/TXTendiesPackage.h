//
//  TXTendiesPackage.h
//  .tendies 容器模型
//
//  目录约定（清理后只剩一个根目录）：
//    /var/mobile/Library/TendiesX/              投放目录 —— 用 Filza 把 .tendies 丢这里
//    /var/mobile/Library/TendiesX/Library/<名字>/  素材库 —— 自动解压结果，长期保留
//
//  .tendies 不是 Apple 系统格式，是 Nugget 打包的 PosterBoard 海报描述包（zip）。
//  实测形态：
//    1) video 型：内含 mp4/mov，可用 AVPlayer 循环播放
//    2) ca 型   ：内含若干 .ca 包（CoreAnimation CAAML + JS + 图片，**没有视频**），
//                 目前只能取一张静态兜底图，.ca 渲染待接入
//  所以解析不做任何固定目录假设，一律递归扫描后按内容判定类型。
//

#import <Foundation/Foundation.h>

/// 壁纸类型
extern NSString *const TXWallpaperKindVideo;    // 含视频
extern NSString *const TXWallpaperKindCA;       // 只有 CoreAnimation .ca 包
extern NSString *const TXWallpaperKindImage;    // 只有静态图
extern NSString *const TXWallpaperKindUnknown;

@interface TXTendiesPackage : NSObject

@property (nonatomic, copy,   readonly) NSString *path;         // 素材目录（素材库里的解压结果）
@property (nonatomic, copy,   readonly) NSString *displayName;  // 展示名
@property (nonatomic, copy,   readonly) NSString *kind;         // 见上方 TXWallpaperKind*
@property (nonatomic, copy,   readonly) NSURL *videoURL;        // 主视频（kind=video）
@property (nonatomic, copy,   readonly) NSURL *fallbackImageURL;// 静态兜底图（kind=ca/image）
@property (nonatomic, copy,   readonly) NSDictionary *descriptor; // Wallpaper.plist / providerInfo.plist
@property (nonatomic, copy,   readonly) NSArray<NSString *> *caBundlePaths; // .ca 包目录

#pragma mark - 目录与导入

/// 素材库目录（解压结果）
+ (NSString *)libraryDirectory;

/// 投放目录（用 Filza 把 .tendies 丢这里）
+ (NSString *)inboxDirectory;

/// 扫描投放目录里的 .tendies：解压进素材库，成功后删掉源文件。
/// 返回「源文件路径 -> 素材库目录」映射，供调用方把偏好改指到解压目录。
+ (NSDictionary<NSString *, NSString *> *)importPendingPackagesWithSourceRemoval:(BOOL)removeSource;

/// 素材库里的全部壁纸目录（按路径排序）
+ (NSArray<NSString *> *)availablePackagePaths;

/// 第一个可用项（自动发现）
+ (NSString *)firstAvailablePackagePath;

/// 解析一个素材目录
+ (instancetype)packageAtPath:(NSString *)path;

@end
