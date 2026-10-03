#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import <AVFoundation/AVFoundation.h>

#pragma mark - 渲染层

/// 渲染层：video 型走 AVPlayerLooper 循环播放；ca / image 型先退化成静态兜底图，
/// 保证「挂载链路」可见可用，后续再接 CoreAnimation(.ca/CAAML) 渲染。
@interface TXWallpaperRenderer : UIView
@property (nonatomic, strong) TXTendiesPackage *package;
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, copy)   NSString *mode;
- (void)tx_start;
- (void)tx_pause;
@end

@implementation TXWallpaperRenderer

- (instancetype)initWithPackage:(TXTendiesPackage *)package {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        _package = package;
        self.backgroundColor = UIColor.blackColor;
        self.clipsToBounds = YES;
        self.userInteractionEnabled = YES;

        if (package.videoURL) {
            [self tx_setupVideo];
        } else if (package.fallbackImageURL) {
            [self tx_setupStaticImage];
        } else {
            _mode = @"empty";
            TXLog(@"渲染层: 无可渲染内容（既无视频也无图片）");
        }
    }
    return self;
}

// 视频型：AVQueuePlayer + AVPlayerLooper 无缝循环
- (void)tx_setupVideo {
    _mode = @"video";
    AVPlayerItem *item = [AVPlayerItem playerItemWithURL:_package.videoURL];
    _player = [AVQueuePlayer queuePlayerWithItems:@[item]];
    _player.muted = YES;
    _looper = [AVPlayerLooper playerLooperWithPlayer:_player templateItem:item];

    _playerLayer = [AVPlayerLayer playerLayerWithPlayer:_player];
    _playerLayer.videoGravity = AVLayerVideoGravityResizeAspectFill;
    [self.layer addSublayer:_playerLayer];

    TXLog(@"渲染层: video 模式 video=%@", _package.videoURL.path);
}

// ca / image 型：暂时显示静态兜底图（.ca 里的 Background 层资源或最大图）
- (void)tx_setupStaticImage {
    _mode = @"static";
    UIImage *image = [UIImage imageWithContentsOfFile:_package.fallbackImageURL.path];
    _imageView = [[UIImageView alloc] initWithImage:image];
    _imageView.frame = self.bounds;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_imageView];

    TXLog(@"渲染层: static 兜底模式 kind=%@ image=%@ (%@)，.ca 渲染待接入",
          _package.kind, _package.fallbackImageURL.path, image ? @"已加载" : @"解码失败");
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
    self.imageView.frame = self.bounds;
}

- (void)tx_start { [self.player play];  }
- (void)tx_pause { [self.player pause]; }

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
          self.activePackage
              ? [NSString stringWithFormat:@"%@(%@)", self.activePackage.displayName, self.activePackage.kind]
              : @"未解析出可用壁纸");

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
    // 放在最上层盖住系统静态壁纸（系统原图在 contentView 里，被不透明内容遮住即可）
    [view addSubview:renderer];
    [self.renderers setObject:renderer forKey:view];
    [renderer tx_start];

    if (prefs.interactionEnabled) {
        TXInteractionView *interaction = [[TXInteractionView alloc] initWithFrame:renderer.bounds];
        interaction.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        interaction.backgroundColor = UIColor.clearColor;
        [renderer addSubview:interaction];
    }

    TXLog(@"已挂载: %@ (%@/%@) -> %@ (bounds=%@)",
          self.activePackage.displayName, self.activePackage.kind, renderer.mode,
          NSStringFromClass(view.class), NSStringFromCGRect(view.bounds));
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
