#import "TXLogger.h"

/// 1 = 同时用 NSLog 输出一份到系统日志（3uTools / idevicesyslog / Console.app 可见）
#ifndef TXLOG_MIRROR_CONSOLE
#define TXLOG_MIRROR_CONSOLE 1
#endif

/// 超过该大小就滚存为 .log.1
static const unsigned long long kTXLogMaxBytes = 1024 * 1024;   // 1 MB

static NSString *const kTXLogFileName = @"TendiesX.log";

#pragma mark - 队列 / 路径

static dispatch_queue_t TXLogQueue(void) {
    static dispatch_queue_t queue;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        queue = dispatch_queue_create("com.axs.tendiesx.log", DISPATCH_QUEUE_SERIAL);
    });
    return queue;
}

static NSDateFormatter *TXLogDateFormatter(void) {
    // 只在 TXLogQueue 上访问，串行队列保证线程安全
    static NSDateFormatter *formatter;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        formatter = [[NSDateFormatter alloc] init];
        formatter.dateFormat = @"MM-dd HH:mm:ss.SSS";
        formatter.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    return formatter;
}

/// 按优先级找一个可写目录：真实 /var/mobile（rootful 与非 rootless 通用）
/// → rootless 的 /var/jb 镜像 → 沙盒 Documents → 临时目录
static NSArray<NSString *> *TXLogCandidateDirectories(void) {
    NSMutableArray<NSString *> *dirs = [NSMutableArray array];
    [dirs addObject:@"/var/mobile/Library/Logs"];
    [dirs addObject:@"/var/jb/var/mobile/Library/Logs"];
    NSString *docs = [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject];
    if (docs.length) {
        [dirs addObject:docs];
    }
    NSString *tmp = NSTemporaryDirectory();
    if (tmp.length) {
        [dirs addObject:tmp];
    }
    return dirs;
}

static NSString *TXResolveLogPath(void) {
    static NSString *path = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSFileManager *fm = NSFileManager.defaultManager;
        for (NSString *dir in TXLogCandidateDirectories()) {
            NSError *error = nil;
            if (![fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:&error]) {
                continue;
            }
            NSString *candidate = [dir stringByAppendingPathComponent:kTXLogFileName];
            if ([fm fileExistsAtPath:candidate]) {
                path = candidate;
                break;
            }
            if ([fm createFileAtPath:candidate contents:nil attributes:nil]) {
                path = candidate;
                break;
            }
        }
    });
    return path;
}

NSString *TXLogFilePath(void) {
    return TXResolveLogPath();
}

#pragma mark - 写入

/// 只在 TXLogQueue 上调用
static void TXLogRotateIfNeeded(void) {
    NSString *path = TXResolveLogPath();
    if (!path) {
        return;
    }
    NSFileManager *fm = NSFileManager.defaultManager;
    NSDictionary<NSFileAttributeKey, id> *attrs = [fm attributesOfItemAtPath:path error:NULL];
    if ([attrs fileSize] <= kTXLogMaxBytes) {
        return;
    }
    NSString *archive = [path stringByAppendingString:@".1"];
    [fm removeItemAtPath:archive error:NULL];
    [fm moveItemAtPath:path toPath:archive error:NULL];
}

/// 只在 TXLogQueue 上调用
static void TXLogWrite(NSString *message) {
    NSString *path = TXResolveLogPath();
    if (!path) {
        return;
    }
    TXLogRotateIfNeeded();

    NSString *line = [NSString stringWithFormat:@"%@ %@\n",
                      [TXLogDateFormatter() stringFromDate:[NSDate date]],
                      message];
    NSData *data = [line dataUsingEncoding:NSUTF8StringEncoding];
    if (!data.length) {
        return;
    }

    NSFileHandle *handle = [NSFileHandle fileHandleForWritingAtPath:path];
    if (!handle) {
        return;
    }
    @try {
        [handle seekToEndOfFile];
        [handle writeData:data];
    } @catch (NSException *exception) {
        // 磁盘满 / 句柄失效：丢掉这一行，绝不因为日志把 SpringBoard 拖崩
    } @finally {
        [handle closeFile];
    }
}

#pragma mark - 对外接口

void TXLog(NSString *format, ...) {
    if (!format.length) {
        return;
    }
    va_list args;
    va_start(args, format);
    NSString *message = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);

#if TXLOG_MIRROR_CONSOLE
    NSLog(@"[TendiesX] %@", message);
#endif

    dispatch_async(TXLogQueue(), ^{
        TXLogWrite(message);
    });
}

void TXLogTruncate(void) {
    dispatch_async(TXLogQueue(), ^{
        NSString *path = TXResolveLogPath();
        if (!path) {
            return;
        }
        [NSFileManager.defaultManager removeItemAtPath:path error:NULL];
        [NSFileManager.defaultManager createFileAtPath:path contents:nil attributes:nil];
    });
}
