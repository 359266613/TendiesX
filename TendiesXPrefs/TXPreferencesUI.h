//
//  TXPreferencesUI.h
//  Preferences.framework（私有）的最小声明，只为编译期用，运行期由 Settings.app
//  已经加载的真实类来解析，所以不需要链接该框架（LDFLAGS 用 dynamic_lookup）。
//

#ifndef TXPreferencesUI_h
#define TXPreferencesUI_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

/// PSSpecifier 的 cell 类型
enum {
    TXCellGroup      = 0,
    TXCellLink       = 1,
    TXCellLinkList   = 2,
    TXCellTitle      = 4,
    TXCellSwitch     = 6,
    TXCellStaticText = 7,
    TXCellButton     = 13,
};

@interface PSSpecifier : NSObject
+ (instancetype)groupSpecifier;
+ (instancetype)groupSpecifierWithName:(NSString *)name;
+ (instancetype)preferenceSpecifierNamed:(NSString *)name
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long long)cell
                                    edit:(Class)edit;
- (void)setProperty:(id)value forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;
- (void)setButtonAction:(SEL)action;
- (void)setTarget:(id)target;
- (NSString *)name;
@end

@interface PSListController : UIViewController
@property (nonatomic, retain) NSArray *specifiers;
@property (nonatomic, retain) PSSpecifier *specifier;
- (void)reloadSpecifiers;
- (void)reloadSpecifier:(PSSpecifier *)specifier;
@end

#endif /* TXPreferencesUI_h */
