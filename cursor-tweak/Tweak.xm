// Tweak.xm — 便捷光标 (KPCursor) 独立插件  v1.0-3（防御式版本）
//
// 功能：
//   1. 从屏幕底部（左侧或右侧）向上滑动，超过设定距离后唤出鼠标式光标；
//   2. 手指在屏幕上拖动 = 移动光标（相对移动，速度由“光标灵敏度”调节）；
//   3. 在屏幕上轻点一下 = 在光标位置模拟一次点击（通过 IOHIDEvent 注入触摸事件）；
//   4. 光标右上角的小按钮可隐藏光标。
//
// 仅注入 SpringBoard 进程。
//
// v1.0-3 变更（修复注销后黑屏）：
//   - 不再 hook SpringBoard 的 applicationDidFinishLaunching:（规避该私有方法
//     在 iOS 16 上的调用时序问题），改用 %ctor 延迟 2 秒在主线启动，全程 @try/@catch；
//   - 未启用功能时不创建任何窗口/UI（注销启动时零 UI 操作，最大程度避免启动崩溃）；
//   - 所有手势回调、模拟点击全部加 @try/@catch，异常只吞不掉进程；
//   - IOHIDEventSet*Value 调用前判空。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

// ================= IOHIDEvent 私有接口（模拟触摸点击用） =================
typedef struct __IOHIDEvent *IOHIDEventRef;
typedef struct __IOHIDEventSystemClient *IOHIDEventSystemClientRef;

extern "C" {
IOHIDEventSystemClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
IOHIDEventRef IOHIDEventCreateDigitizerEvent(CFAllocatorRef allocator,
    uint64_t timeStamp, uint32_t type,
    uint32_t index, uint32_t identity, uint32_t eventMask,
    uint32_t buttonMask, double x, double y, double z,
    double tipPressure, double barrelPressure,
    unsigned char range, unsigned char touch, unsigned int options);
void IOHIDEventSetFloatValue(IOHIDEventRef event, uint32_t field, float value);
void IOHIDEventSystemClientDispatchEvent(IOHIDEventSystemClientRef client, IOHIDEventRef event);
}

// 常量（来自 IOHIDEventTypes.h）
enum {
    kIOHIDDigitizerEventRange         = 0x00000001,
    kIOHIDDigitizerEventTouch         = 0x00000002,
    kIOHIDDigitizerTransducerTypeHand = 3,
    kIOHIDEventFieldDigitizerX        = 12,
    kIOHIDEventFieldDigitizerY        = 13,
    kIOHIDEventFieldDigitizerIndex    = 17,
    kIOHIDEventFieldDigitizerIdentity = 18,
};

static NSString * const KPCPrefsDomain = @"com.kpcursor";
static NSString * const KPCKeyEnabled      = @"enabled";
static NSString * const KPCKeySide         = @"side";
static NSString * const KPCKeyCursorSize   = @"cursorSize";
static NSString * const KPCKeyActiveHeight = @"activeHeight";
static NSString * const KPCKeyDragDistance = @"dragDistance";
static NSString * const KPCKeyKeen         = @"keen";

// ================= 穿透窗口：空白区域不拦截触摸 =================
@interface KPCPassthroughWindow : UIWindow
@end
@implementation KPCPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    @try {
        UIView *hit = [super hitTest:point withEvent:event];
        if (hit == self) return nil;
        return hit;
    } @catch (NSException *e) {
        return nil;
    }
}
@end

@interface KPCCursorManager : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

@implementation KPCCursorManager {
    UIWindow *_window;
    UIView   *_stripView;
    UIView   *_overlayView;
    UIView   *_cursorView;
    UIButton *_hideButton;

    IOHIDEventSystemClientRef _hidClient;

    BOOL     _enabled;
    NSInteger _side;
    CGFloat  _cursorSize;
    CGFloat  _activeHeight;
    CGFloat  _dragDistance;
    CGFloat  _keen;

    BOOL     _cursorActive;
    CGPoint  _cursorCenter;
    CGPoint  _lastPanTranslation;
    BOOL     _started;
}

+ (instancetype)sharedInstance {
    static KPCCursorManager *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KPCCursorManager alloc] init];
    });
    return instance;
}

- (void)start {
    if (_started) return;
    _started = YES;
    @try {
        [self loadPrefs];
        // 只有启用时才创建 UI；未启用时注销/启动不做任何界面操作
        if (_enabled) {
            [self ensureUI];
        }
        [[NSNotificationCenter defaultCenter] addObserver:self
            selector:@selector(prefsChanged)
            name:NSUserDefaultsDidChangeNotification object:nil];
    } @catch (NSException *e) { }
}

// ---------- 设置 ----------
- (void)loadPrefs {
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:KPCPrefsDomain];
    _enabled       = [d boolForKey:KPCKeyEnabled];
    _side          = [d integerForKey:KPCKeySide];
    _cursorSize    = [d objectForKey:KPCKeyCursorSize] ? [d floatForKey:KPCKeyCursorSize] : 12.0;
    _activeHeight  = [d objectForKey:KPCKeyActiveHeight] ? [d floatForKey:KPCKeyActiveHeight] : 300.0;
    _dragDistance  = [d objectForKey:KPCKeyDragDistance] ? [d floatForKey:KPCKeyDragDistance] : 90.0;
    _keen          = [d objectForKey:KPCKeyKeen] ? [d floatForKey:KPCKeyKeen] : 4.0;

    _cursorSize   = MAX(10, MIN(30, _cursorSize));
    _activeHeight = MAX(200, MIN(1000, _activeHeight));
    _dragDistance = MAX(50, MIN(150, _dragDistance));
    _keen         = MAX(3, MIN(8, _keen));
}

- (void)prefsChanged {
    @try {
        [self loadPrefs];
        if (_enabled) {
            [self ensureUI];
            [self rebuildStrip];
        } else {
            [self hideCursor];
        }
    } @catch (NSException *e) { }
}

- (void)ensureUI {
    if (_window) return;
    [self buildWindow];
    [self rebuildStrip];
}

// ---------- 界面搭建 ----------
- (void)buildWindow {
    CGRect bounds = [UIScreen mainScreen].bounds;
    _window = [[KPCPassthroughWindow alloc] initWithFrame:bounds];
    _window.windowLevel = UIWindowLevelStatusBar + 1;
    _window.userInteractionEnabled = YES;
    _window.hidden = NO;

    _stripView = [[UIView alloc] initWithFrame:CGRectZero];
    _stripView.backgroundColor = [UIColor clearColor];
    _stripView.userInteractionEnabled = YES;
    UIPanGestureRecognizer *stripPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(stripPan:)];
    [_stripView addGestureRecognizer:stripPan];
    [_window addSubview:_stripView];

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
    [_hideButton addTarget:self action:@selector(hideCursor) forControlEvents:UIControlEventTouchUpInside];
    [_overlayView addSubview:_hideButton];
}

- (void)rebuildStrip {
    if (!_stripView || !_window) return;
    @try {
        CGRect bounds = [UIScreen mainScreen].bounds;
        CGFloat h = _activeHeight;
        CGRect frame;
        if (_side == 1) {
            frame = CGRectMake(0, bounds.size.height - h, bounds.size.width / 2.0, h);
        } else {
            frame = CGRectMake(bounds.size.width / 2.0, bounds.size.height - h, bounds.size.width / 2.0, h);
        }
        _stripView.frame = frame;
        _stripView.hidden = !_enabled || _cursorActive;
        _stripView.userInteractionEnabled = _enabled && !_cursorActive;
    } @catch (NSException *e) { }
}

// ---------- 手势：底部上滑唤出 ----------
- (void)stripPan:(UIPanGestureRecognizer *)g {
    if (!_enabled) return;
    @try {
        CGPoint t = [g translationInView:_window];
        if (g.state == UIGestureRecognizerStateBegan) {
            _lastPanTranslation = t;
            return;
        }
        if (g.state == UIGestureRecognizerStateChanged) {
            if (!_cursorActive && -t.y >= _dragDistance) {
                [self showCursorAt:CGPointMake(CGRectGetMidX(_window.bounds),
                                               CGRectGetMidY(_window.bounds))];
            }
        }
    } @catch (NSException *e) { }
}

// ---------- 光标模式：拖动 = 移动光标 ----------
- (void)overlayPan:(UIPanGestureRecognizer *)g {
    if (!_cursorActive) return;
    @try {
        CGPoint t = [g translationInView:_window];
        if (g.state == UIGestureRecognizerStateBegan) {
            _lastPanTranslation = t;
            return;
        }
        if (g.state == UIGestureRecognizerStateChanged) {
            [self moveCursorBy:CGPointMake(t.x - _lastPanTranslation.x,
                                           t.y - _lastPanTranslation.y)];
            _lastPanTranslation = t;
        }
    } @catch (NSException *e) { }
}

// ---------- 光标模式：轻点 = 模拟点击 ----------
- (void)overlayTap:(UITapGestureRecognizer *)g {
    if (!_cursorActive) return;
    @try {
        CGPoint p = [g locationInView:_overlayView];
        if (CGRectContainsPoint(_hideButton.frame, p)) return;
        [self clickAt:_cursorCenter];
    } @catch (NSException *e) { }
}

// ---------- 光标显隐与移动 ----------
- (void)showCursorAt:(CGPoint)center {
    @try {
        _cursorCenter = [self clampCenter:center];
        _cursorActive = YES;
        [self rebuildStrip];
        _overlayView.hidden = NO;
        _overlayView.userInteractionEnabled = YES;
        [self layoutCursor];
    } @catch (NSException *e) { }
}

- (void)hideCursor {
    _cursorActive = NO;
    if (_overlayView) {
        _overlayView.hidden = YES;
        _overlayView.userInteractionEnabled = NO;
    }
    [self rebuildStrip];
}

- (void)moveCursorBy:(CGPoint)delta {
    if (!_cursorActive) return;
    @try {
        CGFloat mult = _keen / 2.0;
        _cursorCenter = [self clampCenter:CGPointMake(_cursorCenter.x + delta.x * mult,
                                                      _cursorCenter.y + delta.y * mult)];
        [self layoutCursor];
    } @catch (NSException *e) { }
}

- (CGPoint)clampCenter:(CGPoint)c {
    CGRect b = _window.bounds;
    CGFloat half = _cursorSize / 2.0 + 12;
    c.x = MAX(half, MIN(b.size.width - half, c.x));
    c.y = MAX(half, MIN(b.size.height - half, c.y));
    return c;
}

- (void)layoutCursor {
    @try {
        CGFloat d = _cursorSize;
        _cursorView.frame = CGRectMake(_cursorCenter.x - d/2, _cursorCenter.y - d/2, d, d);
        _cursorView.layer.cornerRadius = d/2;
        _cursorView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
        _cursorView.layer.borderColor = [UIColor whiteColor].CGColor;
        _cursorView.layer.borderWidth = 2;

        _hideButton.frame = CGRectMake(_cursorCenter.x + d/2 - 14,
                                       _cursorCenter.y - d/2 - 14, 22, 22);
        _hideButton.layer.cornerRadius = 11;
    } @catch (NSException *e) { }
}

// ---------- 模拟点击（IOHIDEvent 注入） ----------
- (void)clickAt:(CGPoint)pt {
    @try {
        _overlayView.userInteractionEnabled = NO;
        [self injectTouchAt:pt phase:0];
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            @try {
                [self injectTouchAt:pt phase:2];
                dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                               dispatch_get_main_queue(), ^{
                    @try {
                        if (self->_cursorActive) {
                            self->_overlayView.userInteractionEnabled = YES;
                        }
                    } @catch (NSException *e) { }
                });
            } @catch (NSException *e) { }
        });
    } @catch (NSException *e) { }
}

// phase: 0=按下 1=移动 2=抬起
- (void)injectTouchAt:(CGPoint)pt phase:(int)phase {
    @try {
        if (!_hidClient) {
            _hidClient = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
        }
        CGFloat scale = [UIScreen mainScreen].scale;
        uint32_t mask = (phase == 2)
            ? kIOHIDDigitizerEventTouch
            : (kIOHIDDigitizerEventRange | kIOHIDDigitizerEventTouch);

        IOHIDEventRef event = IOHIDEventCreateDigitizerEvent(kCFAllocatorDefault,
            mach_absolute_time(), kIOHIDDigitizerTransducerTypeHand,
            0, 1, mask, 0,
            0, 0, 0, 0, 0,
            true, true, 0);

        if (event) {
            IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerX, pt.x * scale);
            IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerY, pt.y * scale);
            IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerIndex, 0);
            IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerIdentity, 1);
            IOHIDEventSystemClientDispatchEvent(_hidClient, event);
            CFRelease(event);
        }
    } @catch (NSException *e) { }
}

@end

// ================= 入口：延迟启动，全程保护 =================
%ctor {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        @try {
            [[KPCCursorManager sharedInstance] start];
        } @catch (NSException *e) { }
    });
}
