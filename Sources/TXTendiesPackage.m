#import "TXTendiesPackage.h"
#import "TXLogger.h"
#import "TXZipArchive.h"

static NSString *const kTXVideoExtensions[] = { @"mp4", @"mov", @"m4v", nil };
static NSString *const kTXDescriptorNames[] = { @"descriptor.plist", @"configuration.plist", @"Info.plist", nil };

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

@interface TXTendiesPackage ()
@property (nonatomic, copy,   readwrite) NSString *path;
@property (nonatomic, copy,   readwrite) NSString *displayName;
@property (nonatomic, copy,   readwrite) NSURL *videoURL;
@property (nonatomic, copy,   readwrite) NSURL *thumbnailURL;
@property (nonatomic, copy,   readwrite) NSDictionary *descriptor;
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
            // 目录形态：目录名以 .tendies 结尾，或内含 versions/contents
            BOOL isTendiesDir = isDir && ([item hasSuffix:@".tendies"] || [fm fileExistsAtPath:[full stringByAppendingPathComponent:@"versions"]]);
            if (isTendiesZip || isTendiesDir) {
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
        _looping = YES;
        _stillTime = 0.0;
        _descriptor = @{};

        NSFileManager *fm = NSFileManager.defaultManager;
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:_path isDirectory:&isDir]) {
            TXLog(@"路径不存在: %@", _path);
            return nil;
        }

        NSString *loadRoot = _path;
        if (!isDir) {
            NSString *unpacked = [self tx_unpackContainer:_path];
            if (!unpacked) {
                return nil;
            }
            loadRoot = unpacked;
            _unpackedFromZip = YES;
        }

        if (![self tx_loadFromDirectory:loadRoot]) {
            TXLog(@"解析失败（未在 contents/versions 下找到视频）: %@", loadRoot);
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

#pragma mark - 目录解析

- (BOOL)tx_loadFromDirectory:(NSString *)directory {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *contents = [self tx_locateContentsDirectory:directory];

    if (contents) {
        for (NSString *name in [self tx_descriptorNames]) {
            NSString *candidate = [contents stringByAppendingPathComponent:name];
            NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:candidate];
            if ([plist isKindOfClass:NSDictionary.class]) {
                _descriptor = plist;
                break;
            }
        }
    }

    NSString *scanRoot = contents ?: directory;
    for (NSString *file in [fm contentsOfDirectoryAtPath:scanRoot error:NULL]) {
        NSString *ext = [file.pathExtension lowercaseString];
        NSString *full = [scanRoot stringByAppendingPathComponent:file];

        if (!_videoURL && [self tx_isVideoExtension:ext]) {
            _videoURL = [NSURL fileURLWithPath:full];
        } else if (!_thumbnailURL && ([ext isEqualToString:@"png"]
                                   || [ext isEqualToString:@"jpg"]
                                   || [ext isEqualToString:@"jpeg"])) {
            _thumbnailURL = [NSURL fileURLWithPath:full];
        }
    }

    if (!_videoURL) {
        // contents 里没有再往下找一层，兼容部分打包方式
        if (contents) {
            for (NSString *sub in [fm contentsOfDirectoryAtPath:contents error:NULL]) {
                NSString *subDir = [contents stringByAppendingPathComponent:sub];
                BOOL isDir = NO;
                if (![fm fileExistsAtPath:subDir isDirectory:&isDir] || !isDir) {
                    continue;
                }
                for (NSString *file in [fm contentsOfDirectoryAtPath:subDir error:NULL]) {
                    if ([self tx_isVideoExtension:[file.pathExtension lowercaseString]]) {
                        _videoURL = [NSURL fileURLWithPath:[subDir stringByAppendingPathComponent:file]];
                        break;
                    }
                }
                if (_videoURL) {
                    break;
                }
            }
        }
    }

    if (!_videoURL) {
        return NO;
    }

    id still = _descriptor[@"stillTime"] ?: _descriptor[@"still_time"];
    if ([still respondsToSelector:@selector(doubleValue)]) {
        _stillTime = [still doubleValue];
    }

    id name = _descriptor[@"name"] ?: _descriptor[@"displayName"];
    _displayName = [name isKindOfClass:NSString.class]
        ? name
        : [_path.lastPathComponent stringByDeletingPathExtension];

    TXLog(@"解析成功: name=%@ video=%@ 描述字段=%lu contents=%@ zip=%@",
          _displayName, _videoURL.path, (unsigned long)_descriptor.count,
          contents ?: @"(根目录)", _unpackedFromZip ? @"是" : @"否");
    return YES;
}

/// PosterBoard 布局：contents/ 或 versions/<n>/contents/
- (NSString *)tx_locateContentsDirectory:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;

    NSString *direct = [root stringByAppendingPathComponent:@"contents"];
    if ([fm fileExistsAtPath:direct]) {
        return direct;
    }

    NSString *versions = [root stringByAppendingPathComponent:@"versions"];
    for (NSString *item in [fm contentsOfDirectoryAtPath:versions error:NULL]) {
        NSString *candidate = [[versions stringByAppendingPathComponent:item]
                               stringByAppendingPathComponent:@"contents"];
        if ([fm fileExistsAtPath:candidate]) {
            return candidate;
        }
    }
    return nil;
}

- (NSArray<NSString *> *)tx_descriptorNames {
    NSMutableArray<NSString *> *names = [NSMutableArray array];
    for (int i = 0; kTXDescriptorNames[i] != nil; i++) {
        [names addObject:kTXDescriptorNames[i]];
    }
    return names;
}

- (BOOL)tx_isVideoExtension:(NSString *)ext {
    for (int i = 0; kTXVideoExtensions[i] != nil; i++) {
        if ([ext isEqualToString:kTXVideoExtensions[i]]) {
            return YES;
        }
    }
    return NO;
}

@end
