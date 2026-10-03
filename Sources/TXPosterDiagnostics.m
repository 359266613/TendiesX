#import "TXPosterDiagnostics.h"
#import "TXPosterInstaller.h"
#import "TXLogger.h"

static NSString *const kTXDescriptorIdentifierFile =
    @"com.apple.posterkit.provider.descriptor.identifier";

static BOOL TXIsDir(NSString *path) {
    BOOL isDir = NO;
    [NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&isDir];
    return isDir;
}

/// 读 descriptor identifier（纯文本，如 "7400"）
static NSString *TXIdentifierOf(NSString *descriptorDir) {
    NSString *file = [descriptorDir stringByAppendingPathComponent:kTXDescriptorIdentifierFile];
    NSString *text = [NSString stringWithContentsOfFile:file encoding:NSUTF8StringEncoding error:NULL];
    if (!text.length) {
        text = [NSString stringWithContentsOfFile:file encoding:NSISOLatin1StringEncoding error:NULL];
    }
    return [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
}

/// 目录下所有文件的相对路径集合（只收文件，收目录名能看出结构）
static NSSet<NSString *> *TXEntrySetOf(NSString *root) {
    NSMutableSet<NSString *> *set = [NSMutableSet set];
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *relative in [fm enumeratorAtPath:root]) {
        BOOL isDir = NO;
        if (![fm fileExistsAtPath:[root stringByAppendingPathComponent:relative] isDirectory:&isDir]) {
            continue;
        }
        [set addObject:isDir ? [relative stringByAppendingString:@"/"] : relative];
        if (set.count > 4000) {
            break;   // 防御：异常大的目录不要刷爆日志
        }
    }
    return set;
}

/// 把集合压成可读的多行文本（带数量、限条数）
static NSString *TXDescribeSet(NSSet<NSString *> *set, NSString *title, NSUInteger maxLines) {
    NSArray<NSString *> *sorted = [set.allObjects sortedArrayUsingSelector:@selector(compare:)];
    if (!sorted.count) {
        return [NSString stringWithFormat:@"  %@: (空)", title];
    }
    NSArray<NSString *> *shown = sorted.count > maxLines
        ? [sorted subarrayWithRange:NSMakeRange(0, maxLines)] : sorted;
    NSString *body = [shown componentsJoinedByString:@"\n    "];
    if (sorted.count > maxLines) {
        body = [body stringByAppendingFormat:@"\n    …(还有 %lu 项)",
                (unsigned long)(sorted.count - maxLines)];
    }
    return [NSString stringWithFormat:@"  %@ (%lu 项):\n    %@",
            title, (unsigned long)sorted.count, body];
}

/// 把 descriptor 里的 Wallpaper.plist 读成字典打出来（binary/xml 都能读）
static void TXLogPlistIn(NSString *descriptorDir, NSString *label) {
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *found = nil;
    for (NSString *relative in [fm enumeratorAtPath:descriptorDir]) {
        if ([relative.lastPathComponent isEqualToString:@"Wallpaper.plist"]
            || [relative.lastPathComponent isEqualToString:@"providerInfo.plist"]) {
            found = [descriptorDir stringByAppendingPathComponent:relative];
            break;
        }
    }
    if (!found) {
        TXLog(@"[对比] %@: 没有 Wallpaper.plist / providerInfo.plist", label);
        return;
    }
    id plist = [NSDictionary dictionaryWithContentsOfFile:found];
    NSString *text = plist ? [plist description] : @"(读取失败)";
    if (text.length > 900) {
        text = [[text substringToIndex:900] stringByAppendingString:@" …"];
    }
    TXLog(@"[对比] %@ 的 %@:\n%@", label, found.lastPathComponent, text);
}

@implementation TXPosterDiagnostics

+ (void)compareDescriptorAt:(NSString *)installedPath extension:(NSString *)extensionIdentifier {
    if (!installedPath.length || !extensionIdentifier.length) {
        return;
    }
    NSString *descriptorsRoot = [[TXPosterInstaller storeVersionDir]
        stringByAppendingPathComponent:[NSString stringWithFormat:@"Extensions/%@/descriptors",
                                        extensionIdentifier]];
    if (!TXIsDir(descriptorsRoot)) {
        TXLog(@"[对比] 找不到 descriptors 目录: %@", descriptorsRoot);
        return;
    }

    NSString *ourIdentifier = TXIdentifierOf(installedPath);
    TXLog(@"[对比] 开始：我们装的 identifier=%@ 目录=%@",
          ourIdentifier.length ? ourIdentifier : @"(读不到)", installedPath.lastPathComponent);

    NSSet<NSString *> *ourSet = TXEntrySetOf(installedPath);
    TXLog(@"[对比] 我们这份：\n%@", TXDescribeSet(ourSet, @"文件/目录", 60));
    TXLogPlistIn(installedPath, @"我们这份");

    // 找同 identifier 的其它副本（通常是系统自带那份，最能说明差异）
    NSFileManager *fm = NSFileManager.defaultManager;
    NSUInteger compared = 0;
    for (NSString *entry in [[fm contentsOfDirectoryAtPath:descriptorsRoot error:NULL]
                             sortedArrayUsingSelector:@selector(compare:)]) {
        NSString *dir = [descriptorsRoot stringByAppendingPathComponent:entry];
        if (!TXIsDir(dir) || [dir isEqualToString:installedPath]) {
            continue;
        }
        NSString *identifier = TXIdentifierOf(dir);
        if (!identifier.length || ![identifier isEqualToString:ourIdentifier]) {
            continue;
        }

        compared++;
        TXLog(@"[对比] 参照 %@（identifier=%@）：\n%@",
              entry, identifier, TXDescribeSet(TXEntrySetOf(dir), @"文件/目录", 60));

        NSSet<NSString *> *otherSet = TXEntrySetOf(dir);
        NSMutableSet<NSString *> *onlyOurs = [ourSet mutableCopy];
        [onlyOurs minusSet:otherSet];
        NSMutableSet<NSString *> *onlyTheirs = [otherSet mutableCopy];
        [onlyTheirs minusSet:ourSet];

        TXLog(@"[对比] 差异 ↓\n%@\n%@",
              TXDescribeSet(onlyOurs, @"只在【我们】这边有", 25),
              TXDescribeSet(onlyTheirs, @"只在【系统】那边有", 25));
        TXLogPlistIn(dir, @"系统那份");

        if (compared >= 2) {
            break;   // 最多比两份，避免日志爆掉
        }
    }
    if (!compared) {
        TXLog(@"[对比] 没有找到同 identifier 的其它副本可比（系统里没有同款）");
    }
}

+ (void)schedulePostMigrationDump:(NSString *)installedPath delay:(NSTimeInterval)delay {
    if (!installedPath.length) {
        return;
    }
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                   dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        if (!TXIsDir(installedPath)) {
            TXLog(@"[对比] 迁移后检查：目录已不存在 %@", installedPath.lastPathComponent);
            return;
        }
        NSArray<NSString *> *versions =
            [[fm contentsOfDirectoryAtPath:[installedPath stringByAppendingPathComponent:@"versions"]
                                     error:NULL] sortedArrayUsingSelector:@selector(compare:)];
        TXLog(@"[对比] 迁移后（+%.0fs）我们的副本：versions=[%@]",
              delay, versions.count ? [versions componentsJoinedByString:@","] : @"(无)");
        TXLog(@"[对比] 迁移后：\n%@", TXDescribeSet(TXEntrySetOf(installedPath), @"文件/目录", 60));
    });
}

@end
