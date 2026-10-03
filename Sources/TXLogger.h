//
//  TXLogger.h
//  文件日志：默认写到 /var/mobile/Library/Logs/TendiesX.log
//  - SpringBoard 进程里 NSLog 走 Apple 统一日志，iOS 16+ 用 USB 抓经常抓不到，
//    所以统一走文件，用 Filza 直接看。
//  - 同时镜像一份到 NSLog（TXLOG_MIRROR_CONSOLE=1），方便 3uTools / idevicesyslog。
//

#import <Foundation/Foundation.h>

/// 实际解析到的日志文件路径（解析失败返回 nil）
FOUNDATION_EXPORT NSString *TXLogFilePath(void);

/// 写一行日志（自动加时间戳、自动滚存），线程安全
FOUNDATION_EXPORT void TXLog(NSString *format, ...) NS_FORMAT_FUNCTION(1, 2);

/// 截断日志文件（清空）
FOUNDATION_EXPORT void TXLogTruncate(void);

/// 带调用位置的日志
#define TXLogHere(fmt, ...) TXLog(@"[%s:%d] " fmt, __func__, __LINE__, ##__VA_ARGS__)
