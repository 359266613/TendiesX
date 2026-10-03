//
//  TendiesXPublicFrameworks.h
//  Metal / MetalKit / CoreImage / ImageIO 都是公开框架，头文件随 iOS SDK 分发，
//  不需要从设备 dump 拷贝，直接 import 框架头即可。此文件只是聚合入口。
//
//  注意：不要同时再 import 那些从设备 dump 出来的同名 ipsw 头（例如自己拷的
//  CALayer.h / AVPlayer.h），否则会出现 duplicate interface definition。
//

#ifndef TendiesXPublicFrameworks_h
#define TendiesXPublicFrameworks_h

#import <Metal/Metal.h>        // MTLDevice / MTLCommandQueue / MTLTexture
#import <MetalKit/MetalKit.h>  // MTKView / MTKTextureLoader
#import <CoreImage/CoreImage.h> // CIContext / CIFilter / CIImage
#import <ImageIO/ImageIO.h>    // CGImageSource / CGImageDestination（GIF / HEIC 逐帧）

#endif /* TendiesXPublicFrameworks_h */
