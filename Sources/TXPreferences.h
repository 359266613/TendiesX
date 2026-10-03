//
//  TXPreferences.h
//  偏好读写（域 com.axs.tendiesx）
//
//  route A 只需要三样东西：总开关、选中的素材路径、上一次安装结果。
//  渲染相关的参数（触摸/视差/兜底挂载）已随 route B 一起删除。
//
//  面板用 CFPreferencesSetAppValue 写、这里用 CFPreferencesCopyAppValue 读，
//  rootless / roothide 下路径由 CFPreferences 自行处理，勿手拼 plist 路径。
//

#import <Foundation/Foundation.h>

@interface TXPreferences : NSObject

+ (instancetype)sharedInstance;

/// 总开关：关掉后 worker 不响应安装请求
@property (nonatomic, assign, readonly) BOOL enabled;
/// 安装后自动把新壁纸设为当前壁纸（走 PRSService 建配置 + 选中），默认开
@property (nonatomic, assign, readonly) BOOL autoApply;
/// 选中的 .tendies（压缩包或已解包目录）
@property (nonatomic, copy,   readonly) NSString *sourcePath;
/// 上一次安装结果（worker 写、面板回读后弹窗）
@property (nonatomic, copy,   readonly) NSString *lastInstallMessage;

- (void)reload;
- (void)updateSourcePath:(NSString *)path;
- (void)updateLastInstallMessage:(NSString *)message;

@end
