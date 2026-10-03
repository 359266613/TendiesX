//
//  Wallpaper.xm
//  Hook 层：只做「取实例 / 转发调用」，业务全在 TXWallpaperManager。
//  方法签名来自 Headers/TXWallpaper.h（手写最小声明）。
//

#import "TendiesX.h"
#import "TXWallpaperManager.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import "TXPosterStoreProbe.h"
#import <objc/runtime.h>

#pragma mark - 1. 壁纸视图：挂载 / 布局 / 显隐 / 前后台生命周期

%hook PBUIWallpaperView

- (void)didMoveToWindow {
    %orig;
    if (self.window) {
        [TXWallpaperManager.sharedManager attachToWallpaperView:self];
    }
}

- (void)layoutSubviews {
    %orig;
    [TXWallpaperManager.sharedManager layoutWallpaperWithView:self];
}

// 诊断用：下拉通知中心 / 上滑多任务时，系统可能会隐藏壁纸视图，
// 这就是「壁纸闪一下就没」的原因。打出来才能确认。
- (void)setHidden:(BOOL)hidden {
    %orig;
    if (hidden) {
        TXLog(@"hook: %@ setHidden=%d (variant=%lld)", NSStringFromClass(self.class), hidden,
              (long long)self.variant);
    }
}

- (void)prepareToAppear {
    %orig;
    TXLog(@"hook: %@ -prepareToAppear", NSStringFromClass(self.class));
    [TXWallpaperManager.sharedManager resumeWallpaperWithView:self];
}

- (void)prepareToDisappear {
    %orig;
    TXLog(@"hook: %@ -prepareToDisappear", NSStringFromClass(self.class));
    [TXWallpaperManager.sharedManager pauseWallpaperWithView:self];
}

%end

#pragma mark - 2. 壁纸容器控制器：主挂载点 + 壁纸变更

%hook PBUIWallpaperViewController

// 容器布局完成后把自定义渲染层挂到 _wallpaperContainerView。
// 这是 Zone 的做法：壁纸视图的 contentView 在 iOS 16 上可能是
// PBUIFakeBlurView / PBUISnapshotReplicaView 这类副本，挂进去会"松手就消失"。
- (void)viewDidLayoutSubviews {
    %orig;

    UIView *container = nil;
    @try {
        container = [self valueForKey:@"wallpaperContainerView"];
    } @catch (NSException *exception) {
        // KVC 取不到就退回壁纸视图那条路
    }
    if (container) {
        [TXWallpaperManager.sharedManager attachToWallpaperContainerView:container];
    }
}

- (void)noteWallpapersDidUpdate {
    %orig;
    TXLog(@"hook: PBUIWallpaperViewController -noteWallpapersDidUpdate");
    [TXWallpaperManager.sharedManager reloadFromDisk];
}

- (void)_handleWallpaperChangedForVariant:(long long)variant {
    %orig;
    TXLog(@"hook: 壁纸变更 variant=%lld", variant);
    [TXWallpaperManager.sharedManager reloadFromDisk];
}

%end

#pragma mark - 3. 锁屏生命周期

%hook SBLockScreenViewControllerBase

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    [TXWallpaperManager.sharedManager setLockScreenActive:YES];
}

- (void)viewWillDisappear:(BOOL)animated {
    %orig;
    [TXWallpaperManager.sharedManager setLockScreenActive:NO];
}

%end

#pragma mark - 4. 全局事件（可选，主屏全区域交互时用）

%hook UIApplication

- (void)sendEvent:(UIEvent *)event {
    %orig;
    if (TXPreferences.sharedInstance.interactionEnabled) {
        [TXWallpaperManager.sharedManager handleEvent:event];
    }
}

%end

%ctor {
    TXLog(@"======== TendiesX 已加载 ========");
    TXLog(@"系统 %@ (%@) | 日志文件: %@",
          UIDevice.currentDevice.systemVersion,
          UIDevice.currentDevice.model,
          TXLogFilePath() ?: @"(解析失败，只能看系统日志)");

    Class cls = objc_getClass("PBUIWallpaperView");
    TXLog(@"PBUIWallpaperView = %@", cls ? NSStringFromClass(cls) : @"(缺失)");
    if (!cls) {
        TXLog(@"警告: 本系统没有 PBUIWallpaperView，壁纸 hook 不会生效");
    }
    TXLog(@"CAPackage = %@ | BSUICAPackageView = %@",
          objc_getClass("CAPackage") ? @"有" : @"缺失",
          objc_getClass("BSUICAPackageView") ? @"有" : @"缺失");

    // sharedManager 首次访问时内部就会 reloadFromDisk，把偏好与解析结果打进日志
    (void)TXWallpaperManager.sharedManager;

    // 探测系统海报存储落点（确定 ca 型 .tendies 的安装位置后即可去掉）
    TXProbePosterStore();
}
