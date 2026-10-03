#import "TXPosterInstaller.h"
#import "TXZipArchive.h"
#import "TXPosterDiagnostics.h"
#import "TXLogger.h"
#import <UIKit/UIKit.h>

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
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTXManifestDomain);
}

/// descriptor 的 identifier 写在 <descriptor>/com.apple.posterkit.provider.descriptor.identifier，
/// 是纯文本（实测内容就是 "7400"，4 字节、无换行），给 PRSService 建配置时要用。
static NSString *TXDescriptorIdentifierIn(NSString *descriptorDirectory) {
    NSString *file = [descriptorDirectory stringByAppendingPathComponent:
                      @"com.apple.posterkit.provider.descriptor.identifier"];
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) {
        text = [NSString stringWithContentsOfFile:file encoding:NSISOLatin1StringEncoding error:NULL];
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
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

    // 重复安装改为"替换"：先清掉我们自己上次装的、identifier 相同的副本。
    // 只认清单里记录过的 UUID —— 系统自带的同 identifier 壁纸绝不碰（那是别人的资产）。
    NSMutableArray<NSDictionary *> *manifest = [TXInstalledManifest() mutableCopy];

    for (NSString *entry in [fm contentsOfDirectoryAtPath:sourceDir error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *src = [sourceDir stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(src)) {
            continue;
        }

        NSString *identifier = TXDescriptorIdentifierIn(src);

        if (identifier.length) {
            NSMutableArray<NSDictionary *> *keep = [NSMutableArray array];
            for (NSDictionary *record in manifest) {
                BOOL sameIdentifier = [record[@"identifier"] isEqualToString:identifier];
                BOOL sameExtension = [record[@"extension"] isEqualToString:extension];
                NSString *oldUUID = record[@"uuid"];
                if (sameIdentifier && sameExtension && oldUUID.length) {
                    NSString *oldPath = [destRoot stringByAppendingPathComponent:oldUUID];
                    if (TXIsDirectory(oldPath)) {
                        [fm removeItemAtPath:oldPath error:NULL];
                        TXLog(@"[A] 清理上次装的同款 %@（identifier=%@）", oldUUID, identifier);
                    }
                } else {
                    [keep addObject:record];
                }
            }
            [manifest setArray:keep];
        }

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
                  entry, identifier.length ? identifier : @"(未读到)", newUUID);
        } else {
            // 失败就删掉残缺目录，免得留下一个半成品让 PosterBoard 收录
            [fm removeItemAtPath:dst error:NULL];
            TXLog(@"[A] 安装失败 %@: %@", entry, copyError.localizedDescription);
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

/// descriptor 的「当前版本号」：取 versions/ 下最大的那个数字。
/// PosterBoard 每次改写都会把它 +1；系统自带的是几千，我们装的是 0~4。
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

    // 按 identifier 分组
    NSMutableDictionary<NSString *, NSMutableArray<NSDictionary *> *> *groups = [NSMutableDictionary dictionary];
    for (NSString *entry in [fm contentsOfDirectoryAtPath:descriptorsRoot error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(dir)) {
            continue;
        }
        NSString *identifier = TXDescriptorIdentifierIn(dir);
        if (!identifier.length) {
            continue;
        }
        NSMutableArray<NSDictionary *> *list = groups[identifier];
        if (!list) {
            list = [NSMutableArray array];
            groups[identifier] = list;
        }
        [list addObject:@{ @"uuid": entry, @"version": @(TXMaxVersionIn(dir)) }];
    }

    NSUInteger removed = 0;
    for (NSString *identifier in groups) {
        NSMutableArray<NSDictionary *> *list = groups[identifier];
        if (list.count < 2) {
            continue;   // 只有一份（通常是系统自带的），不碰
        }
        [list sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
            return [b[@"version"] compare:a[@"version"]];   // 版本高的排前面
        }];
        NSDictionary *keep = list.firstObject;
        TXLog(@"[清理] identifier=%@ 有 %lu 份，保留 %@ (v%@)",
              identifier, (unsigned long)list.count, keep[@"uuid"], keep[@"version"]);

        for (NSUInteger i = 1; i < list.count; i++) {
            NSDictionary *record = list[i];
            NSString *uuid = record[@"uuid"];
            NSInteger version = [record[@"version"] integerValue];
            if (version >= 1000) {
                TXLog(@"[清理] 跳过 %@（v%ld，看着像系统管理的，不动）", uuid, (long)version);
                continue;
            }
            NSError *error = nil;
            if ([fm removeItemAtPath:[descriptorsRoot stringByAppendingPathComponent:uuid]
                               error:&error]) {
                removed++;
                TXLog(@"[清理] 已删除重复项 %@ (identifier=%@ v%ld)", uuid, identifier, (long)version);
            } else {
                TXLog(@"[清理] 删除失败 %@: %@", uuid, error.localizedDescription);
            }
        }
    }

    // 同步清理安装清单：只保留目录还在的记录
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

@end
