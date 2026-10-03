//
//  TXRootListController.m
//  设置面板：写 com.axs.tendiesx 偏好，并广播 Darwin 通知让 SpringBoard 侧重载。
//  扫描目录：/var/mobile/Library/TendiesX/ 与 /var/mobile/Media/TendiesX/
//

#import "TXPreferencesUI.h"
#import "TXLogger.h"

static NSString *const kTXDomain = @"com.axs.tendiesx";
static NSString *const kTXReloadNotification = @"com.axs.tendiesx/ReloadPrefs";
static NSString *const kTXTendiesDirs[] = {
    @"/var/mobile/Library/TendiesX",
    @"/var/mobile/Media/TendiesX",
    nil
};

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
    return [[path lastPathComponent] stringByDeletingPathExtension];
}

static NSArray<NSString *> *TXScanPackages(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (int i = 0; kTXTendiesDirs[i] != nil; i++) {
        NSString *dir = kTXTendiesDirs[i];
        NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:dir error:NULL];
        TXLog(@"面板扫描 %@ -> %lu 项", dir, (unsigned long)items.count);
        for (NSString *item in items) {
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

#pragma mark - 壁纸列表（二级页）

static NSArray *gTXPackageSpecifiers = nil;

@interface TXPackageListController : PSListController
@end

@implementation TXPackageListController

- (NSArray *)specifiers {
    if (!gTXPackageSpecifiers) {
        TXLog(@"面板: 开始构建壁纸列表 specifiers");
        NSMutableArray *specs = [NSMutableArray array];
        NSString *current = TXPrefGet(@"ActivePackagePath");

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"选择 .tendies 壁纸"]];

        NSArray<NSString *> *packages = TXScanPackages();
        if (!packages.count) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"（没扫描到 .tendies，请先放到 /var/mobile/Library/TendiesX/）"
                                                           target:nil set:nil get:nil detail:nil
                                                             cell:TXCellStaticText edit:nil]];
        }

        for (NSString *path in packages) {
            BOOL selected = [path isEqualToString:current];
            NSString *title = [NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", TXDisplayName(path)];

            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title
                                                              target:self
                                                                 set:nil
                                                                 get:nil
                                                              detail:nil
                                                                cell:TXCellButton
                                                                edit:nil];
            [spec setButtonAction:@selector(tx_pickPackage:)];
            [spec setProperty:path forKey:@"txPackagePath"];
            [specs addObject:spec];
        }

        PSSpecifier *autoSpec = [PSSpecifier groupSpecifierWithName:@"设为自动（取扫描到的第一个）"];
        [specs addObject:autoSpec];

        PSSpecifier *autoCell = [PSSpecifier preferenceSpecifierNamed:@"自动"
                                                              target:self set:nil get:nil detail:nil
                                                                cell:TXCellButton edit:nil];
        [autoCell setButtonAction:@selector(tx_pickPackage:)];
        [autoCell setProperty:@"自动" forKey:@"txPackagePath"];
        [specs addObject:autoCell];

        gTXPackageSpecifiers = specs;
        TXLog(@"面板: 壁纸列表构建完成，%lu 个 specifier", (unsigned long)specs.count);
    }
    return gTXPackageSpecifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择壁纸";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    [self reloadSpecifiers];
}

- (void)tx_pickPackage:(PSSpecifier *)specifier {
    NSString *path = [specifier propertyForKey:@"txPackagePath"];
    NSString *value = [path isEqualToString:@"自动"] ? @"" : path;

    TXPrefSet(@"ActivePackagePath", value);
    TXLog(@"面板: ActivePackagePath -> %@", value.length ? value : @"(自动)");

    gTXPackageSpecifiers = nil;
    [self reloadSpecifiers];
    [self.navigationController popViewControllerAnimated:YES];
}

@end

#pragma mark - 根页面

static NSArray *gTXRootSpecifiers = nil;

@interface TXRootListController : PSListController
@end

@interface TXRootListController ()
- (PSSpecifier *)tx_switchNamed:(NSString *)name set:(SEL)set get:(SEL)get;
- (void)tx_rescan:(PSSpecifier *)specifier;
@end

@implementation TXRootListController

/// 能打出来就说明 bundle 的二进制已被 Settings 加载，类可用
+ (void)load {
    TXLog(@"======== TendiesXPrefs bundle 已加载，TXRootListController 可用 ========");
}

- (NSArray *)specifiers {
    if (!gTXRootSpecifiers) {
        TXLog(@"面板: 开始构建根 specifiers");
        NSMutableArray *specs = [NSMutableArray array];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"开关"]];

        [specs addObject:[self tx_switchNamed:@"启用"
                                          set:@selector(tx_setEnabled:specifier:)
                                          get:@selector(tx_getEnabled:)]];

        [specs addObject:[self tx_switchNamed:@"触摸交互"
                                          set:@selector(tx_setInteraction:specifier:)
                                          get:@selector(tx_getInteraction:)]];

        [specs addObject:[self tx_switchNamed:@"陀螺仪视差"
                                          set:@selector(tx_setParallax:specifier:)
                                          get:@selector(tx_getParallax:)]];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"壁纸"]];

        NSString *current = TXPrefGet(@"ActivePackagePath");
        NSString *currentName = current.length ? TXDisplayName(current) : @"自动";
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:[NSString stringWithFormat:@"选择壁纸（当前：%@）", currentName]
                                                       target:self
                                                          set:nil
                                                          get:nil
                                                       detail:[TXPackageListController class]
                                                         cell:TXCellLink
                                                         edit:nil]];

        PSSpecifier *rescan = [PSSpecifier preferenceSpecifierNamed:@"重新扫描目录"
                                                            target:self set:nil get:nil detail:nil
                                                              cell:TXCellButton edit:nil];
        [rescan setButtonAction:@selector(tx_rescan:)];
        [specs addObject:rescan];

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"说明"]];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"把 .tendies 放到 /var/mobile/Library/TendiesX/，再回这里点「重新扫描目录」"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellStaticText edit:nil]];

        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"运行日志：/var/mobile/Library/Logs/TendiesX.log"
                                                       target:nil set:nil get:nil detail:nil
                                                         cell:TXCellStaticText edit:nil]];

        gTXRootSpecifiers = specs;
        TXLog(@"面板: 根 specifiers 构建完成，%lu 个", (unsigned long)specs.count);
    }
    return gTXRootSpecifiers;
}

- (PSSpecifier *)tx_switchNamed:(NSString *)name set:(SEL)set get:(SEL)get {
    return [PSSpecifier preferenceSpecifierNamed:name
                                          target:self
                                             set:set
                                             get:get
                                          detail:nil
                                            cell:TXCellSwitch
                                            edit:nil];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"TendiesX";
    TXLog(@"面板: viewDidLoad");
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    TXLog(@"面板: viewWillAppear，当前 specifiers=%lu", (unsigned long)[self specifiers].count);
    // 每次进入都重建一次，避免 PSListController 缓存了空数组导致白屏
    [self reloadSpecifiers];
}

- (void)tx_rescan:(PSSpecifier *)specifier {
    gTXRootSpecifiers = nil;
    gTXPackageSpecifiers = nil;
    [self reloadSpecifiers];
    TXLog(@"面板: 重新扫描目录完成");
}

#pragma mark - 开关读写

- (id)tx_getEnabled:(PSSpecifier *)specifier     { return @(TXPrefBool(@"Enabled", YES)); }
- (id)tx_getInteraction:(PSSpecifier *)specifier { return @(TXPrefBool(@"InteractionEnabled", YES)); }
- (id)tx_getParallax:(PSSpecifier *)specifier    { return @(TXPrefBool(@"ParallaxEnabled", YES)); }

- (void)tx_setEnabled:(id)value specifier:(PSSpecifier *)specifier {
    TXPrefSet(@"Enabled", value);
    gTXRootSpecifiers = nil;
    TXLog(@"面板: Enabled -> %@", value);
}
- (void)tx_setInteraction:(id)value specifier:(PSSpecifier *)specifier {
    TXPrefSet(@"InteractionEnabled", value);
    TXLog(@"面板: InteractionEnabled -> %@", value);
}
- (void)tx_setParallax:(id)value specifier:(PSSpecifier *)specifier {
    TXPrefSet(@"ParallaxEnabled", value);
    TXLog(@"面板: ParallaxEnabled -> %@", value);
}

@end
