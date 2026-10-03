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

- (void)attachToWallpaperView:(UIView *)view;   // 挂载渲染层（已挂载会先卸载）
- (void)layoutWallpaperWithView:(UIView *)view; // 尺寸变化
- (void)pauseWallpaperWithView:(UIView *)view;
- (void)resumeWallpaperWithView:(UIView *)view;

- (void)setLockScreenActive:(BOOL)active;       // 锁屏出现/消失
- (void)handleEvent:(UIEvent *)event;           // 全局事件（可用作全屏交互）

@end
