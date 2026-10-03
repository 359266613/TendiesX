//
//  TXCAPackageView.h
//  把 .ca 目录（CoreAnimation 包 / CAAML）交给系统原生渲染。
//
//  为什么必须这样做：
//  .tendies 的 <名字>.wallpaper/ 下是三个 .ca 目录，里面是 main.caml（CAAML 图层树）
//  加 assets 贴图，**不是图片素材也不是视频**。取其中一张 png 当静态图只是兜底，
//  真正的动画必须让系统加载 CAPackage 才能播出来。
//

#import <UIKit/UIKit.h>

@interface TXCAPackageView : UIView

/// 传入 .ca 目录路径（xxx_Background-390w-844h@3x~iphone.ca）
- (instancetype)initWithCAPackagePath:(NSString *)path;

/// 是否成功加载
@property (nonatomic, readonly) BOOL loaded;

/// 加载方式："BSUICAPackageView"（成功）/ "failed"（失败，调用方应退回静态兜底）
@property (nonatomic, readonly, copy) NSString *loadMode;

@end
