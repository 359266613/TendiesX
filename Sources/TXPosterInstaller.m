#import "TXPosterInstaller.h"
#import "TXPosterStoreProbe.h"
#import "TXLogger.h"
#import <UIKit/UIKit.h>

static NSString *const kTXDefaultPosterExtension = @"com.apple.WallpaperKit.CollectionsPoster";

/// 安装时要跳过的垃圾文件（macOS 打包残留）
static BOOL TXIsJunkEntry(NSString *name) {
    return [name hasPrefix:@"."] || [name isEqualToString:@"__MACOSX"] || [name isEqualToString:@"LICENSE.txt"];
}

static BOOL TXIsDirectory(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
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

#pragma mark - 目标定位

/// iOS 16 用 59、iOS 17+ 用 61；store 里已有哪个就用哪个，都没有就返回 nil
- (NSString *)tx_versionDirUnder:(NSString *)storeRoot {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:storeRoot error:NULL];
    if (!items.count) {
        return nil;
    }
    NSInteger major = UIDevice.currentDevice.systemVersion.integerValue;
    NSString *preferred = (major >= 17) ? @"61" : @"59";
    if ([items containsObject:preferred]) {
        return [storeRoot stringByAppendingPathComponent:preferred];
    }
    for (NSString *item in items) {
        if (TXIsDirectory([storeRoot stringByAppendingPathComponent:item]) && item.integerValue > 0) {
            return [storeRoot stringByAppendingPathComponent:item];
        }
    }
    return nil;
}

/// 在解包目录里找 descriptors 目录，并推断它属于哪个扩展
- (BOOL)tx_findSourceDescriptorsOf:(NSString *)packagePath
                             inDir:(NSString **)outDir
                         extension:(NSString **)outExtension {
    NSFileManager *fm = NSFileManager.defaultManager;

    // 1) descriptor 格式：<包>/descriptors  → 默认 CollectionsPoster
    NSString *direct = [packagePath stringByAppendingPathComponent:@"descriptors"];
    if (TXIsDirectory(direct)) {
        *outDir = direct;
        *outExtension = kTXDefaultPosterExtension;
        return YES;
    }

    // 2) container 格式：<包>/Container/.../Extensions/<扩展ID>/descriptors
    NSString *container = [packagePath stringByAppendingPathComponent:@"Container"];
    NSString *root = TXIsDirectory(container) ? container : packagePath;
    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:root];
    for (NSString *relative in enumerator) {
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

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:source];
    for (NSString *relative in enumerator) {
        if (TXIsJunkEntry(relative.lastPathComponent)) {
            continue;
        }
        if ([relative containsString:@"__MACOSX"]) {
            continue;   // macOS 打包残留，整枝跳过
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

- (NSArray<NSString *> *)installPackageAtPath:(NSString *)packagePath {
    NSMutableArray<NSString *> *installed = [NSMutableArray array];
    NSFileManager *fm = NSFileManager.defaultManager;

    if (!packagePath.length || !TXIsDirectory(packagePath)) {
        TXLog(@"[A] 安装失败: 路径不是目录 %@", packagePath ?: @"(空)");
        return installed;
    }

    NSString *storeRoot = TXPosterStoreRoot();
    if (!storeRoot) {
        TXLog(@"[A] 安装失败: 找不到 PRBPosterExtensionDataStore");
        return installed;
    }
    NSString *versionDir = [self tx_versionDirUnder:storeRoot];
    if (!versionDir) {
        TXLog(@"[A] 安装失败: 存储里没有版本目录（应形如 …/59 或 …/61）");
        return installed;
    }

    NSString *sourceDir = nil;
    NSString *extension = nil;
    if (![self tx_findSourceDescriptorsOf:packagePath inDir:&sourceDir extension:&extension]) {
        TXLog(@"[A] 安装失败: %@ 里没有 descriptors/ 目录，不是可安装的 .tendies",
              packagePath.lastPathComponent);
        return installed;
    }

    NSString *destRoot = [versionDir stringByAppendingPathComponent:
                          [NSString stringWithFormat:@"Extensions/%@/descriptors", extension]];
    TXLog(@"[A] 源=%@ 扩展=%@ 目标=%@", sourceDir, extension, destRoot);

    NSError *dirError = nil;
    if (![fm createDirectoryAtPath:destRoot withIntermediateDirectories:YES attributes:nil error:&dirError]) {
        TXLog(@"[A] 安装失败: 建不了目标目录: %@", dirError.localizedDescription);
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

        // UUID 随机化：descriptor 里的文件都不引用 UUID（已核对），换名安全，
        // 且能避免和系统已有壁纸撞 UUID。
        NSString *newUUID = [NSUUID UUID].UUIDString.uppercaseString;
        NSString *dst = [destRoot stringByAppendingPathComponent:newUUID];

        NSError *copyError = nil;
        if ([self tx_copyDescriptor:src to:dst error:&copyError]) {
            [installed addObject:dst];
            TXLog(@"[A] 已安装 %@ -> %@", entry, newUUID);
        } else {
            TXLog(@"[A] 安装失败 %@: %@", entry, copyError.localizedDescription);
        }
    }

    if (installed.count) {
        TXLog(@"[A] 共 %lu 个 descriptor 安装完成，重启 PosterBoard 让它重扫",
              (unsigned long)installed.count);
        // PosterBoard 与我们是同一个 uid(mobile)，可以直接让它退出重载
        int ret = system("killall -9 PosterBoard 2>/dev/null");
        TXLog(@"[A] killall PosterBoard 返回 %d（非 0 也没关系，respring 同样生效）", ret);
    } else {
        TXLog(@"[A] 没有安装任何 descriptor（源目录里没有 UUID 子目录？）");
    }
    return installed;
}

@end
