//
//  Headers/Preferences/PSTableCell.h
//  本插件自用的**最小**声明（不是完整 dump），只包含自定义 cell 用到的东西：
//  自定义 cell 继承 PSTableCell，靠 Value1 样式（左标题 / 右值）+ refreshCellContentsWithSpecifier: 刷新。
//  完整 dump 见 Reference/Private/PSTableCell.h（仅核对名字用）。
//

#ifndef TendiesXPSTableCell_h
#define TendiesXPSTableCell_h

#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import "PSSpecifier.h"

@interface PSTableCell : UITableViewCell

@property (nonatomic, strong) PSSpecifier *specifier;
@property (nonatomic) long long type;

/// 框架创建 cell 时用的初始化器（specifier 顺着它传进来）
- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier;

/// cell 复用 / reloadSpecifier 时框架重调，内容必须在这里同步
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier;
- (void)reloadWithSpecifier:(PSSpecifier *)specifier animated:(BOOL)animated;

@end

#endif /* TendiesXPSTableCell_h */
