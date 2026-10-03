#import "TXPosterStoreProbe.h"
#import "TXLogger.h"

static NSString *const kTXProbeRoots[] = {
    @"/var/mobile/Library/PosterBoard",
    @"/var/mobile/Library/PosterKit",
    @"/var/mobile/Library/SpringBoard",
    @"/var/mobile/Library/Caches/com.apple.PosterBoard",
    nil
};

/// 单次探测输出的行数上限，避免把日志刷爆
static const NSUInteger kTXProbeLineBudget = 100;
static const NSUInteger kTXProbeMaxDepth = 3;

static void TXProbeDump(NSString *path, NSUInteger depth, NSUInteger *budget) {
    if (*budget == 0) {
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    BOOL isDir = NO;
    if (![fm fileExistsAtPath:path isDirectory:&isDir]) {
        return;
    }

    NSString *indent = [@"" stringByPaddingToLength:depth * 2 withString:@" " startingAtIndex:0];
    TXLog(@"  %@%@%@", indent, path.lastPathComponent, isDir ? @"/" : @"");
    (*budget)--;

    if (!isDir || depth >= kTXProbeMaxDepth) {
        return;
    }
    for (NSString *item in [fm contentsOfDirectoryAtPath:path error:NULL]) {
        if (*budget == 0) {
            TXLog(@"  %@...(已达行数上限)", indent);
            return;
        }
        TXProbeDump([path stringByAppendingPathComponent:item], depth + 1, budget);
    }
}

void TXProbePosterStore(void) {
    TXLog(@"---- PosterBoard 存储探测开始（用于确定 .tendies 安装落点）----");
    NSUInteger budget = kTXProbeLineBudget;
    NSFileManager *fm = NSFileManager.defaultManager;

    for (int i = 0; kTXProbeRoots[i] != nil; i++) {
        NSString *root = kTXProbeRoots[i];
        if (budget == 0) {
            TXLog(@"  ...(后续路径已跳过)");
            break;
        }
        if (![fm fileExistsAtPath:root]) {
            TXLog(@"  [不存在] %@", root);
            continue;
        }
        TXLog(@"  [存在] %@", root);
        TXProbeDump(root, 1, &budget);
    }

    TXLog(@"---- PosterBoard 存储探测结束 ----");
}
