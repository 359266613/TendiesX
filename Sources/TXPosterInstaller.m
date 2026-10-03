#import "TXPosterInstaller.h"
#import "TXZipArchive.h"
#import "TXPosterDiagnostics.h"
#import "TXLogger.h"
#import <UIKit/UIKit.h>
#import <spawn.h>

static NSString *const kTXDefaultPosterExtension = @"com.apple.WallpaperKit.CollectionsPoster";

static BOOL TXIsDirectory(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
}

/// 安装时跳过的打包残留。
/// 注意：**不能**简单地跳过所有点开头的名字 —— descriptor 里有必需文件就叫
/// .com.apple.posterkit.provider.contents.configurableOptions.plist，误删会让配置项丢失。
static BOOL TXIsJunkEntry(NSString *name) {
    return [name isEqualToString:@".DS_Store"]
        || [name hasPrefix:@"._"]          // macOS AppleDouble
        || [name isEqualToString:@"__MACOSX"]
        || [name isEqualToString:@"LICENSE.txt"]
        || [name isEqualToString:@"README.md"];
}

@interface TXPosterInstaller ()
@property (nonatomic, copy, readwrite) NSString *lastInstalledExtension;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *lastInstalledDescriptorIdentifiers;
@end

#pragma mark - 安装清单（只用来清掉"我们自己上次装的"，绝不碰系统自带壁纸）

static NSString *const kTXManifestDomain = @"com.axs.tendiesx";
static NSString *const kTXManifestKey = @"InstalledDescriptors";

static NSArray<NSDictionary *> *TXInstalledManifest(void) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)kTXManifestKey,
                                                       (__bridge CFStringRef)kTXManifestDomain);
    NSArray *list = value ? (__bridge_transfer NSArray *)value : nil;
    return [list isKindOfClass:NSArray.class] ? list : @[];
}

static void TXSaveInstalledManifest(NSArray<NSDictionary *> *manifest) {
    CFPreferencesSetAppValue((__bridge CFStringRef)kTXManifestKey,
                             (__bridge CFPropertyListRef)manifest,
                             (__bridge CFStringRef)kTXManifestDomain);
    Boolean synced = CFPreferencesAppSynchronize((__bridge CFStringRef)kTXManifestDomain);
    // 顺带回读一次：之前"替换没生效"怀疑就是清单没落盘，这里把结果记下来
    TXLog(@"[A] 安装清单写入 %lu 条（落盘=%@，回读 %lu 条）",
          (unsigned long)manifest.count, synced ? @"成功" : @"失败",
          (unsigned long)TXInstalledManifest().count);
}

/// descriptor 的 identifier 写在 <descriptor>/com.apple.posterkit.provider.descriptor.identifier，
/// 是纯文本（实测内容就是 "7400"，4 字节、无换行），给 PRSService 建配置时要用。
/// 两种命名都试一遍：实测不带点，个别版本带点前缀。
static NSString *TXDescriptorIdentifierIn(NSString *descriptorDirectory) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *name in @[ @"com.apple.posterkit.provider.descriptor.identifier",
                              @".com.apple.posterkit.provider.descriptor.identifier" ]) {
        NSString *file = [descriptorDirectory stringByAppendingPathComponent:name];
        if (![fm fileExistsAtPath:file]) {
            continue;
        }
        NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
        if (!text.length) {
            text = [NSString stringWithContentsOfFile:file encoding:NSISOLatin1StringEncoding error:NULL];
        }
        text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        if (text.length) {
            return text;
        }
    }
    return nil;
}

/// descriptor 里的最大版本号：PosterBoard 每次改写都会 +1。
/// 系统自带的是几千（实测 3991），我们自己刚装的是 0~n —— 这是区分"谁的"唯一可靠依据。
static NSInteger TXMaxVersionIn(NSString *descriptorDir) {
    NSInteger maximum = -1;
    NSString *versions = [descriptorDir stringByAppendingPathComponent:@"versions"];
    for (NSString *item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:versions
                                                                            error:NULL]) {
        NSInteger value = item.integerValue;
        if (value > maximum) {
            maximum = value;
        }
    }
    return maximum;
}

/// 目录里的文件总数（空壳变体 = 0，装了也是黑图）
static NSUInteger TXFileCountIn(NSString *directory) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger count = 0;
    for (NSString *relative in [fm enumeratorAtPath:directory]) {
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:[directory stringByAppendingPathComponent:relative]
                     isDirectory:&isDir] && !isDir) {
            count++;
        }
    }
    return count;
}

/// 扫目标库，返回 identifier -> 该 identifier 的 descriptor 份数（用来判断"本机有没有同款"）
static NSDictionary<NSString *, NSNumber *> *TXStoreIdentifierCounts(NSString *descriptorsRoot) {
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorsRoot
                                                                             error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(dir)) {
            continue;
        }
        NSString *identifier = TXDescriptorIdentifierIn(dir);
        if (identifier.length) {
            counts[identifier] = @(counts[identifier].unsignedIntegerValue + 1);
        }
    }
    return counts;
}

/// 本机库里是否存在「系统自带的」同 identifier 条目（版本号 >= 1000）。
/// 只有这种情况才说明我们装的是"系统壁纸的变体"，替换旧副本才是对的。
static BOOL TXStoreHasSystemDescriptor(NSString *descriptorsRoot, NSString *identifier) {
    if (!identifier.length) {
        return NO;
    }
    for (NSString *entry in [NSFileManager.defaultManager contentsOfDirectoryAtPath:descriptorsRoot
                                                                             error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(dir)) {
            continue;
        }
        if ([identifier isEqualToString:TXDescriptorIdentifierIn(dir)] && TXMaxVersionIn(dir) >= 1000) {
            return YES;
        }
    }
    return NO;
}

/// 删掉目标库里「identifier 命中且版本号 < 1000」的目录 —— 那些只可能是我们自己装的旧副本。
/// 系统自带的同 identifier 壁纸版本号是几千，永远不碰。
/// @return 删除的份数
static NSUInteger TXRemoveOurCopiesOfIdentifiers(NSString *descriptorsRoot,
                                                 NSSet<NSString *> *identifiers) {
    if (!identifiers.count) {
        return 0;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger removed = 0;
    for (NSString *entry in [fm contentsOfDirectoryAtPath:descriptorsRoot error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(dir)) {
            continue;
        }
        NSString *identifier = TXDescriptorIdentifierIn(dir);
        if (!identifier.length || ![identifiers containsObject:identifier]) {
            continue;
        }
        NSInteger version = TXMaxVersionIn(dir);
        if (version >= 1000) {
            TXLog(@"[A] 保留系统自带的 %@ (identifier=%@ v%ld)", entry, identifier, (long)version);
            continue;
        }
        if ([fm removeItemAtPath:dir error:NULL]) {
            removed++;
            TXLog(@"[A] 清掉上次装的副本 %@ (identifier=%@ v%ld)", entry, identifier, (long)version);
        }
    }
    return removed;
}

@implementation TXPosterInstaller

+ (instancetype)sharedInstaller {
    static TXPosterInstaller *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[TXPosterInstaller alloc] init];
    });
    return shared;
}

#pragma mark - 海报存储定位

+ (NSString *)storeRoot {
    NSFileManager *fm = NSFileManager.defaultManager;
    static NSString *const kContainerRoots[] = {
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Data/System",
        nil
    };

    for (int r = 0; kContainerRoots[r] != nil; r++) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:kContainerRoots[r] error:NULL]) {
            NSString *container = [kContainerRoots[r] stringByAppendingPathComponent:uuid];
            NSString *metadata = [container stringByAppendingPathComponent:
                                  @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:metadata];
            if (![dict[@"MCMMetadataIdentifier"] isEqualToString:@"com.apple.PosterBoard"]) {
                continue;
            }
            NSString *support = [container stringByAppendingPathComponent:@"Library/Application Support"];
            for (NSString *item in [fm contentsOfDirectoryAtPath:support error:NULL]) {
                if ([item containsString:@"PRBPosterExtensionDataStore"]) {
                    return [support stringByAppendingPathComponent:item];
                }
            }
        }
    }
    return nil;
}

+ (NSString *)storeVersionDir {
    NSString *root = [self storeRoot];
    if (!root) {
        return nil;
    }
    NSArray<NSString *> *items = [NSFileManager.defaultManager contentsOfDirectoryAtPath:root error:NULL];

    // .tendies 里可能自带 61（iOS 17+）的路径，这里必须按设备实际版本改写
    NSString *preferred = (UIDevice.currentDevice.systemVersion.integerValue >= 17) ? @"61" : @"59";
    if ([items containsObject:preferred]) {
        return [root stringByAppendingPathComponent:preferred];
    }
    for (NSString *item in items) {
        if (TXIsDirectory([root stringByAppendingPathComponent:item]) && item.integerValue > 0) {
            return [root stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

#pragma mark - 解包

/// 目录直接返回；压缩包解到同名目录（xx.tendies → xx.tendies/），已解包过就复用
- (NSString *)tx_directoryForSource:(NSString *)source {
    if (TXIsDirectory(source)) {
        return source;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    TXZipArchive *zip = [TXZipArchive archiveWithContentsOfFile:source];
    if (!zip) {
        TXLog(@"[A] 不是有效的 zip: %@", source.lastPathComponent);
        return nil;
    }

    // 源压缩包与目标目录同名（xx.tendies 是文件 → xx.tendies/ 是目录），
    // 不能在已存在的文件路径上 createDirectory，所以先解到临时目录再改名。
    // 这样中途失败也不会把用户的原压缩包弄丢。
    NSString *destination = source;
    NSString *temporary = [source stringByAppendingString:@".unpacking"];
    [fm removeItemAtPath:temporary error:NULL];

    NSError *error = nil;
    if (![zip extractToDirectory:temporary error:&error]) {
        [fm removeItemAtPath:temporary error:NULL];
        TXLog(@"[A] 解包失败: %@", error.localizedDescription ?: @"未知原因");
        return nil;
    }
    [fm removeItemAtPath:destination error:NULL];
    if (![fm moveItemAtPath:temporary toPath:destination error:&error]) {
        [fm removeItemAtPath:temporary error:NULL];
        TXLog(@"[A] 解包后改名失败: %@", error.localizedDescription);
        return nil;
    }

    TXLog(@"[A] 已解包 %@ -> %@/（%lu 项）",
          source.lastPathComponent, destination.lastPathComponent,
          (unsigned long)zip.entries.count);
    return destination;
}

#pragma mark - 源 descriptor 定位

/// documentation.md：descriptor 文件夹叫 descriptor 或 descriptors，
/// 还可以加 ordered 之类的修饰词，所以按「名字里含 descriptor」来认，而不是精确匹配。
static BOOL TXIsDescriptorsFolderName(NSString *name) {
    return [name.lowercaseString containsString:@"descriptor"];
}

/// documentation.md：文件夹名带 mercury → MercuryPoster；
/// 带 video / photos → PhotosPosterProvider；默认 CollectionsPoster。
static NSString *TXExtensionForNames(NSArray<NSString *> *names) {
    for (NSString *name in names) {
        NSString *lower = name.lowercaseString;
        if ([lower containsString:@"mercury"]) {
            return @"com.apple.MercuryPoster";
        }
        if ([lower containsString:@"photos"] || [lower containsString:@"video"]) {
            return @"com.apple.PhotosUIPrivate.PhotosPosterProvider";
        }
    }
    return kTXDefaultPosterExtension;
}

/// 看起来像 bundle id（含点号）才当成扩展 ID 用
static BOOL TXLooksLikeBundleIdentifier(NSString *name) {
    return [name containsString:@"."] && ![name hasPrefix:@"."] && name.length > 3;
}

/// 支持两种 .tendies 布局：
///   descriptors/<UUID>/...                                     （descriptor 格式）
///   Container/.../Extensions/<扩展ID>/descriptors/<UUID>/...    （container 格式，扩展 ID 从路径反推）
- (BOOL)tx_findDescriptorsIn:(NSString *)directory
                      inDir:(NSString **)outDir
                  extension:(NSString **)outExtension {
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1) descriptor 格式：<包>/descriptors（兼容 descriptor / "descriptors ordered"）
    for (NSString *item in [fm contentsOfDirectoryAtPath:directory error:NULL]) {
        if (!TXIsDescriptorsFolderName(item)) {
            continue;
        }
        NSString *full = [directory stringByAppendingPathComponent:item];
        if (!TXIsDirectory(full)) {
            continue;
        }
        *outDir = full;
        *outExtension = TXExtensionForNames(@[directory.lastPathComponent, item]);
        return YES;
    }

    // 2) container 格式：<包>/Container/.../Extensions/<扩展ID>/descriptors
    NSString *container = [directory stringByAppendingPathComponent:@"Container"];
    NSString *root = TXIsDirectory(container) ? container : directory;
    for (NSString *relative in [fm enumeratorAtPath:root]) {
        if (!TXIsDescriptorsFolderName(relative.lastPathComponent)) {
            continue;
        }
        NSString *absolute = [root stringByAppendingPathComponent:relative];
        if (!TXIsDirectory(absolute)) {
            continue;
        }
        // 上一级目录就是扩展 ID（形如 com.apple.WallpaperKit.CollectionsPoster）
        NSString *parent = absolute.stringByDeletingLastPathComponent.lastPathComponent;
        *outDir = absolute;
        *outExtension = TXLooksLikeBundleIdentifier(parent)
            ? parent
            : TXExtensionForNames(@[directory.lastPathComponent, relative]);
        return YES;
    }
    return NO;
}

#pragma mark - 复制

- (BOOL)tx_copyDescriptor:(NSString *)source to:(NSString *)destination error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:destination withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    for (NSString *relative in [fm enumeratorAtPath:source]) {
        if (TXIsJunkEntry(relative.lastPathComponent) || [relative containsString:@"__MACOSX"]) {
            continue;
        }
        NSString *src = [source stringByAppendingPathComponent:relative];
        NSString *dst = [destination stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:src isDirectory:&isDir]) {
            continue;
        }
        if (isDir) {
            [fm createDirectoryAtPath:dst withIntermediateDirectories:YES attributes:nil error:NULL];
            continue;
        }
        [fm createDirectoryAtPath:dst.stringByDeletingLastPathComponent
     withIntermediateDirectories:YES attributes:nil error:NULL];
        if (![fm copyItemAtPath:src toPath:dst error:error]) {
            return NO;
        }
    }
    return YES;
}

#pragma mark - 安装

- (NSArray<NSString *> *)installFromPath:(NSString *)path {
    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    NSMutableArray<NSString *> *identifiers = [NSMutableArray array];
    _lastInstalledExtension = nil;
    _lastInstalledDescriptorIdentifiers = @[];

    if (!path.length) {
        TXLog(@"[A] 安装失败: 源路径为空");
        return installed;
    }

    NSString *directory = [self tx_directoryForSource:path];
    if (!directory) {
        return installed;
    }

    NSString *versionDir = [self.class storeVersionDir];
    if (!versionDir) {
        TXLog(@"[A] 安装失败: 找不到海报存储的版本目录（应形如 …/59 或 …/61）");
        return installed;
    }

    NSString *sourceDir = nil;
    NSString *extension = nil;
    if (![self tx_findDescriptorsIn:directory inDir:&sourceDir extension:&extension]) {
        TXLog(@"[A] 安装失败: %@ 里没有 descriptors/ 目录（不是可安装的 .tendies）",
              directory.lastPathComponent);
        return installed;
    }

    NSString *destRoot = [versionDir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"Extensions/%@/descriptors", extension]];
    _lastInstalledExtension = [extension copy];
    TXLog(@"[A] 源=%@ 扩展=%@ 目标=%@", sourceDir, extension, destRoot);

    NSFileManager *fm = NSFileManager.defaultManager;
    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        TXLog(@"[A] 安装失败: 建不了目标目录（%@）", dirError.localizedDescription);
        return installed;
    }

    // 1) 先把源里的 descriptor 收集出来（identifier + 文件数）
    NSMutableArray<NSDictionary *> *candidates = [NSMutableArray array];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:sourceDir error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *src = [sourceDir stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(src)) {
            continue;
        }
        NSString *identifier = TXDescriptorIdentifierIn(src);
        NSUInteger files = TXFileCountIn(src);
        [candidates addObject:@{ @"path": src, @"name": entry,
                                 @"identifier": identifier ?: @"", @"files": @(files) }];
        TXLog(@"[A] 源 descriptor %@: identifier=%@ 文件数=%lu",
              entry, identifier.length ? identifier : @"(读不到)", (unsigned long)files);
    }
    if (!candidates.count) {
        TXLog(@"[A] 源里没有 descriptor 子目录");
        return installed;
    }

    // 2) 本机库里已有的 identifier -> 份数（判断"这台设备认可哪些原生壁纸"）
    NSDictionary<NSString *, NSNumber *> *storeCounts = TXStoreIdentifierCounts(destRoot);
    BOOL hasStoreMatch = NO;
    for (NSDictionary *item in candidates) {
        if (((NSString *)item[@"identifier"]).length && storeCounts[item[@"identifier"]]) {
            hasStoreMatch = YES;
            break;
        }
    }
    // 只有「源里带多个 descriptor」才可能是多机型变体包（如 iOS16.tendies 的 7400+7410），
    // 这种才做变体过滤。独立素材（社区做的单文件素材等）一律照装，
    // 绝不因为"本机库里没有同款"就把用户想装的壁纸丢掉。
    BOOL filterVariants = hasStoreMatch && candidates.count > 1;
    TXLog(@"[A] 源 %lu 个 descriptor，本机有同款=%@，变体过滤=%@",
          (unsigned long)candidates.count, hasStoreMatch ? @"是" : @"否",
          filterVariants ? @"开" : @"关");

    // 3) 挑要装的（空壳一律跳过：装了也是黑图）
    NSMutableArray<NSDictionary *> *selected = [NSMutableArray array];
    for (NSDictionary *item in candidates) {
        NSString *identifier = item[@"identifier"];
        if ([item[@"files"] unsignedIntegerValue] == 0) {
            TXLog(@"[A] 跳过 %@（0 个文件）", item[@"name"]);
            continue;
        }
        if (filterVariants && !storeCounts[identifier]) {
            TXLog(@"[A] 跳过 %@（identifier=%@ 本机库里没有同款，属于其它机型变体）",
                  item[@"name"], identifier.length ? identifier : @"(读不到)");
            continue;
        }
        [selected addObject:item];
    }
    if (!selected.count) {
        TXLog(@"[A] 没有可装的 descriptor（源 %lu 个都被过滤了）", (unsigned long)candidates.count);
        return installed;
    }

    // 4) 替换：**只清"系统同类壁纸的旧变体"**。
    //    判据：库里已经存在同 identifier 的系统条目（版本号 >= 1000）—— 这时我们装的是它的变体，
    //    旧变体必须删掉，否则收藏里会堆出 13 份 7400。
    //    独立素材（库里没有系统同款）什么都不删：保持 v0.0.1-18 那种"各装各的"行为，
    //    多个素材能共存，多余的副本交给「清理重复壁纸」处理。
    NSMutableSet<NSString *> *replaceable = [NSMutableSet set];
    for (NSDictionary *item in selected) {
        NSString *identifier = item[@"identifier"];
        if (identifier.length && TXStoreHasSystemDescriptor(destRoot, identifier)) {
            [replaceable addObject:identifier];
        }
    }
    NSUInteger replaced = TXRemoveOurCopiesOfIdentifiers(destRoot, replaceable);
    TXLog(@"[A] 替换：清掉旧副本 %lu 份（可替换 identifier %lu 个）；本次装 %lu 个（源 %lu 个）",
          (unsigned long)replaced, (unsigned long)replaceable.count,
          (unsigned long)selected.count, (unsigned long)candidates.count);

    // 5) 复制 + 更新安装清单（清单只作记录，替换不依赖它）
    NSMutableArray<NSDictionary *> *manifest = [TXInstalledManifest() mutableCopy];
    [manifest filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, NSDictionary *bindings) {
            return TXIsDirectory([destRoot stringByAppendingPathComponent:record[@"uuid"] ?: @""]);
        }]];

    for (NSDictionary *item in selected) {
        NSString *src = item[@"path"];
        NSString *identifier = item[@"identifier"];

        // UUID 随机化：descriptor 内的文件都不引用 UUID（已逐个核对），换名安全。
        NSString *newUUID = [NSUUID UUID].UUIDString.uppercaseString;
        NSString *dst = [destRoot stringByAppendingPathComponent:newUUID];

        NSError *copyError = nil;
        if ([self tx_copyDescriptor:src to:dst error:&copyError]) {
            [installed addObject:dst];
            if (identifier.length) {
                [identifiers addObject:identifier];
                [manifest addObject:@{ @"uuid": newUUID,
                                       @"identifier": identifier,
                                       @"extension": extension }];
            }
            TXLog(@"[A] 已安装 descriptor %@ (identifier=%@) -> %@",
                  item[@"name"], identifier.length ? identifier : @"(未读到)", newUUID);
        } else {
            // 失败就删掉残缺目录，免得留下一个半成品让 PosterBoard 收录
            [fm removeItemAtPath:dst error:NULL];
            TXLog(@"[A] 安装失败 %@: %@", item[@"name"], copyError.localizedDescription);
        }
    }
    _lastInstalledDescriptorIdentifiers = [identifiers copy];
    TXSaveInstalledManifest(manifest);

    if (installed.count) {
        TXLog(@"[A] 共 %lu 个 descriptor 安装完成，交给 worker 调 PRSService 让 PosterBoard 重扫",
              (unsigned long)installed.count);
        // 这里不再 killall PosterBoard：
        // 1) iOS 上没有 system()（SDK 标记 __API_UNAVAILABLE(ios)）；
        // 2) 官方重扫方式是 PRSService -refreshPosterDescriptorsForExtension:，
        //    由 Hooks/Worker.xm 在安装成功后调用，不用重启进程。

        // 对比诊断：我们这份 vs 系统里同 identifier 的那份（最能说明"为什么没动画"）
        NSString *first = installed.firstObject;
        [TXPosterDiagnostics compareDescriptorAt:first extension:extension];
        [TXPosterDiagnostics schedulePostMigrationDump:first delay:8.0];
    } else {
        TXLog(@"[A] 没有安装任何 descriptor（源目录里没有 UUID 子目录？）");
    }
    return installed;
}

#pragma mark - 清理重复项

- (NSUInteger)cleanupDuplicateInstallsInExtension:(NSString *)extensionIdentifier {
    if (!extensionIdentifier.length) {
        return 0;
    }
    NSString *versionDir = [self.class storeVersionDir];
    if (!versionDir) {
        TXLog(@"[清理] 找不到海报存储，放弃");
        return 0;
    }
    NSString *descriptorsRoot = [versionDir stringByAppendingPathComponent:
        [NSString stringWithFormat:@"Extensions/%@/descriptors", extensionIdentifier]];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (!TXIsDirectory(descriptorsRoot)) {
        TXLog(@"[清理] 没有 descriptors 目录: %@", descriptorsRoot);
        return 0;
    }

    // 先盘库：identifier -> 该 identifier 的所有副本；identifier 读不到的单独记着
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    NSMutableArray<NSDictionary *> *orphans = [NSMutableArray array];
    NSMutableArray<NSString *> *inventory = [NSMutableArray array];

    for (NSString *entry in [fm contentsOfDirectoryAtPath:descriptorsRoot error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(dir)) {
            continue;
        }
        NSInteger version = TXMaxVersionIn(dir);
        NSString *identifier = TXDescriptorIdentifierIn(dir);
        [inventory addObject:[NSString stringWithFormat:@"%@(v%ld)",
                              identifier.length ? identifier : @"?", (long)version]];

        if (!identifier.length) {
            [orphans addObject:@{ @"uuid": entry, @"version": @(version) }];
            continue;
        }
        NSMutableArray<NSDictionary *> *list = groups[identifier];
        if (!list) {
            list = [NSMutableArray array];
            groups[identifier] = list;
        }
        [list addObject:@{ @"uuid": entry, @"version": @(version) }];
    }
    TXLog(@"[清理] 库里有 %lu 个 descriptor：%@",
          (unsigned long)inventory.count, [inventory componentsJoinedByString:@", "]);

    NSMutableArray<NSDictionary *> *victims = [NSMutableArray array];

    // 同一 identifier 多份：留版本号最高的那份（系统自带的），其余低版本的都是我们自己装的
    for (NSString *identifier in groups) {
        NSMutableArray<NSDictionary *> *list = groups[identifier];
        if (list.count < 2) {
            continue;
        }
        [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"version"] compare:a[@"version"]];   // 版本高的排前面
        }];
        TXLog(@"[清理] identifier=%@ 有 %lu 份，保留 v%@", identifier,
              (unsigned long)list.count, list.firstObject[@"version"]);
        for (NSUInteger i = 1; i < list.count; i++) {
            [victims addObject:list[i]];
        }
    }

    // identifier 读不到的：版本号低（不是系统管理的）就一并清掉
    for (NSDictionary *record in orphans) {
        if ([record[@"version"] integerValue] < 1000) {
            [victims addObject:record];
        } else {
            TXLog(@"[清理] 跳过 %@（identifier 读不到但 v%@ 像系统的）", record[@"uuid"], record[@"version"]);
        }
    }

    NSUInteger removed = 0;
    for (NSDictionary *record in victims) {
        NSString *uuid = record[@"uuid"];
        if ([record[@"version"] integerValue] >= 1000) {
            TXLog(@"[清理] 跳过 %@（v%@，系统管理的）", uuid, record[@"version"]);
            continue;
        }
        NSError *error = nil;
        if ([fm removeItemAtPath:[descriptorsRoot stringByAppendingPathComponent:uuid]
                           error:&error]) {
            removed++;
            TXLog(@"[清理] 已删除 %@ (v%@)", uuid, record[@"version"]);
        } else {
            TXLog(@"[清理] 删除失败 %@: %@", uuid, error.localizedDescription);
        }
    }

    // 清单里目录已经没了的记录一并清掉
    NSMutableArray<NSDictionary *> *survivors = [NSMutableArray array];
    for (NSDictionary *record in TXInstalledManifest()) {
        NSString *uuid = record[@"uuid"];
        if (uuid.length && TXIsDirectory([descriptorsRoot stringByAppendingPathComponent:uuid])) {
            [survivors addObject:record];
        }
    }
    TXSaveInstalledManifest(survivors);

    TXLog(@"[清理] 完成，共删除 %lu 个重复项", (unsigned long)removed);
    return removed;
}

#pragma mark - 让 PosterBoard 重新读盘

/// 删过 descriptor 之后光靠 PRS 重扫不够：PosterBoard 的图库里还留着旧行、缩略图也是旧的
/// （收藏里那一片黑图就是这么来的）。它由 launchd 托管，kill 掉会立刻自己重启。
+ (void)restartPosterBoard {
    // 3 秒内重复调用就跳过（连点安装/清理时不必反复杀）
    static CFTimeInterval lastKill = 0;
    CFTimeInterval now = CFAbsoluteTimeGetCurrent();
    if (now - lastKill < 3.0) {
        return;
    }
    lastKill = now;

    extern char **environ;
    const char *argv[] = { "/usr/bin/killall", "-9", "PosterBoard", NULL };
    pid_t pid = 0;
    int result = posix_spawn(&pid, "/usr/bin/killall", NULL, NULL, (char *const *)argv, environ);
    TXLog(@"[A] 重启 PosterBoard: %@", result == 0 ? @"已发出" : @"失败（killall 不可用）");
}

@end
