#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
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
    }
    return self;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
}

- (void)tx_start  { [self.player play]; }
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
        [shared reloadFromDisk];
    });
    return shared;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _renderers = [NSMapTable weakToStrongObjectsMapTable];
    }
    return self;
}

- (void)reloadFromDisk {
    NSString *path = TXPreferences.sharedInstance.activePackagePath;
    self.activePackage = [TXTendiesPackage packageAtPath:path];

    NSArray<UIView *> *views = self.renderers.keyEnumerator.allObjects;
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
    if (!prefs.enabled || !self.activePackage) {
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

    NSLog(@"[TendiesX] mounted %@ -> %@", self.activePackage.displayName, NSStringFromClass(view.class));
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
    // TODO: 锁屏激活时可降低帧率 / 暂停，避免与面容、息屏显示互相抢占
    NSLog(@"[TendiesX] lock screen active = %d", active);
}

- (void)handleEvent:(UIEvent *)event {
    // TODO: 需要主屏全区域交互时，在这里把触摸分发给当前渲染层
}

@end
