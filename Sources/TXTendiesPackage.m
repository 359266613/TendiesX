#import "TXTendiesPackage.h"
#import "TXLogger.h"
#import "TXZipArchive.h"

NSString *const TXWallpaperKindVideo   = @"video";
NSString *const TXWallpaperKindCA      = @"ca";
NSString *const TXWallpaperKindImage   = @"image";
NSString *const TXWallpaperKindUnknown = @"unknown";

/// 唯一根目录：投放目录就是它本身，素材库是它的 Library 子目录
static NSString *const kTXBaseDirectory = @"/var/mobile/Library/TendiesX";

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

static unsigned long long TXFileSize(NSString *path) {
    return [[NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL] fileSize];
}

/// 目录名安全化（避免路径穿越与非法字符）
static NSString *TXSafeComponentName(NSString *component) {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *safe = [[component componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];
    safe = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return safe.length ? safe : @"package";
}

/// 去掉分辨率尾巴，例如 7400.WWDC_2022-390w-844h@3x~iphone -> 7400.WWDC_2022
static NSString *TXTrimmedName(NSString *name) {
    NSRange range = [name rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    return range.location == NSNotFound ? name : [name substringToIndex:range.location];
}

/// 素材库目录（失败时回落到临时目录）
static NSString *TXLibraryDirectory(void) {
    static NSString *dir = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *candidate = [kTXBaseDirectory stringByAppendingPathComponent:@"Library"];
        if ([fm createDirectoryAtPath:candidate withIntermediateDirectories:YES attributes:nil error:NULL]
            || [fm fileExistsAtPath:candidate]) {
            dir = candidate;
            return;
        }
        NSString *fallback = [NSTemporaryDirectory() stringByAppendingPathComponent:@"TendiesX/Library"];
        [fm createDirectoryAtPath:fallback withIntermediateDirectories:YES attributes:nil error:NULL];
        dir = fallback;
    });
    return dir;
}

@interface TXTendiesPackage ()
@property (nonatomic, copy, readwrite) NSString *path;
@property (nonatomic, copy, readwrite) NSString *displayName;
@property (nonatomic, copy, readwrite) NSString *kind;
@property (nonatomic, copy, readwrite) NSURL *videoURL;
@property (nonatomic, copy, readwrite) NSURL *fallbackImageURL;
@property (nonatomic, copy, readwrite) NSDictionary *descriptor;
@property (nonatomic, copy, readwrite) NSArray<NSString *> *caBundlePaths;
@end

@implementation TXTendiesPackage

#pragma mark - 目录与导入

+ (NSString *)libraryDirectory { return TXLibraryDirectory(); }
+ (NSString *)inboxDirectory   { return kTXBaseDirectory; }

+ (NSDictionary<NSString *, NSString *> *)importPendingPackagesWithSourceRemoval:(BOOL)removeSource {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *library = TXLibraryDirectory();
    NSMutableDictionary<NSString *, NSString *> *mapping = [NSMutableDictionary dictionary];

    for (NSString *item in [fm contentsOfDirectoryAtPath:kTXBaseDirectory error:NULL]) {
        if (![[item.pathExtension lowercaseString] isEqualToString:@"tendies"]) {
            continue;
        }

        NSString *source = [kTXBaseDirectory stringByAppendingPathComponent:item];
        NSString *destination = [library stringByAppendingPathComponent:
                                 TXSafeComponentName(item.stringByDeletingPathExtension)];
        NSString *marker = [destination stringByAppendingPathComponent:@".unpacked"];

        // 已解压过就直接删源文件；没解压过才解
        if (![fm fileExistsAtPath:marker]) {
            TXLog(@"导入素材: %@", item);
            TXZipArchive *archive = [TXZipArchive archiveWithContentsOfFile:source];
            NSError *error = nil;
            if (!archive || ![archive extractToDirectory:destination error:&error]) {
                TXLog(@"导入失败（保留源文件）: %@（%@）", item,
                      error.localizedDescription ?: @"不是合法 zip");
                continue;
            }
            [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
        }

        if (removeSource) {
            NSError *removeError = nil;
            if (![fm removeItemAtPath:source error:&removeError]) {
                TXLog(@"源文件删除失败: %@", removeError.localizedDescription);
            }
        }
        mapping[source] = destination;
    }
    return mapping;
}

+ (NSArray<NSString *> *)availablePackagePaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *library = TXLibraryDirectory();
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (NSString *item in [fm contentsOfDirectoryAtPath:library error:NULL]) {
        NSString *full = [library stringByAppendingPathComponent:item];
        BOOL isDir = NO;
        if ([fm fileExistsAtPath:full isDirectory:&isDir] && isDir) {
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
        _caBundlePaths = @[];

        BOOL isDir = NO;
        if (![NSFileManager.defaultManager fileExistsAtPath:_path isDirectory:&isDir] || !isDir) {
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
            : _path.lastPathComponent;
    }
    _displayName = TXTrimmedName(name);

    TXLog(@"解析成功: name=%@ kind=%@ video=%@ fallbackImage=%@",
          _displayName, _kind,
          _videoURL.lastPathComponent ?: @"(无)",
          _fallbackImageURL.lastPathComponent ?: @"(无)");
    return YES;
}

@end
