#import "TXCAPackageView.h"
#import "TXWallpaper.h"
#import "TXLogger.h"
#import <QuartzCore/QuartzCore.h>

//  实现依据：Reference/Private/BSUICAPackageView.h（iOS 16.5 dump 逐条核对）
//
//  ★ 之前这里写的是「先建 CAPackage 再 setPackage:」，两处都是错的：
//    1) BSUICAPackageView 里没有 setPackage: 这个方法；
//    2) CAPackage 里也没有 initWithContentsOfURL:publishedObjectViewClassMap:。
//    真实做法：BSUICAPackageView 自己持有 _rootLayer 和 _stateController，
//    只要把 .ca 目录的 URL 交给 -initWithURL: 即可，states / 动画由它内部驱动。

@implementation TXCAPackageView {
    BSUICAPackageView *_packageView;
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
    return _packageView != nil;
}

#pragma mark - 加载

- (void)tx_loadPackageAtPath:(NSString *)path {
    if (!path.length) {
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir] || !isDir) {
        TXLog(@"CA 包路径不是目录: %@", path);
        return;
    }
    // .ca 包必须带 main.caml（CAAML 图层树），没有就不是 CA 包
    if (![fm fileExistsAtPath:[path stringByAppendingPathComponent:@"main.caml"]]) {
        TXLog(@"CA 包缺少 main.caml，跳过: %@", path.lastPathComponent);
        return;
    }

    Class viewClass = NSClassFromString(@"BSUICAPackageView");
    if (!viewClass) {
        TXLog(@"本系统没有 BSUICAPackageView，无法渲染 .ca: %@", path.lastPathComponent);
        return;
    }
    if (![viewClass instancesRespondToSelector:NSSelectorFromString(@"initWithURL:")]) {
        TXLog(@"BSUICAPackageView 不支持 initWithURL:，无法渲染 .ca");
        return;
    }

    BSUICAPackageView *view = [(BSUICAPackageView *)[viewClass alloc] initWithURL:[NSURL fileURLWithPath:path]];
    if (!view) {
        TXLog(@"BSUICAPackageView 加载失败: %@", path.lastPathComponent);
        return;
    }

    view.frame = self.bounds;
    view.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    view.userInteractionEnabled = NO;
    [self addSubview:view];
    _packageView = view;
    _loadMode = @"BSUICAPackageView";

    // publishedObjectNames 是包里可被外部引用的对象名，出问题时靠它判断包有没有真的读进来
    NSArray *names = view.publishedObjectNames;
    TXLog(@"CA 包加载成功: %@ 自然尺寸=%@ 发布对象=%@",
          path.lastPathComponent,
          NSStringFromCGSize([view sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)]),
          names.count ? [names componentsJoinedByString:@","] : @"(无)");
}

#pragma mark - 布局

- (void)layoutSubviews {
    [super layoutSubviews];
    _packageView.frame = self.bounds;
}

@end
