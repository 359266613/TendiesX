//
//  Headers/Preferences/PSSpecifier.h
//  本插件自用的**最小**声明（不是完整 dump，只包含面板用到的东西）：
//    ① cell 类型常量（Preferences 私有枚举；值跨版本稳定，运行时等价于 +cellTypeFromString:）
//    ② PSSpecifier 只声明面板用到的属性/方法
//  完整 dump 见 Reference/Private/PSSpecifier.h（只用来核对名字，不参与编译）。
//

#ifndef TendiesXPSSpecifier_h
#define TendiesXPSSpecifier_h

#import <Foundation/Foundation.h>

/// cell 类型（模板里直接用这些常量，不再运行时换算）
typedef enum {
    PSGroupCell      = 0,   // 分组标题
    PSLinkCell       = 1,   // 可跳转的二级页入口
    PSTitleValueCell = 4,   // 左标题右值的普通行
    PSSwitchCell     = 6,   // 开关
    PSButtonCell     = 13,  // 按钮
} TXPSCellType;

@interface PSSpecifier : NSObject

@property (nonatomic) SEL buttonAction;
@property (nonatomic) long long cellType;
@property (nonatomic, strong) Class detailControllerClass;
@property (nonatomic, strong) NSString *identifier;
@property (nonatomic, strong) NSString *name;
@property (nonatomic, weak) id target;

/// 建分组行
+ (instancetype)groupSpecifierWithName:(NSString *)name;

/// 建普通行（cell 传上面的常量，detail 传二级页控制器类）
+ (instancetype)preferenceSpecifierNamed:(NSString *)named
                                  target:(id)target
                                     set:(SEL)set
                                     get:(SEL)get
                                  detail:(Class)detail
                                    cell:(long long)cell
                                    edit:(Class)edit;

/// plist 里的 key 都会变成 specifier 的属性
- (void)setProperty:(id)property forKey:(NSString *)key;
- (id)propertyForKey:(NSString *)key;

@end

#endif /* TendiesXPSSpecifier_h */
