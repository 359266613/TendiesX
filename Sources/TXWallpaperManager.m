#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - 渲染层

@interface TXWallpaperRenderer : UIView
@property (nonatomic, strong) TXTendiesPackage *package;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
- (void)tx_start;
- (void)tx_pause;
@end

@implementation TXWallpaperRenderer

- (instancetype)initWithPackage:(TXTendiesPackage *)package {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _package = package;
        self.backgroundColor = UIColor.clearColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;

        AVPlayerItem *item = [AVPlayerItem playerItemWithURL:package.videoURL];
        _player = [AVQueuePlayer queuePlayerWithItems:@[item]];
        _player.muted = YES;
        _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];

        _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
        _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
        [self.layer addSublayer:_playerLayer];

        TXLog(@"渲染层创建: name=%@ video=%@", package.displayName, package.videoURL.path);
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}

- (void)tx_start  { [self.player play];  }
- (void)tx_pause  { [self.player pause]; }

@end

#pragma mark - 触摸交互层

@interface TXInteractionView : UIView
@end

@implementation TXInteractionView

// 壁纸视图位于图标之下，此层只会拿到主屏空白区域的触摸，不会抢图标的手势
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent *)event { return YES; }

- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
    // TODO: 依据 .tendies 描述文件里的触发规则做涟漪 / 视差偏转
}
- (void)touchesMoved:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesEnded:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}
- (void)touchesCancelled:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {}

@end

#pragma mark - 管理器

@interface TXWallpaperManager ()
@property (nonatomic, strong) NSMapTable<UIView *, TXWallpaperRenderer *> *renderers;
@property (nonatomic, strong, readwrite) TXTendiesPackage *activePackage;
@end

@implementation TXWallpaperManager

+ (instancetype)sharedManager {
    static TXWallpaperManager *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[TXWallpaperManager alloc] init];
        TXLog(@"管理器初始化，开始读取偏好与 .tendies");
        [shared reloadFromDisk];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderers = [NSMapTable weakToStrongObjectsMapTable];
        // 设置面板改完偏好会发 Darwin 通知 -> TXPreferences 广播本通知 -> 这里重载
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(tx_preferencesDidReload)
                                                     name:@"TXPreferencesDidReload"
                                                   object:nil];
    }
    return self;
}

- (void)tx_preferencesDidReload {
    dispatch_async(dispatch_get_main_queue(), ^{
        TXLog(@"收到偏好变更通知，重新加载壁纸");
        [self reloadFromDisk];
    });
}

- (void)reloadFromDisk {
    TXPreferences *prefs = TXPreferences.sharedInstance;
    NSString *path = prefs.activePackagePath;

    if (!path.length) {
        path = [TXTendiesPackage firstAvailablePackagePath];
        if (path.length) {
            TXLog(@"未配置 ActivePackagePath，自动发现: %@", path);
        }
    }

    self.activePackage = [TXTendiesPackage packageAtPath:path];

    TXLog(@"重新加载: enabled=%d interaction=%d parallax=%d path=%@ -> %@",
          prefs.enabled, prefs.interactionEnabled, prefs.parallaxEnabled,
          path.length ? path : @"(空)",
          self.activePackage ? self.activePackage.displayName : @"未解析出可用壁纸");

    NSArray<UIView *> *views = self.renderers.keyEnumerator.allObjects;
    if (views.count) {
        TXLog(@"重新挂载已存在的 %lu 个壁纸视图", (unsigned long)views.count);
    }
    for (UIView *view in views) {
        [self attachToWallpaperView:view];
    }
}

- (void)attachToWallpaperView:(UIView *)view {
    if (!view) {
        return;
    }

    TXWallpaperRenderer *existing = [self.renderers objectForKey:view];
    [existing removeFromSuperview];
    [self.renderers removeObjectForKey:view];

    TXPreferences *prefs = TXPreferences.sharedInstance;
    if (!prefs.enabled) {
        TXLog(@"跳过挂载(%@): 总开关 Enabled=NO", NSStringFromClass(view.class));
        return;
    }
    if (!self.activePackage) {
        TXLog(@"跳过挂载(%@): 无可用 .tendies，ActivePackagePath=%@",
              NSStringFromClass(view.class),
              prefs.activePackagePath.length ? prefs.activePackagePath : @"(空)");
        return;
    }

    TXWallpaperRenderer *renderer = [[TXWallpaperRenderer alloc] initWithPackage:self.activePackage];
    renderer.frame = view.bounds;
    renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    // 放在最上层盖住系统静态壁纸（系统原图在 contentView 里，被不透明视频遮住即可）
    [view addSubview:renderer];
    [self.renderers setObject:renderer forKey:view];
    [renderer tx_start];

    if (prefs.interactionEnabled) {
        TXInteractionView *interaction = [[TXInteractionView alloc] initWithFrame:renderer.bounds];
        interaction.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        interaction.backgroundColor = UIColor.clearColor;
        [renderer addSubview:interaction];
    }

    TXLog(@"已挂载: %@ -> %@ (bounds=%@)",
          self.activePackage.displayName, NSStringFromClass(view.class),
          NSStringFromCGRect(view.bounds));
}

- (void)layoutWallpaperWithView:(UIView *)view {
    TXWallpaperRenderer *renderer = [self.renderers objectForKey:view];
    if (!renderer) {
        return;
    }
    renderer.frame = view.bounds;
    [renderer setNeedsLayout];
}

- (void)pauseWallpaperWithView:(UIView *)view {
    [[self.renderers objectForKey:view] tx_pause];
}

- (void)resumeWallpaperWithView:(UIView *)view {
    TXWallpaperRenderer *renderer = [self.renderers objectForKey:view];
    if (renderer) {
        [renderer tx_start];
    } else {
        [self attachToWallpaperView:view];
    }
}

- (void)setLockScreenActive:(BOOL)active {
    TXLog(@"锁屏激活 = %d", active);
    // TODO: 锁屏激活时可降低帧率 / 暂停，避免与面容、息屏显示互相抢占
}

- (void)handleEvent:(UIEvent *)event {
    // TODO: 需要主屏全区域交互时，在这里把触摸分发给当前渲染层
}

@end
