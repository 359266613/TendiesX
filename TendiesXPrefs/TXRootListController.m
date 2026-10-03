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
#import "TXPosterInstaller.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kTXDomain = @"com.axs.tendiesx";
static NSString *const kTXReloadNotification = @"com.axs.tendiesx/ReloadPrefs";
/// 与 Tweak 侧统一：只有一个根目录
///   <根>/xxx.tendies     投放中的压缩包
///   <根>/xxx.tendies/    解压后的素材目录（同名，但是目录）
static NSString *const kTXBaseDir = @"/var/mobile/Library/TendiesX";
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

/// cell 类型不写死数字：dump 确认 PSTableCell 有 +cellTypeFromString:，
/// 由它把 "PSSwitchCell" 这类字符串转成当前系统使用的数字；取不到才退回兜底值。
static long long TXCellType(NSString *name, long long fallback) {
    Class cls = NSClassFromString(@"PSTableCell");
    if ([cls respondsToSelector:@selector(cellTypeFromString:)]) {
        long long type = [cls cellTypeFromString:name];
        if (type > 0) {
            return type;
        }
    }
    return fallback;
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

/// 只发重载通知，不写任何键（让 SpringBoard 侧的 Tweak 立刻重新读盘 + 导入素材）
static void TXNotifyReload(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kTXReloadNotification,
                                         NULL, NULL, YES);
}

#pragma mark - 扫描

static NSString *TXDisplayName(NSString *path) {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSRange dash = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return dash.location == NSNotFound ? name : [name substringToIndex:dash.location];
}

/// xxx.tendies 是「目录」的才是可用素材；是「压缩包」的属于还没导入
static NSArray<NSString *> *TXScanPackages(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (NSString *item in [fm contentsOfDirectoryAtPath:kTXBaseDir error:NULL]) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"tendies"] == NO) {
            continue;
        }
        NSString *full = [kTXBaseDir stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
            [found addObject:full];
        }
    }

    [found sortUsingSelector:@selector(compare:)];
    return found;
}

/// 还没导入的压缩包数量（只用于提示行）
static NSUInteger TXPendingImportCount(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger count = 0;

    for (NSString *item in [fm contentsOfDirectoryAtPath:kTXBaseDir error:NULL]) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"tendies"] == NO
            || [item hasPrefix:@"."]) {
            continue;
        }
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[kTXBaseDir stringByAppendingPathComponent:item]
                     isDirectory:&isDir] && !isDir) {
            count++;
        }
    }
    return count;
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

        if (TXPendingImportCount()) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"检测到未导入的 .tendies，请回上一页导入"
                                                           target:nil set:nil get:nil detail:nil
                                                             cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];
        }

        for (NSString *path in packages) {
            BOOL selected = [path isEqualToString:current];
            // 用普通行 + 自己接管 didSelectRowAtIndexPath：
            // 不依赖 PSButtonCell 的 buttonAction 内部行为，也不碰 PSListItemsController。
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", TXDisplayName(path)]
                                                              target:nil set:nil get:nil detail:nil
                                                                cell:TXCellType(@"PSTitleValueCell", TXCellTitle) edit:nil];
            [specs addObject:spec];
            [paths addObject:path];
        }

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"其它"]];

        PSSpecifier *autoSpec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@",
                                  (!current.length ? @"✓ " : @""), kTXAutoTitle]
                                                              target:nil set:nil get:nil detail:nil
                                                                cell:TXCellType(@"PSTitleValueCell", TXCellTitle) edit:nil];
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

@interface TXRootListController : PSListController <UIDocumentPickerDelegate>
@end

@interface TXRootListController ()
- (PSSpecifier *)tx_switchNamed:(NSString *)name key:(NSString *)key to:(NSMutableArray *)specs;
- (void)tx_buttonNamed:(NSString *)name action:(SEL)action to:(NSMutableArray *)specs;
- (void)tx_pickFiles:(PSSpecifier *)specifier;
- (void)tx_rescan:(PSSpecifier *)specifier;
- (void)tx_installPoster:(PSSpecifier *)specifier;
- (void)tx_alertMessage:(NSString *)message;
- (void)tx_refreshAfterImport;
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
        // 默认关：挂到副本宿主会让系统同时跑多套动画，表现为严重卡顿
        [self tx_switchNamed:@"兜底挂载（仅排查用）" key:@"MountFallback" to:specs];

        #pragma mark 壁纸（二级页）
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"壁纸"]];
        NSString *current = TXPrefGet(@"ActivePackagePath");
        PSSpecifier *picker = [PSSpecifier preferenceSpecifierNamed:
                               [NSString stringWithFormat:@"选择壁纸（当前：%@）",
                                current.length ? TXDisplayName(current) : @"自动"]
                                                             target:nil set:nil get:nil
                                                           detail:[TXPackageListController class]
                                                             cell:TXCellType(@"PSLinkCell", TXCellLink) edit:nil];
        [specs addObject:picker];

        #pragma mark 导入素材
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"导入素材"]];
        [self tx_buttonNamed:@"从「文件」App 选择 .tendies" action:@selector(tx_pickFiles:) to:specs];
        [self tx_buttonNamed:@"重新扫描素材目录" action:@selector(tx_rescan:) to:specs];
        // route A：装进系统海报库，由 PosterBoard 原生渲染（锁屏/主屏/AOD 全由系统负责）
        [self tx_buttonNamed:@"安装到系统海报库（推荐）" action:@selector(tx_installPoster:) to:specs];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"装完去「设置 → 墙纸 → 添加新墙纸 → 收藏」里选它"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"解压后是 /var/mobile/Library/TendiesX/名字.tendies/（同名目录），不留压缩包"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"也可以直接用 Filza 把 .tendies 丢进 /var/mobile/Library/TendiesX/ 再点重新扫描"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];

        #pragma mark 说明
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"说明"]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"运行日志：/var/mobile/Library/Logs/TendiesX.log"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];

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
                                                         cell:TXCellType(@"PSSwitchCell", TXCellSwitch)
                                                         edit:nil];
    [spec setProperty:key forKey:@"key"];
    [specs addObject:spec];
    return spec;
}

- (void)tx_buttonNamed:(NSString *)name action:(SEL)action to:(NSMutableArray *)specs {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:name target:self set:nil get:nil
                                                       detail:nil cell:TXCellType(@"PSButtonCell", TXCellButton) edit:nil];
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

// 重新扫描：通知 Tweak 重新读盘，稍后刷新列表
- (void)tx_rescan:(PSSpecifier *)specifier {
    TXNotifyReload();
    TXLog(@"面板: 已请求重新扫描素材");
    [self tx_refreshAfterImport];
}

// 按钮 cell 的 action 通常带 specifier 参数，这里兜无参版本（不同系统版本行为不一致）
- (void)tx_rescan    { [self tx_rescan:nil]; }
- (void)tx_pickFiles { [self tx_pickFiles:nil]; }

#pragma mark - route A：安装进系统海报库

- (void)tx_alertMessage:(NSString *)message {
    UIAlertController *alert =
        [UIAlertController alertControllerWithTitle:@"TendiesX"
                                            message:message
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好"
                                              style:UIAlertActionStyleDefault
                                            handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

// 把当前选中 .tendies 的 descriptor 写进 PosterBoard 的海报存储。
// 之后渲染完全由系统负责：不会卡（不在我们进程里画），也不会"松手就消失"。
- (void)tx_installPoster:(PSSpecifier *)specifier {
    NSString *path = TXPrefGet(@"ActivePackagePath");
    if (!path.length) {
        [self tx_alertMessage:@"先在「壁纸」里选一个已导入的 .tendies"];
        return;
    }
    TXLog(@"面板: 开始安装到系统海报库: %@", path);

    NSArray<NSString *> *installed =
        [TXPosterInstaller.sharedInstaller installPackageAtPath:path];

    if (installed.count) {
        [self tx_alertMessage:[NSString stringWithFormat:
            @"已安装 %lu 个海报。\n\n下一步：设置 → 墙纸 → 添加新墙纸 → 收藏，"
            @"选中它即可。锁屏/主屏动画全部由系统渲染。",
            (unsigned long)installed.count]];
    } else {
        [self tx_alertMessage:@"安装失败。请看日志 /var/mobile/Library/Logs/TendiesX.log 里的 [A] 开头的行"];
    }
}

- (void)tx_installPoster { [self tx_installPoster:nil]; }

#pragma mark - 从「文件」App 导入

// asCopy:YES 会把用户选中的文件先复制到 App 自己的临时目录再给我们 URL，
// 省掉 security-scoped 那一套，拿到就能直接搬走。
- (void)tx_pickFiles:(PSSpecifier *)specifier {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData]
                                                                   asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
    TXLog(@"面板: 打开「文件」选择器");
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger copied = 0;

    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        if (![[name.pathExtension lowercaseString] isEqualToString:@"tendies"]) {
            name = [name stringByAppendingPathExtension:@"tendies"];
        }
        // 目标与解压目录同名（xxx.tendies）：删掉旧的压缩包或旧素材目录，实现同名替换
        NSString *destination = [kTXBaseDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:destination error:NULL];

        NSError *error = nil;
        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:&error]) {
            copied++;
        } else {
            TXLog(@"面板: 复制失败 %@（%@）", name, error.localizedDescription);
        }
    }

    TXLog(@"面板: 已放入投放目录 %lu 个，请求 Tweak 导入解压", (unsigned long)copied);
    if (copied) {
        TXNotifyReload();
    }
    [self tx_refreshAfterImport];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    TXLog(@"面板: 取消选择文件");
}

// 导入 + 解压是在 SpringBoard 侧异步做的，等一会儿再刷新列表
- (void)tx_refreshAfterImport {
    __weak TXRootListController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gTXRootSpecifiers = nil;
        gTXPackageSpecifiers = nil;
        gTXPackagePaths = nil;
        [weakSelf reloadSpecifiers];
        TXLog(@"面板: 列表已刷新");
    });
}

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
