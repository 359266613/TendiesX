#import "TXPosterStoreProbe.h"
#import "TXLogger.h"

/// 单次探测输出的行数上限，避免把日志刷爆
static const NSUInteger kTXProbeLineBudget = 220;

/// 猜测的固定路径（iOS 16.5 实测都不存在，留着以后版本验证）
static NSString *const kTXProbeFixedPaths[] = {
    @"/var/mobile/Library/PosterBoard",
    @"/var/mobile/Library/PosterKit",
    @"/var/mobile/Library/Caches/com.apple.PosterBoard",
    nil
};

#pragma mark - 通用工具

static BOOL TXProbeIsDir(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
}

static void TXProbeLog(NSString *indent, NSString *path, BOOL isDir) {
    TXLog(@"  %@%@%@", indent, path, isDir ? @"/" : @"");
}

/// 递归打印目录树（限深度、限行数）
static void TXProbeDump(NSString *path, NSUInteger depth, NSUInteger maxDepth, NSUInteger *budget) {
    if (*budget == 0) {
        return;
    }
    TXProbeLog([@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0],
               path.lastPathComponent, TXProbeIsDir(path));
    (*budget)--;

    if (!TXProbeIsDir(path) || depth >= maxDepth) {
        return;
    }
    for (NSString *item in [NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]) {
        if (*budget == 0) {
            return;
        }
        TXProbeDump([path stringByAppendingPathComponent:item], depth + 1, maxDepth, budget);
    }
}

/// 只列出名字里含 keyword 的条目（避免把整个目录刷出来）
static void TXProbeFilteredListing(NSString *parent, NSString *keyword, NSUInteger *budget) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:parent error:NULL];
    if (!items) {
        return;
    }
    BOOL matched = NO;
    for (NSString *item in items) {
        if (![item.lowercaseString containsString:keyword]) {
            continue;
        }
        matched = YES;
        NSString *full = [parent stringByAppendingPathComponent:item];
        TXProbeLog(@"    ", full, TXProbeIsDir(full));
        if (*budget == 0) {
            return;
        }
        (*budget)--;
    }
    if (!matched) {
        TXLog(@"    (%@ 下没有含 \"%@\" 的条目)", parent, keyword);
    }
}

/// 参考 PosterForge 的实现，海报描述符存在：
///   <PosterBoard 容器>/Library/Application Support/PRBPosterExtensionDataStore/<结构版本>/
///       Extensions/<扩展ID>/descriptors/<UUID>/
/// <结构版本> 与 <扩展ID> 随系统版本变化，所以这里定向把这几层打出来，
/// 拿到真机上的真实值后才能正确安装 .tendies 里的 descriptors/<UUID>。
/// 属主与权限：决定我们能否从 SpringBoard(mobile) 直接写进 PosterBoard 容器
static NSString *TXProbeAttributes(NSString *path) {
    NSDictionary<NSFileAttributeKey, id> *attrs =
        [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
    if (!attrs) {
        return @"(读不到属性)";
    }
    return [NSString stringWithFormat:@"owner=%@ mode=0%o",
            attrs[NSFileOwnerAccountName] ?: @"?",
            [attrs[NSFilePosixPermissions] unsignedIntValue] & 07777];
}

static void TXProbePosterBoardStore(NSString *container, NSUInteger *budget) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *support = [container stringByAppendingPathComponent:@"Library/Application Support"];
    TXLog(@"    Application Support 下的条目：");

    for (NSString *item in [fm contentsOfDirectoryAtPath:support error:NULL]) {
        if (*budget == 0) {
            return;
        }
        if (![item.lowercaseString containsString:@"store"]) {
            continue;   // 只关心 PRBPosterExtensionDataStore 这类
        }
        NSString *store = [support stringByAppendingPathComponent:item];
        TXLog(@"      [存储] %@  %@", store, TXProbeAttributes(store));
        (*budget)--;

        // 下一层通常是结构版本号（PosterForge 在 iOS 16 上写死 59）
        for (NSString *version in [fm contentsOfDirectoryAtPath:store error:NULL]) {
            if (*budget == 0) {
                return;
            }
            NSString *versionPath = [store stringByAppendingPathComponent:version];
            if (TXProbeIsDir(versionPath) == NO) {
                continue;
            }
            TXLog(@"        结构版本: %@  %@", version, TXProbeAttributes(versionPath));
            (*budget)--;

            NSString *extensions = [versionPath stringByAppendingPathComponent:@"Extensions"];
            for (NSString *ext in [fm contentsOfDirectoryAtPath:extensions error:NULL]) {
                if (*budget == 0) {
                    return;
                }
                NSString *extensionsEntry = [extensions stringByAppendingPathComponent:ext];
                NSString *descriptors = [extensionsEntry stringByAppendingPathComponent:@"descriptors"];
                NSArray<NSString *> *items = [fm contentsOfDirectoryAtPath:descriptors error:NULL];
                TXLog(@"          扩展 %@ -> descriptors 条目数 %lu  %@",
                      ext, (unsigned long)items.count, TXProbeAttributes(descriptors));
                for (NSString *one in items) {
                    TXLog(@"            已有: %@", one);
                }
                (*budget)--;
            }
        }
    }
}

/// 扫描应用数据容器，按容器标识找出 PosterBoard 容器
static void TXProbeAppContainers(NSUInteger *budget) {
    static NSString *const kContainerRoots[] = {
        @"/var/mobile/Containers/Data/Application",
        @"/var/mobile/Containers/Data/System",
        @"/var/containers/Data/System",
        nil
    };
    NSFileManager *fm = NSFileManager.defaultManager;

    for (int r = 0; kContainerRoots[r] != nil; r++) {
        NSString *root = kContainerRoots[r];
        if (!TXProbeIsDir(root)) {
            TXLog(@"    [不存在] %@", root);
            continue;
        }
        TXLog(@"    扫描容器 %@", root);
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:root error:NULL]) {
            if (*budget == 0) {
                return;
            }
            NSString *container = [root stringByAppendingPathComponent:uuid];
            NSString *metadata = [container stringByAppendingPathComponent:
                                  @".com.apple.mobile_container_manager.metadata.plist"];
            NSDictionary *dict = [NSDictionary dictionaryWithContentsOfFile:metadata];
            NSString *identifier = dict[@"MCMMetadataIdentifier"];
            if (![identifier isKindOfClass:NSString.class]
                || ![identifier.lowercaseString containsString:@"poster"]) {
                continue;
            }
            TXLog(@"    [命中] %@ -> %@", identifier, container);
            (*budget)--;
            TXProbePosterBoardStore(container, budget);
        }
    }
}

#pragma mark - 入口

void TXProbePosterStore(void) {
    TXLog(@"---- PosterBoard 存储探测开始（用于确定 .tendies 安装落点）----");
    NSUInteger budget = kTXProbeLineBudget;

    // 1) 先看猜测的固定路径
    for (int i = 0; kTXProbeFixedPaths[i] != nil; i++) {
        NSString *path = kTXProbeFixedPaths[i];
        if (TXProbeIsDir(path)) {
            TXLog(@"  [存在] %@", path);
            TXProbeDump(path, 1, 3, &budget);
        } else {
            TXLog(@"  [不存在] %@", path);
        }
    }

    // 2) 广域搜索：/var/mobile/Library 与系统组容器里名字含 poster 的条目
    TXLog(@"  -- 按名字搜索（含 poster）--");
    if (TXProbeIsDir(@"/var/mobile/Library")) {
        TXProbeFilteredListing(@"/var/mobile/Library", @"poster", &budget);
    }
    if (TXProbeIsDir(@"/var/containers/Shared/SystemGroup")) {
        TXLog(@"    /var/containers/Shared/SystemGroup:");
        TXProbeFilteredListing(@"/var/containers/Shared/SystemGroup", @"poster", &budget);
    }

    // 3) 扫容器元数据，找 PosterBoard 的沙盒
    TXLog(@"  -- 扫描应用容器 --");
    TXProbeAppContainers(&budget);

    TXLog(@"---- PosterBoard 存储探测结束（剩余额度 %lu）----", (unsigned long)budget);

    // 顺手把「现成一个 descriptor 的完整结构」打出来，作为 route A 的复刻模板
    TXProbeDescriptorTemplate();
}

#pragma mark - descriptor 结构探测（route A 的复刻模板）

/// 定位 <PosterBoard 容器>/Library/Application Support/PRBPosterExtensionDataStore
static NSString *TXProbeFindPosterStore(void) {
    NSFileManager *fm = NSFileManager.defaultManager;
    static NSString *const kRoots[] = {
        @"/var/mobile/Containers/Data/Application",
        @"/var/containers/Data/System",
        nil
    };
    for (int r = 0; kRoots[r] != nil; r++) {
        for (NSString *uuid in [fm contentsOfDirectoryAtPath:kRoots[r] error:NULL]) {
            NSString *container = [kRoots[r] stringByAppendingPathComponent:uuid];
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

/// 递归打印目录树：带文件大小，每个目录最多列 15 项，避免 assets 刷屏
static void TXProbeDumpTree(NSString *path, NSUInteger depth, NSUInteger maxDepth, NSUInteger *budget) {
    if (*budget == 0) {
        return;
    }
    NSString *indent = [@"" stringByPaddingToLength:depth * 2 + 4 withString:@" " startingAtIndex:0];
    BOOL isDir = TXProbeIsDir(path);
    if (isDir) {
        TXLog(@"%@%@/", indent, path.lastPathComponent);
    } else {
        NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:NULL];
        TXLog(@"%@%@ (%llu B)", indent, path.lastPathComponent,
              [attrs[NSFileSize] unsignedLongLongValue]);
    }
    (*budget)--;

    if (!isDir || depth >= maxDepth || *budget == 0) {
        return;
    }
    NSArray<NSString *> *items =
        [[NSFileManager.defaultManager contentsOfDirectoryAtPath:path error:NULL]
         sortedArrayUsingSelector:@selector(compare:)];
    NSUInteger shown = 0;
    for (NSString *item in items) {
        if (shown >= 15) {
            TXLog(@"%@  …(还有 %lu 项)", indent, (unsigned long)(items.count - shown));
            (*budget)--;
            break;
        }
        TXProbeDumpTree([path stringByAppendingPathComponent:item], depth + 1, maxDepth, budget);
        shown++;
        if (*budget == 0) {
            return;
        }
    }
}

void TXProbeDescriptorTemplate(void) {
    TXLog(@"---- descriptor 结构探测开始（route A 复刻模板）----");

    NSString *store = TXProbeFindPosterStore();
    if (!store) {
        TXLog(@"  未找到 PRBPosterExtensionDataStore");
        return;
    }

    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger budget = 400;

    for (NSString *version in [fm contentsOfDirectoryAtPath:store error:NULL]) {
        NSString *versionPath = [store stringByAppendingPathComponent:version];
        if (!TXProbeIsDir(versionPath)) {
            continue;
        }
        NSString *extDir = [versionPath stringByAppendingPathComponent:
                            @"Extensions/com.apple.WallpaperKit.CollectionsPoster"];
        if (!TXProbeIsDir(extDir)) {
            TXLog(@"  [无] 结构版本 %@ 下没有 CollectionsPoster", version);
            continue;
        }

        TXLog(@"  [模板] 结构版本 %@ / CollectionsPoster", version);
        TXLog(@"    扩展目录自身条目（找 descriptor 索引/清单文件）:");
        for (NSString *item in [fm contentsOfDirectoryAtPath:extDir error:NULL]) {
            NSString *full = [extDir stringByAppendingPathComponent:item];
            TXLog(@"      %@%@  %@", item, TXProbeIsDir(full) ? @"/" : @"", TXProbeAttributes(full));
            if (--budget == 0) {
                return;
            }
        }

        NSString *descriptors = [extDir stringByAppendingPathComponent:@"descriptors"];
        NSArray<NSString *> *uuids = [fm contentsOfDirectoryAtPath:descriptors error:NULL];
        TXLog(@"    descriptors 共 %lu 个，取第一个当模板:", (unsigned long)uuids.count);
        NSString *sample = uuids.firstObject;
        if (sample) {
            TXLog(@"    样本 UUID: %@", sample);
            TXProbeDumpTree([descriptors stringByAppendingPathComponent:sample], 0, 7, &budget);
        }

        TXLog(@"---- descriptor 结构探测结束（剩余额度 %lu）----", (unsigned long)budget);
        return;
    }

    TXLog(@"---- descriptor 结构探测结束：没有可用的 CollectionsPoster 模板 ----");
}
