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

/// 扫描应用数据容器，按容器标识找出 PosterBoard / PosterKit 相关容器
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
            // 调整：之前写成 depth=3 / maxDepth=2，条件 depth>=maxDepth 直接返回，
            // 结果只打了一行 "Library/"。改成从 depth=1 起、最多recursion 3 层。
            TXProbeDump([container stringByAppendingPathComponent:@"Library"], 1, 3, budget);
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
}
