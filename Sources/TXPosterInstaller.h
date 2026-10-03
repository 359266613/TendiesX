//
//  TXPosterInstaller.h
//  route A：把 .tendies 的 descriptor 装进系统海报库，让 PosterBoard 原生渲染。
//
//  为什么这是"正道"：
//  documentation.md 写明 .tendies 就是 PosterBoard 的还原结构，不是运行时资源包。
//  装进去之后，主屏 / 锁屏 / AOD / 视差 / 景深 / 切换动画全部由系统负责，
//  渲染完全不经过 SpringBoard 里的我们 —— 既不会卡，也不会"松手就消失"。
//
//  实测确认（iOS 16.5）：
//    <商店根>/59/Extensions/com.apple.WallpaperKit.CollectionsPoster/descriptors/<UUID>/
//    其中 59 是 iOS 16 的结构版本（iOS 17+ 是 61），属主 mobile、权限 0777，可直接写。
//
//  descriptor 目录内的文件都不引用 UUID（已逐个核对过），所以 UUID 可以随机化。
//

#import <Foundation/Foundation.h>

@interface TXPosterInstaller : NSObject

+ (instancetype)sharedInstaller;

/// 把一个「已解包的 .tendies 目录」安装进系统海报库。
/// 支持两种格式：
///   descriptors/<UUID>/...                       （descriptor 格式）
///   Container/.../Extensions/<扩展ID>/descriptors/<UUID>/...   （container 格式，自带版本号会映射到设备实际版本）
/// @return 实际写入的 descriptor 目录路径数组（空数组表示没装成，日志里有原因）
- (NSArray<NSString *> *)installPackageAtPath:(NSString *)packagePath;

@end
