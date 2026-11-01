// Tweak.xm — 便捷光标 (KPCursor) v1.0-4
//
// 设计目标：在 SpringBoard 里绝不因为「插件自己的 bug」把系统搞死。
//
// v1.0-4 相对 v1.0-3 的关键改动（每一条都对应一次真实风险）：
//   1. 重新核对 IOHIDEventCreateDigitizerEvent 的**真实原型**（15 个参数，IOHIDFloat = double），
//      并把 digitizer 字段号改成 IOHIDEventFieldBase(kIOHIDEventTypeDigitizer) 计算值。
//      以前用 12/13/17/18 是错的，坐标字段根本没写进去。
//   2. 触摸注入全部挪到独立串行队列，绝不在手势回调 / 主线程里同步注入，
//      并加 _injecting 重入锁 + 点击冷却，避免「注入 → 再触发 → 再注入」的事件风暴。
//   3. 激活热区从「半屏大小、永久拦截触摸」缩小成底部一条（默认 60pt），
//      不再把半个屏幕变成黑洞（这也是「手机像死机」的常见原因）。
//   4. 窗口挂到当前 UIWindowScene 上，避免 iOS 16 上 scene-less UIWindow 的异常。
//   5. 三重自杀保险：默认关闭、/var/mobile/Library/Preferences/com.kpcursor.disabled
//      紧急开关、连续 3 次启动失败自动禁用（防白苹果循环）。
//   6. 光标 20 秒无操作自动退出，任何情况下都不会把你锁在「全屏接管」状态里。
//
// 日志：/var/mobile/Library/Logs/KPCursor.log

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <Foundation/Foundation.h>
#include <mach/mach_time.h>
#include <unistd.h>
#include <math.h>

// ============================================================================
// 一、IOHID 私有接口（原型抄自 IOHIDFamily-…/IOHIDEvent.h，不要凭记忆改）
// ============================================================================

typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;
typedef double IOHIDFloat;   // 64 位下就是 double，浮点参数走 d0–d7

extern "C" {
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
// type: 0=Monitor 1=Admin(可注入) 2=Simple；没权限时返回 NULL
IOHIDEventSystemClientRef IOHIDEventSystemClientCreateWithType(CFAllocatorRef allocator,
                                                              int type,
                                                              CFDictionaryRef attributes);
void IOHIDEventSystemClientScheduleWithRunLoop(IOHIDEventSystemClientRef client,
                                               CFRunLoopRef runLoop,
                                               CFStringRef runLoopMode);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);

// 15 个参数，顺序和类型都不能错：
//   allocator, timeStamp, type, index, identity, eventMask, buttonMask,
//   x, y, z, tipPressure, barrelPressure, range, touch, options
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
                                             uint64_t timeStamp,
                                             uint32_t type,
                                             uint32_t index,
                                             uint32_t identity,
                                             uint32_t eventMask,
                                             uint32_t buttonMask,
                                             IOHIDFloat x, IOHIDFloat y, IOHIDFloat z,
                                             IOHIDFloat tipPressure, IOHIDFloat barrelPressure,
                                             Boolean range, Boolean touch,
                                             uint32_t options);
void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, IOHIDFloat value);
// 第三个参数用 CFIndex（64 位）而不是 int：真实头文件里就是 CFIndex，
// 传 int 时高位可能带垃圾，属于典型的 ABI 隐患。
void IOHIDEventSetIntegerValue(IOHIDEventRef event, uint32_t field, CFIndex value);
}

// 常用常量（值取自 IOHIDEventTypes.h）
enum {
    kKPCDigitizerTypeHand   = 0x23,   // kIOHIDDigitizerTransducerTypeHand
    kKPCEventRange          = 0x00000001,
    kKPCEventTouch          = 0x00000002,
    kKPCEventPosition       = 0x00000004,
    kKPCEventStart          = 0x00000100,
};

// IOHIDEventFieldBase(type) = (type << 16)，kIOHIDEventTypeDigitizer = 11
#define KPC_FIELD_BASE ((unsigned)(11u << 16))
enum {
    kKPCFieldDigitizerX        = KPC_FIELD_BASE + 0,
    kKPCFieldDigitizerY        = KPC_FIELD_BASE + 1,
    kKPCFieldDigitizerIndex    = KPC_FIELD_BASE + 5,
    kKPCFieldDigitizerIdentity = KPC_FIELD_BASE + 6,
    // 显示集成标记：告诉系统「这个坐标是屏幕像素坐标」，而不是归一化坐标
    kKPCFieldDisplayIntegrated = KPC_FIELD_BASE + 25,
};

// ============================================================================
// 二、常量与日志
// ============================================================================

static NSString *const KPCPrefsDomain    = @"com.kpcursor";
static NSString *const KPCKeyEnabled     = @"enabled";
static NSString *const KPCKeySide        = @"side";
static NSString *const KPCKeyCursorSize  = @"cursorSize";
static NSString *const KPCKeyActiveH     = @"activeHeight";
static NSString *const KPCKeyDragDist    = @"dragDistance";
static NSString *const KPCKeyKeen        = @"keen";

static NSString *const KPCNotifyPrefs    = @"com.kpcursor.prefschanged";
static NSString *const KPCKillSwitchFile = @"/var/mobile/Library/Preferences/com.kpcursor.disabled";
static NSString *const KPCBootCountFile  = @"/var/mobile/Library/Preferences/com.kpcursor.bootcount";
static NSString *const KPCLogFile        = @"/var/mobile/Library/Logs/KPCursor.log";

static void KPCWriteLine(NSString *line) {
    NSFileManager *fm = [NSFileManager defaultManager];
    if (![fm fileExistsAtPath:KPCLogFile]) {
        [fm createDirectoryAtPath:@"/var/mobile/Library/Logs"
      withIntermediateDirectories:YES attributes:nil error:NULL];
        [[NSData data] writeToFile:KPCLogFile atomically:YES];
    }
    NSFileHandle *fh = [NSFileHandle fileHandleForWritingAtPath:KPCLogFile];
    if (!fh) return;
    @try {
        [fh seekToEndOfFile];
        [fh writeData:[line dataUsingEncoding:NSUTF8StringEncoding]];
    } @catch (NSException *e) { }
    [fh closeFile];
}

#define KPLog(fmt, ...) do { \
    NSString *kpcLine = [NSString stringWithFormat:@"[%@] " fmt "\n", \
        [[NSDate date] descriptionWithLocale:nil], ##__VA_ARGS__]; \
    KPCWriteLine(kpcLine); \
    NSLog(@"[KPCursor] " fmt, ##__VA_ARGS__); \
} while (0)

static int KPCReadBootCount(void) {
    NSString *s = [NSString stringWithContentsOfFile:KPCBootCountFile
                                            encoding:NSUTF8StringEncoding error:NULL];
    return s ? s.intValue : 0;
}

static void KPCWriteBootCount(int n) {
    NSString *s = [NSString stringWithFormat:@"%d", n];
    [s writeToFile:KPCBootCountFile atomically:YES encoding:NSUTF8StringEncoding error:NULL];
}

// ============================================================================
// 三、窗口：点在自己身上时返回 nil，让下面的 App 拿到触摸
// ============================================================================

@interface KPCPassthroughWindow : UIWindow
@end

@implementation KPCPassthroughWindow

- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    return (hit == self) ? nil : hit;
}

@end

// ============================================================================
// 四、管理器
// ============================================================================

static void KPCOnPrefsChangedDarwin(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo);

@interface KPCCursorManager : NSObject
+ (instancetype)sharedInstance;
- (void)startIfSafe;
@end

@implementation KPCCursorManager {
    UIWindow *_window;
    UIView   *_stripView;
    UIView   *_overlayView;
    UIView   *_cursorView;
    UIButton *_hideButton;

    IOHIDEventSystemClientRef _hidClient;
    dispatch_queue_t _hidQueue;

    BOOL      _enabled;
    NSInteger _side;
    CGFloat   _cursorSize;
    CGFloat   _activeHeight;
    CGFloat   _dragDistance;
    CGFloat   _keen;

    BOOL      _cursorActive;
    CGPoint   _cursorCenter;
    CGPoint   _lastPanTranslation;
    BOOL      _stripTriggered;

    BOOL      _injecting;
    NSTimeInterval _lastClickTime;

    BOOL      _started;
    NSTimer  *_idleTimer;
}

+ (instancetype)sharedInstance {
    static KPCCursorManager *instance = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ instance = [[KPCCursorManager alloc] init]; });
    return instance;
}

- (instancetype)init {
    if ((self = [super init])) {
        _hidQueue = dispatch_queue_create("com.kpcursor.hid", DISPATCH_QUEUE_SERIAL);
        _lastClickTime = 0;
    }
    return self;
}

// ---------------------------------------------------------------- 启动

- (void)startIfSafe {
    if (_started) return;

    if ([[NSFileManager defaultManager] fileExistsAtPath:KPCKillSwitchFile]) {
        KPLog(@"kill switch file present, KPCursor stays off");
        _started = YES;      // 不再尝试
        return;
    }
    int boot = KPCReadBootCount();
    if (boot > 3) {
        // 连续 3 次没活过 25 秒 => 大概率是崩溃/卡死循环。
        // 直接把紧急开关文件写出来，并清零计数，避免永远起不来。
        KPLog(@"boot count %d > 3, auto disabled (writing %@)", boot, KPCKillSwitchFile);
        NSString *why = @"KPCursor 连续 3 次启动失败，已自动停用。\n"
                         "排查完成后删除本文件即可重新启用。\n";
        [why writeToFile:KPCKillSwitchFile atomically:YES
                encoding:NSUTF8StringEncoding error:NULL];
        KPCWriteBootCount(0);
        _started = YES;
        return;
    }

    _started = YES;
    @try {
        [self loadPrefs];
        KPLog(@"start: enabled=%d side=%ld size=%.0f height=%.0f", _enabled, (long)_side,
              _cursorSize, _activeHeight);
        if (_enabled) [self ensureUI];

        NSNotificationCenter *nc = [NSNotificationCenter defaultCenter];
        [nc addObserver:self selector:@selector(prefsChanged)
                   name:NSUserDefaultsDidChangeNotification object:nil];
        [nc addObserver:self selector:@selector(prefsChanged)
                   name:UIApplicationDidBecomeActiveNotification object:nil];

        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(),
                                        (__bridge const void *)self,
                                        KPCOnPrefsChangedDarwin,
                                        (__bridge CFStringRef)KPCNotifyPrefs,
                                        NULL,
                                        CFNotificationSuspensionBehaviorDeliverImmediately);
    } @catch (NSException *e) {
        KPLog(@"start exception: %@", e);
    }
}

static void KPCOnPrefsChangedDarwin(CFNotificationCenterRef center, void *observer,
                                    CFStringRef name, const void *object,
                                    CFDictionaryRef userInfo) {
    @autoreleasepool {
        KPCCursorManager *mgr = (__bridge KPCCursorManager *)observer;
        dispatch_async(dispatch_get_main_queue(), ^{ [mgr prefsChanged]; });
    }
}

// ---------------------------------------------------------------- 设置

- (void)loadPrefs {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:KPCPrefsDomain];
    [d synchronize];
    _enabled      = [d boolForKey:KPCKeyEnabled];
    _side         = [d integerForKey:KPCKeySide];
    _cursorSize   = [d objectForKey:KPCKeyCursorSize]  ? [d floatForKey:KPCKeyCursorSize]  : 12.0;
    _activeHeight = [d objectForKey:KPCKeyActiveH]     ? [d floatForKey:KPCKeyActiveH]     : 60.0;
    _dragDistance = [d objectForKey:KPCKeyDragDist]    ? [d floatForKey:KPCKeyDragDist]    : 90.0;
    _keen         = [d objectForKey:KPCKeyKeen]        ? [d floatForKey:KPCKeyKeen]        : 4.0;

    _cursorSize   = MAX(10.0, MIN(30.0,   _cursorSize));
    _activeHeight = MAX(20.0, MIN(200.0,  _activeHeight));   // 热区高度，故意压小
    _dragDistance = MAX(50.0, MIN(150.0,  _dragDistance));
    _keen         = MAX(3.0,  MIN(8.0,    _keen));
}

- (void)prefsChanged {
    @try {
        BOOL wasEnabled = _enabled;
        [self loadPrefs];
        KPLog(@"prefs changed: enabled=%d", _enabled);

        if (_enabled && !wasEnabled) {
            [self ensureUI];
        } else if (!_enabled && wasEnabled) {
            [self hideCursor];
            [self teardownUI];
        } else if (_enabled) {
            [self rebuildStrip];
            [self layoutCursor];
        }
    } @catch (NSException *e) {
        KPLog(@"prefsChanged exception: %@", e);
    }
}

// ---------------------------------------------------------------- 界面

- (UIWindowScene *)activeScene {
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if (![scene isKindOfClass:[UIWindowScene class]]) continue;
        if (scene.activationState == UISceneActivationStateForegroundActive) return (UIWindowScene *)scene;
    }
    for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
        if ([scene isKindOfClass:[UIWindowScene class]]) return (UIWindowScene *)scene;
    }
    return nil;
}

- (void)ensureUI {
    if (_window) return;
    @try {
        UIWindowScene *scene = [self activeScene];
        if (scene) {
            _window = [[KPCPassthroughWindow alloc] initWithWindowScene:scene];
            _window.frame = scene.coordinateSpace.bounds;
        } else {
            _window = [[KPCPassthroughWindow alloc] initWithFrame:[UIScreen mainScreen].bounds];
        }
        _window.windowLevel    = UIWindowLevelStatusBar + 1;
        _window.backgroundColor = [UIColor clearColor];
        _window.opaque          = NO;
        _window.hidden          = NO;
        _window.userInteractionEnabled = YES;

        [self buildSubviews];
        [self rebuildStrip];
        KPLog(@"UI ready, scene=%@", scene ? @"yes" : @"no");
    } @catch (NSException *e) {
        KPLog(@"ensureUI exception: %@", e);
        _window = nil;
    }
}

- (void)teardownUI {
    @try {
        [_stripView removeFromSuperview];
        [_overlayView removeFromSuperview];
        _stripView = nil; _overlayView = nil; _cursorView = nil; _hideButton = nil;
        _window.hidden = YES;
        _window = nil;
    } @catch (NSException *e) { }
}

- (void)buildSubviews {
    CGRect bounds = _window.bounds;

    // --- 激活热区：只占屏幕底部一条，绝不全屏 ---
    _stripView = [[UIView alloc] initWithFrame:CGRectZero];
    _stripView.backgroundColor = [UIColor clearColor];
    _stripView.userInteractionEnabled = YES;
    UIPanGestureRecognizer *stripPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(stripPan:)];
    stripPan.cancelsTouchesInView = NO;
    stripPan.delaysTouchesBegan   = NO;
    [_stripView addGestureRecognizer:stripPan];
    [_window addSubview:_stripView];

    // --- 光标模式的全屏层：只在这一层里接管触摸 ---
    _overlayView = [[UIView alloc] initWithFrame:bounds];
    _overlayView.backgroundColor = [UIColor clearColor];
    _overlayView.userInteractionEnabled = NO;
    _overlayView.hidden = YES;

    UIPanGestureRecognizer *overlayPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(overlayPan:)];
    [_overlayView addGestureRecognizer:overlayPan];

    UITapGestureRecognizer *overlayTap =
        [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(overlayTap:)];
    [_overlayView addGestureRecognizer:overlayTap];

    [_window addSubview:_overlayView];

    _cursorView = [[UIView alloc] initWithFrame:CGRectZero];
    _cursorView.userInteractionEnabled = NO;
    [_overlayView addSubview:_cursorView];

    _hideButton = [UIButton buttonWithType:UIButtonTypeCustom];
    _hideButton.titleLabel.font = [UIFont boldSystemFontOfSize:11];
    [_hideButton setTitle:@"✕" forState:UIControlStateNormal];
    [_hideButton setTitleColor:[UIColor whiteColor] forState:UIControlStateNormal];
    _hideButton.backgroundColor = [UIColor colorWithWhite:0.2 alpha:0.85];
    _hideButton.layer.cornerRadius = 11;
    _hideButton.layer.borderColor = [UIColor whiteColor].CGColor;
    _hideButton.layer.borderWidth = 1;
    [_hideButton addTarget:self action:@selector(hideCursor)
          forControlEvents:UIControlEventTouchUpInside];
    [_overlayView addSubview:_hideButton];
}

- (void)rebuildStrip {
    if (!_stripView || !_window) return;
    CGRect b = _window.bounds;
    CGFloat w = b.size.width / 2.0;
    CGFloat h = MAX(20.0, MIN(200.0, _activeHeight));
    CGRect f = (_side == 1)
        ? CGRectMake(0, b.size.height - h, w, h)
        : CGRectMake(b.size.width - w, b.size.height - h, w, h);

    _stripView.frame = f;
    _stripView.hidden = !_enabled || _cursorActive;
    _stripView.userInteractionEnabled = _enabled && !_cursorActive;
}

// ---------------------------------------------------------------- 手势

- (void)stripPan:(UIPanGestureRecognizer *)g {
    if (!_enabled || _cursorActive) return;
    @try {
        CGPoint t = [g translationInView:_window];
        switch (g.state) {
            case UIGestureRecognizerStateBegan:
                _stripTriggered = NO;
                _lastPanTranslation = t;
                break;
            case UIGestureRecognizerStateChanged:
                // 必须「向上」且以纵向为主，避免和横向滑动打架
                if (!_stripTriggered &&
                    (-t.y >= _dragDistance) &&
                    (fabs(t.y) > fabs(t.x) * 1.5)) {
                    _stripTriggered = YES;
                    CGPoint p = [g locationInView:_window];
                    [self showCursorAt:p];
                }
                break;
            case UIGestureRecognizerStateEnded:
            case UIGestureRecognizerStateCancelled:
            case UIGestureRecognizerStateFailed:
                _stripTriggered = NO;
                break;
            default:
                break;
        }
    } @catch (NSException *e) {
        KPLog(@"stripPan exception: %@", e);
    }
}

- (void)overlayPan:(UIPanGestureRecognizer *)g {
    if (!_cursorActive) return;
    @try {
        CGPoint t = [g translationInView:_window];
        if (g.state == UIGestureRecognizerStateBegan) {
            _lastPanTranslation = t;
            [self resetIdleTimer];
            return;
        }
        if (g.state == UIGestureRecognizerStateChanged) {
            [self moveCursorBy:CGPointMake(t.x - _lastPanTranslation.x,
                                           t.y - _lastPanTranslation.y)];
            _lastPanTranslation = t;
            [self resetIdleTimer];
        }
    } @catch (NSException *e) {
        KPLog(@"overlayPan exception: %@", e);
    }
}

- (void)overlayTap:(UITapGestureRecognizer *)g {
    if (!_cursorActive || _injecting) return;
    @try {
        CGPoint p = [g locationInView:_overlayView];
        if (_hideButton && CGRectContainsPoint(_hideButton.frame, p)) return;

        NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
        if (now - _lastClickTime < 0.2) return;      // 冷却，防连点/递归
        _lastClickTime = now;

        [self clickAt:_cursorCenter];
    } @catch (NSException *e) {
        KPLog(@"overlayTap exception: %@", e);
    }
}

// ---------------------------------------------------------------- 光标

- (void)showCursorAt:(CGPoint)point {
    @try {
        _cursorCenter = [self clampCenter:point];
        _cursorActive = YES;
        [self rebuildStrip];
        _overlayView.hidden = NO;
        _overlayView.userInteractionEnabled = YES;
        [self layoutCursor];
        [self resetIdleTimer];
        KPLog(@"cursor on at (%.0f, %.0f)", _cursorCenter.x, _cursorCenter.y);
    } @catch (NSException *e) {
        KPLog(@"showCursor exception: %@", e);
    }
}

- (void)hideCursor {
    _cursorActive = NO;
    [_idleTimer invalidate];
    _idleTimer = nil;
    if (_overlayView) {
        _overlayView.hidden = YES;
        _overlayView.userInteractionEnabled = NO;
    }
    [self rebuildStrip];
}

- (void)resetIdleTimer {
    [_idleTimer invalidate];
    __weak typeof(self) weakSelf = self;
    _idleTimer = [NSTimer scheduledTimerWithTimeInterval:20.0 repeats:NO block:^(NSTimer *t) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf) return;
        KPLog(@"idle timeout, auto hide cursor");
        [strongSelf hideCursor];
    }];
}

- (void)moveCursorBy:(CGPoint)delta {
    if (!_cursorActive) return;
    CGFloat mult = _keen / 2.0;
    _cursorCenter = [self clampCenter:CGPointMake(_cursorCenter.x + delta.x * mult,
                                                  _cursorCenter.y + delta.y * mult)];
    [self layoutCursor];
}

- (CGPoint)clampCenter:(CGPoint)c {
    CGRect b = _window ? _window.bounds : [UIScreen mainScreen].bounds;
    CGFloat half = _cursorSize / 2.0 + 12.0;
    c.x = MAX(half, MIN(b.size.width  - half, c.x));
    c.y = MAX(half, MIN(b.size.height - half, c.y));
    return c;
}

- (void)layoutCursor {
    if (!_cursorView) return;
    @try {
        CGFloat d = _cursorSize;
        _cursorView.frame = CGRectMake(_cursorCenter.x - d / 2, _cursorCenter.y - d / 2, d, d);
        _cursorView.layer.cornerRadius = d / 2;
        _cursorView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        _cursorView.layer.borderColor = [UIColor whiteColor].CGColor;
        _cursorView.layer.borderWidth = 2;

        _hideButton.frame = CGRectMake(_cursorCenter.x + d / 2 - 14,
                                       _cursorCenter.y - d / 2 - 14, 22, 22);
        _hideButton.layer.cornerRadius = 11;
    } @catch (NSException *e) { }
}

// ---------------------------------------------------------------- 注入

- (void)ensureHIDClient {
    if (_hidClient) return;
    _hidClient = IOHIDEventSystemClientCreateWithType(kCFAllocatorDefault, 1, NULL);
    if (!_hidClient) _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (_hidClient) {
        IOHIDEventSystemClientScheduleWithRunLoop(_hidClient, CFRunLoopGetMain(),
                                                  kCFRunLoopDefaultMode);
        KPLog(@"HID client ready");
    } else {
        KPLog(@"HID client creation FAILED (no entitlement?)");
    }
}

- (void)injectTouchAt:(CGPoint)pt down:(BOOL)down {
    if (!_hidClient) return;
    @try {
        CGFloat scale = [UIScreen mainScreen].scale;
        IOHIDFloat x = (IOHIDFloat)(pt.x * scale);
        IOHIDFloat y = (IOHIDFloat)(pt.y * scale);

        uint32_t mask = down
            ? (kKPCEventRange | kKPCEventTouch | kKPCEventStart | kKPCEventPosition)
            : kKPCEventTouch;

        IOHIDEventRef ev = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
                                                          mach_absolute_time(),
                                                          kKPCDigitizerTypeHand,
                                                          0,        // index
                                                          1,        // identity（固定一根手指）
                                                          mask,
                                                          0,        // buttonMask
                                                          x, y, 0,
                                                          down ? 1.0 : 0.0,  // tipPressure
                                                          0,
                                                          down, down,        // range, touch
                                                          0);
        if (!ev) {
            KPLog(@"digitizer event creation returned NULL");
            return;
        }
        IOHIDEventSetIntegerValue(ev, kKPCFieldDisplayIntegrated, 1);
        IOHIDEventSetFloatValue(ev, kKPCFieldDigitizerX, x);
        IOHIDEventSetFloatValue(ev, kKPCFieldDigitizerY, y);
        IOHIDEventSetIntegerValue(ev, kKPCFieldDigitizerIndex, 0);
        IOHIDEventSetIntegerValue(ev, kKPCFieldDigitizerIdentity, 1);

        IOHIDEventSystemClientDispatchEvent(_hidClient, ev);
        CFRelease(ev);
    } @catch (NSException *e) {
        KPLog(@"inject exception: %@", e);
    }
}

- (void)clickAt:(CGPoint)pt {
    if (_injecting || !_cursorActive) return;
    _injecting = YES;
    _overlayView.userInteractionEnabled = NO;    // 注入期间不做接收方

    __weak typeof(self) weakSelf = self;
    dispatch_async(_hidQueue, ^{
        typeof(self) s = weakSelf;
        if (!s) return;
        @try {
            [s ensureHIDClient];
            [s injectTouchAt:pt down:YES];
            usleep(60 * 1000);
            [s injectTouchAt:pt down:NO];
        } @catch (NSException *e) {
            KPLog(@"click worker exception: %@", e);
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.08 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            typeof(self) s2 = weakSelf;
            if (!s2) return;
            s2->_injecting = NO;
            if (s2->_cursorActive) s2->_overlayView.userInteractionEnabled = YES;
        });
    });
}

@end

// ============================================================================
// 五、入口：只负责「晚一点、安全地」把管理器叫起来
// ============================================================================

%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.5 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [[KPCCursorManager sharedInstance] startIfSafe];
    });
}

%end

%ctor {
    @autoreleasepool {
        // 启动计数：20 秒内 SpringBoard 没重启过就算这次启动成功。
        // 连续 3 次失败（崩溃/卡死循环）后插件自动停用，防止白苹果。
        int boot = KPCReadBootCount() + 1;
        KPCWriteBootCount(boot);

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            KPCWriteBootCount(0);
        });

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            [[KPCCursorManager sharedInstance] startIfSafe];
        });
    }
}
