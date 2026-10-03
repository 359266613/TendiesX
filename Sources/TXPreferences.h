//
//  TXPreferences.h
//  偏好读写（域：com.axs.tendiesx）
//  设置面板用 CFPreferencesSetAppValue 写入，这里用 CFPreferencesCopyAppValue 读取，
//  rootless / roothide 下路径由 CFPreferences 自行处理，勿手拼 plist 路径。
//

#import <Foundation/Foundation.h>

@interface TXPreferences : NSObject

+ (instancetype)sharedInstance;

@property (nonatomic, assign, readonly) BOOL enabled;             // 总开关
@property (nonatomic, copy,   readonly) NSString *activePackagePath; // 当前 .tendies 路径
@property (nonatomic, assign, readonly) BOOL interactionEnabled;  // 触摸交互
@property (nonatomic, assign, readonly) BOOL parallaxEnabled;     // 陀螺仪视差

/// 兜底挂载：默认 NO。只有找到「主壁纸容器」才挂渲染层；
/// 允许挂到副本宿主（假模糊/快照/portal）会让系统同时跑多套 CAAML 动画，
/// 表现就是"手机很卡" —— 所以默认关闭，只在排查时打开。
@property (nonatomic, assign, readonly) BOOL mountFallbackEnabled;

- (void)reload;

/// 调整：壁纸引擎导入 .tendies 后，源文件会被删除，
/// 需要把偏好里的路径改指到解压后的素材库目录（面板不需要用）。
- (void)updateActivePackagePath:(NSString *)path;

@end
