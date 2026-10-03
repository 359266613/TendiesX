//
//  TXPrivateTypes.h
//  ipsw dump 里有两个私有结构体是用「匿名 struct」写在方法签名里的，例如：
//      - (struct { long long x0; long long x1; double x2; })currentHomescreenStyleTransitionState;
//  这种写法在参数位置会触发 clang 错误：
//      error: 'X' cannot be defined in a parameter type
//  这里补上具名 typedef，各私有头统一引用本文件。
//
//  布局与系统二进制完全一致（纯 C 值类型，无对齐差异），仅补名字，不改 ABI。
//

#ifndef TXPrivateTypes_h
#define TXPrivateTypes_h

/// PBUI/SBF 壁纸样式过渡状态（long long variant, long long style, double scale）
typedef struct {
    long long x0;
    long long x1;
    double    x2;
} PBUIWallpaperStyleTransitionState;

/// PBUIWallpaperView backdrop/material 生成参数
typedef struct {
    long long x0;
    long long x1;
    long long x2;
    double    x3;
    double    x4;
    double    x5;
    double    x6;
    long long x7;
} PBUIWallpaperBackdropParameters;

#endif /* TXPrivateTypes_h */
