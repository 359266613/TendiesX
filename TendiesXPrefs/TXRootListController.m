//
//  TXRootListController.m
//  设置面板：写 com.axs.tendiesx 偏好，并广播 Darwin 通知让 SpringBoard 侧重载。
//  扫描目录：/var/mobile/Library/TendiesX/ 与 /var/mobile/Media/TendiesX/
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

#pragma mark - specifiers 写回（面板白屏的关键）

/// 调整：PSListController 的表数据源读的是它自己的 `_specifiers` 实例变量。
/// 只 `return` 数组而不写回该 ivar 时，日志能看到 specifiers 已构建，但界面全白。
/// 这里用运行期取 ivar 写入，避免为拿偏移而引入整套 Preferences 私有头。
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

#pragma mark - 壁纸列表（二级页）

static NSArray *gTXPackageSpecifiers = nil;

@interface TXPackageListController : PSListController
@end

@implementation TXPackageListController

- (NSArray *)specifiers {
    if (!gTXPackageSpecifiers) {
        TXLog(@"面板: 开始构建壁纸列表");
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
            PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:
                                 [NSString stringWithFormat:@"%@%@", selected ? @"✓ " : @"", TXDisplayName(path)]
                                                              target:self set:nil get:nil detail:nil
                                                                cell:TXCellButton edit:nil];
            [spec setButtonAction:@selector(tx_pickPackage:)];
            [spec setProperty:path forKey:@"txPackagePath"];
            [specs addObject:spec];
        }

        [specs addObject:[PSSpecifier groupSpecifierWithName:@"恢复自动"]];
        PSSpecifier *autoCell = [PSSpecifier preferenceSpecifierNamed:@"自动（取扫描到的第一个）"
                                                              target:self set:nil get:nil detail:nil
                                                                cell:TXCellButton edit:nil];
        [autoCell setButtonAction:@selector(tx_pickPackage:)];
        [autoCell setProperty:@"自动" forKey:@"txPackagePath"];
        [specs addObject:autoCell];

        gTXPackageSpecifiers = [specs copy];
        TXLog(@"面板: 壁纸列表构建完成，%lu 个", (unsigned long)gTXPackageSpecifiers.count);
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
- (void)tx_buttonNamed:(NSString *)name action:(SEL)action to:(NSMutableArray *)specs;
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

        #pragma mark 开关
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

        #pragma mark 壁纸
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"壁纸"]];
        NSString *current = TXPrefGet(@"ActivePackagePath");
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:
                      [NSString stringWithFormat:@"选择壁纸（当前：%@）", current.length ? TXDisplayName(current) : @"自动"]
                                                       target:self set:nil get:nil
                                                     detail:[TXPackageListController class]
                                                       cell:TXCellLink edit:nil]];
        [self tx_buttonNamed:@"重新扫描目录" action:@selector(tx_rescan:) to:specs];

        #pragma mark 说明
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"说明"]];
        [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"把 .tendies 放到 /var/mobile/Library/TendiesX/，再回这里点「重新扫描目录」"
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

- (PSSpecifier *)tx_switchNamed:(NSString *)name set:(SEL)set get:(SEL)get {
    return [PSSpecifier preferenceSpecifierNamed:name target:self set:set get:get
                                          detail:nil cell:TXCellSwitch edit:nil];
}

// 通用：往规格列表末尾加一个按钮型 specifier
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
}
- (void)tx_setInteraction:(id)value specifier:(PSSpecifier *)specifier { TXPrefSet(@"InteractionEnabled", value); }
- (void)tx_setParallax:(id)value specifier:(PSSpecifier *)specifier    { TXPrefSet(@"ParallaxEnabled", value); }

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
    [self openURL:[NSURL URLWithString:@"http://qm.qq.com/cgi-bin/qm/qr?_wv=1027&k=b9yIV3X8xKi3ZZUC7YXIr1YasKOzjYnm&authKey=ReN7wx79FV6Y4EIowsWSljNRUTSaGfgwWlmRzuvpWpBxl%2BCEKz%2BMNP3JePx1mMQ8&noverify=0&group_code=1001525693"]
         fallback:nil];
}
- (void)openQQGroup:(id)_            { [self openQQGroup]; }

@end
