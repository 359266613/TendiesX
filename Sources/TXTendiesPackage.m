#import "TXTendiesPackage.h"
#import "TXLogger.h"
#import "TXZipArchive.h"

NSString *const TXWallpaperKindVideo   = @"video";
NSString *const TXWallpaperKindCA      = @"ca";
NSString *const TXWallpaperKindImage   = @"image";
NSString *const TXWallpaperKindUnknown = @"unknown";

/// 唯一根目录：压缩包投放 + 解压结果都在这里（解压目录与压缩包同名，只是变成目录）
///   <根>/xxx.tendies     投放中的压缩包
///   <根>/xxx.tendies/    解压后的素材目录
static NSString *const kTXStorageDirectory = @"/var/mobile/Library/TendiesX";
/// 解压暂存目录：先解到这里，删掉压缩包后再改名成 xxx.tendies
static NSString *const kTXStagingName = @".importing";

static NSString *const kTXVideoExtensions[] = { @"mp4", @"mov", @"m4v", nil };
static NSString *const kTXImageExtensions[] = { @"png", @"jpg", @"jpeg", nil };

#pragma mark - 小工具

static BOOL TXExtensionInList(NSString *ext, NSString *const *list) {
    for (int i = 0; list[i] != nil; i++) {
        if ([ext isEqualToString:list[i]]) {
            return YES;
        }
    }
    return NO;
}

static BOOL TXIsTendiesName(NSString *name) {
    return [name.pathExtension.lowercaseString isEqualToString:@"tendies"];
}

static BOOL TXIsDirectoryAtPath(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
}

static unsigned long long TXFileSize(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL] fileSize];
}

/// 去掉分辨率尾巴，例如 7400.WWDC_2022-390w-844h@3x~iphone -> 7400.WWDC_2022
static NSString *TXTrimmedName(NSString *name) {
    NSRange range = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return range.location == NSNotFound ? name : [name substringToIndex:range.location];
}

/// 确保根目录存在
static NSString *TXStorageDirectoryPath(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        [NSFileManager.defaultManager createDirectoryAtPath:kTXStorageDirectory
                               withIntermediateDirectories:YES
                                                attributes:nil
                                                     error:NULL];
    });
    return kTXStorageDirectory;
}

@interface TXTendiesPackage ()
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy, readwrite) NSString *kind;
@property (nonatomic, copy, readwrite) NSURL *videoURL;
@property (nonatomic, copy, readwrite) NSURL *fallbackImageURL;
@property (nonatomic, copy, readwrite) NSDictionary *descriptor;
@property (nonatomic, copy, readwrite) NSString *backgroundCAPath;
@property (nonatomic, copy, readwrite) NSString *floatingCAPath;
@property (nonatomic, copy, readwrite) NSString *foregroundCAPath;
@end

@implementation TXTendiesPackage

#pragma mark - 目录与导入

+ (NSString *)storageDirectory {
    return TXStorageDirectoryPath();
}

+ (NSDictionary<NSString *, NSString *> *)importPendingPackagesWithSourceRemoval:(BOOL)removeSource {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = TXStorageDirectoryPath();
    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];

    for (NSString *item in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        if (!TXIsTendiesName(item)) {
            continue;
        }

        NSString *source = [base stringByAppendingPathComponent:item];
        if (TXIsDirectoryAtPath(source)) {
            continue;   // 已经是解压后的素材目录
        }

        // 解压目标与压缩包同名（只是从文件变成目录）
        NSString *destination = source;
        NSDate *sourceDate = [fm attributesOfItemAtPath:source error:NULL].fileModificationDate;

        if (TXIsDirectoryAtPath(destination)) {
            // 已导入过：压缩包不比目录新就直接删掉压缩包
            NSDate *destinationDate = [fm attributesOfItemAtPath:destination error:NULL].fileModificationDate;
            BOOL newer = sourceDate && destinationDate
                && [sourceDate compare:destinationDate] == NSOrderedDescending;
            if (!newer) {
                if (removeSource) {
                    [fm removeItemAtPath:source error:NULL];
                }
                mapping[source] = destination;
                continue;
            }
            TXLog(@"重新导入（压缩包更新）: %@", item);
            [fm removeItemAtPath:destination error:NULL];
        }

        // 先解到暂存目录，成功后再腾位置改名，避免中途失败丢掉原压缩包
        NSString *staging = [base stringByAppendingPathComponent:kTXStagingName];
        [fm removeItemAtPath:staging error:NULL];

        TXLog(@"导入素材: %@", item);
        TXZipArchive *archive = [TXZipArchive archiveWithContentsOfFile:source];
        NSError *error = nil;
        if (!archive || ![archive extractToDirectory:staging error:&error]) {
            TXLog(@"导入失败（保留压缩包）: %@（%@）", item,
                  error.localizedDescription ?: @"不是合法 zip");
            [fm removeItemAtPath:staging error:NULL];
            continue;
        }

        if (removeSource) {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:source error:&removeError]) {
                TXLog(@"压缩包删除失败: %@", removeError.localizedDescription);
                [fm removeItemAtPath:staging error:NULL];
                continue;
            }
        }
        if (![fm moveItemAtPath:staging toPath:destination error:&error]) {
            TXLog(@"导入失败（改名失败）: %@（%@）", item, error.localizedDescription);
            [fm removeItemAtPath:staging error:NULL];
            continue;
        }

        mapping[source] = destination;
        TXLog(@"导入完成: %@", destination.lastPathComponent);
    }
    return mapping;
}

+ (NSArray<NSString *> *)availablePackagePaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *base = TXStorageDirectoryPath();
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (NSString *item in [fm contentsOfDirectoryAtPath:base error:NULL]) {
        if (!TXIsTendiesName(item)) {
            continue;
        }
        NSString *full = [base stringByAppendingPathComponent:item];
        if (TXIsDirectoryAtPath(full)) {
            [found addObject:full];
        }
    }

    [found sortUsingSelector:@selector(compare:)];
    return found;
}

+ (NSString *)firstAvailablePackagePath {
    return [self availablePackagePaths].firstObject;
}

+ (instancetype)packageAtPath:(NSString *)path {
    return path.length ? [[self alloc] initWithPath:path] : nil;
}

#pragma mark - 构造

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _kind = TXWallpaperKindUnknown;
        _descriptor = @{};

        if (!TXIsDirectoryAtPath(_path)) {
            TXLog(@"不是有效的素材目录: %@", _path);
            return nil;
        }
        if (![self tx_scanDirectory:_path]) {
            TXLog(@"解析失败（目录里没有任何可用资源）: %@", _path);
            return nil;
        }
    }
    return self;
}

#pragma mark - 递归扫描（不假设任何固定目录）

- (BOOL)tx_scanDirectory:(NSString *)directory {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSUInteger videoCount = 0;
    NSUInteger imageCount = 0;
    NSUInteger caCount = 0;
    NSString *largestVideo = nil;
    NSString *largestImage = nil;
    NSString *wallpaperDir = nil;
    unsigned long long largestVideoSize = 0;
    unsigned long long largestImageSize = 0;

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:directory];
    for (NSString *relative in enumerator) {
        NSString *item = relative.lastPathComponent;
        if ([item isEqualToString:@".DS_Store"]) {
            continue;
        }

        NSString *full = [directory stringByAppendingPathComponent:relative];
        NSString *ext = item.pathExtension.lowercaseString;

        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) {
            if ([ext isEqualToString:@"ca"]) {
                caCount++;
                // 按目录名判定角色（xxx_Background-*.ca / xxx_Floating-*.ca / xxx_Foreground-*.ca）
                NSString *lower = item.lowercaseString;
                if ([lower containsString:@"background"]) {
                    _backgroundCAPath = _backgroundCAPath ?: full;
                } else if ([lower containsString:@"floating"]) {
                    _floatingCAPath = _floatingCAPath ?: full;
                } else if ([lower containsString:@"foreground"]) {
                    _foregroundCAPath = _foregroundCAPath ?: full;
                } else {
                    _backgroundCAPath = _backgroundCAPath ?: full;   // 没名字的当背景用
                }
            } else if (!wallpaperDir && [ext isEqualToString:@"wallpaper"]) {
                wallpaperDir = full;
            }
            continue;
        }

        if (TXExtensionInList(ext, kTXVideoExtensions)) {
            videoCount++;
            unsigned long long size = TXFileSize(full);
            if (size > largestVideoSize) {
                largestVideoSize = size;
                largestVideo = full;
            }
        } else if (TXExtensionInList(ext, kTXImageExtensions)) {
            imageCount++;
            unsigned long long size = TXFileSize(full);
            if (size > largestImageSize) {
                largestImageSize = size;
                largestImage = full;
            }
        } else if (!_descriptor.count
                   && ([item isEqualToString:@"Wallpaper.plist"]
                       || [item isEqualToString:@"providerInfo.plist"])) {
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:full];
            if ([dict isKindOfClass:NSDictionary.class]) {
                _descriptor = dict;
            }
        }
    }

    TXLog(@"扫描 %@: 视频 %lu / 图片 %lu / .ca 包 %lu / .wallpaper 目录 %@",
          directory.lastPathComponent, (unsigned long)videoCount, (unsigned long)imageCount,
          (unsigned long)caCount, wallpaperDir ? @"有" : @"无");

    if (videoCount) {
        _videoURL = [NSURL fileURLWithPath:largestVideo];
        _kind = TXWallpaperKindVideo;
    } else if (caCount) {
        _kind = TXWallpaperKindCA;
    } else if (imageCount) {
        _kind = TXWallpaperKindImage;
    } else {
        return NO;
    }

    if (largestImage) {
        _fallbackImageURL = [NSURL fileURLWithPath:largestImage];
    }

    NSString *name = wallpaperDir.lastPathComponent.stringByDeletingPathExtension;
    if (!name.length) {
        id plistName = _descriptor[@"name"] ?: _descriptor[@"displayName"];
        name = [plistName isKindOfClass:NSString.class]
            ? plistName
            : _path.lastPathComponent.stringByDeletingPathExtension;
    }
    _displayName = TXTrimmedName(name);

    TXLog(@"解析成功: name=%@ kind=%@ video=%@ 兜底图=%@ CA层[bg=%@ float=%@ fg=%@]",
          _displayName, _kind,
          _videoURL.lastPathComponent ?: @"(无)",
          _fallbackImageURL.lastPathComponent ?: @"(无)",
          _backgroundCAPath.lastPathComponent ?: @"-",
          _floatingCAPath.lastPathComponent ?: @"-",
          _foregroundCAPath.lastPathComponent ?: @"-");
    return YES;
}

@end
