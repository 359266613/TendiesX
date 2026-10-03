#import "TXTendiesPackage.h"
#import "TXLogger.h"
#import "TXZipArchive.h"

NSString *const TXWallpaperKindVideo   = @"video";
NSString *const TXWallpaperKindCA      = @"ca";
NSString *const TXWallpaperKindImage   = @"image";
NSString *const TXWallpaperKindUnknown = @"unknown";

static NSString *const kTXVideoExtensions[] = { @"mp4", @"mov", @"m4v", @"mkv", @"avi", nil };
static NSString *const kTXImageExtensions[] = { @"png", @"jpg", @"jpeg", @"heic", nil };

#pragma mark - 路径约定

/// 解包缓存根目录
static NSString *TXTendiesCacheRoot(void) {
    static NSString *root = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        NSArray<NSString *> *candidates = @[
            @"/var/mobile/Library/Caches/TendiesX",
            [NSTemporaryDirectory() stringByAppendingPathComponent:@"TendiesX"],
        ];
        for (NSString *dir in candidates) {
            if (!dir.length) {
                continue;
            }
            if ([fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:NULL]
                || [fm fileExistsAtPath:dir]) {
                root = dir;
                break;
            }
        }
    });
    return root;
}

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

/// 静态兜底图优先级：路径含 background 的 > 体积最大的
static NSString *TXChooseFallbackImage(NSArray<NSString *> *images) {
    NSString *background = nil;
    NSString *largest = nil;
    unsigned long long largestSize = 0;

    for (NSString *path in images) {
        if (!background && [path.lowercaseString containsString:@"background"]) {
            background = path;
        }
        unsigned long long size = TXFileSize(path);
        if (size > largestSize) {
            largestSize = size;
            largest = path;
        }
    }
    return background ?: largest;
}

@interface TXTendiesPackage ()
@property (nonatomic, copy,   readwrite) NSString *path;
@property (nonatomic, copy,   readwrite) NSString *rootDirectory;
@property (nonatomic, copy,   readwrite) NSString *displayName;
@property (nonatomic, copy,   readwrite) NSString *kind;
@property (nonatomic, copy,   readwrite) NSURL *videoURL;
@property (nonatomic, copy,   readwrite) NSURL *fallbackImageURL;
@property (nonatomic, copy,   readwrite) NSDictionary *descriptor;
@property (nonatomic, copy,   readwrite) NSArray<NSString *> *caBundlePaths;
@property (nonatomic, assign, readwrite) NSTimeInterval stillTime;
@property (nonatomic, assign, readwrite) BOOL looping;
@property (nonatomic, assign, readwrite) BOOL unpackedFromZip;
@end

@implementation TXTendiesPackage

#pragma mark - 目录约定

+ (NSArray<NSString *> *)searchDirectories {
    NSMutableArray<NSString *> *dirs = [NSMutableArray arrayWithObjects:
                                        @"/var/mobile/Library/TendiesX",
                                        @"/var/mobile/Media/TendiesX",
                                        nil];
    NSString *cache = TXTendiesCacheRoot();
    if (cache.length) {
        [dirs addObject:cache];
    }
    return dirs;
}

+ (NSArray<NSString *> *)availablePackagePaths {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSMutableArray<NSString *> *found = [NSMutableArray array];

    for (NSString *dir in [self searchDirectories]) {
        for (NSString *item in [fm contentsOfDirectoryAtPath:dir error:NULL]) {
            NSString *full = [dir stringByAppendingPathComponent:item];
            BOOL isDir = NO;
            if (![fm fileExistsAtPath:full isDirectory:&isDir]) {
                continue;
            }
            BOOL isTendiesZip = [[item.pathExtension lowercaseString] isEqualToString:@"tendies"];
            BOOL isUnpackedTendies = isDir && [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"descriptors"]];
            if (isTendiesZip || isUnpackedTendies) {
                [found addObject:full];
            }
        }
    }

    [found sortUsingSelector:@selector(compare:)];
    return found;
}

+ (NSString *)firstAvailablePackagePath {
    return [self availablePackagePaths].firstObject;
}

+ (BOOL)isTendiesURL:(NSURL *)url {
    return [[url.pathExtension lowercaseString] isEqualToString:@"tendies"];
}

#pragma mark - 构造

+ (instancetype)packageAtPath:(NSString *)path {
    return path.length ? [[self alloc] initWithPath:path] : nil;
}

- (instancetype)initWithPath:(NSString *)path {
    self = [super init];
    if (self) {
        _path = [path copy];
        _rootDirectory = [path copy];
        _kind = TXWallpaperKindUnknown;
        _looping = YES;
        _stillTime = 0.0;
        _descriptor = @{};
        _caBundlePaths = @[];

        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:_path isDirectory:&isDir]) {
            TXLog(@"路径不存在: %@", _path);
            return nil;
        }

        if (!isDir) {
            NSString *unpacked = [self tx_unpackContainer:_path];
            if (!unpacked) {
                return nil;
            }
            _rootDirectory = unpacked;
            _unpackedFromZip = YES;
        }

        if (![self tx_scanDirectory:_rootDirectory]) {
            TXLog(@"解析失败（递归扫描后没有任何可用资源）: %@", _rootDirectory);
            return nil;
        }
    }
    return self;
}

#pragma mark - 解包

/// .tendies(zip) -> 缓存目录，返回可用目录；失败返回 nil
- (NSString *)tx_unpackContainer:(NSString *)containerPath {
    NSString *cacheRoot = TXTendiesCacheRoot();
    if (!cacheRoot.length) {
        TXLog(@"找不到可写的解包缓存目录");
        return nil;
    }

    NSString *name = [self tx_safeComponent:[[containerPath lastPathComponent] stringByDeletingPathExtension]];
    NSString *destination = [cacheRoot stringByAppendingPathComponent:name];
    NSFileManager *fm = NSFileManager.defaultManager;

    // 源文件比上次解包新才重新解
    NSString *marker = [destination stringByAppendingPathComponent:@".unpacked"];
    NSDictionary *sourceAttributes = [fm attributesOfItemAtPath:containerPath error:NULL];
    NSDictionary *markerAttributes = [fm attributesOfItemAtPath:marker error:NULL];
    BOOL needsUnpack = YES;
    if (sourceAttributes && markerAttributes) {
        NSDate *sourceDate = sourceAttributes.fileModificationDate;
        NSDate *markerDate = markerAttributes.fileModificationDate;
        needsUnpack = (sourceDate && markerDate && [sourceDate compare:markerDate] == NSOrderedDescending);
    }

    if (!needsUnpack) {
        TXLog(@"复用已有解包结果: %@", destination);
        return destination;
    }

    TXLog(@"开始解包 .tendies: %@ -> %@", containerPath, destination);
    TXZipArchive *archive = [TXZipArchive archiveWithContentsOfFile:containerPath];
    if (!archive) {
        TXLog(@"不是合法的 zip 容器: %@", containerPath);
        return nil;
    }

    [fm removeItemAtPath:destination error:NULL];
    NSError *error = nil;
    if (![archive extractToDirectory:destination error:&error]) {
        TXLog(@"解包失败: %@", error.localizedDescription ?: @"未知错误");
        return nil;
    }

    [@"1" writeToFile:marker atomically:YES encoding:NSUTF8StringEncoding error:NULL];
    return destination;
}

/// 目录名安全化（避免路径穿越与非法字符）
- (NSString *)tx_safeComponent:(NSString *)component {
    NSCharacterSet *illegal = [NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"];
    NSString *safe = [[component componentsSeparatedByCharactersInSet:illegal] componentsJoinedByString:@"_"];
    safe = [safe stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return safe.length ? safe : @"package";
}

#pragma mark - 递归扫描（不假设任何固定目录）

- (BOOL)tx_scanDirectory:(NSString *)directory {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSMutableArray<NSString *> *videos = [NSMutableArray array];
    NSMutableArray<NSString *> *images = [NSMutableArray array];
    NSMutableArray<NSString *> *caBundles = [NSMutableArray array];
    NSMutableArray<NSString *> *wallpaperDirs = [NSMutableArray array];
    NSMutableArray<NSString *> *plists = [NSMutableArray array];

    NSDirectoryEnumerator<NSString *> *enumerator = [fm enumeratorAtPath:directory];
    for (NSString *relative in enumerator) {
        NSString *item = relative.lastPathComponent;
        if ([item isEqualToString:@".DS_Store"]) {
            continue;
        }
        NSString *full = [directory stringByAppendingPathComponent:relative];
        NSString *ext = [item.pathExtension lowercaseString];

        BOOL isDir = NO;
        [fm fileExistsAtPath:full isDirectory:&isDir];
        if (isDir) {
            if ([ext isEqualToString:@"ca"]) {
                [caBundles addObject:full];
            } else if ([ext isEqualToString:@"wallpaper"]) {
                [wallpaperDirs addObject:full];
            }
            continue;
        }

        if (TXExtensionInList(ext, kTXVideoExtensions)) {
            [videos addObject:full];
        } else if (TXExtensionInList(ext, kTXImageExtensions)) {
            [images addObject:full];
        } else if ([ext isEqualToString:@"plist"]) {
            [plists addObject:full];
        }
    }

    TXLog(@"扫描 %@: 视频 %lu / 图片 %lu / .ca 包 %lu / .wallpaper 目录 %lu / plist %lu",
          directory.lastPathComponent,
          (unsigned long)videos.count, (unsigned long)images.count,
          (unsigned long)caBundles.count, (unsigned long)wallpaperDirs.count,
          (unsigned long)plists.count);

    // 描述 plist：优先 Wallpaper.plist / providerInfo.plist
    for (NSString *plist in plists) {
        NSString *name = plist.lastPathComponent;
        if ([name isEqualToString:@"Wallpaper.plist"] || [name isEqualToString:@"providerInfo.plist"]) {
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:plist];
            if ([dict isKindOfClass:NSDictionary.class]) {
                _descriptor = dict;
                break;
            }
        }
    }

    _caBundlePaths = [caBundles copy];

    // 类型判定：视频优先，其次 .ca，再次纯图片
    if (videos.count) {
        // 取体积最大的视频作为主视频
        NSString *main = videos.firstObject;
        unsigned long long largest = 0;
        for (NSString *video in videos) {
            unsigned long long size = TXFileSize(video);
            if (size > largest) {
                largest = size;
                main = video;
            }
        }
        _videoURL = [NSURL fileURLWithPath:main];
        _kind = TXWallpaperKindVideo;
    } else if (caBundles.count) {
        _kind = TXWallpaperKindCA;
    } else if (images.count) {
        _kind = TXWallpaperKindImage;
    } else {
        _kind = TXWallpaperKindUnknown;
        return NO;
    }

    if (images.count) {
        NSString *fallback = TXChooseFallbackImage(images);
        if (fallback) {
            _fallbackImageURL = [NSURL fileURLWithPath:fallback];
        }
    }

    // 展示名：优先 .wallpaper 目录名，其次 Wallpaper.plist 里的名字，最后文件名
    NSString *name = wallpaperDirs.firstObject.lastPathComponent;
    if (name.length) {
        _displayName = [name stringByDeletingPathExtension];
    } else {
        id plistName = _descriptor[@"name"] ?: _descriptor[@"displayName"];
        _displayName = [plistName isKindOfClass:NSString.class]
            ? plistName
            : [_path.lastPathComponent stringByDeletingPathExtension];
    }
    // 去掉分辨率尾巴，例如 7400.WWDC_2022-390w-844h@3x~iphone
    NSRange dash = [_displayName rangeOfString:@"-\\d+w-\\d+h" options:NSRegularExpressionSearch];
    if (dash.location != NSNotFound) {
        _displayName = [_displayName substringToIndex:dash.location];
    }

    id still = _descriptor[@"stillTime"] ?: _descriptor[@"still_time"];
    if ([still respondsToSelector:@selector(doubleValue)]) {
        _stillTime = [still doubleValue];
    }

    TXLog(@"解析成功: name=%@ kind=%@ video=%@ fallbackImage=%@ .ca=%lu zip=%@",
          _displayName, _kind,
          _videoURL.path ?: @"(无)",
          _fallbackImageURL.path ?: @"(无)",
          (unsigned long)_caBundlePaths.count,
          _unpackedFromZip ? @"是" : @"否");
    return YES;
}

@end
