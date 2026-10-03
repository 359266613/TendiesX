//
//  TXPosterDiagnostics.h
//  装完之后的对比诊断：把「我们刚装进去的 descriptor」和「系统里 identifier 相同的其它 descriptor」
//  做文件级对比，并把两边的 Wallpaper.plist 打进日志。
//
//  为什么需要它：
//  壁纸能被应用、能显示，但"没有交互动画"这种问题无法靠猜 —— 必须知道我们的副本
//  跟系统自带的那一份（同一张壁纸，identifier 相同）到底差哪些文件、差什么配置。
//  另外 PosterBoard 会对装进去的 descriptor 做"迁移"（versions/0 → versions/1、2…），
//  所以再延迟 dump 一次，看它改了什么。
//

#import <Foundation/Foundation.h>

@interface TXPosterDiagnostics : NSObject

/// 对比：installedPath 是我们的新副本，同扩展下 identifier 相同的其它目录作为参照
+ (void)compareDescriptorAt:(NSString *)installedPath
                  extension:(NSString *)extensionIdentifier;

/// 延迟若干秒后重新 dump 同一个目录（看 PosterBoard 迁移后加了/改了什么）
+ (void)schedulePostMigrationDump:(NSString *)installedPath delay:(NSTimeInterval)delay;

@end
