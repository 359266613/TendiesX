//
//  TXWallpaper.h
//  参与编译的私有 API 最小声明（手写，不引任何 ipsw dump 头）。
//
//  为什么不用 Reference/ 里那些 dump 头：
//  1) 它们是「二进制类布局的转述」，每个属性还额外手写了一遍 (id) 版 setter，
//     类型必然与 @property 冲突，-Werror 下直接编译失败；
//  2) 内联匿名 struct 写在参数位置是硬错误；
//  3) 里面 90% 的成员我们根本不会调用。
//
//  需要新方法时，在这里按 dump（Reference/Private/xxx.h）补一行即可。
//

#ifndef TXWallpaper_h
#define TXWallpaper_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#pragma mark - PaperBoardUI（壁纸真正落点，iOS 15~17 通用）

/// 壁纸视图基类。系统实际实例通常是它的子类 PBUIStaticWallpaperView
@interface PBUIWallpaperView : UIView
@property (nonatomic, retain) UIView *contentView;
@property (nonatomic, readonly) UIImage *wallpaperImage;
@property (nonatomic, readonly) long long wallpaperType;
@property (nonatomic, readonly) BOOL hasVideo;
@property (nonatomic) long long variant;
@property (nonatomic) BOOL wallpaperAnimationEnabled;
@property (nonatomic) BOOL parallaxEnabled;
@property (nonatomic) double parallaxFactor;
@property (nonatomic, readonly, copy) NSString *wallpaperName;
- (void)prepareToAppear;
- (void)prepareToDisappear;
- (void)invalidate;
- (void)setVariant:(long long)variant withAnimationFactory:(id)factory;
- (BOOL)isDisplayingWallpaperWithConfiguration:(id)configuration forVariant:(long long)variant;
@end

@interface PBUIStaticWallpaperView : PBUIWallpaperView
@end

/// 壁纸容器控制器，同时管锁屏与主屏两个 variant
@interface PBUIWallpaperViewController : UIViewController
@property (retain, nonatomic) PBUIWallpaperView *homescreenWallpaperView;
@property (retain, nonatomic) PBUIWallpaperView *lockscreenWallpaperView;
@property (nonatomic) long long activeVariant;
- (PBUIWallpaperView *)wallpaperViewForVariant:(long long)variant;
- (PBUIWallpaperView *)_activeWallpaperView;
- (void)noteWallpapersDidUpdate;
- (void)_handleWallpaperChangedForVariant:(long long)variant;
- (id)suspendWallpaperAnimationForReason:(id)reason;
- (void)addObserver:(id)observer forVariant:(long long)variant;
@end

#pragma mark - SpringBoard

@interface SBHomeScreenViewController : UIViewController
@end

@interface SBLockScreenViewControllerBase : UIViewController
@end

@interface SBLockStateAggregator : NSObject
+ (instancetype)sharedInstance;
- (unsigned long long)lockState;
@end

/// 需要拿壁纸视图/控制器实例时可以走这里（方法名按真机 dump 核对后再补）
@interface SBWallpaperController : NSObject
+ (instancetype)sharedInstance;
@end

#pragma mark - CoreAnimation Package（.ca 原生渲染的关键）

//  .tendies 解压后的 <名字>.wallpaper/ 里有三个 .ca 目录：
//    xxx_Background-*.ca / xxx_Floating-*.ca / xxx_Foreground-*.ca
//  每个 .ca 目录整体就是一个 CoreAnimation 包（main.caml = CAAML 图层树 + assets/*.png|jpg），
//  系统自带加载/渲染能力，不需要我们自己解析 main.caml。
//
//  CAPackage（QuartzCore）用协议声明而不是 @interface，避免与 SDK 头重复定义冲突。
//  真实类通过 NSClassFromString(@"CAPackage") 取，走运行时。
@protocol TXCAPackage <NSObject>
- (id)initWithContentsOfURL:(NSURL *)url
  publishedObjectViewClassMap:(NSDictionary *)map;
- (id)publishedObjectWithName:(NSString *)name;
- (CALayer *)rootLayer;
@end

/// BaseBoardUI 里的 CA 包视图 —— SpringBoard 自己渲染 .ca 用的就是它
@interface BSUICAPackageView : UIView
- (void)setPackage:(id)package;
- (void)setState:(NSString *)state;
- (void)setState:(NSString *)state animated:(BOOL)animated;
- (void)setState:(NSString *)state ofLayer:(CALayer *)layer transitionSpeed:(double)speed;
- (void)setStateController:(id)controller;
- (void)setStatesData:(id)statesData;
@end

#endif /* TXWallpaper_h */
