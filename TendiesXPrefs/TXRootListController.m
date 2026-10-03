//
//  TXRootListController.m
//  设置面板分两半：
//    · 开关 / 素材 / 安装 / 说明  → Resources/Root.plist（改文案不用重编）
//    · 关于我们（Sileo / TG / QQ）→ 本文件里动态构建（写死在代码里，方便随时改链接）
//
//  这里只做四件事：
//    1) 在 plist 结果后面追加「关于我们」，并按 id 把按钮接到方法上；
//    2) 刷新动态文案（"当前素材"那一行）；
//    3) 实现按钮逻辑：安装 / 清理重复 / 选文件 / 重新扫描 / 关于我们；
//    4) 二级页「选择素材」—— 它是扫目录得到的动态列表，只能留在代码里。
//
//  设计要点（都是踩过的坑，勿改回去）：
//  1) **不要从零构建 specifiers**：PSListController 会自动读 bundle 里的 Root.plist，
//     从零构建再写回 _specifiers 很容易整页白屏。
//     允许的重写只有一种：先 `[super specifiers]` 拿 plist 结果，再在后面追加代码里的那一段，
//     最后写回 _specifiers —— 见下面 -specifiers；
//  2) 开关值走控制器级 readPreferenceValue: / setPreferenceValue:specifier:
//     （dump 确认声明在 PSViewController 上），所以 Root.plist 里只写 key、不写 defaults；
//  3) 切换开关时不要重建 specifiers（会让正在处理的点击回弹，表现为开关自己关掉）；
//  4) **不要用 PSListItemsController + set:/get:** —— 它在 prepareSpecifiersMetadata 里
//     会拿到非字符串的选择器值并抛 unrecognized selector，直接把设置 App 干崩（已实测）。
//

#import "TXPreferencesUI.h"
#import "TXLogger.h"
#import <objc/runtime.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

static NSString *const kTXDomain = @"com.axs.tendiesx";
static NSString *const kTXReloadNotification = @"com.axs.tendiesx/ReloadPrefs";
static NSString *const kTXInstallNotification = @"com.axs.tendiesx/InstallPoster";
static NSString *const kTXCleanupNotification = @"com.axs.tendiesx/CleanupDuplicates";

/// 素材根目录（与 Tweak 侧一致）：压缩包和已解包目录都放这里
static NSString *const kTXBaseDir = @"/var/mobile/Library/TendiesX";

#pragma mark - specifiers 写回（二级页动态列表要用）

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
}

static BOOL TXPrefBool(NSString *key, BOOL fallback) {
    id value = TXPrefGet(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

/// 广播 Darwin 通知，让 SpringBoard 侧 worker 重新读偏好
static void TXNotifyReload(void) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)kTXReloadNotification,
                                         NULL, NULL, YES);
}

static void TXNotify(NSString *name) {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, YES);
}

#pragma mark - 扫描

static NSString *TXDisplayName(NSString *path) {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSRange dash = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return dash.location == NSNotFound ? name : [name substringToIndex:dash.location];
}

/// 素材目录里的全部 .tendies：压缩包和已解包目录都算（安装时自动解包）
static NSArray<NSString *> *TXScanPackages(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (NSString *item in [fm contentsOfDirectoryAtPath:kTXBaseDir error:NULL]) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"tendies"] == NO
            || [item hasPrefix:@"."]) {
            continue;
        }
        [found addObject:[kTXBaseDir stringByAppendingPathComponent:item]];
    }

    [found sortUsingSelector:@selector(compare:)];
    return found;
}

#pragma mark - 素材列表（二级页，动态）

static NSArray *gTXPackageSpecifiers = nil;
static NSArray<NSString *> *gTXPackagePaths = nil;   // 与 section 0 的行一一对应

@interface TXPackageListController : PSListController
@end

@implementation TXPackageListController

- (NSArray *)specifiers {
    if (!gTXPackageSpecifiers) {
        TXLog(@"面板: 开始构建素材列表");
        NSMutableArray *specs = [NSMutableArray array];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];

        NSString *current = TXPrefGet(@"SourcePath");
        NSArray<NSString *> *packages = TXScanPackages();

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"点一下选中要安装的素材"]];

        for (NSString *path in packages) {
            BOOL selected = [path isEqualToString:current];
            // 用普通行 + 自己接管 didSelectRowAtIndexPath：不依赖 PSButtonCell 的内部行为，
            // 也绝不碰 PSListItemsController。
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", TXDisplayName(path)]
                                                              target:nil set:nil get:nil detail:nil
                                                                cell:TXCellType(@"PSTitleValueCell", TXCellTitle) edit:nil];
            [specs addObject:spec];
            [paths addObject:path];
        }

        if (!paths.count) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"还没有素材。回上一页用「文件」App 选一个 .tendies"
                                                           target:nil set:nil get:nil detail:nil
                                                             cell:TXCellType(@"PSStaticTextCell", TXCellStaticText) edit:nil]];
        }

        gTXPackagePaths = [paths copy];
        gTXPackageSpecifiers = [specs copy];
        TXLog(@"面板: 素材列表构建完成，%lu 个", (unsigned long)paths.count);
    }
    TXAssignSpecifiers(self, gTXPackageSpecifiers);
    return gTXPackageSpecifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择素材";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    gTXPackageSpecifiers = nil;
    gTXPackagePaths = nil;
    [self reloadSpecifiers];
}

// 自己接管点击：section 0 的行按顺序对应 gTXPackagePaths
- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];

    if (indexPath.section != 0 || indexPath.row >= (NSInteger)gTXPackagePaths.count) {
        return;
    }
    NSString *path = gTXPackagePaths[indexPath.row];

    TXPrefSet(@"SourcePath", path);
    TXNotifyReload();
    TXLog(@"面板: SourcePath -> %@", path);

    // 不自动返回：留在列表里把 ✓ 刷出来，用户能看到确实选过去了
    gTXPackageSpecifiers = nil;
    gTXPackagePaths = nil;
    [self reloadSpecifiers];
}

@end

#pragma mark - Root.plist 加载（原生优先，自己解析兜底）

/// Root.plist 的真实路径：先问 bundle，再按安装路径兜底（rootless 在 /var/jb 下）
static NSString *TXRootPlistPath(void) {
    Class cls = NSClassFromString(@"TXRootListController");
    NSBundle *bundle = cls ? [NSBundle bundleForClass:cls] : NSBundle.mainBundle;
    NSString *path = [bundle pathForResource:@"Root" ofType:@"plist"];
    if (path.length) {
        return path;
    }
    NSString *relative = @"Library/PreferenceBundles/TendiesXPrefs.bundle/Root.plist";
    for (NSString *root in @[ @"/var/jb", @"/" ]) {
        NSString *candidate = [root stringByAppendingPathComponent:relative];
        if ([NSFileManager.defaultManager fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

/// 原生加载器 loadSpecifiersFromPlistName:target: —— dump 没收录，所以先探再用。
/// 用 IMP 调用（避免 performSelector 的 ARC 警告），返回值按 +0 处理。
static NSArray *TXLoadSpecifiersNatively(id controller) {
    SEL loader = NSSelectorFromString(@"loadSpecifiersFromPlistName:target:");
    if (![controller respondsToSelector:loader]) {
        return nil;
    }
    IMP imp = [controller methodForSelector:loader];
    if (!imp) {
        return nil;
    }
    typedef NSArray *(*TXSpecLoaderFn)(id, SEL, NSString *, id);
    return ((TXSpecLoaderFn)imp)(controller, loader, @"Root", controller);
}

/// 自解析 Root.plist：与 PSListController 行为对齐的最小实现，只覆盖本插件用到的 cell。
/// 有它兜底，面板内容永远和 Root.plist 一致（不依赖任何私有加载器）。
static NSArray *TXSpecifiersFromPlist(NSDictionary *plist, id target) {
    NSArray *items = plist[@"items"];
    if (![items isKindOfClass:NSArray.class]) {
        return @[];
    }

    NSMutableArray *specs = [NSMutableArray array];
    for (NSDictionary *item in items) {
        if (![item isKindOfClass:NSDictionary.class]) {
            continue;
        }
        NSString *cellName = [item[@"cell"] isKindOfClass:NSString.class] ? item[@"cell"] : @"PSGroupSpecifier";
        NSString *label = [item[@"label"] isKindOfClass:NSString.class] ? item[@"label"] : @"";

        PSSpecifier *spec = nil;
        if ([cellName isEqualToString:@"PSGroupSpecifier"]) {
            spec = [PSSpecifier groupSpecifierWithName:label];
        } else {
            Class detailClass = nil;
            if ([item[@"detail"] isKindOfClass:NSString.class]) {
                detailClass = NSClassFromString(item[@"detail"]);
            }
            // 开关的读写选择器直接指到本类（plist 里没写 get/set 时原生也会这么做）
            SEL getter = NULL;
            SEL setter = NULL;
            if ([cellName isEqualToString:@"PSSwitchCell"]) {
                getter = NSSelectorFromString(@"tx_getSwitchValue:");
                setter = NSSelectorFromString(@"tx_setSwitchValue:specifier:");
            }
            spec = [PSSpecifier preferenceSpecifierNamed:label
                                                  target:target
                                                     set:setter
                                                     get:getter
                                                  detail:detailClass
                                                    cell:TXCellType(cellName, TXCellStaticText)
                                                    edit:NULL];
        }
        if (!spec) {
            continue;
        }

        // 其余键原样搬过去：key / default / footerText / id / action ...
        for (NSString *key in item) {
            if ([key isEqualToString:@"cell"] || [key isEqualToString:@"label"]) {
                continue;
            }
            id value = item[key];
            if (value) {
                [spec setProperty:value forKey:key];
            }
        }
        [specs addObject:spec];
    }
    return specs;
}

/// 面板自检：这几行是排查「面板空/只有一部分」的唯一依据
static void TXLogPanelProbe(void) {
    Class cls = NSClassFromString(@"TXRootListController");
    NSBundle *bundle = cls ? [NSBundle bundleForClass:cls] : NSBundle.mainBundle;
    Class listClass = NSClassFromString(@"PSListController");
    BOOL hasLoader = [listClass instancesRespondToSelector:
                      NSSelectorFromString(@"loadSpecifiersFromPlistName:target:")];
    TXLog(@"面板: bundle=%@", bundle.bundlePath ?: @"(未知)");
    TXLog(@"面板: Root.plist=%@", TXRootPlistPath() ?: @"(没找到！)");
    TXLog(@"面板: 原生加载器=%@", hasLoader ? @"有" : @"缺失");
}

#pragma mark - 根页面（布局全部来自 Resources/Root.plist）

@interface TXRootListController : PSListController <UIDocumentPickerDelegate>
@end

@interface TXRootListController ()
- (NSArray *)tx_aboutSpecifiers;
- (BOOL)tx_hasAboutSection:(NSArray *)specifiers;
- (void)tx_wireButtons;
- (void)tx_refreshDynamicLabels;
- (id)tx_getSwitchValue:(PSSpecifier *)specifier;
- (void)tx_setSwitchValue:(id)value specifier:(PSSpecifier *)specifier;
- (void)tx_installPoster:(PSSpecifier *)specifier;
- (void)tx_cleanupDuplicates:(PSSpecifier *)specifier;
- (void)tx_pollInstallResult:(NSUInteger)attempt;
- (void)tx_pickFiles:(PSSpecifier *)specifier;
- (void)tx_rescan:(PSSpecifier *)specifier;
- (void)tx_alertMessage:(NSString *)message;
- (void)tx_refreshAfterImport;
- (void)openSileoRepo:(id)sender;
- (void)openTelegramChannel:(id)sender;
- (void)openQQGroup:(id)sender;
@end

/// plist 里的按钮 id -> 本类的方法（plist 的 action 只是说明文字，这里才是真正的绑定）
static NSDictionary<NSString *, NSString *> *TXButtonSelectors(void) {
    static NSDictionary<NSString *, NSString *> *map;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        map = @{
            @"install": @"tx_installPoster:",
            @"cleanup": @"tx_cleanupDuplicates:",
            @"pick":    @"tx_pickFiles:",
            @"rescan":  @"tx_rescan:",
            @"sileo":   @"openSileoRepo:",
            @"tg":      @"openTelegramChannel:",
            @"qq":      @"openQQGroup:",
        };
    });
    return map;
}

@implementation TXRootListController

+ (void)load {
    TXLog(@"======== TendiesXPrefs bundle 已加载，TXRootListController 可用 ========");
}

- (void)viewDidLoad {
    [super viewDidLoad];
    // Root.plist 里的 detail 只是字符串，不产生类引用，链接器可能把二级页剔除；
    // 这里显式引用一次保活，并确认它真的在。
    Class detailClass = [TXPackageListController class];
    (void)detailClass;
    TXLogPanelProbe();
    TXLog(@"面板: viewDidLoad，二级页类=%@",
          NSClassFromString(@"TXPackageListController") ? @"可用" : @"缺失");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self tx_wireButtons];
    [self tx_refreshDynamicLabels];
    gTXPackageSpecifiers = nil;   // 回到根页面时让二级页重新扫目录
    gTXPackagePaths = nil;
}

#pragma mark - specifiers（plist + 代码追加的「关于我们」）

/// 唯一允许重写 specifiers 的理由：Root.plist 里放不了"关于我们"那三个按钮
/// （链接/文案要写在代码里，方便直接改）。
/// 做法是**先拿父类结果再追加**，绝不从零构建 —— plist 依旧是布局的唯一来源。
- (NSArray *)specifiers {
    // 三级兜底，任何一级拿到内容就不再往下走（实测 [super specifiers] 在 iOS 16.5 上
    // 并不会自动读 bundle 里的 Root.plist，所以原生加载器和自解析都留着）
    NSArray *base = [super specifiers];
    NSString *source = @"父类";

    if (!base.count) {
        NSArray *native = TXLoadSpecifiersNatively(self);
        if (native.count) {
            base = native;
            source = @"loadSpecifiersFromPlistName:";
        }
    }
    if (!base.count) {
        NSString *path = TXRootPlistPath();
        NSDictionary *plist = path.length ? [NSDictionary dictionaryWithContentsOfFile:path] : nil;
        base = TXSpecifiersFromPlist(plist, self);
        source = path.length ? @"自解析 Root.plist" : @"没有 Root.plist";
    }

    if ([self tx_hasAboutSection:base]) {
        return base;   // 已经追加过了（缓存里返回的就是追加后的那份）
    }

    TXLog(@"面板: 布局来源=%@，%lu 行", source, (unsigned long)base.count);
    NSArray *combined = [(base ?: @[]) arrayByAddingObjectsFromArray:[self tx_aboutSpecifiers]];
    TXAssignSpecifiers(self, combined);   // 表数据源读的是 _specifiers，必须写回
    return combined;
}

/// 「关于我们」——固定在代码里：要改链接 / 文案直接改这张表，不用碰 plist
- (NSArray *)tx_aboutSpecifiers {
    NSMutableArray *specs = [NSMutableArray array];

    PSSpecifier *group = [PSSpecifier groupSpecifierWithName:@"关于我们"];
    [group setProperty:@"aboutGroup" forKey:@"id"];
    [specs addObject:group];

    NSArray<NSArray<NSString *> *> *rows = @[
        @[ @"sileo", @"Sileo 越狱源", @"openSileoRepo:" ],
        @[ @"tg",    @"TG分享频道",   @"openTelegramChannel:" ],
        @[ @"qq",    @"QQ交流群组",   @"openQQGroup:" ],
    ];

    for (NSArray<NSString *> *row in rows) {
        PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:row[1]
                                                          target:self
                                                             set:NULL
                                                             get:NULL
                                                          detail:nil
                                                            cell:TXCellType(@"PSButtonCell", TXCellButton)
                                                            edit:NULL];
        [spec setProperty:row[0] forKey:@"id"];
        [spec setProperty:row[2] forKey:@"action"];
        [spec setTarget:self];
        [spec setButtonAction:NSSelectorFromString(row[2])];
        [specs addObject:spec];
    }
    return specs;
}

- (BOOL)tx_hasAboutSection:(NSArray *)specifiers {
    for (PSSpecifier *spec in specifiers) {
        if ([[spec propertyForKey:@"id"] isEqualToString:@"aboutGroup"]) {
            return YES;
        }
    }
    return NO;
}

/// 把 plist 里带 id 的按钮接到方法上
- (void)tx_wireButtons {
    NSDictionary<NSString *, NSString *> *map = TXButtonSelectors();
    NSUInteger wired = 0;
    for (PSSpecifier *spec in [self specifiers]) {
        NSString *identifier = [spec propertyForKey:@"id"];
        NSString *selectorName = identifier.length ? map[identifier] : nil;
        if (!selectorName.length) {
            continue;
        }
        [spec setTarget:self];
        [spec setButtonAction:NSSelectorFromString(selectorName)];
        wired++;
    }
    TXLog(@"面板: 按钮已绑定 %lu 个（共 %lu 行）",
          (unsigned long)wired, (unsigned long)[[self specifiers] count]);
}

/// 刷新「当前素材」那一行（值是动态的，不能在 plist 里写死）
- (void)tx_refreshDynamicLabels {
    NSString *path = TXPrefGet(@"SourcePath");
    NSString *text = path.length ? TXDisplayName(path) : @"(无)";
    for (PSSpecifier *spec in [self specifiers]) {
        if (![[spec propertyForKey:@"id"] isEqualToString:@"currentMaterial"]) {
            continue;
        }
        [spec setProperty:[NSString stringWithFormat:@"当前素材：%@", text] forKey:@"label"];
        [self reloadSpecifier:spec];
        break;
    }
}

#pragma mark - 安装

// 真正的文件操作在 SpringBoard 侧完成（面板沙盒写不了别的 App 容器），
// 这里只发通知，然后轮询 worker 写回的结果。
- (void)tx_installPoster:(PSSpecifier *)specifier {
    NSString *path = TXPrefGet(@"SourcePath");
    if (!path.length) {
        [self tx_alertMessage:@"先在「选择素材」里选一个 .tendies"];
        return;
    }
    TXLog(@"面板: 请求安装 %@", path);

    TXPrefSet(@"LastInstallMessage", @"");
    TXNotify(kTXInstallNotification);
    [self tx_pollInstallResult:0];
}

- (void)tx_cleanupDuplicates:(PSSpecifier *)specifier {
    TXLog(@"面板: 请求清理重复壁纸");
    TXPrefSet(@"LastInstallMessage", @"");
    TXNotify(kTXCleanupNotification);
    [self tx_pollInstallResult:0];
}

/// worker 侧是「解包 → 复制 → 重扫 → 建配置 → 设为当前壁纸」的异步链路，
/// 所以轮询偏好里的结果：遇到"正在…"就再等一轮，最多 3 轮，避免弹出中间态。
- (void)tx_pollInstallResult:(NSUInteger)attempt {
    __weak TXRootListController *weakSelf = self;
    NSTimeInterval delay = (attempt == 0) ? 6.0 : 7.0;

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *message = TXPrefGet(@"LastInstallMessage");
        if ([message containsString:@"正在"] && attempt < 3) {
            TXLog(@"面板: 仍在进行（第 %lu 次轮询）", (unsigned long)attempt + 1);
            [weakSelf tx_pollInstallResult:attempt + 1];
            return;
        }
        [weakSelf tx_alertMessage:[NSString stringWithFormat:
            @"%@\n\n详情见日志 /var/mobile/Library/Logs/TendiesX.log",
            message.length ? message : @"已发出请求，但没收到结果（看日志确认）"]];
    });
}

- (void)tx_rescan:(PSSpecifier *)specifier {
    TXNotifyReload();
    TXLog(@"面板: 已请求重新扫描素材");
    [self tx_refreshAfterImport];
}

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

- (void)tx_refreshAfterImport {
    __weak TXRootListController *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        gTXPackageSpecifiers = nil;
        gTXPackagePaths = nil;
        [weakSelf reloadSpecifiers];
        TXLog(@"面板: 列表已刷新");
    });
}

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
    NSString *lastDestination = nil;

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
            lastDestination = destination;
        } else {
            TXLog(@"面板: 复制失败 %@（%@）", name, error.localizedDescription);
        }
    }

    TXLog(@"面板: 已放入素材目录 %lu 个", (unsigned long)copied);
    if (copied && lastDestination) {
        TXPrefSet(@"SourcePath", lastDestination);   // 直接选中刚放入的，省一步
    }
    TXNotifyReload();
    [self tx_refreshAfterImport];
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    TXLog(@"面板: 取消选择文件");
}

#pragma mark - 开关读写（plist 只写 key，具体读写走这里）

- (id)readPreferenceValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return nil;
    }
    id value = TXPrefGet(key);
    if (value) {
        return value;
    }
    return [specifier propertyForKey:@"default"] ?: @YES;
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return;
    }
    TXPrefSet(key, value);
    TXNotifyReload();
    TXLog(@"面板: %@ -> %@", key, value);
}

// 部分系统版本的 cell 会走 specifier 的 get/set 选择器，两条路都兜着
- (id)tx_getSwitchValue:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    return key.length ? @(TXPrefBool(key, YES)) : @NO;
}

- (void)tx_setSwitchValue:(id)value specifier:(PSSpecifier *)specifier {
    NSString *key = [specifier propertyForKey:@"key"];
    if (!key.length) {
        return;
    }
    TXPrefSet(key, value);
    TXLog(@"面板: %@ -> %@", key, value);
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

- (void)openSileoRepo:(id)sender {
    NSString *source = @"https://axs66.github.io/pro";
    NSString *encoded = [source stringByAddingPercentEncodingWithAllowedCharacters:
                         NSCharacterSet.URLQueryAllowedCharacterSet] ?: source;
    [self openURL:[NSURL URLWithString:[NSString stringWithFormat:@"sileo://source/%@", encoded]]
         fallback:[NSURL URLWithString:source]];
}

- (void)openTelegramChannel:(id)sender {
    [self openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
         fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}

- (void)openQQGroup:(id)sender {
    [self openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&card_type=group&uin=678055716"]
         fallback:nil];
}

@end
