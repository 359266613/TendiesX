#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import "TXWallpaper.h"
#import <AVFoundation/AVFoundation.h>

/// 日志用的短路径（只留父目录名/文件名），避免整条绝对路径把日志撑爆
static NSString *TXShortPath(NSString *path) {
    if (!path.length) {
        return @"(空)";
    }
    return [NSString stringWithFormat:@"%@/%@",
            path.stringByDeletingLastPathComponent.lastPathComponent,
            path.lastPathComponent];
}

// 调整：壁纸视图会被系统反复重建，每次 didMoveToWindow 都可能新建渲染层。
// 加一级图片缓存，避免同一个包反复解码同一张大图。
static UIImage *TXLoadCachedImage(NSString *path) {
    if (!path.length) {
        return nil;
    }
    static NSCache<NSString *, UIImage *> *cache;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cache = [[NSCache alloc] init];
        cache.countLimit = 4;
    });
    UIImage *image = [cache objectForKey:path];
    if (!image) {
        image = [UIImage imageWithContentsOfFile:path];
        if (image) {
            [cache setObject:image forKey:path];
        }
    }
    return image;
}

#pragma mark - 渲染层

/// 把一个视图的直接子视图列成一行（带尺寸和 hidden，方便看出"谁盖住谁"）
static NSString *TXChildDescription(UIView *view) {
    NSMutableString *desc = [NSMutableString string];
    for (UIView *sub in view.subviews) {
        [desc appendFormat:@"%@(%.0fx%.0f,hidden=%d) ", NSStringFromClass(sub.class),
                            sub.bounds.size.width, sub.bounds.size.height, sub.hidden];
    }
    return desc;
}

/// 调整：一次性打印壁纸视图及其**父级**的子视图层级。
/// 模糊 / 暗淡 / 快照层一般是壁纸视图的兄弟节点（同容器、在它上面），
/// 只看壁纸视图自己的子视图是查不出"被谁盖住"的。
static void TXDumpHierarchyOnce(UIView *view) {
    static NSMutableSet<NSString *> *dumped;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        dumped = [NSMutableSet set];
    });

    NSString *key = NSStringFromClass(view.class);
    if ([dumped containsObject:key]) {
        return;
    }
    [dumped addObject:key];

    UIView *content = [(PBUIWallpaperView *)view contentView];
    UIView *parent = view.superview;
    TXLog(@"层级 %@: contentView=%@", key,
          content ? NSStringFromClass(content.class) : @"(无)");
    TXLog(@"  自身子视图 = [%@]", TXChildDescription(view));
    TXLog(@"  父级 %@ 子视图 = [%@]",
          parent ? NSStringFromClass(parent.class) : @"(无)",
          parent ? TXChildDescription(parent) : @"");
}

/// 渲染层：video 型走 AVPlayerLooper 循环播放；ca / image 型先退化成静态兜底图，
/// 保证「挂载链路」可见可用，后续再接 CoreAnimation(.ca/CAAML) 渲染。
@interface TXWallpaperRenderer : UIView
@property (nonatomic, strong) TXTendiesPackage *package;
@property (nonatomic, weak)   UIView *host;      // 实际承载的父视图
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

    TXLog(@"渲染层: video 模式 video=%@", _package.videoURL.lastPathComponent);
}

// ca / image 型：暂时显示静态兜底图（.ca 里的 Background 层资源或最大图）
- (void)tx_setupStaticImage {
    _mode = @"static";
    UIImage *image = TXLoadCachedImage(_package.fallbackImageURL.path);
    _imageView = [[UIImageView alloc] initWithImage:image];
    _imageView.frame = self.bounds;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_imageView];

    TXLog(@"渲染层: static 兜底模式 kind=%@ image=%@ (%@)，.ca 渲染待接入",
          _package.kind, _package.fallbackImageURL.lastPathComponent,
          image ? @"已加载" : @"解码失败");
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
    // 调整：先把投放目录里的 .tendies 导入（解压到素材库并删掉源文件）。
    // 这样用 Filza 丢进目录的素材，重载一次就变成可用壁纸，目录里不留 .tendies 原文件。
    NSDictionary<NSString *, NSString *> *imported =
        [TXTendiesPackage importPendingPackagesWithSourceRemoval:YES];

    TXPreferences *prefs = TXPreferences.sharedInstance;
    NSString *path = prefs.activePackagePath;

    // 当前选中的正好是刚被导入的 .tendies（源文件已删）→ 改指到素材库目录
    NSString *remapped = path.length ? imported[path] : nil;
    if (remapped.length) {
        TXLog(@"当前壁纸已导入，改指素材库: %@", TXShortPath(remapped));
        [prefs updateActivePackagePath:remapped];
        path = remapped;
    }

    // 配置的路径失效（被删 / 未导入）时自动回落到素材库里的第一个
    self.activePackage = [TXTendiesPackage packageAtPath:path];
    if (!self.activePackage) {
        path = [TXTendiesPackage firstAvailablePackagePath];
        self.activePackage = [TXTendiesPackage packageAtPath:path];
    }

    TXLog(@"重新加载: enabled=%d interaction=%d parallax=%d path=%@ -> %@",
          prefs.enabled, prefs.interactionEnabled, prefs.parallaxEnabled,
          TXShortPath(path),
          self.activePackage
              ? [NSString stringWithFormat:@"%@(%@)", self.activePackage.displayName, self.activePackage.kind]
              : @"未解析出可用壁纸");

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

    // 调整：didMoveToWindow 会高频触发（切页/转屏都会走）。
    // 同一视图已挂着同一个包时直接复用，不重建 —— 重建会重新解码图片、
    // 让视频从头播放，表现为闪烁 + 反复解大图。
    if (existing && existing.package && self.activePackage
        && [existing.package.path isEqualToString:self.activePackage.path]) {
        UIView *host = existing.host ?: view;
        existing.frame = host.bounds;
        [existing tx_start];
        return;
    }

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
              prefs.activePackagePath.length ? TXShortPath(prefs.activePackagePath) : @"(空)");
        return;
    }

    // 调整：优先挂进系统自己的 contentView（系统原图所在的那层），这样系统的
    // 模糊 / 暗淡 / legibility 处理会一并作用在我们的内容上，层级也更稳；
    // 没有 contentView 时退回挂到壁纸视图本身。
    UIView *host = view;
    UIView *content = [(PBUIWallpaperView *)view contentView];
    if (content) {
        host = content;
    }

    TXDumpHierarchyOnce(view);

    TXWallpaperRenderer *renderer = [[TXWallpaperRenderer alloc] initWithPackage:self.activePackage];
    renderer.host = host;
    renderer.frame = host.bounds;
    renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:renderer];
    [self.renderers setObject:renderer forKey:view];
    [renderer tx_start];

    if (prefs.interactionEnabled) {
        TXInteractionView *interaction = [[TXInteractionView alloc] initWithFrame:renderer.bounds];
        interaction.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        interaction.backgroundColor = UIColor.clearColor;
        [renderer addSubview:interaction];
    }

    TXLog(@"已挂载: %@ (%@/%@) -> %@ @ %@ (variant=%lld bounds=%@)",
          self.activePackage.displayName, self.activePackage.kind, renderer.mode,
          NSStringFromClass(view.class), NSStringFromClass(host.class),
          (long long)[(PBUIWallpaperView *)view variant],
          NSStringFromCGRect(host.bounds));
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
