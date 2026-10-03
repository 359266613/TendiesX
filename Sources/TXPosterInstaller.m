#import "TXPosterInstaller.h"
#import "TXZipArchive.h"
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
@end

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

    for (NSString *entry in [fm contentsOfDirectoryAtPath:sourceDir error:NULL]) {
        if (TXIsJunkEntry(entry)) {
            continue;
        }
        NSString *src = [sourceDir stringByAppendingPathComponent:entry];
        if (!TXIsDirectory(src)) {
            continue;
        }

        // UUID 随机化：descriptor 内的文件都不引用 UUID（已逐个核对），换名安全，
        // 且永不与系统已有壁纸撞 UUID。
        NSString *newUUID = [NSUUID UUID].UUIDString.uppercaseString;
        NSString *dst = [destRoot stringByAppendingPathComponent:newUUID];

        NSError *copyError = nil;
        if ([self tx_copyDescriptor:src to:dst error:&copyError]) {
            [installed addObject:dst];
            TXLog(@"[A] 已安装 descriptor %@ -> %@", entry, newUUID);
        } else {
            TXLog(@"[A] 安装失败 %@: %@", entry, copyError.localizedDescription);
        }
    }

    if (installed.count) {
        TXLog(@"[A] 共 %lu 个 descriptor 安装完成，交给 worker 调 PRSService 让 PosterBoard 重扫",
              (unsigned long)installed.count);
        // 这里不再 killall PosterBoard：
        // 1) iOS 上没有 system()（SDK 标记 __API_UNAVAILABLE(ios)）；
        // 2) 官方重扫方式是 PRSService -refreshPosterDescriptorsForExtension:，
        //    由 Hooks/Worker.xm 在安装成功后调用，不用重启进程。
    } else {
        TXLog(@"[A] 没有安装任何 descriptor（源目录里没有 UUID 子目录？）");
    }
    return installed;
}

@end
