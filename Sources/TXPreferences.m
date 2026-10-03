#import "TXPreferences.h"
#import "TXLogger.h"

static NSString *const kTXPrefsDomain = @"com.axs.tendiesx";
static NSString *const kTXPrefsReloadNotification = @"com.axs.tendiesx/ReloadPrefs";

static id TXCopyPref(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyAppValue((__bridge CFStringRef)key,
                                                        (__bridge CFStringRef)kTXPrefsDomain);
    return value ? (__bridge_transfer id)value : nil;
}

static BOOL TXCopyBoolPref(NSString *key, BOOL fallback) {
    id value = TXCopyPref(key);
    return [value respondsToSelector:@selector(boolValue)] ? [value boolValue] : fallback;
}

static void TXPrefsReloadCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    [[TXPreferences sharedInstance] reload];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"TXPreferencesDidReload"
                                                        object:nil];
}

@interface TXPreferences ()
@property (nonatomic, assign, readwrite) BOOL enabled;
@property (nonatomic, copy,   readwrite) NSString *activePackagePath;
@property (nonatomic, assign, readwrite) BOOL interactionEnabled;
@property (nonatomic, assign, readwrite) BOOL parallaxEnabled;
@end

@implementation TXPreferences

+ (instancetype)sharedInstance {
    static TXPreferences *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[TXPreferences alloc] init];
        [shared reload];
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)shared,
                                        TXPrefsReloadCallback,
                                        (__bridge CFStringRef)kTXPrefsReloadNotification,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    });
    return shared;
}

- (void)reload {
    self.enabled            = TXCopyBoolPref(@"Enabled", YES);
    self.interactionEnabled = TXCopyBoolPref(@"InteractionEnabled", YES);
    self.parallaxEnabled    = TXCopyBoolPref(@"ParallaxEnabled", YES);

    id path = TXCopyPref(@"ActivePackagePath");
    self.activePackagePath = [path isKindOfClass:NSString.class] && [path length] > 0 ? path : nil;

    TXLog(@"偏好读取 [%@]: Enabled=%d Interaction=%d Parallax=%d ActivePackagePath=%@",
          kTXPrefsDomain, self.enabled, self.interactionEnabled, self.parallaxEnabled,
          self.activePackagePath ?: @"(空)");
}

@end
