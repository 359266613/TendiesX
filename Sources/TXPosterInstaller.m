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

#pragma mark - 给素材换一个"自己的" identifier

/// .tendies 素材大多是从系统壁纸改内容做的，identifier 照抄（实测 iOS16 / 仙逆_王林 /
/// 气质美乳女菩萨 三个素材全是 7400）。PosterBoard 认 descriptor 靠 identifier，
/// 撞号就会表现成"装进去了、收藏里也有，但显示和生效的永远是系统那份"。
/// 所以安装时给每个素材算一个只属于它的 identifier：
///   · 同一素材每次算出来一样 → 重复安装仍然是"替换自己"，不堆重复项
///   · 不同素材互不相同 → 收藏里各是各的，AutoApply 也不会再指到系统那份
///   · 9 开头 6 位，避开 Apple 的编号段（7400 / 7410 / 7610 …）
static NSString *TXIdentifierForMaterial(NSString *materialKey) {
    uint32_t hash = 2166136261u;
    for (NSUInteger i = 0; i < materialKey.length; i++) {
        hash = (hash ^ [materialKey characterAtIndex:i]) * 16777619u;
    }
    return [NSString stringWithFormat:@"9%05u", hash % 100000u];
}

/// 递归把对象里出现的旧 identifier 换成新的；标题（name）一并改成素材名，
/// 否则收藏里三条都叫 "WWDC 2022"，根本分不出哪个是哪个。
static id TXRewritingObject(id object, NSString *oldId, NSString *newId, NSString *title) {
    if ([object isKindOfClass:NSString.class]) {
        NSString *text = (NSString *)object;
        return [text containsString:oldId]
            ? [text stringByReplacingOccurrencesOfString:oldId withString:newId]
            : text;
    }
    if ([object isKindOfClass:NSArray.class]) {
        NSMutableArray *result = [NSMutableArray arrayWithCapacity:[object count]];
        for (id item in object) {
            [result addObject:TXRewritingObject(item, oldId, newId, title)];
        }
        return result;
    }
    if ([object isKindOfClass:NSDictionary.class]) {
        NSMutableDictionary *result = [NSMutableDictionary dictionaryWithCapacity:[object count]];
        for (id key in object) {
            id value = TXRewritingObject(object[key], oldId, newId, title);
            if (title.length && [key isEqualToString:@"name"] && [value isKindOfClass:NSString.class]) {
                value = title;
            }
            result[key] = value;
        }
        return result;
    }
    return object;
}

/// 纯文本类型的扩展名（这些里面可能带 identifier，改一遍最稳）
static BOOL TXIsRewritableTextName(NSString *name) {
    NSString *ext = name.pathExtension.lowercaseString;
    return [ext isEqualToString:@"caml"] || [ext isEqualToString:@"xml"] || [ext isEqualToString:@"js"]
        || [ext isEqualToString:@"json"] || [ext isEqualToString:@"txt"] || [ext isEqualToString:@"identifier"]
        || ext.length == 0;
}

/// 把 descriptor 目录里的 oldId 全部换成 newId：
///   ① 名字里带它的目录/文件（7400.WWDC_2022-390w-844h@3x~iphone.wallpaper/、…_Background-….ca 等）
///   ② com.apple.posterkit.provider.descriptor.identifier 的内容
///   ③ 各 plist / caml / xml / js 里的字符串（Wallpaper.plist 的 identifier 与引用到的 .ca 名字）
/// 图片（HEIC/jpg/png）和 .atx 快照只改名字、不动内容。
static void TXRenameIdentifierInDescriptor(NSString *directory,
                                           NSString *oldId,
                                           NSString *newId,
                                           NSString *materialName) {
    if (!oldId.length || !newId.length || [oldId isEqualToString:newId]) {
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;

    // ① 先改名：深的先改，免得改了父目录之后子路径失效
    NSMutableArray<NSString *> *paths = [NSMutableArray array];
    for (NSString *relative in [fm enumeratorAtPath:directory]) {
        if ([relative.lastPathComponent containsString:oldId]) {
            [paths addObject:relative];
        }
    }
    [paths sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        return [b compare:a];
    }];
    NSUInteger renamed = 0;
    for (NSString *relative in paths) {
        NSString *from = [directory stringByAppendingPathComponent:relative];
        NSString *name = [relative.lastPathComponent stringByReplacingOccurrencesOfString:oldId
                                                                              withString:newId];
        NSString *to = [from.stringByDeletingLastPathComponent stringByAppendingPathComponent:name];
        if ([fm moveItemAtPath:from toPath:to error:NULL]) {
            renamed++;
        }
    }

    // ② identifier 文本
    NSString *identifierFile = [directory stringByAppendingPathComponent:
                                @"com.apple.posterkit.provider.descriptor.identifier"];
    [newId writeToFile:identifierFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];

    // ③ 内容
    NSUInteger rewritten = 0;
    for (NSString *relative in [fm enumeratorAtPath:directory]) {
        NSString *name = relative.lastPathComponent;
        NSString *path = [directory stringByAppendingPathComponent:relative];
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:path isDirectory:&isDir] || isDir) {
            continue;
        }

        if ([name hasSuffix:@".plist"]) {
            // plist 可能是二进制，必须按 plist 解析再写回
            NSData *data = [NSData dataWithContentsOfFile:path];
            id plist = data.length
                ? [NSPropertyListSerialization propertyListWithData:data
                                                            options:NSPropertyListMutableContainers
                                                             format:NULL
                                                              error:NULL]
                : nil;
            if (!plist) {
                continue;
            }
            BOOL renameTitle = [name isEqualToString:@"Wallpaper.plist"] || [name isEqualToString:@"providerInfo.plist"];
            id rewrittenPlist = TXRewritingObject(plist, oldId, newId, renameTitle ? materialName : nil);
            NSData *out = [NSPropertyListSerialization dataWithPropertyList:rewrittenPlist
                                                                    format:NSPropertyListXMLFormat_v1_0
                                                                   options:0
                                                                     error:NULL];
            if (out && [out writeToFile:path atomically:YES]) {
                rewritten++;
            }
            continue;
        }

        if (!TXIsRewritableTextName(name)) {
            continue;   // 图片 / 快照不动内容
        }
        NSString *text = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:NULL];
        if (!text.length || ![text containsString:oldId]) {
            continue;
        }
        NSString *updated = [text stringByReplacingOccurrencesOfString:oldId withString:newId];
        if ([updated writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:NULL]) {
            rewritten++;
        }
    }

    TXLog(@"[A] 换成自己的 identifier：%@ -> %@（改名 %lu 项，改内容 %lu 个文件）",
          oldId, newId, (unsigned long)renamed, (unsigned long)rewritten);
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

    // 素材名（去掉 .tendies）：用来算它自己的 identifier，也用来当收藏里的标题
    NSString *materialName = [directory.lastPathComponent stringByDeletingPathExtension];
    TXLog(@"[A] 素材=%@ 扩展=%@ 目标=%@", materialName, extension, destRoot);

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

    // 3) 挑要装的（空壳一律跳过：装了也是黑图），并给每条算出"它自己的" identifier
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
        NSMutableDictionary *record = [item mutableCopy];
        record[@"newIdentifier"] = identifier.length
            ? TXIdentifierForMaterial([materialName stringByAppendingString:item[@"name"]])
            : @"";
        [selected addObject:record];
    }
    if (!selected.count) {
        TXLog(@"[A] 没有可装的 descriptor（源 %lu 个都被过滤了）", (unsigned long)candidates.count);
        return installed;
    }

    // 4) 替换：按"它自己的 identifier"清旧副本。
    //    因为 identifier 是按素材名算出来的固定值，所以：
    //      · 同一个素材重复安装 → 命中同 identifier → 替换掉自己上次那份（不堆重复项）
    //      · 不同素材 → identifier 各不相同 → 谁也不删谁（三个素材可以共存）
    //    系统自带的条目版本号是几千，TXRemoveOurCopiesOfIdentifiers 里会主动跳过。
    NSMutableSet<NSString *> *replaceable = [NSMutableSet set];
    for (NSDictionary *item in selected) {
        if (((NSString *)item[@"newIdentifier"]).length) {
            [replaceable addObject:item[@"newIdentifier"]];
        }
    }
    NSUInteger replaced = TXRemoveOurCopiesOfIdentifiers(destRoot, replaceable);
    TXLog(@"[A] 替换：清掉旧副本 %lu 份；本次装 %lu 个（源 %lu 个）",
          (unsigned long)replaced, (unsigned long)selected.count, (unsigned long)candidates.count);

    // 5) 复制 → 换成自己的 identifier → 更新安装清单
    NSMutableArray<NSDictionary *> *manifest = [TXInstalledManifest() mutableCopy];
    [manifest filterUsingPredicate:
        [NSPredicate predicateWithBlock:^BOOL(NSDictionary *record, NSDictionary *bindings) {
            return TXIsDirectory([destRoot stringByAppendingPathComponent:record[@"uuid"] ?: @""]);
        }]];

    for (NSDictionary *item in selected) {
        NSString *src = item[@"path"];
        NSString *sourceIdentifier = item[@"identifier"];
        NSString *installedIdentifier = item[@"newIdentifier"];

        // UUID 随机化：descriptor 内的文件都不引用 UUID（已逐个核对），换名安全。
        NSString *newUUID = [NSUUID UUID].UUIDString.uppercaseString;
        NSString *dst = [destRoot stringByAppendingPathComponent:newUUID];

        NSError *copyError = nil;
        if ([self tx_copyDescriptor:src to:dst error:&copyError]) {
            // 关键一步：素材自带的 identifier 多半和系统壁纸撞号（三个素材都是 7400），
            // 换成只属于它的那个，收藏里才会是独立的一份、显示自己的画面。
            if (sourceIdentifier.length && installedIdentifier.length) {
                TXRenameIdentifierInDescriptor(dst, sourceIdentifier, installedIdentifier, materialName);
            }

            [installed addObject:dst];
            if (installedIdentifier.length) {
                [identifiers addObject:installedIdentifier];
                [manifest addObject:@{ @"uuid": newUUID,
                                       @"identifier": installedIdentifier,
                                       @"extension": extension }];
            }
            TXLog(@"[A] 已安装 descriptor %@ (identifier=%@ → %@) -> %@",
                  item[@"name"], sourceIdentifier.length ? sourceIdentifier : @"(未读到)",
                  installedIdentifier.length ? installedIdentifier : @"(未读到)", newUUID);
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
