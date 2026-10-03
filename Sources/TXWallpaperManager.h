//
//  TXWallpaperManager.h
//  壁纸引擎单例：负责把 .tendies 的渲染层挂到系统壁纸视图上，并管理生命周期。
//  所有 Hook 入口都只调这里的方法，Hook 里不写业务逻辑。
//

#import <UIKit/UIKit.h>

@class TXTendiesPackage;

@interface TXWallpaperManager : NSObject

+ (instancetype)sharedManager;

@property (nonatomic, strong, readonly) TXTendiesPackage *activePackage;

/// 重新读取偏好 + 重新解析 .tendies（壁纸变更/偏好变更时调用）
- (void)reloadFromDisk;

#pragma mark - 由 Hook 调用

/// 主挂载点：PBUIWallpaperViewController 的 _wallpaperContainerView。
/// 壁纸视图自己的 contentView 在 iOS 16 上经常是「副本」
/// （PBUIFakeBlurView / PBUISnapshotReplicaView / PBUIPortalReplicaEffectView），
/// 挂进去会"下拉通知中心看得到、松手就消失"。
- (void)attachToWallpaperContainerView:(UIView *)container;

- (void)attachToWallpaperView:(UIView *)view;   // 退路：只能拿到壁纸视图时用
- (void)layoutWallpaperWithView:(UIView *)view; // 尺寸变化
- (void)pauseWallpaperWithView:(UIView *)view;
- (void)resumeWallpaperWithView:(UIView *)view;

- (void)setLockScreenActive:(BOOL)active;       // 锁屏出现/消失
- (void)handleEvent:(UIEvent *)event;           // 全局事件（可用作全屏交互）

#pragma mark - 工具 / 诊断

/// 按名字读实例变量（沿继承链查找）。
/// 不能用 KVC：UIKit 私有类普遍把 accessInstanceVariablesDirectly 关掉，
/// valueForKey:@"wallpaperContainerView" 会直接失败 —— 这正是容器一直没找到的原因。
+ (id)tx_ivarValue:(id)object named:(NSString *)name;

/// 启动几秒后打印一次：容器到底找没找到、当前渲染层挂在哪个宿主上
- (void)logContainerDiagnostics;

@end
