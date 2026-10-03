//
//  Wallpaper.xm
//  Hook 层：只做「取实例 / 转发调用」，业务全在 TXWallpaperManager。
//  所有方法签名都来自 Headers/Private 下清洗过的私有头。
//

#import "TendiesX.h"
#import "TXWallpaperManager.h"
#import "TXPreferences.h"
#import <objc/runtime.h>

#pragma mark - 1. 壁纸视图：挂载 / 布局 / 前后台生命周期

%hook PBUIWallpaperView

- (void)didMoveToWindow {
    %orig;
    [TXWallpaperManager.sharedManager attachToWallpaperView:self];
}

- (void)layoutSubviews {
    %orig;
    [TXWallpaperManager.sharedManager layoutWallpaperWithView:self];
}

- (void)prepareToAppear {
    %orig;
    [TXWallpaperManager.sharedManager resumeWallpaperWithView:self];
}

- (void)prepareToDisappear {
    %orig;
    [TXWallpaperManager.sharedManager pauseWallpaperWithView:self];
}

%end

#pragma mark - 2. 壁纸变更：重新解析 .tendies

%hook PBUIWallpaperViewController

- (void)noteWallpapersDidUpdate {
    %orig;
    [TXWallpaperManager.sharedManager reloadFromDisk];
}

- (void)_handleWallpaperChangedForVariant:(long long)variant {
    %orig;
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
    Class cls = objc_getClass("PBUIWallpaperView");
    NSLog(@"[TendiesX] loaded, PBUIWallpaperView = %@", cls ? NSStringFromClass(cls) : @"(missing)");
}
