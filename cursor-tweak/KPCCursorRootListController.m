// KPCCursorRootListController.m — 便捷光标设置页控制器
#import <Preferences/PSListController.h>

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
    // 纯 spec 页面，无需额外逻辑；修改设置后 tweak 通过
    // NSUserDefaultsDidChangeNotification 自动生效，无需注销。
}

@end
