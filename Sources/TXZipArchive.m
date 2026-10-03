#import "TXZipArchive.h"
#import "TXLogger.h"
#import <zlib.h>

static const uint32_t kTXZipSignatureEOCD  = 0x06054b50;
static const uint32_t kTXZipSignatureCDH   = 0x02014b50;
static const uint32_t kTXZipSignatureLocal = 0x04034b50;
static const uint32_t kTXZipZIP64Sentinel  = 0xFFFFFFFF;

static uint16_t TXZipReadU16(const uint8_t *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static uint32_t TXZipReadU32(const uint8_t *p) {
    return (uint32_t)(p[0] | (p[1] << 8) | (p[2] << 16) | ((uint32_t)p[3] << 24));
}

/// raw deflate 解压（ZIP 的 deflate 流不带 zlib 头，所以 windowBits 取负）
static NSData *TXZipInflateRaw(NSData *input, NSUInteger expectedSize) {
    if (!input.length) {
        return [NSData data];
    }
    z_stream stream;
    memset(&stream, 0, sizeof(stream));
    if (inflateInit2(&stream, -MAX_WBITS) != Z_OK) {
        return nil;
    }

    NSMutableData *output = [NSMutableData dataWithLength:MAX(expectedSize, (NSUInteger)65536)];
    stream.next_in  = (Bytef *)input.bytes;
    stream.avail_in = (uInt)input.length;
    stream.next_out  = (Bytef *)output.mutableBytes;
    stream.avail_out = (uInt)output.length;

    int status = inflate(&stream, Z_NO_FLUSH);
    while (status == Z_OK) {
        if (stream.avail_out == 0) {
            NSUInteger used = output.length;
            [output increaseLengthBy:65536];
            stream.next_out  = (Bytef *)output.mutableBytes + used;
            stream.avail_out = 65536;
        }
        status = inflate(&stream, Z_NO_FLUSH);
    }

    NSUInteger produced = (NSUInteger)stream.total_out;
    inflateEnd(&stream);

    if (status != Z_STREAM_END) {
        return nil;
    }
    [output setLength:produced];
    return output;
}

@implementation TXZipEntry
@end

@implementation TXZipArchive {
    NSData *_data;
    NSArray<TXZipEntry *> *_entries;
}

+ (instancetype)archiveWithContentsOfFile:(NSString *)filePath {
    NSData *data = [NSData dataWithContentsOfFile:filePath options:0 error:NULL];
    if (!data.length) {
        return nil;
    }
    return [[self alloc] initWithData:data];
}

- (instancetype)initWithData:(NSData *)data {
    self = [super init];
    if (self) {
        _data = data;
        _entries = [self tx_parseCentralDirectory];
        if (!_entries.count) {
            return nil;
        }
    }
    return self;
}

- (NSArray<TXZipEntry *> *)entries {
    return _entries;
}

#pragma mark - 解析

- (NSArray<TXZipEntry *> *)tx_parseCentralDirectory {
    const uint8_t *bytes = _data.bytes;
    NSUInteger length = _data.length;
    if (length < 22) {
        return nil;
    }

    // EOCD 在文件末尾，注释最长 65535，所以从尾部往前最多扫 22 + 65535 字节
    NSUInteger maxBack = MIN(length, (NSUInteger)22 + 65535);
    NSInteger eocd = -1;
    for (NSUInteger i = 0; i + 22 <= maxBack; i++) {
        NSUInteger pos = length - 22 - i;
        if (TXZipReadU32(bytes + pos) == kTXZipSignatureEOCD) {
            eocd = (NSInteger)pos;
            break;
        }
    }
    if (eocd < 0) {
        TXLog(@"zip: 找不到 EOCD，不是合法 zip");
        return nil;
    }

    uint16_t count = TXZipReadU16(bytes + eocd + 10);
    uint32_t centralOffset = TXZipReadU32(bytes + eocd + 16);
    if (!count || centralOffset >= length) {
        return nil;
    }

    NSMutableArray<TXZipEntry *> *result = [NSMutableArray arrayWithCapacity:count];
    NSUInteger cursor = centralOffset;

    for (uint16_t i = 0; i < count; i++) {
        if (cursor + 46 > length || TXZipReadU32(bytes + cursor) != kTXZipSignatureCDH) {
            break;
        }
        uint16_t method   = TXZipReadU16(bytes + cursor + 10);
        uint32_t csize    = TXZipReadU32(bytes + cursor + 20);
        uint32_t usize    = TXZipReadU32(bytes + cursor + 24);
        uint16_t nameLen  = TXZipReadU16(bytes + cursor + 28);
        uint16_t extraLen = TXZipReadU16(bytes + cursor + 30);
        uint16_t cmtLen   = TXZipReadU16(bytes + cursor + 32);
        uint32_t localOff = TXZipReadU32(bytes + cursor + 42);

        if (cursor + 46 + nameLen > length) {
            break;
        }

        if (csize == kTXZipZIP64Sentinel || usize == kTXZipZIP64Sentinel || localOff == kTXZipZIP64Sentinel) {
            TXLog(@"zip: 跳过 ZIP64 条目，暂不支持");
        } else {
            NSString *name = [[NSString alloc] initWithBytes:bytes + cursor + 46
                                                      length:nameLen
                                                    encoding:NSUTF8StringEncoding];
            if (!name.length) {
                name = [[NSString alloc] initWithBytes:bytes + cursor + 46
                                                length:nameLen
                                              encoding:NSISOLatin1StringEncoding];
            }
            if (name.length) {
                TXZipEntry *entry = [TXZipEntry new];
                entry.path = name;
                entry.method = method;
                entry.compressedSize = csize;
                entry.uncompressedSize = usize;
                entry.localHeaderOffset = localOff;
                [result addObject:entry];
            }
        }
        cursor += 46 + nameLen + extraLen + cmtLen;
    }

    TXLog(@"zip: 中央目录解析出 %lu 个条目", (unsigned long)result.count);
    return result;
}

#pragma mark - 读取 / 解包

- (NSData *)dataForEntry:(TXZipEntry *)entry {
    const uint8_t *bytes = _data.bytes;
    NSUInteger length = _data.length;
    NSUInteger offset = (NSUInteger)entry.localHeaderOffset;

    if (offset + 30 > length || TXZipReadU32(bytes + offset) != kTXZipSignatureLocal) {
        return nil;
    }
    uint16_t nameLen  = TXZipReadU16(bytes + offset + 26);
    uint16_t extraLen = TXZipReadU16(bytes + offset + 28);
    NSUInteger dataStart = offset + 30 + nameLen + extraLen;

    if (dataStart + entry.compressedSize > length) {
        return nil;
    }

    NSData *raw = [NSData dataWithBytes:(bytes + dataStart) length:(NSUInteger)entry.compressedSize];

    if (entry.method == 0) {
        return raw;
    }
    if (entry.method == 8) {
        NSData *inflated = TXZipInflateRaw(raw, (NSUInteger)entry.uncompressedSize);
        if (!inflated) {
            TXLog(@"zip: deflate 解压失败: %@", entry.path);
        }
        return inflated;
    }

    TXLog(@"zip: 不支持的压缩方式 %u: %@", entry.method, entry.path);
    return nil;
}

- (BOOL)extractToDirectory:(NSString *)directory error:(NSError **)error {
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:directory withIntermediateDirectories:YES attributes:nil error:error]) {
        return NO;
    }

    NSUInteger written = 0;
    for (TXZipEntry *entry in _entries) {
        if ([entry.path hasSuffix:@"/"]) {
            continue;   // 目录项，交给文件路径按需创建
        }
        NSString *relative = [TXZipArchive tx_sanitizedRelativePath:entry.path];
        if (!relative.length) {
            TXLog(@"zip: 跳过可疑路径 %@", entry.path);
            continue;
        }

        NSString *outputPath = [directory stringByAppendingPathComponent:relative];
        [fm createDirectoryAtPath:[outputPath stringByDeletingLastPathComponent]
      withIntermediateDirectories:YES
                       attributes:nil
                            error:NULL];

        NSData *data = [self dataForEntry:entry];
        if (!data) {
            continue;
        }
        if (![data writeToFile:outputPath options:NSDataWritingAtomic error:error]) {
            return NO;
        }
        written++;
    }

    TXLog(@"zip: 解出 %lu 个文件 -> %@", (unsigned long)written, directory);
    return written > 0;
}

/// 去掉前导 / 与 .，遇到 .. 直接判为非法
+ (NSString *)tx_sanitizedRelativePath:(NSString *)path {
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    for (NSString *part in [path componentsSeparatedByString:@"/"]) {
        if (!part.length || [part isEqualToString:@"."]) {
            continue;
        }
        if ([part isEqualToString:@".."]) {
            return nil;
        }
        [parts addObject:part];
    }
    return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

@end
