//
//  Headers/Preferences/PSListController.h
//  本插件自用的**最小**声明（不是完整 dump）。
//  完整的 PSListController.h 需要一整套 PS* 协议头，本面板用不到，所以只声明必要接口。
//  运行时这些类由设置 App 已经加载的 Preferences.framework 提供，
//  所以 bundle 只需要 `-undefined dynamic_lookup`，不必链接该私有框架。
//

#ifndef TendiesXPSListController_h
#define TendiesXPSListController_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PSSpecifier.h"

@interface PSViewController : UIViewController

/// 开关等 cell 的读写入口（两条路：控制器级 + specifier 的 get/set 选择器）
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;

@end

@interface PSListController : PSViewController

/// 从 bundle 里的 Root.plist 加载规格（模板的标准做法）
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;

- (NSArray *)specifiers;
- (PSSpecifier *)specifierForID:(NSString *)identifier;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;

@end

#endif /* TendiesXPSListController_h */
