//
//  TXRootListController.m
//  设置面板：写 com.axs.tendiesx 偏好，并广播 Darwin 通知让 SpringBoard 侧重载。
//  扫描目录：/var/mobile/Library/TendiesX/ 与 /var/mobile/Media/TendiesX/
//
//  设计要点（踩过的坑，勿改回去）：
//  1. 必须把 specifiers 写回 PSListController 的 _specifiers 实例变量，否则面板全白；
//  2. 开关值同时实现「specifier 的 get/set 选择器」与控制器级
//     readPreferenceValue: / setPreferenceValue:specifier: 两条路；
//  3. 切换开关时**不要**重建 specifiers（会让正在处理的点击回弹，表现为开关自己关掉）；
//  4. **不要用 PSListItemsController + set:/get:** —— 它在 prepareSpecifiersMetadata 里会
//      拿到非字符串的选择器值并抛 unrecognized selector，直接把设置 App 干崩（已实测）。
//      壁纸选择改为自建二级页 + 自己实现 didSelectRowAtIndexPath。
//

#import "TXPreferencesUI.h"
#import "TXLogger.h"
#import <objc/runtime.h>

static NSString *const kTXDomain = @"com.axs.tendiesx";
static NSString *const kTXReloadNotification = @"com.axs.tendiesx/ReloadPrefs";
static NSString *const kTXTendiesDirs[] = {
    @"/var/mobile/Library/TendiesX",
    @"/var/mobile/Media/TendiesX",
    nil
};
/// 「自动」选项对应的值（空串 = 让 Tweak 自动发现）
static NSString *const kTXAutoValue = @"";
static NSString *const kTXAutoTitle = @"自动（扫描到的第一个）";

#pragma mark - specifiers 写回（面板白屏的关键）

/// PSListController 的表数据源读的是它自己的 `_specifiers` 实例变量。
/// 只 `return` 数组而不写回该 ivar 时，日志能看到 specifiers 已构建，但界面全白。
static void TXAssignSpecifiers(PSListController *controller, NSArray *specifiers) {
    static Ivar ivar = NULL;
    if (!ivar) {
        ivar = class_getInstanceVariable(object_getClass(controller), "_specifiers");
    }
    if (ivar) {
        object_setIvar(controller, ivar, specifiers);
    }
}

#pragma mark - 偏好读写

static id TXPrefGet(NSString *key) {
    return (__bridge_transfer id)CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                           (__bridge CFStringRef)kTXDomain);
}

static void TXPrefSet(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kTXDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTXDomain);

    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kTXReloadNotification,
                                         NULL, NULL, YES);
}

static BOOL TXPrefBool(NSString *key, BOOL fallback) {
    id value = TXPrefGet(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

#pragma mark - 扫描

static NSString *TXDisplayName(NSString *path) {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSRange dash = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return dash.location == NSNotFound ? name : [name substringToIndex:dash.location];
}

static NSArray<NSString *> *TXScanPackages(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (int i = 0; kTXTendiesDirs[i] != nil; i++) {
        NSString *dir = kTXTendiesDirs[i];
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) {
                continue;
            }
            if ([[item.pathExtension lowercaseString] isEqualToString:@"tendies"]
                || (isDir && [item hasSuffix:@".tendies"])) {
                [found addObject:full];
            }
        }
    }

    [found sortUsingSelector:@selector(compare:)];
    return found;
}

#pragma mark - 壁纸列表（自建二级页）

static NSArray *gTXPackageSpecifiers = nil;
static NSArray<NSString *> *gTXPackagePaths = nil;   // 与 section 0 的行一一对应

@interface TXPackageListController : PSListController
@end

@implementation TXPackageListController

- (NSArray *)specifiers {
    if (!gTXPackageSpecifiers) {
        TXLog(@"面板: 开始构建壁纸列表");
        NSMutableArray *specs = [NSMutableArray array];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];

        NSString *current = TXPrefGet(@"ActivePackagePath");
        NSArray<NSString *> *packages = TXScanPackages();

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"点一下即可切换"]];

        for (NSString *path in packages) {
            BOOL selected = [path isEqualToString:current];
            // 用普通行 + 自己接管 didSelectRowAtIndexPath：
            // 不依赖 PSButtonCell 的 buttonAction 内部行为，也不碰 PSListItemsController。
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", TXDisplayName(path)]
                                                              target:nil set:nil get:nil detail:nil
                                                                cell:TXCellTitle edit:nil];
            [specs addObject:spec];
            [paths addObject:path];
        }

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"其它"]];

        PSSpecifier *autoSpec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@",
                                  (!current.length ? @"✓ " : @""), kTXAutoTitle]
                                                              target:nil set:nil get:nil detail:nil
                                                                cell:TXCellTitle edit:nil];
        [specs addObject:autoSpec];

        gTXPackagePaths = [paths copy];
        gTXPackageSpecifiers = [specs copy];
        TXLog(@"面板: 壁纸列表构建完成，%lu 个壁纸", (unsigned long)paths.count);
    }
    TXAssignSpecifiers(self, gTXPackageSpecifiers);
    return gTXPackageSpecifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择壁纸";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    gTXPackageSpecifiers = nil;
    gTXPackagePaths = nil;
    [self reloadSpecifiers];
}

// 自己接管点击：section 0 的行按顺序对应 gTXPackagePaths，section 1 只有「自动」
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    NSString *path = nil;
    if (indexPath.section == 0) {
        if (indexPath.row < (NSInteger)gTXPackagePaths.count) {
            path = gTXPackagePaths[indexPath.row];
        }
    } else {
        path = kTXAutoValue;
    }

    if (path == nil) {
        return;
    }

    TXPrefSet(@"ActivePackagePath", path);
    TXLog(@"面板: ActivePackagePath -> %@", path.length ? path : @"(自动)");

    // 不自动返回：留在列表里把 ✓ 刷出来，用户能看到确实切过去了
    gTXPackageSpecifiers = nil;
    gTXPackagePaths = nil;
    [self reloadSpecifiers];
}

@end

#pragma mark - 根页面

static NSArray *gTXRootSpecifiers = nil;

@interface TXRootListController : PSListController
@end

@interface TXRootListController ()
- (PSSpecifier *)tx_switchNamed:(NSString *)name key:(NSString *)key to:(NSMutableArray *)specs;
- (void)tx_buttonNamed:(NSString *)name action:(SEL)action to:(NSMutableArray *)specs;
- (void)tx_rescan:(PSSpecifier *)specifier;
@end

@implementation TXRootListController

/// 能打出来就说明 bundle 的二进制已被 Settings 加载，类可用
+ (void)load {
    TXLog(@"======== TendiesXPrefs bundle 已加载，TXRootListController 可用 ========");
}

#pragma mark - 规格构建

- (NSArray *)specifiers {
    if (!gTXRootSpecifiers) {
        TXLog(@"面板: 开始构建根 specifiers");
        NSMutableArray *specs = [NSMutableArray array];

        #pragma mark 开关
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"开关"]];
        [self tx_switchNamed:@"启用"       key:@"Enabled"            to:specs];
        [self tx_switchNamed:@"触摸交互"   key:@"InteractionEnabled" to:specs];
        [self tx_switchNamed:@"陀螺仪视差" key:@"ParallaxEnabled"    to:specs];

        #pragma mark 壁纸（二级页）
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"壁纸"]];
        NSString *current = TXPrefGet(@"ActivePackagePath");
        PSSpecifier *picker = [PSSpecifier preferenceSpecifierNamed:
                               [NSString stringWithFormat:@"选择壁纸（当前：%@）",
                                current.length ? TXDisplayName(current) : @"自动"]
                                                             target:nil set:nil get:nil
                                                           detail:[TXPackageListController class]
                                                             cell:TXCellLink edit:nil];
        [specs addObject:picker];
        [self tx_buttonNamed:@"重新扫描目录" action:@selector(tx_rescan:) to:specs];

        #pragma mark 说明
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"说明"]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"把 .tendies 放到 /var/mobile/Library/TendiesX/，再点「重新扫描目录」"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellStaticText edit:nil]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"运行日志：/var/mobile/Library/Logs/TendiesX.log"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellStaticText edit:nil]];

        #pragma mark 关于我们（固定：所有插件一致）
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"关于我们"]];
        [self tx_buttonNamed:@"Sileo 越狱源" action:@selector(openSileoRepo:) to:specs];
        [self tx_buttonNamed:@"TG分享频道"  action:@selector(openTelegramChannel:) to:specs];
        [self tx_buttonNamed:@"QQ交流群组"  action:@selector(openQQGroup:) to:specs];

        gTXRootSpecifiers = [specs copy];
        TXLog(@"面板: 根 specifiers 构建完成，%lu 个", (unsigned long)gTXRootSpecifiers.count);
    }
    TXAssignSpecifiers(self, gTXRootSpecifiers);
    return gTXRootSpecifiers;
}

- (PSSpecifier *)tx_switchNamed:(NSString *)name key:(NSString *)key to:(NSMutableArray *)specs {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name
                                                       target:self
                                                          set:@selector(tx_setSwitchValue:specifier:)
                                                          get:@selector(tx_getSwitchValue:)
                                                       detail:nil
                                                         cell:TXCellSwitch
                                                         edit:nil];
    [spec setProperty:key forKey:@"key"];
    [specs addObject:spec];
    return spec;
}

- (void)tx_buttonNamed:(NSString *)name action:(SEL)action to:(NSMutableArray *)specs {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil
                                                       detail:nil cell:TXCellButton edit:nil];
    [spec setButtonAction:action];
    [specs addObject:spec];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TendiesX";
    TXLog(@"面板: viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    gTXRootSpecifiers = nil;
    [self reloadSpecifiers];
}

- (void)tx_rescan:(PSSpecifier *)specifier {
    gTXRootSpecifiers = nil;
    gTXPackageSpecifiers = nil;
    gTXPackagePaths = nil;
    [self reloadSpecifiers];
    TXLog(@"面板: 重新扫描目录完成");
}

// 「重新扫描目录」等按钮走这里（按钮 cell 的 action 会带 specifier 参数）
- (void)tx_rescan { [self tx_rescan:nil]; }

#pragma mark - 开关读写（get/set 选择器 + 控制器级读写，两条路都覆盖）

- (id)tx_getSwitchValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return @NO;
    }
    return @(TXPrefBool(key, YES));
}

- (void)tx_setSwitchValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return;
    }
    TXPrefSet(key, value);
    TXLog(@"面板: %@ -> %@", key, value);
}

#pragma mark - 控制器级读写（部分版本的 cell 走这两条）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return nil;
    }
    id value = TXPrefGet(key);
    if (value) {
        return value;
    }
    // 开关类没写过时默认开
    return [specifier propertyForKey:@"default"] ?: @YES;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return;
    }
    TXPrefSet(key, value);
}

#pragma mark - 关于我们（固定：scheme 优先 + 网页兜底）

- (void)openURL:(NSURL *)primary fallback:(NSURL *)fallback {
    UIApplication *app = UIApplication.sharedApplication;
    if (primary) {
        [app openURL:primary options:@{} completionHandler:^(BOOL success) {
            if (!success && fallback) {
                [app openURL:fallback options:@{} completionHandler:nil];
            }
        }];
    } else if (fallback) {
        [app openURL:fallback options:@{} completionHandler:nil];
    }
}

- (void)openSileoRepo {
    NSString *source = @"https://axs66.github.io/pro";
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet] ?: source;
    [self openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sileo://source/%@", encoded]]
         fallback:[NSURL URLWithString:source]];
}
- (void)openSileoRepo:(id)_          { [self openSileoRepo]; }

- (void)openTelegramChannel {
    [self openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
         fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}
- (void)openTelegramChannel:(id)_    { [self openTelegramChannel]; }

- (void)openQQGroup {
    [self openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&card_type=group&uin=678055716"]
         fallback:nil];
}
- (void)openQQGroup:(id)_            { [self openQQGroup]; }

@end
