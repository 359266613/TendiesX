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

#pragma mark - 容器查找

//  关键修正：原来用 [vc valueForKey:@"wallpaperContainerView"] 读容器，
//  但 UIKit 私有类普遍把 accessInstanceVariablesDirectly 关掉，KVC 会失败并被
//  @try/@catch 静默吞掉 —— 这就是日志里「主壁纸容器」一次都没出现的原因。
//  改成直接按名字读实例变量（沿继承链找），不依赖 KVC 策略。
static void TXTryAttachContainer(id vc) {
    if (!vc) {
        return;
    }
    UIView *container = [TXWallpaperManager tx_ivarValue:vc named:@"_wallpaperContainerView"];
    if (!container) {
        return;   // 找不到就等启动几秒后的诊断日志说明
    }
    [TXWallpaperManager.sharedManager attachToWallpaperContainerView:container];
}

#pragma mark - 1. 壁纸视图：退路挂载 / 布局 / 显隐 / 前后台生命周期

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

// 诊断用：下拉通知中心 / 上滑多任务时系统可能隐藏壁纸视图
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

// 三个时机都试，任一个先到就挂上（viewDidLoad 时容器可能还没建，layout 后一定有）
- (void)viewDidLoad {
    %orig;
    TXLog(@"hook: PBUIWallpaperViewController -viewDidLoad");
    TXTryAttachContainer(self);
}

- (void)viewDidLayoutSubviews {
    %orig;
    TXTryAttachContainer(self);
}

- (void)viewDidAppear:(BOOL)animated {
    %orig;
    TXLog(@"hook: PBUIWallpaperViewController -viewDidAppear");
    TXTryAttachContainer(self);
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

    Class viewClass = objc_getClass("PBUIWallpaperView");
    Class vcClass = objc_getClass("PBUIWallpaperViewController");
    TXLog(@"PBUIWallpaperView = %@ | PBUIWallpaperViewController = %@",
          viewClass ? @"有" : @"缺失", vcClass ? @"有" : @"缺失");
    TXLog(@"BSUICAPackageView = %@",
          objc_getClass("BSUICAPackageView") ? @"有" : @"缺失");

    // sharedManager 首次访问时内部就会 reloadFromDisk
    (void)TXWallpaperManager.sharedManager;

    // 探测系统海报存储落点（确定 descriptor 安装位置用，可随时去掉）
    TXProbePosterStore();

    // 6 秒后打一次诊断：容器到底找没找到、渲染层现在挂在哪
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(6.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [TXWallpaperManager.sharedManager logContainerDiagnostics];
    });
}
