//
//  TXDetailCell.m
//

#import "TXDetailCell.h"
#import <UIKit/UIKit.h>

// PSTableCell 的右侧值标签是 Preferences 的私有接口，显式声明一次再用
@interface PSTableCell (TXDetailValue)
- (void)setValue:(id)value;
@end

@implementation TXDetailCell

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                   specifier:(PSSpecifier *)specifier {
    // 固定 Value1：左边标题、右边说明
    self = [super initWithStyle:UITableViewCellStyleValue1
              reuseIdentifier:reuseIdentifier
                   specifier:specifier];
    if (self) {
        [self tx_refreshWithSpecifier:specifier];
    }
    return self;
}

// cell 被复用时框架会重新调这里，保证内容始终跟着当前 specifier
- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    [self tx_refreshWithSpecifier:specifier];
}

- (void)tx_refreshWithSpecifier:(PSSpecifier *)specifier {
    // 标题由框架按 specifier.name 显示，这里只补右侧的值
    self.textLabel.text = specifier.name ?: @"";

    NSString *detail = [specifier propertyForKey:@"txDetailText"] ?: @"";
    self.detailTextLabel.text = detail;
    if ([self respondsToSelector:@selector(setValue:)]) {
        [self setValue:detail];   // Preferences 的 PSTableCell 用这个更新右侧值标签
    }

    // 这一行点进去还有一页（选择素材），所以永远要箭头
    self.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
}

@end
