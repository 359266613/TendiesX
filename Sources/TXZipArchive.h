//
//  TXZipArchive.h
//  极简 ZIP 读取器（只读），支持 stored(0) 与 deflate(8)，基于系统 zlib。
//  .tendies 是 Nugget 自定义的 zip 容器，系统不认，必须自己解包。
//

#import <Foundation/Foundation.h>

@interface TXZipEntry : NSObject
@property (nonatomic, copy)   NSString *path;
@property (nonatomic, assign) uint16_t method;                 // 0 = stored, 8 = deflate
@property (nonatomic, assign) unsigned long long compressedSize;
@property (nonatomic, assign) unsigned long long uncompressedSize;
@property (nonatomic, assign) unsigned long long localHeaderOffset;
@end

@interface TXZipArchive : NSObject

+ (instancetype)archiveWithContentsOfFile:(NSString *)filePath;

@property (nonatomic, copy, readonly) NSArray<TXZipEntry *> *entries;

/// 解出单个条目的内容，失败返回 nil
- (NSData *)dataForEntry:(TXZipEntry *)entry;

/// 全部解到目录（自动建子目录，拒绝 ../ 越界路径）
- (BOOL)extractToDirectory:(NSString *)directory error:(NSError **)error;

@end
