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

- (void)reload;

@end
