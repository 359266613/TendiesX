//
//  TXPreferencesUI.h
//  Preferences.framework（私有）的最小声明，只为编译期用；运行期由 Settings.app
//  已经加载的真实类来解析，所以不需要链接该框架（LDFLAGS 用 dynamic_lookup）。
//
//  每条都对照 Reference/Private/ 的 dump 核对过（iOS 16.5）：
//    PSSpecifier.h / PSViewController.h / PSListController.h / PSTableCell.h
//
//  两个已修正的坑：
//    1) PSListController 的父类是 PSViewController（不是 UIViewController），
//       readPreferenceValue: / setPreferenceValue:specifier: 声明在 PSViewController 上；
//    2) cell 类型**不要写死数字** —— PSTableCell 有 +cellTypeFromString:，
//       用 "PSSwitchCell" 这类字符串在运行时换数字，跨版本更稳。
//

#ifndef TXPreferencesUI_h
#define TXPreferencesUI_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// cell 类型兜底值（正常走 PSTableCell +cellTypeFromString:，取不到时才用这些）
enum {
    TXCellGroup      = 0,   // PSGroupCell
    TXCellLink       = 1,   // PSLinkCell
    TXCellTitle      = 4,   // PSTitleValueCell
    TXCellSwitch     = 6,   // PSSwitchCell
    TXCellStaticText = 7,   // PSStaticTextCell
    TXCellButton     = 13,  // PSButtonCell
};

@interface PSSpecifier : NSObject
@property (nonatomic, retain) NSString *name;
@property (nonatomic) long long cellType;
@property (nonatomic) SEL buttonAction;
@property (weak, nonatomic) id target;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)emptyGroupSpecifier;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long long)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
@end

/// 只用到「字符串 → cell 类型数字」的转换
@interface PSTableCell : UITableViewCell
+ (long long)cellTypeFromString:(NSString *)string;
+ (NSString *)stringFromCellType:(long long)type;
@end

@interface PSViewController : UIViewController
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface PSListController : PSViewController
@property (nonatomic, retain) NSArray *specifiers;
@property (nonatomic, retain) PSSpecifier *specifier;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end

#endif /* TXPreferencesUI_h */
