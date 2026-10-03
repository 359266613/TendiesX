//
//  Worker.xm
//  SpringBoard 侧 worker —— route A 专用。
//
//  它**不 hook 任何东西**，也不渲染任何东西：
//  只监听设置面板发来的 Darwin 通知，然后做两件文件操作：
//    1) 把 .tendies 解包（如果是压缩包）
//    2) 把 descriptor 复制进 PosterBoard 的海报存储，重启 PosterBoard 重扫
//
//  为什么不放在设置面板里做：写别的 App 容器会撞沙盒；SpringBoard 的沙盒权限足够，
//  且我们已实测它能读写该目录（属主 mobile、权限 0777）。
//

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#import "TXLogger.h"
#import "TXPreferences.h"
#import "TXPosterInstaller.h"

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

        NSArray<NSString *> *installed =
            [TXPosterInstaller.sharedInstaller installFromPath:source];

        NSString *message = installed.count
            ? [NSString stringWithFormat:@"已安装 %lu 个海报", (unsigned long)installed.count]
            : @"安装失败，详见日志 TendiesX.log 里 [A] 开头的行";
        [prefs updateLastInstallMessage:message];
        TXLog(@"[worker] 安装结束: %@", message);
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

    CFNotificationCenterRef center = CFNotificationCenterGetDarwinNotifyCenter();
    CFNotificationCenterAddObserver(center, NULL, TXHandleInstallPoster,
                                    (__bridge CFStringRef)kTXNotifyInstallPoster,
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);
    CFNotificationCenterAddObserver(center, NULL, TXHandleReload,
                                    CFSTR("com.axs.tendiesx/ReloadPrefs"),
                                    NULL, CFNotificationSuspensionBehaviorDeliverImmediately);

    TXLog(@"worker 就绪：等待设置面板的安装请求");
}
