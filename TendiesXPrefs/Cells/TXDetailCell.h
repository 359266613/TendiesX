//
//  TXDetailCell.h
//  「左边标题 + 右边当前值 + 箭头」的通用 cell：
//   · 右侧文字取 specifier 的 txDetailText（控制器在 viewWillAppear / 选完之后刷新）
//   · 点进去仍然是正常的二级页（specifier 的 detailControllerClass 决定推哪个页面）
//
//  实现方式与 KeyboardTools 的 KTDetailCell 一致（Preferences 的 PSTableCell 子类）。
//  头文件只引 PSSpecifier.h：theos 自带的那套 Preferences 私有头是 module，
//  引一个头就等于把 Preferences 整个模块（含 PSTableCell）带进来。
//

#import <Preferences/PSSpecifier.h>

@interface TXDetailCell : PSTableCell
@end
