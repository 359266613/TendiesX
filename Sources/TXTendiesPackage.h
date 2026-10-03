//
//  TXTendiesPackage.h
//  .tendies 容器模型
//
//  目录约定（与社区其他插件一致，素材目录保留 .tendies 后缀）：
//    /var/mobile/Library/TendiesX/气质美乳女菩萨.tendies      ← 投放中的压缩包（导入成功后删掉）
//    /var/mobile/Library/TendiesX/气质美乳女菩萨.tendies/     ← 解压后的素材目录（同名，但是目录）
//
//  .tendies 不是 Apple 系统格式，是 Nugget/PosterBoard 的「描述符包」（zip）：
//    descriptors/<UUID>/ + versions/<n>/contents/...  + Wallpaper.plist / providerInfo.plist
//  实测两种形态：
//    1) video 型：内含 mp4/mov，可用 AVPlayer 循环播放
//    2) ca 型   ：内含若干 .ca 包（CoreAnimation CAAML + JS + 图片，**没有视频**），
//                 目前只能取一张静态兜底图；.ca 真正渲染需要交给 PosterBoard
//
//  解析不做任何固定目录假设，一律递归扫描后按内容判定类型。
//

#import <Foundation/Foundation.h>

/// 壁纸类型
extern NSString *const TXWallpaperKindVideo;    // 含视频
extern NSString *const TXWallpaperKindCA;       // 只有 CoreAnimation .ca 包
extern NSString *const TXWallpaperKindImage;    // 只有静态图
extern NSString *const TXWallpaperKindUnknown;

@interface TXTendiesPackage : NSObject

@property (nonatomic, copy,   readonly) NSString *path;         // 素材目录
@property (nonatomic, copy,   readonly) NSString *displayName;  // 展示名
@property (nonatomic, copy,   readonly) NSString *kind;         // 见上方 TXWallpaperKind*
@property (nonatomic, copy,   readonly) NSURL *videoURL;        // 主视频（kind=video）
@property (nonatomic, copy,   readonly) NSURL *fallbackImageURL;// 静态兜底图（kind=ca/image）
@property (nonatomic, copy,   readonly) NSDictionary *descriptor; // Wallpaper.plist / providerInfo.plist
@property (nonatomic, copy,   readonly) NSArray<NSString *> *caBundlePaths; // .ca 包目录

#pragma mark - 目录与导入

/// 素材根目录：/var/mobile/Library/TendiesX
+ (NSString *)storageDirectory;

/// 扫描根目录里的 xxx.tendies 压缩包：解压成同名目录（xxx.tendies/），成功后删掉压缩包。
/// 返回「压缩包路径 -> 解压目录」映射，供调用方把偏好改指过去。
+ (NSDictionary<NSString *, NSString *> *)importPendingPackagesWithSourceRemoval:(BOOL)removeSource;

/// 根目录下全部素材目录（xxx.tendies 是目录的那些），按路径排序
+ (NSArray<NSString *> *)availablePackagePaths;

/// 第一个可用项（自动发现）
+ (NSString *)firstAvailablePackagePath;

/// 解析一个素材目录
+ (instancetype)packageAtPath:(NSString *)path;

@end
