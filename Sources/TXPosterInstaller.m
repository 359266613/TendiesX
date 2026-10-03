#import "TXPosterInstaller.h"
#import "TXZipArchive.h"
#import "TXLogger.h"
#import <UIKit/UIKit.h>
#import <stdlib.h>

static NSString *const kTXDefaultPosterExtension = @"com.apple.WallpaperKit.CollectionsPoster";

static BOOL TXIsDirectory(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
}

/// 安装时跳过的打包残留
static BOOL TXIsJunkEntry(NSString *name) {
    return [name hasPrefix:@"."]
        || [name isEqualToString:@"__MACOSX"]
        || [name isEqualToString:@"LICENSE.txt"]
        || [name isEqualToString:@"README.md"];
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

    NSString *destination = source;
    TXZipArchive *zip = [TXZipArchive archiveWithContentsOfFile:source];
    if (!zip) {
        TXLog(@"[A] 不是有效的 zip: %@", source.lastPathComponent);
        return nil;
    }
    NSError *error = nil;
    if (![zip extractToDirectory:destination error:&error]) {
        TXLog(@"[A] 解包失败: %@", error.localizedDescription);
        return nil;
    }
    TXLog(@"[A] 已解包 %@ -> %@/（%lu 项）",
          source.lastPathComponent, destination.lastPathComponent,
          (unsigned long)zip.entries.count);
    return destination;
}

#pragma mark - 源 descriptor 定位

/// 支持两种 .tendies 布局：
///   descriptors/<UUID>/...                                     （descriptor 格式）
///   Container/.../Extensions/<扩展ID>/descriptors/<UUID>/...    （container 格式，扩展 ID 从路径反推）
- (BOOL)tx_findDescriptorsIn:(NSString *)directory
                      inDir:(NSString **)outDir
                  extension:(NSString **)outExtension {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *direct = [directory stringByAppendingPathComponent:@"descriptors"];
    if (TXIsDirectory(direct)) {
        *outDir = direct;
        *outExtension = kTXDefaultPosterExtension;
        return YES;
    }

    NSString *container = [directory stringByAppendingPathComponent:@"Container"];
    NSString *root = TXIsDirectory(container) ? container : directory;
    for (NSString *relative in [fm enumeratorAtPath:root]) {
        if (![relative.lastPathComponent isEqualToString:@"descriptors"]) {
            continue;
        }
        NSString *absolute = [root stringByAppendingPathComponent:relative];
        if (!TXIsDirectory(absolute)) {
            continue;
        }
        NSString *ext = absolute.stringByDeletingLastPathComponent.lastPathComponent;
        *outDir = absolute;
        *outExtension = ext.length ? ext : kTXDefaultPosterExtension;
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
        TXLog(@"[A] 共 %lu 个 descriptor 安装完成，重启 PosterBoard 让它重扫",
              (unsigned long)installed.count);
        int ret = system("killall -9 PosterBoard 2>/dev/null");
        TXLog(@"[A] killall PosterBoard 返回 %d（非 0 也没关系，respring 同样生效）", ret);
    } else {
        TXLog(@"[A] 没有安装任何 descriptor（源目录里没有 UUID 子目录？）");
    }
    return installed;
}

@end
