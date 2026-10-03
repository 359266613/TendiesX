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

static void TXSetPref(NSString *key, id value) {
    CFPreferencesSetAppValue((__bridge CFStringRef)key,
                             (__bridge CFPropertyListRef)value,
                             (__bridge CFStringRef)kTXPrefsDomain);
    CFPreferencesAppSynchronize((__bridge CFStringRef)kTXPrefsDomain);
}

static void TXPrefsReloadCallback(CFNotificationCenterRef center,
                                  void *observer,
                                  CFStringRef name,
                                  const void *object,
                                  CFDictionaryRef userInfo) {
    [[TXPreferences sharedInstance] reload];
}

@interface TXPreferences ()
@property (nonatomic, assign, readwrite) BOOL enabled;
@property (nonatomic, copy,   readwrite) NSString *sourcePath;
@property (nonatomic, copy,   readwrite) NSString *lastInstallMessage;
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

- (void)updateSourcePath:(NSString *)path {
    TXSetPref(@"SourcePath", path.length ? path : @"");
    self.sourcePath = path.length ? path : nil;
    TXLog(@"偏好改写 SourcePath = %@", path.length ? path : @"(空)");
}

- (void)updateLastInstallMessage:(NSString *)message {
    TXSetPref(@"LastInstallMessage", message.length ? message : @"");
    self.lastInstallMessage = message;
}

- (void)reload {
    self.enabled = TXCopyBoolPref(@"Enabled", YES);

    id path = TXCopyPref(@"SourcePath");
    self.sourcePath = [path isKindOfClass:NSString.class] && [path length] > 0 ? path : nil;

    id message = TXCopyPref(@"LastInstallMessage");
    self.lastInstallMessage = [message isKindOfClass:NSString.class] ? message : nil;

    TXLog(@"偏好读取 [%@]: Enabled=%d SourcePath=%@",
          kTXPrefsDomain, self.enabled, self.sourcePath ?: @"(空)");
}

@end
