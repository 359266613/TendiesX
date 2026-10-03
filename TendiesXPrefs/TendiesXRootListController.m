//
//  TendiesXRootListController.m
//  设置面板（按 ios-tweak-scaffold 模板）：
//    · Resources/Root.plist → 全部规格（开关 / 素材 / 素材操作按钮），改文案不用重编
//    · 本文件               → 固定「关于我们」按钮组 + 二级页「选择素材」+ 按钮动作
//
//  面板只做三件事：写偏好、发 Darwin 通知、把结果弹出来。
//  真正的文件操作（解包 / 装 descriptor / 设为当前壁纸）在 SpringBoard 侧 worker 里做，
//  因为设置 App 的沙盒写不了别的 App 容器。
//

#import "TendiesXRootListController.h"
#import <Preferences/PSSpecifier.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>
#import "TXLogger.h"
#import "Cells/TXDetailCell.h"

static NSString * const kDomain = @"com.axs.tendiesx";   // 与 control 的 Package 一致
static NSString * const kMediaDir = @"/var/mobile/Library/TendiesX";
static NSString * const kInstallNote = @"com.axs.tendiesx/InstallPoster";
static NSString * const kCleanupNote = @"com.axs.tendiesx/CleanupDuplicates";

#pragma mark - 素材目录

// 素材目录里的全部 .tendies：压缩包和已解包目录都算（worker 侧会自动解包）
static NSArray<NSString *> *TXPackages(void) {
    NSMutableArray<NSString *> *found = [NSMutableArray array];
    for (NSString *item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:kMediaDir
                                                                            error:NULL]) {
        if ([[item.pathExtension lowercaseString] isEqualToString:@"tendies"] && ![item hasPrefix:@"."]) {
            [found addObject:[kMediaDir stringByAppendingPathComponent:item]];
        }
    }
    [found sortUsingSelector:@selector(compare:)];
    return found;
}

// 显示名：去掉 "-1234w-5678h" 这类分辨率后缀
static NSString *TXDisplayName(NSString *path) {
    NSString *name = [[path lastPathComponent] stringByDeletingPathExtension];
    NSRange dash = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return dash.location == NSNotFound ? name : [name substringToIndex:dash.location];
}

#pragma mark - 素材列表（二级页：扫目录得到，动态行）

@interface TXPackageListController : PSListController
@end

@implementation TXPackageListController {
    NSArray<NSString *> *_paths;   // 与第 0 组的行一一对应
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSString *current = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] stringForKey:@"SourcePath"];
        NSMutableArray *specs = [NSMutableArray arrayWithObject:
                                 [PSSpecifier groupSpecifierWithName:@"点一下选中要安装的素材"]];
        NSMutableArray<NSString *> *paths = [NSMutableArray array];

        for (NSString *path in TXPackages()) {
            NSString *title = [NSString stringWithFormat:@"%@%@",
                               [path isEqualToString:current] ? @"✓ " : @"", TXDisplayName(path)];
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:title target:nil set:nil get:nil
                                                            detail:nil cell:PSTitleValueCell edit:nil]];
            [paths addObject:path];
        }
        if (!paths.count) {
            [specs addObject:[PSSpecifier preferenceSpecifierNamed:@"还没有素材：回上一页用「文件」App 选一个 .tendies"
                                                           target:nil set:nil get:nil
                                                         detail:nil cell:PSTitleValueCell edit:nil]];
        }
        _paths = [paths copy];
        _specifiers = specs;   // 表数据源读的就是这个 ivar
        TXLog(@"面板: 素材列表 %lu 个", (unsigned long)paths.count);
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
    self.title = @"选择素材";
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    _specifiers = nil;   // 每次进来重扫，素材增删都看得见
    [self reloadSpecifiers];
}

- (void)tableView:(UITableView *)tableView didSelectRowAtIndexPath:(NSIndexPath *)indexPath {
    [tableView deselectRowAtIndexPath:indexPath animated:YES];
    if (indexPath.section != 0 || indexPath.row >= (NSInteger)_paths.count) {
        return;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [defaults setObject:_paths[indexPath.row] forKey:@"SourcePath"];
    [defaults synchronize];
    TXLog(@"面板: 已选中素材 %@", _paths[indexPath.row]);

    // 不自动返回：把 ✓ 刷出来，用户能看到确实选过去了
    [self reloadSpecifiers];
}

@end

#pragma mark - 根页面

@interface TendiesXRootListController () <UIDocumentPickerDelegate>
- (void)btn:(NSString *)title act:(SEL)action to:(NSMutableArray *)array;
- (void)fixButtonActions:(NSMutableArray *)specs;
- (void)refreshMaterialRow;
- (void)tx_installPoster:(id)sender;
- (void)tx_cleanupDuplicates:(id)sender;
- (void)tx_pickFiles:(id)sender;
- (void)pollResult:(NSUInteger)attempt;
- (void)notify:(NSString *)name;
- (void)alert:(NSString *)message;
- (void)openURL:(NSURL *)primary fallback:(NSURL *)fallback;
- (void)openSileoRepo;
- (void)openSileoRepo:(id)_;
- (void)openTelegramChannel;
- (void)openTelegramChannel:(id)_;
- (void)openQQGroup;
- (void)openQQGroup:(id)_;
@end

@implementation TendiesXRootListController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Root.plist 里「选择素材」的 detail 只是类名字符串，不产生类引用，链接器可能把二级页剔掉；
    // 这里显式引用一次保活，并确认它真的在。
    (void)[TXPackageListController class];
    TXLog(@"面板: 二级页类=%@", NSClassFromString(@"TXPackageListController") ? @"可用" : @"缺失");
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        // 全部规格（开关 / 素材 / 素材操作）都在 Resources/Root.plist 里
        NSMutableArray *specs = [[self loadSpecifiersFromPlistName:@"Root" target:self] mutableCopy];
        [self fixButtonActions:specs];   // plist 的 action 没被带进来时兜一手

        // 关于我们（固定：每个插件都相同，照抄即可）
        [specs addObject:[PSSpecifier groupSpecifierWithName:@"关于我们"]];
        [self btn:@"Sileo 越狱源" act:@selector(openSileoRepo:) to:specs];
        [self btn:@"TG分享频道" act:@selector(openTelegramChannel:) to:specs];
        [self btn:@"QQ交流群组" act:@selector(openQQGroup:) to:specs];

        _specifiers = specs;
        TXLog(@"面板: 规格构建完成（%lu 行，plist + 关于我们）", (unsigned long)_specifiers.count);
    }
    return _specifiers;
}

/// plist 里按钮写的是 action（Preferences 的约定）；个别版本没把 action 带进 specifier，
/// 就按 id 兜一下，保证按钮一定点得动。
- (void)fixButtonActions:(NSMutableArray *)specs {
    NSDictionary<NSString *, NSString *> *fallback = @{
        @"install": @"tx_installPoster:",
        @"cleanup": @"tx_cleanupDuplicates:",
        @"pick": @"tx_pickFiles:",
    };
    for (PSSpecifier *spec in specs) {
        if (spec.buttonAction || !spec.identifier.length) {
            continue;
        }
        NSString *selectorName = fallback[spec.identifier];
        if (selectorName.length) {
            spec.buttonAction = NSSelectorFromString(selectorName);
        }
    }
}

// 通用：往规格列表末尾加一个按钮型 specifier
- (void)btn:(NSString *)title act:(SEL)action to:(NSMutableArray *)array {
    PSSpecifier *spec = [PSSpecifier preferenceSpecifierNamed:title target:self set:nil get:nil
                                                      detail:nil cell:PSButtonCell edit:nil];
    spec.buttonAction = action;
    [array addObject:spec];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    (void)[self specifiers];        // 保证规格已构建并写回，下面才找得到那一行
    [self refreshMaterialRow];      // 从选择页返回后，右侧的名字要跟着变
}

/// 「选择素材」这一行：cell 换成 TXDetailCell，右侧显示当前素材名（KeyboardTools 同款做法）
- (void)refreshMaterialRow {
    PSSpecifier *spec = [self specifierForID:@"material"];
    if (!spec) {
        return;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSString *path = [defaults stringForKey:@"SourcePath"];

    // 素材是丢进目录就能用的，所以这里不靠任何"扫描"动作：
    // 每次进面板都自己核对一次，选中的文件被 Filza 删了就把选择清掉（否则装的时候才发现）
    if (path.length && ![NSFileManager.defaultManager fileExistsAtPath:path]) {
        TXLog(@"面板: 选中的素材已不存在，自动清掉选择：%@", path);
        [defaults removeObjectForKey:@"SourcePath"];
        [defaults synchronize];
        path = nil;
    }
    NSString *name = path.length ? TXDisplayName(path) : @"未选择";

    [spec setProperty:[TXDetailCell class] forKey:@"cellClass"];
    if ([[spec propertyForKey:@"txDetailText"] isEqualToString:name]) {
        return;   // 没变就不重画这一行
    }
    [spec setProperty:name forKey:@"txDetailText"];
    [self reloadSpecifier:spec];
}

#pragma mark - 开关读写（plist 里写 defaults+key，这里实时读写并落盘）

- (id)readPreferenceValue:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) {
        return nil;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    id value = [defaults objectForKey:key];
    return value ?: [spec propertyForKey:@"default"];
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)spec {
    NSString *key = [spec propertyForKey:@"key"];
    if (!key) {
        return;
    }
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    if ([value isKindOfClass:[NSNumber class]]) {
        NSNumber *number = (NSNumber *)value;
        if (strcmp([number objCType], @encode(BOOL)) == 0 || strcmp([number objCType], @encode(char)) == 0) {
            [defaults setBool:[number boolValue] forKey:key];
        } else {
            [defaults setDouble:[number doubleValue] forKey:key];
        }
    } else {
        [defaults setObject:value forKey:key];
    }
    [defaults synchronize];
    TXLog(@"面板: %@ = %@", key, value);
}

#pragma mark - 安装 / 清理（真正的活儿在 SpringBoard 侧 worker）

- (void)tx_installPoster:(id)sender {
    NSString *path = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] stringForKey:@"SourcePath"];
    if (!path.length) {
        [self alert:@"先在「选择素材」里选一个 .tendies"];
        return;
    }
    TXLog(@"面板: 请求安装 %@", path);
    [self startWorkerWith:kInstallNote];
}

- (void)tx_cleanupDuplicates:(id)sender {
    TXLog(@"面板: 请求清理重复壁纸");
    [self startWorkerWith:kCleanupNote];
}

// 清掉上次的结果 → 发通知 → 轮询 worker 写回的进度
- (void)startWorkerWith:(NSString *)notification {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    [defaults setObject:@"" forKey:@"LastInstallMessage"];
    [defaults synchronize];
    [self notify:notification];
    [self pollResult:0];
}

- (void)pollResult:(NSUInteger)attempt {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        NSString *message = [[[NSUserDefaults alloc] initWithSuiteName:kDomain] stringForKey:@"LastInstallMessage"];
        if (!message.length && attempt < 5) {
            [weakSelf pollResult:attempt + 1];
            return;
        }
        [weakSelf alert:message.length ? message : @"已发出请求，但没等到回复（详情看 TendiesX.log）"];
    });
}

#pragma mark - 从「文件」App 导入

- (void)tx_pickFiles:(id)sender {
    UIDocumentPickerViewController *picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[UTTypeData] asCopy:YES];
    picker.delegate = self;
    picker.allowsMultipleSelection = YES;
    [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController *)controller
 didPickDocumentsAtURLs:(NSArray<NSURL *> *)urls {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kDomain];
    NSUInteger copied = 0;

    for (NSURL *url in urls) {
        NSString *name = url.lastPathComponent;
        if (![[name.pathExtension lowercaseString] isEqualToString:@"tendies"]) {
            name = [name stringByAppendingPathExtension:@"tendies"];
        }
        // 目标与解压目录同名（xxx.tendies）：同名即替换
        NSString *destination = [kMediaDir stringByAppendingPathComponent:name];
        [fm removeItemAtPath:destination error:NULL];

        if ([fm copyItemAtURL:url toURL:[NSURL fileURLWithPath:destination] error:NULL]) {
            copied++;
            [defaults setObject:destination forKey:@"SourcePath"];   // 直接选中刚放入的
        } else {
            TXLog(@"面板: 复制失败 %@", name);
        }
    }

    [defaults synchronize];
    TXLog(@"面板: 已放入素材目录 %lu 个", (unsigned long)copied);
    [self reloadSpecifiers];
    [self refreshMaterialRow];   // 右侧那行立刻显示新选中的素材
}

- (void)documentPickerWasCancelled:(UIDocumentPickerViewController *)controller {
    TXLog(@"面板: 取消选择文件");
}

#pragma mark - 小工具

- (void)notify:(NSString *)name {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         (__bridge CFStringRef)name, NULL, NULL, YES);
}

- (void)alert:(NSString *)message {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"TendiesX"
                                                                   message:message
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"好" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
}

#pragma mark - 关于我们（固定：scheme 优先 + 网页兜底，所有插件相同）

- (void)openURL:(NSURL *)primary fallback:(NSURL *)fallback {
    UIApplication *app = [UIApplication sharedApplication];
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
                         [NSCharacterSet URLQueryAllowedCharacterSet]];
    NSURL *url = [NSURL URLWithString:[NSString stringWithFormat:@"sileo://source/%@", encoded]];
    if (!url) {
        url = [NSURL URLWithString:[NSString stringWithFormat:@"sileo://add-source?source=%@", encoded ?: source]];
    }
    [self openURL:url fallback:[NSURL URLWithString:source]];
}
- (void)openSileoRepo:(id)_ {
    [self openSileoRepo];
}

- (void)openTelegramChannel {
    [self openURL:[NSURL URLWithString:@"tg://resolve?domain=wxfx8"]
         fallback:[NSURL URLWithString:@"https://t.me/wxfx8"]];
}
- (void)openTelegramChannel:(id)_ {
    [self openTelegramChannel];
}

- (void)openQQGroup {
    [self openURL:[NSURL URLWithString:@"mqqapi://card/show_pslcard?src_type=internal&version=1&card_type=group&uin=678055716"]
         fallback:nil];
}
- (void)openQQGroup:(id)_ {
    [self openQQGroup];
}

@end
