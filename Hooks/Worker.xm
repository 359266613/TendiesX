//
//  Worker.xm
//  SpringBoard 侧 worker —— route A 专用。
//
//  它**不 hook 任何东西**，也不渲染任何东西。监听设置面板发来的 Darwin 通知：
//
//    安装（InstallPoster）：
//      1) 解包 .tendies（如果是压缩包）
//      2) 把 descriptor 复制进 PosterBoard 的海报存储（重复安装=替换自己上次装的）
//      3) 让 PosterBoard 重扫该扩展，并回读 descriptor 列表作验证
//      4) 对比诊断：我们这份 vs 系统里同 identifier 的那份
//      5) 若开了「自动生效」：建配置 → 设为当前壁纸 → 刷预览 → 回读确认
//
//    清理（CleanupDuplicates）：
//      同一 identifier 只保留版本号最高的一份（系统自带那份），删掉其余低版本副本
//
//  为什么文件操作 + PRS 调用都放这里：写别的 App 容器会撞沙盒，PRSService 是 XPC 客户端；
//  SpringBoard 的权限足够，且已实测它能读写该目录（属主 mobile、权限 0777）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "TXLogger.h"
#import "TXPreferences.h"
#import "TXPosterInstaller.h"
#import "TXPosterService.h"

static NSString *const kTXNotifyInstallPoster = @"com.axs.tendiesx/InstallPoster";
static NSString *const kTXNotifyCleanup = @"com.axs.tendiesx/CleanupDuplicates";
static NSString *const kTXDefaultExtension = @"com.apple.WallpaperKit.CollectionsPoster";

#pragma mark - 串行化

/// 设置面板连点会连发通知（实测间隔只有 3ms），并发安装会把同一个目标目录写坏、
/// 还会在收藏里堆出一堆重复项。所有操作都串到这个队列上，一次只跑一个；
/// 顺带也不占用 SpringBoard 主线程。
static dispatch_queue_t TXWorkerQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.axs.tendiesx.worker", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

#pragma mark - 通知处理

static void TXHandleReload(CFNotificationCenterRef center,
                           void *observer,
                           CFStringRef name,
                           const void *object,
                           CFDictionaryRef userInfo) {
    [[TXPreferences sharedInstance] reload];
}

static void TXHandleInstallPoster(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    dispatch_async(TXWorkerQueue(), ^{
        @autoreleasepool {
            TXPreferences *prefs = TXPreferences.sharedInstance;
            [prefs reload];

            if (!prefs.enabled) {
                TXLog(@"[worker] 总开关已关，忽略安装请求");
                [prefs updateLastInstallMessage:@"插件总开关已关闭"];
                return;
            }

            NSString *source = prefs.sourcePath;
            TXLog(@"[worker] 收到安装请求: %@", source ?: @"(空)");
            if (!source.length) {
                [prefs updateLastInstallMessage:@"还没有选中素材"];
                return;
            }

            TXPosterInstaller *installer = TXPosterInstaller.sharedInstaller;
            NSArray<NSString *> *installed = [installer installFromPath:source];
            NSString *extension = installer.lastInstalledExtension;
            NSArray<NSString *> *identifiers = installer.lastInstalledDescriptorIdentifiers;

            if (!installed.count) {
                [prefs updateLastInstallMessage:@"安装失败，详见日志里 [A] 开头的行"];
                return;
            }

            // 先给即时反馈，避免面板等不到异步回调
            [prefs updateLastInstallMessage:[NSString stringWithFormat:
                @"已安装 %lu 个，正在让 PosterBoard 重扫…", (unsigned long)installed.count]];

            [TXPosterService.sharedService refreshExtension:extension
                                                 completion:^(NSUInteger count, NSArray *list) {
                NSString *base = count
                    ? [NSString stringWithFormat:@"已安装 %lu 个；该扩展现有 %lu 个壁纸（%@）",
                       (unsigned long)installed.count, (unsigned long)count,
                       list.count ? [list componentsJoinedByString:@", "] : @"无标识"]
                    : [NSString stringWithFormat:@"已安装 %lu 个；但读不到该扩展的壁纸列表（看日志 [PRS] 行）",
                       (unsigned long)installed.count];

                NSString *identifier = identifiers.firstObject;
                if (!prefs.autoApply || !identifier.length) {
                    [prefs updateLastInstallMessage:[base stringByAppendingString:
                        @"\n去「设置 → 墙纸 → 添加新墙纸 → 收藏」即可看到"]];
                    return;
                }

                TXLog(@"[worker] 自动生效: 扩展=%@ descriptor=%@", extension, identifier);
                [prefs updateLastInstallMessage:[base stringByAppendingString:@"；正在自动设为当前壁纸…"]];

                [TXPosterService.sharedService applyDescriptor:identifier
                                                     extension:extension
                                                    completion:^(BOOL applied, NSString *detail) {
                    NSString *final = [NSString stringWithFormat:@"%@\n%@",
                                       base, detail ?: (applied ? @"已自动生效" : @"未能自动生效")];
                    [prefs updateLastInstallMessage:final];
                    TXLog(@"[worker] 安装结束: %@", final);
                }];
            }];
        }
    });
}

static void TXHandleCleanup(CFNotificationCenterRef center,
                            void *observer,
                            CFStringRef name,
                            const void *object,
                            CFDictionaryRef userInfo) {
    dispatch_async(TXWorkerQueue(), ^{
        @autoreleasepool {
            TXPreferences *prefs = TXPreferences.sharedInstance;
            [prefs reload];
            TXLog(@"[worker] 收到清理重复项请求");
            [prefs updateLastInstallMessage:@"正在清理重复壁纸…"];

            NSUInteger removed = [TXPosterInstaller.sharedInstaller
                                  cleanupDuplicateInstallsInExtension:kTXDefaultExtension];

            // 删完让 PosterBoard 重扫，收藏列表才会跟着少掉那些项
            [TXPosterService.sharedService refreshExtension:kTXDefaultExtension
                                                 completion:^(NSUInteger count, NSArray *list) {
                NSString *message = [NSString stringWithFormat:
                    @"已清理 %lu 个重复项；该扩展现有 %lu 个壁纸",
                    (unsigned long)removed, (unsigned long)count];
                [prefs updateLastInstallMessage:message];
                TXLog(@"[worker] 清理结束: %@", message);
            }];
        }
    });
}

#pragma mark - 入口

%ctor {
    TXLog(@"======== TendiesX worker 已加载（route A：装 descriptor + 自动生效）========");
    TXLog(@"系统 %@ (%@) | 日志文件: %@",
          UIDevice.currentDevice.systemVersion,
          UIDevice.currentDevice.model,
          TXLogFilePath() ?: @"(解析失败，只能看系统日志)");

    NSString *storeRoot = [TXPosterInstaller storeRoot];
    NSString *versionDir = [TXPosterInstaller storeVersionDir];
    TXLog(@"海报存储 = %@ | 版本目录 = %@",
          storeRoot.lastPathComponent ?: @"(未找到)",
          versionDir.lastPathComponent ?: @"(未找到)");
    if (!versionDir) {
        TXLog(@"警告: 找不到海报存储，安装会失败（日志里会打 [A] 安装失败）");
    }
    TXLog(@"PRSService = %@（重扫 / 建配置 / 选中都靠它）",
          NSClassFromString(@"PRSService") ? @"有" : @"缺失");
    TXLog(@"PRSPosterConfiguration = %@",
          NSClassFromString(@"PRSPosterConfiguration") ? @"有" : @"缺失");

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, TXHandleInstallPoster,
                                    (__bridge CFStringRef)kTXNotifyInstallPoster,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, TXHandleCleanup,
                                    (__bridge CFStringRef)kTXNotifyCleanup,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, TXHandleReload,
                                    CFSTR("com.axs.tendiesx/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    TXLog(@"worker 就绪：等待设置面板的安装 / 清理请求");
}
