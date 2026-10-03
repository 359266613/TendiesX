#import "TXTendiesPackage.h"
#import "TXLogger.h"

static NSString *const kTXVideoExtensions[] = { @"mp4", @"mov", @"m4v", nil };
static NSString *const kTXDescriptorNames[] = { @"descriptor.plist", @"configuration.plist", @"Info.plist", nil };

@interface TXTendiesPackage ()
@property (nonatomic, copy,   readwrite) NSString *path;
@property (nonatomic, copy,   readwrite) NSString *displayName;
@property (nonatomic, copy,   readwrite) NSURL *videoURL;
@property (nonatomic, copy,   readwrite) NSURL *thumbnailURL;
@property (nonatomic, copy,   readwrite) NSDictionary *descriptor;
@property (nonatomic, assign, readwrite) NSTimeInterval stillTime;
@property (nonatomic, assign, readwrite) BOOL looping;
@end

@implementation TXTendiesPackage

+ (BOOL)isTendiesURL:(NSURL *)url {
    return [[url.pathExtension lowercaseString] isEqualToString:@"tendies"];
}

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
        BOOL exists = [fm fileExistsAtPath:_path isDirectory:&isDir];
        if (!exists) {
            TXLog(@"路径不存在: %@", _path);
            return nil;
        }

        if (isDir) {
            if (![self tx_loadFromDirectory:_path]) {
                TXLog(@"目录解析失败（未在 contents/versions 下找到视频）: %@", _path);
                return nil;
            }
        } else {
            // TODO: .tendies 是 zip 容器。先解包到缓存目录再走目录分支：
            //   1) 引入 SSZipArchive / 或基于 libz 自带 minizip 实现解包
            //   2) 解到 NSTemporaryDirectory()/TendiesX/<hash>/
            //   3) 这里目前先返回 nil，等解包能力接上
            NSString *unpacked = [self tx_unpackContainer:_path];
            if (!unpacked || ![self tx_loadFromDirectory:unpacked]) {
                TXLog(@"容器解包失败: %@", _path);
                return nil;
            }
        }
    }
    return self;
}

#pragma mark - 内部

/// 解包入口（占位）。返回可用目录，失败返回 nil。
- (NSString *)tx_unpackContainer:(NSString *)containerPath {
    // TODO: 接入 zip 解包实现后返回解包目录
    TXLog(@"尚未接入 zip 解包，无法解析容器: %@", containerPath);
    return nil;
}

- (BOOL)tx_loadFromDirectory:(NSString *)directory {
    NSString *contents = [self tx_locateContentsDirectory:directory];
    NSFileManager *fm = NSFileManager.defaultManager;

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
    NSArray<NSString *> *files = [fm contentsOfDirectoryAtPath:scanRoot error:NULL];
    for (NSString *file in files) {
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

    TXLog(@"解析成功: name=%@ video=%@ 描述文件字段=%lu contents=%@",
          _displayName, _videoURL.path, (unsigned long)_descriptor.count,
          contents ?: @"(直接在根目录)");
    return YES;
}

/// PosterBoard 布局：versions/<n>/contents/
- (NSString *)tx_locateContentsDirectory:(NSString *)root {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *direct = [root stringByAppendingPathComponent:@"contents"];
    if ([fm fileExistsAtPath:direct]) {
        return direct;
    }

    NSString *versions = [root stringByAppendingPathComponent:@"versions"];
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:versions error:NULL];
    for (NSString *item in items) {
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
