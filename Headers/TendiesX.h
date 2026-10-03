//
//  TendiesX.h
//  统一入口头：公开框架 + 手写私有 API。
//  注意：Reference/ 下的 ipsw dump 头只作查方法用，禁止 import（会编译失败）。
//

#ifndef TendiesX_h
#define TendiesX_h

/* ---------- 公开框架（SDK 自带） ---------- */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import "TendiesXPublicFrameworks.h"   // Metal / MetalKit / CoreImage / ImageIO

/* ---------- 私有 API（手写最小声明） ---------- */
#import "TXWallpaper.h"

#endif /* TendiesX_h */
