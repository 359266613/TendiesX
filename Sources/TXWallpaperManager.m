#import "TXWallpaperManager.h"
#import "TXTendiesPackage.h"
#import "TXPreferences.h"
#import "TXLogger.h"
#import "TXWallpaper.h"
#import "TXCAPackageView.h"
#import <AVFoundation/AVFoundation.h>
#import <objc/runtime.h>

/// 日志用的短路径（只留父目录名/文件名），避免整条绝对路径把日志撑爆
static NSString *TXShortPath(NSString *path) {
    if (!path.length) {
        return @"(空)";
    }
    return [NSString stringWithFormat:@"%@/%@",
            path.stringByDeletingLastPathComponent.lastPathComponent,
            path.lastPathComponent];
}

#pragma mark - 类判断（类名全部来自 Reference/Private/ 的 dump）

static BOOL TXIsClass(UIView *view, NSString *className) {
    Class cls = NSClassFromString(className);
    return cls && [view isKindOfClass:cls];
}

/// iOS 16 上壁纸内容经常是「副本」：跨进程 portal / 快照 / 假模糊。
/// 它们只在过渡瞬间被合成，落定后就被系统取代 —— 挂进去就会"松手就消失"。
static BOOL TXIsReplicaHost(UIView *view) {
    return TXIsClass(view, @"PBUIFakeBlurView")
        || TXIsClass(view, @"PBUISnapshotReplicaView")
        || TXIsClass(view, @"PBUIPortalReplicaEffectView");
}

/// 向上若干层里有没有出现某个类
static BOOL TXChainContainsClass(UIView *view, NSString *className, NSUInteger depth) {
    UIView *cur = view;
    for (NSUInteger i = 0; i < depth && cur; i++) {
        if (TXIsClass(cur, className)) {
            return YES;
        }
        cur = cur.superview;
    }
    return NO;
}

/// 从 view 往上取 N 层的类名，形如 "PBUIWallpaperView < PBUIFakeBlurView < UIView"
static NSString *TXAncestorChain(UIView *view, NSUInteger depth) {
    NSMutableArray<NSString *> *chain = [NSMutableArray array];
    UIView *cur = view;
    for (NSUInteger i = 0; i < depth && cur; i++) {
        [chain addObject:NSStringFromClass(cur.class)];
        cur = cur.superview;
    }
    return [chain componentsJoinedByString:@" < "];
}

/// 宿主优先级：主壁纸容器(3) > 独立壁纸视图(2) > 假模糊背景里的壁纸视图(1) > 副本(0)
static int TXHostRank(UIView *host) {
    if (TXIsReplicaHost(host)) {
        return 0;   // 快照 / portal 副本，只作最后退路
    }
    if (TXIsClass(host, @"PBUIWallpaperView")) {
        // 挂在 PBUIFakeBlurView 里的是「假模糊背景副本」，降级
        return TXChainContainsClass(host, @"PBUIFakeBlurView", 3) ? 1 : 2;
    }
    return 3;   // 容器或其它未知容器
}

// 壁纸视图会被系统反复重建，加一级图片缓存避免反复解码同一张大图
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

/// 每种类名只打印一次：自身子视图 + 完整的祖先链（判断是不是副本的关键）
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

    UIView *content = TXIsClass(view, @"PBUIWallpaperView")
        ? [(PBUIWallpaperView *)view contentView] : nil;
    TXLog(@"层级 %@: contentView=%@", key,
          content ? NSStringFromClass(content.class) : @"(无)");
    TXLog(@"  自身子视图 = [%@]", TXChildDescription(view));
    TXLog(@"  祖先链 = %@", TXAncestorChain(view, 5));
}

#pragma mark - 渲染层

/// 渲染层：
///   video 型 → AVQueuePlayer + AVPlayerLooper 循环播放
///   ca 型    → 三层 .ca 各自交给系统 BSUICAPackageView 原生渲染
///   image 型 → 静态图兜底
@interface TXWallpaperRenderer : UIView
@property (nonatomic, strong) TXTendiesPackage *package;
@property (nonatomic, weak)   UIView *host;
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
        self.backgroundColor = UIColor.clearColor;
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

// CA 动画没有播放/暂停的概念，用 layer.speed 把整棵子树一起停
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

// 壁纸层位于图标之下，只会拿到主屏空白区域的触摸，不会抢图标手势
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
@property (nonatomic, strong, readwrite) TXTendiesPackage *activePackage;

/// 全局唯一的渲染层。之前是「每个壁纸视图一个渲染层」→ 系统会同时存在好几个
/// 壁纸视图（主屏/锁屏/若干假模糊副本），结果就是好几套 3 层 .ca 叠在一起，
/// 日志里表现为 "CA 包加载成功" 反复出现 + 画面乱叠。
@property (nonatomic, strong) TXWallpaperRenderer *renderer;
@property (nonatomic, weak)   UIView *rendererHost;
@property (nonatomic, assign) int rendererHostRank;

/// 已找到的主壁纸容器（一旦找到，永远优先于壁纸视图）
@property (nonatomic, weak) UIView *containerHost;

/// 跳过原因去重，避免 didMoveToWindow 高频刷日志
@property (nonatomic, copy) NSString *lastSkipReason;

/// 唯一的挂载实现
- (void)attachToHost:(UIView *)host;
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

+ (id)tx_ivarValue:(id)object named:(NSString *)name {
    if (!object || !name.length) {
        return nil;
    }
    for (Class cls = object_getClass(object); cls; cls = class_getSuperclass(cls)) {
        Ivar ivar = class_getInstanceVariable(cls, name.UTF8String);
        if (ivar) {
            return object_getIvar(object, ivar);
        }
    }
    return nil;
}

- (instancetype)init {
    self = [super init];
    if (self) {
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

- (void)tx_logSkipOnce:(NSString *)reason {
    if ([self.lastSkipReason isEqualToString:reason]) {
        return;
    }
    self.lastSkipReason = reason;
    TXLog(@"%@", reason);
}

#pragma mark - 解析与重载

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

    self.lastSkipReason = nil;

    // 包变了 → 拆掉旧渲染层，等下一次挂载重建
    if (self.renderer && ![self.renderer.package.path isEqualToString:self.activePackage.path ?: @""]) {
        TXLog(@"包已变更，拆除旧渲染层");
        [self.renderer removeFromSuperview];
        self.renderer = nil;
        self.rendererHostRank = 0;
    }

    // 立刻按现有宿主重挂一次（容器优先）
    [self attachToHost:self.containerHost ?: self.rendererHost];
}

#pragma mark - 挂载

- (void)attachToWallpaperContainerView:(UIView *)container {
    if (!container) {
        return;
    }
    if (self.containerHost != container) {
        self.containerHost = container;
        TXLog(@"★ 找到主壁纸容器: %@ (bounds=%@) 祖先链=%@",
              NSStringFromClass(container.class),
              NSStringFromCGRect(container.bounds),
              TXAncestorChain(container, 3));
    }
    [self attachToHost:container];
}

- (void)attachToWallpaperView:(UIView *)view {
    if (!view) {
        return;
    }
    // 容器已就位时，壁纸视图（多半是副本）不再抢挂载点
    if (self.containerHost && self.rendererHost == self.containerHost) {
        return;
    }
    [self attachToHost:view];
}

/// 唯一的挂载实现：算出宿主优先级，必要时把渲染层「搬家」，绝不重复创建
- (void)attachToHost:(UIView *)host {
    if (!host) {
        return;
    }

    TXPreferences *prefs = TXPreferences.sharedInstance;
    if (!prefs.enabled) {
        [self tx_logSkipOnce:@"跳过挂载: 总开关 Enabled=NO"];
        return;
    }
    if (!self.activePackage) {
        [self tx_logSkipOnce:[NSString stringWithFormat:@"跳过挂载: 无可用 .tendies，ActivePackagePath=%@",
                             prefs.activePackagePath.length ? TXShortPath(prefs.activePackagePath) : @"(空)"]];
        return;
    }

    int rank = TXHostRank(host);
    NSString *hostName = NSStringFromClass(host.class);

    // 同一个包：搬家 or 就地刷新
    if (self.renderer && [self.renderer.package.path isEqualToString:self.activePackage.path]) {
        if (!self.rendererHost) {
            TXLog(@"渲染层重新附着: -> %@ (rank=%d)", hostName, rank);
            [host addSubview:self.renderer];
            [host bringSubviewToFront:self.renderer];
            self.rendererHost = host;
            self.rendererHostRank = rank;
        } else if (rank > self.rendererHostRank) {
            TXLog(@"渲染层搬家: %@(rank=%d) -> %@(rank=%d)",
                  NSStringFromClass(self.rendererHost.class), self.rendererHostRank, hostName, rank);
            [self.renderer removeFromSuperview];
            [host addSubview:self.renderer];
            [host bringSubviewToFront:self.renderer];
            self.rendererHost = host;
            self.rendererHostRank = rank;
        }
        if (self.rendererHost == host) {
            self.renderer.frame = host.bounds;
            [self.renderer setNeedsLayout];
            [self.renderer tx_start];
        }
        return;
    }

    // 首次 / 换包：重建
    if (self.renderer) {
        [self.renderer removeFromSuperview];
        self.renderer = nil;
    }

    TXDumpHierarchyOnce(host);

    TXWallpaperRenderer *renderer = [[TXWallpaperRenderer alloc] initWithPackage:self.activePackage];
    renderer.host = host;
    renderer.frame = host.bounds;
    renderer.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [host addSubview:renderer];
    [host bringSubviewToFront:renderer];

    self.renderer = renderer;
    self.rendererHost = host;
    self.rendererHostRank = rank;
    self.lastSkipReason = nil;

    if (prefs.interactionEnabled && renderer.subviews.count) {
        TXInteractionView *interaction = [[TXInteractionView alloc] initWithFrame:renderer.bounds];
        interaction.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        interaction.backgroundColor = UIColor.clearColor;
        [renderer addSubview:interaction];
    }

    [renderer tx_start];

    TXLog(@"已挂载: %@ (%@/%@) 宿主=%@ rank=%d 宿主祖先链=%@",
          self.activePackage.displayName, self.activePackage.kind, renderer.mode,
          hostName, rank, TXAncestorChain(host, 3));
}

- (void)layoutWallpaperWithView:(UIView *)view {
    if (!self.renderer || self.rendererHost != view) {
        return;   // 只跟当前宿主的尺寸，别被一堆副本视图带着乱动
    }
    self.renderer.frame = view.bounds;
    [self.renderer setNeedsLayout];
    [view bringSubviewToFront:self.renderer];
}

- (void)pauseWallpaperWithView:(UIView *)view {
    [self.renderer tx_pause];
}

- (void)resumeWallpaperWithView:(UIView *)view {
    if (self.renderer) {
        [self.renderer tx_start];
    } else {
        [self attachToHost:self.containerHost ?: view];
    }
}

- (void)setLockScreenActive:(BOOL)active {
    TXLog(@"锁屏激活 = %d", active);
    // TODO: 锁屏激活时可降低帧率 / 暂停，避免与面容、息屏显示互相抢占
}

- (void)handleEvent:(UIEvent *)event {
    // TODO: 需要主屏全区域交互时，在这里把触摸分发给当前渲染层
}

#pragma mark - 诊断

- (void)logContainerDiagnostics {
    if (self.containerHost) {
        TXLog(@"诊断: 主壁纸容器已找到 = %@ (bounds=%@)",
              NSStringFromClass(self.containerHost.class),
              NSStringFromCGRect(self.containerHost.bounds));
    } else {
        TXLog(@"诊断: 未找到 _wallpaperContainerView —— PBUIWallpaperViewController 可能没走到 "
              @"viewDidLoad/viewDidLayoutSubviews，或该版本 ivar 名不同");
    }
    TXLog(@"诊断: 渲染层=%@ 宿主=%@ rank=%d mode=%@",
          self.renderer ? @"有" : @"无",
          self.rendererHost ? NSStringFromClass(self.rendererHost.class) : @"(无)",
          self.rendererHostRank,
          self.renderer.mode ?: @"-");
}

@end
