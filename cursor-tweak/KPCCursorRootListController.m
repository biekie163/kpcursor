// KPCCursorRootListController.m — 便捷光标设置页控制器
#import <Preferences/PSListController.h>
#import <CoreFoundation/CoreFoundation.h>

@interface KPCCursorRootListController : PSListController
@end

@implementation KPCCursorRootListController

- (id)specifiers {
    if (!_specifiers) {
        _specifiers = [self loadSpecifiersFromPlistName:@"Root" target:self];
    }
    return _specifiers;
}

- (void)viewDidLoad {
    [super viewDidLoad];
}

// Hero 关键修复：NSUserDefaultsDidChangeNotification 只在「本进程内」可靠，
// 设置 App 改的是磁盘上的 com.kpcursor.plist，SpringBoard 里原来的监听基本收不到。
// 这里改成跨进程的 Darwin 通知，改完立刻生效，不用注销。
- (void)postPrefsChanged {
    CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                         CFSTR("com.kpcursor.prefschanged"),
                                         NULL, NULL, true);
}

- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];
    [self postPrefsChanged];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [self postPrefsChanged];
}

@end
