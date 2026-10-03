//
//  TXPosterInstaller.h
//  route A 的全部实现：把 .tendies 的 descriptor 装进系统海报库，
//  之后由 PosterBoard 的扩展进程原生渲染（主屏 / 锁屏 / AOD / 视差 / 景深全部由系统负责）。
//
//  为什么必须这样做（而不是自己叠图层）：
//  1) documentation.md 写明 .tendies 就是 "PosterBoard 的还原结构"，不是运行时资源包；
//  2) 自己叠 CAAML 会把多个图层树带进 SpringBoard，实测直接把设备拖卡；
//  3) 自己叠的图层在 iOS 16 上会被系统的快照/portal 副本取代（"下拉可见、松手消失"）。
//
//  实测确认（iOS 16.5）：
//    <商店根>/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/
//    - 59 是 iOS 16 的结构版本，iOS 17+ 是 61（.tendies 里可能自带 61，需映射）
//    - 属主 mobile、权限 0777，SpringBoard 可直接写，不需要 root 守护进程
//    - descriptor 内的文件都不引用 UUID（逐个核对过），所以可以安全随机化 UUID
//

#import <Foundation/Foundation.h>

@interface TXPosterInstaller : NSObject

+ (instancetype)sharedInstaller;

/// 安装一个素材。path 可以是 .tendies 压缩包，也可以是已解包的目录。
/// @return 实际写入的 descriptor 目录路径（空数组表示失败，日志里有原因）
- (NSArray<NSString *> *)installFromPath:(NSString *)path;

/// 海报存储根目录；读不到返回 nil
+ (NSString *)storeRoot;

/// 设备对应的结构版本目录（iOS 16 → 59，iOS 17+ → 61）；读不到返回 nil
+ (NSString *)storeVersionDir;

@end
