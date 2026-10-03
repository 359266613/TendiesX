#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import "TXWallpaper.h"
#import "TXCAPackageView.h"
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

/// iOS 16 上壁纸视图的 contentView 经常是「副本」（fake blur / snapshot replica /
/// portal replica），只在过渡瞬间被合成，落定后就被系统快照取代。
/// 挂进这些宿主就会表现为「下拉通知中心看得到、松手就消失」。
///
/// 三个类名来自 Reference/Private/ 的 dump（PaperBoardUI，iOS 16.5），精确匹配：
///   PBUIFakeBlurView.h / PBUISnapshotReplicaView.h / PBUIPortalReplicaEffectView.h
static BOOL TXIsClass(UIView *view, NSString *className) {
    Class cls = NSClassFromString(className);
    return cls && [view isKindOfClass:cls];
}

static BOOL TXIsReplicaHost(UIView *view) {
    return TXIsClass(view, @"PBUIFakeBlurView")
        || TXIsClass(view, @"PBUISnapshotReplicaView")
        || TXIsClass(view, @"PBUIPortalReplicaEffectView");
}

// 壁纸视图会被系统反复重建，每次 didMoveToWindow 都可能新建渲染层。
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

#pragma mark - 层级诊断

/// 把一个视图的直接子视图列成一行（带尺寸和 hidden，方便看出"谁盖住谁"）
static NSString *TXChildDescription(UIView *view) {
    NSMutableString *desc = [NSMutableString string];
    for (UIView *sub in view.subviews) {
        [desc appendFormat:@"%@(%.0fx%.0f,hidden=%d) ", NSStringFromClass(sub.class),
                            sub.bounds.size.width, sub.bounds.size.height, sub.hidden];
    }
    return desc;
}

/// 一次性打印壁纸视图及其**父级**的子视图层级。
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

    UIView *content = [view isKindOfClass:PBUIWallpaperView.class]
        ? [(PBUIWallpaperView *)view contentView] : nil;
    UIView *parent = view.superview;
    TXLog(@"层级 %@: contentView=%@", key,
          content ? NSStringFromClass(content.class) : @"(无)");
    TXLog(@"  自身子视图 = [%@]", TXChildDescription(view));
    TXLog(@"  父级 %@ 子视图 = [%@]",
          parent ? NSStringFromClass(parent.class) : @"(无)",
          parent ? TXChildDescription(parent) : @"");
}

#pragma mark - 渲染层

/// 渲染层：
///   video 型 → AVQueuePlayer + AVPlayerLooper 循环播放
///   ca 型    → 三层 .ca 各自交给系统 CAPackage / BSUICAPackageView 原生渲染
///   image 型 → 静态图兜底
@interface TXWallpaperRenderer : UIView
@property (nonatomic, strong) TXTendiesPackage *package;
@property (nonatomic, weak)   UIView *host;      // 实际承载的父视图
@property (nonatomic, strong) AVQueuePlayer *player;
@property (nonatomic, strong) AVPlayerLooper *looper;
@property (nonatomic, strong) AVPlayerLayer *playerLayer;
@property (nonatomic, strong) UIImageView *imageView;
@property (nonatomic, strong) NSMutableArray<TXCAPackageView *> *caViews;
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
        _caViews = [NSMutableArray array];

        if (package.videoURL) {
            [self tx_setupVideo];
        } else if ([self tx_setupCoreAnimation]) {
            // 成功走 CA 包渲染
        } else if ([self tx_setupStaticImage]) {
            // 退回静态兜底
        } else {
            _mode = @"empty";
            TXLog(@"渲染层: 无可渲染内容（无视频 / 无 .ca / 无图片）");
        }
    }
    return self;
}

#pragma mark video

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

#pragma mark CoreAnimation（.ca）

// 三层叠放语义（Apple 海报）：Background 最底 → Floating（主体）→ Foreground 最上
- (BOOL)tx_setupCoreAnimation {
    NSArray<NSString *> *paths = @[
        _package.backgroundCAPath ?: @"",
        _package.floatingCAPath ?: @"",
        _package.foregroundCAPath ?: @"",
    ];

    for (NSString *path in paths) {
        if (!path.length) {
            continue;
        }
        TXCAPackageView *caView = [[TXCAPackageView alloc] initWithCAPackagePath:path];
        if (!caView.loaded) {
            TXLog(@"渲染层: 该层加载失败，跳过 %@", path.lastPathComponent);
            continue;
        }
        caView.frame = self.bounds;
        caView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:caView];
        [_caViews addObject:caView];
    }

    if (!_caViews.count) {
        return NO;
    }
    _mode = [NSString stringWithFormat:@"ca(%lu层)", (unsigned long)_caViews.count];
    TXLog(@"渲染层: %@ 模式（系统 CAPackage 原生渲染）", _mode);
    return YES;
}

#pragma mark 静态兜底

- (BOOL)tx_setupStaticImage {
    if (!_package.fallbackImageURL) {
        return NO;
    }
    _mode = @"static";
    UIImage *image = TXLoadCachedImage(_package.fallbackImageURL.path);
    _imageView = [[UIImageView alloc] initWithImage:image];
    _imageView.frame = self.bounds;
    _imageView.contentMode = UIViewContentModeScaleAspectFill;
    _imageView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [self addSubview:_imageView];

    TXLog(@"渲染层: static 兜底模式 kind=%@ image=%@ (%@)",
          _package.kind, _package.fallbackImageURL.lastPathComponent,
          image ? @"已加载" : @"解码失败");
    return YES;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    self.playerLayer.frame = self.bounds;
    self.imageView.frame = self.bounds;
    for (TXCAPackageView *caView in _caViews) {
        caView.frame = self.bounds;
    }
}

// CA 动画没有播放/暂停的概念，这里用 layer.speed 整棵子树一起停
- (void)tx_start {
    self.layer.speed = 1.0;
    [self.player play];
}
- (void)tx_pause {
    self.layer.speed = 0.0;
    [self.player pause];
}

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
/// 已经挂上容器级渲染层的那个容器；存在时不再往壁纸视图里重复挂
@property (nonatomic, weak) UIView *containerHost;
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
    // 先把投放目录里的 .tendies 导入（解压成同名目录并删掉压缩包）
    NSDictionary<NSString *, NSString *> *imported =
        [TXTendiesPackage importPendingPackagesWithSourceRemoval:YES];

    TXPreferences *prefs = TXPreferences.sharedInstance;
    NSString *path = prefs.activePackagePath;

    NSString *remapped = path.length ? imported[path] : nil;
    if (remapped.length) {
        TXLog(@"当前壁纸已导入，改指素材目录: %@", TXShortPath(remapped));
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

    for (UIView *view in self.renderers.keyEnumerator.allObjects) {
        [self attachToWallpaperView:view];
    }
}

#pragma mark - 挂载

/// 参考 Zone 的做法：挂到 PBUIWallpaperViewController 的 _wallpaperContainerView。
/// 这个容器才是「主壁纸容器」；壁纸视图自己的 contentView 在 iOS 16 上经常是副本。
- (void)attachToWallpaperContainerView:(UIView *)container {
    if (!container) {
        return;
    }
    // 容器的父级如果是副本，说明不是主容器
    if (TXIsReplicaHost(container)) {
        return;
    }
    if (self.containerHost != container) {
        self.containerHost = container;
        TXLog(@"主壁纸容器 = %@ (bounds=%@)", NSStringFromClass(container.class),
              NSStringFromCGRect(container.bounds));
    }
    [self attachToWallpaperView:container];
}

- (void)attachToWallpaperView:(UIView *)view {
    if (!view) {
        return;
    }

    // 已经有容器级渲染层时不再往壁纸视图（副本）里重复挂，避免重复解码
    if (self.containerHost && view != self.containerHost) {
        return;
    }

    TXWallpaperRenderer *existing = [self.renderers objectForKey:view];

    // didMoveToWindow 会高频触发（切页/转屏都会走）。
    // 同一视图已挂着同一个包时直接复用，不重建 —— 重建会重新解码图片、
    // 让视频从头播放，表现为闪烁 + 反复解大图。
    if (existing && existing.package && self.activePackage
        && [existing.package.path isEqualToString:self.activePackage.path]) {
        UIView *host = existing.host ?: view;
        existing.frame = host.bounds;
        [existing tx_start];
        [host bringSubviewToFront:existing];
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

    // 宿主选择：容器本身直接用；壁纸视图则挂进它的 contentView
    UIView *host = view;
    if ([view isKindOfClass:PBUIWallpaperView.class]) {
        UIView *content = [(PBUIWallpaperView *)view contentView];
        if (content) {
            host = content;
        }
    }
    if (TXIsReplicaHost(host)) {
        TXLog(@"警告: 宿主的父级是「副本」%@，内容可能在过渡结束后被系统快照替代",
              NSStringFromClass(host.superview.class));
    }

    TXDumpHierarchyOnce(view);

    TXWallpaperRenderer *renderer = [[TXWallpaperRenderer alloc] initWithPackage:self.activePackage];
    renderer.host = host;
    renderer.frame = host.bounds;
    renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:renderer];
    // 容器里还有系统自己的壁纸视图，必须提到最上面，否则被盖住
    [host bringSubviewToFront:renderer];
    [self.renderers setObject:renderer forKey:view];
    [renderer tx_start];

    if (prefs.interactionEnabled) {
        TXInteractionView *interaction = [[TXInteractionView alloc] initWithFrame:renderer.bounds];
        interaction.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        interaction.backgroundColor = UIColor.clearColor;
        [renderer addSubview:interaction];
    }

    long long variant = [view respondsToSelector:@selector(variant)]
        ? [(PBUIWallpaperView *)view variant] : -1;
    TXLog(@"已挂载: %@ (%@/%@) -> %@ @ %@ (variant=%lld bounds=%@)",
          self.activePackage.displayName, self.activePackage.kind, renderer.mode,
          NSStringFromClass(view.class), NSStringFromClass(host.class),
          variant, NSStringFromCGRect(host.bounds));
}

- (void)layoutWallpaperWithView:(UIView *)view {
    TXWallpaperRenderer *renderer = [self.renderers objectForKey:view];
    if (!renderer) {
        return;
    }
    renderer.frame = view.bounds;
    [renderer setNeedsLayout];
    // 系统会在这期间重建子视图顺序，每次布局都把我们提回最上面
    [view bringSubviewToFront:renderer];
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
    // TODO: 锁屏激活时降低帧率 / 暂停，避免与面容、息屏显示互相抢占
}

- (void)handleEvent:(UIEvent *)event {
    // TODO: 需要主屏全区域交互时，在这里把触摸分发给当前渲染层
}

@end
