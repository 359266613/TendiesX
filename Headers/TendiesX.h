//
//  TendiesX.h
//  统一入口头：公开框架 + 私有头（按依赖顺序）
//

#ifndef TendiesX_h
#define TendiesX_h

/* ---------- 公开框架（SDK 自带，无需 dump） ---------- */
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <CoreVideo/CoreVideo.h>
#import <CoreMotion/CoreMotion.h>
#import <AVFoundation/AVFoundation.h>
#import "TendiesXPublicFrameworks.h"   // Metal / MetalKit / CoreImage / ImageIO

/* ---------- 私有头（顺序不可调换） ---------- */
#import "Private/PBUIWallpaperOptions.h"
#import "Private/PBUIWallpaperConfiguration.h"
#import "Private/PBUIWallpaperView.h"
#import "Private/PBUIStaticWallpaperView.h"
#import "Private/PBUIWallpaperConfigurationManager.h"
#import "Private/PBUIWallpaperViewController.h"
#import "Private/SBFWallpaperView.h"
#import "Private/SBFStaticWallpaperView.h"
#import "Private/SBWallpaperController.h"
#import "Private/SBHomeScreenViewController.h"
#import "Private/SBLockScreenViewControllerBase.h"
#import "Private/SBLockStateAggregator.h"
#import "Private/CAFilter.h"
#import "Private/CABackdropLayer.h"

#endif /* TendiesX_h */
