//
//  Worker.xm
//  SpringBoard 侧 worker —— route A 专用。
//
//  它**不 hook 任何东西**，也不渲染任何东西：
//  只监听设置面板发来的 Darwin 通知，然后做三件事：
//    1) 把 .tendies 解包（如果是压缩包）
//    2) 把 descriptor 复制进 PosterBoard 的海报存储
//    3) 通过 PRSService 让 PosterBoard 重扫该扩展，并回读 descriptor 列表作验证
//
//  为什么文件操作放这里：写别的 App 容器会撞沙盒；SpringBoard 的沙盒权限足够，
//  且已实测它能读写该目录（属主 mobile、权限 0777）。
//  为什么 PRS 调用也放这里：PRSService 是 XPC 客户端，设置面板没有相应权限。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "TXLogger.h"
#import "TXPreferences.h"
#import "TXPosterInstaller.h"
#import "TXPosterService.h"

static NSString *const kTXNotifyInstallPoster = @"com.axs.tendiesx/InstallPoster";

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

        if (!installed.count) {
            [prefs updateLastInstallMessage:@"安装失败，详见日志里 [A] 开头的行"];
            return;
        }

        // 先给个即时反馈，避免面板等不到异步回调
        [prefs updateLastInstallMessage:[NSString stringWithFormat:
            @"已安装 %lu 个，正在让 PosterBoard 重扫…", (unsigned long)installed.count]];

        // 让系统重扫并回读列表 —— 这一步的日志 [PRS] 就是"装进去的到底有没有被收录"的答案
        [TXPosterService.sharedService refreshExtension:extension
                                             completion:^(NSUInteger count, NSArray *identifiers) {
            NSString *message = count
                ? [NSString stringWithFormat:@"已安装 %lu 个；该扩展现有 %lu 个壁纸（%@）",
                   (unsigned long)installed.count, (unsigned long)count,
                   identifiers.count ? [identifiers componentsJoinedByString:@", "] : @"无标识"]
                : [NSString stringWithFormat:@"已安装 %lu 个；但读不到该扩展的壁纸列表（看日志 [PRS] 行）",
                   (unsigned long)installed.count];
            [prefs updateLastInstallMessage:message];
            TXLog(@"[worker] 安装结束: %@", message);
        }];
    }
}

#pragma mark - 入口

%ctor {
    TXLog(@"======== TendiesX worker 已加载（route A：只装 descriptor，不渲染）========");
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
    TXLog(@"PRSService = %@（用来自动让 PosterBoard 重扫）",
          NSClassFromString(@"PRSService") ? @"有" : @"缺失");

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, TXHandleInstallPoster,
                                    (__bridge CFStringRef)kTXNotifyInstallPoster,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, TXHandleReload,
                                    CFSTR("com.axs.tendiesx/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    TXLog(@"worker 就绪：等待设置面板的安装请求");
}
