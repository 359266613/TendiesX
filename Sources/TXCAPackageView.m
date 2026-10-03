#import "TXCAPackageView.h"
#import "TXWallpaper.h"
#import "TXLogger.h"
#import <QuartzCore/QuartzCore.h>

@implementation TXCAPackageView {
    UIView *_packageView;   // BSUICAPackageView 实例
    CALayer *_rootLayer;    // 兜底：直接把 CAPackage 的 rootLayer 贴上来
}

- (instancetype)initWithCAPackagePath:(NSString *)path {
    self = [super initWithFrame:CGRectZero];
    if (self) {
        self.backgroundColor = UIColor.clearColor;
        self.userInteractionEnabled = NO;
        self.clipsToBounds = YES;
        _loadMode = @"failed";
        [self tx_loadPackageAtPath:path];
    }
    return self;
}

- (BOOL)loaded {
    return _packageView != nil || _rootLayer != nil;
}

#pragma mark - 加载

- (void)tx_loadPackageAtPath:(NSString *)path {
    if (!path.length) {
        return;
    }

    Class packageClass = NSClassFromString(@"CAPackage");
    if (!packageClass) {
        TXLog(@"CAPackage 类不存在，无法渲染 .ca: %@", path.lastPathComponent);
        return;
    }

    // 用 Zone 抓到的那个初始化器：initWithContentsOfURL:publishedObjectViewClassMap:
    SEL initializer = NSSelectorFromString(@"initWithContentsOfURL:publishedObjectViewClassMap:");
    if (![packageClass instancesRespondToSelector:initializer]) {
        TXLog(@"CAPackage 不支持 initWithContentsOfURL:publishedObjectViewClassMap:，无法渲染 .ca");
        return;
    }

    id<TXCAPackage> package = [(id<TXCAPackage>)packageClass initWithContentsOfURL:[NSURL fileURLWithPath:path]
                                                        publishedObjectViewClassMap:@{}];
    if (!package) {
        TXLog(@"CAPackage 加载失败: %@", path.lastPathComponent);
        return;
    }

    CALayer *rootLayer = [package respondsToSelector:@selector(rootLayer)] ? package.rootLayer : nil;

    // 首选系统自己的 CA 包视图（SpringBoard 渲染 .ca 就用它，states/动画都由它驱动）
    Class packageViewClass = NSClassFromString(@"BSUICAPackageView");
    if (packageViewClass) {
        BSUICAPackageView *view = [(BSUICAPackageView *)[packageViewClass alloc] initWithFrame:self.bounds];
        view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        view.userInteractionEnabled = NO;
        [view setPackage:package];
        [self addSubview:view];
        _packageView = view;
        _loadMode = @"BSUICAPackageView";
    } else if (rootLayer) {
        // 兜底：直接挂 rootLayer（没有 states 驱动，部分素材可能停在初始态）
        rootLayer.frame = self.bounds;
        [self.layer addSublayer:rootLayer];
        _rootLayer = rootLayer;
        _loadMode = @"rootLayer";
    }

    TXLog(@"CAPackage 加载成功: %@ mode=%@ rootLayer=%@ 子层=%lu",
          path.lastPathComponent, _loadMode, rootLayer ? @"有" : @"无",
          (unsigned long)rootLayer.sublayers.count);
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    _packageView.frame = self.bounds;
    if (_rootLayer) {
        [CATransaction begin];
        [CATransaction setDisableActions:YES];
        _rootLayer.frame = self.bounds;
        [CATransaction commit];
    }
}

@end
