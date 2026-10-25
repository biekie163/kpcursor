\// Tweak.xm — 便捷光标 (KPCursor) 独立插件
//
// 功能：
//   1. 从屏幕底部（左侧或右侧）向上滑动，超过设定距离后唤出鼠标式光标；
//   2. 手指在屏幕上拖动 = 移动光标（相对移动，速度由“光标灵敏度”调节）；
//   3. 在屏幕上轻点一下 = 在光标位置模拟一次点击（通过 IOHIDEvent 注入触摸事件）；
//   4. 光标右上角的小按钮可隐藏光标。
//
// 仅注入 SpringBoard 进程。SpringBoard 的窗口层级高于普通 App，
// 因此悬浮层在桌面和任意 App 之上都能显示。
//
// 触摸穿透关键点：使用 KPCPassthroughWindow，空白区域触摸不拦截，
// 只有激活区域 / 光标模式控制层才接收触摸，其余触摸正常落到下方 App。

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import <mach/mach_time.h>

// ================= IOHIDEvent 私有接口（模拟触摸点击用） =================
// 声明来源：IOHIDEventSystemClient.h / IOHIDEvent.h / IOHIDEventTypes.h（越狱社区通用做法，如 FakeTouch）
// 关键点：真实符号是 C 符号（Apple 头文件用 extern "C" 包裹），必须以 extern "C" 声明；
//         参数类型必须与私有头文件一致（坐标为 double），否则运行时找不到符号或坐标错乱。
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
    kIOHIDDigitizerEventRange         = 0x00000001, // 手指按下/移动
    kIOHIDDigitizerEventTouch         = 0x00000002, // 触摸接触
    kIOHIDDigitizerTransducerTypeHand = 3,
    kIOHIDEventFieldDigitizerX        = 12,
    kIOHIDEventFieldDigitizerY        = 13,
    kIOHIDEventFieldDigitizerIndex    = 17,
    kIOHIDEventFieldDigitizerIdentity = 18,
};

static NSString * const KPCPrefsDomain = @"com.kpcursor";
static NSString * const KPCKeyEnabled      = @"enabled";
static NSString * const KPCKeySide         = @"side";          // 0=右侧 1=左侧
static NSString * const KPCKeyCursorSize   = @"cursorSize";    // 10-30
static NSString * const KPCKeyActiveHeight = @"activeHeight";  // 200-1000
static NSString * const KPCKeyDragDistance = @"dragDistance";  // 50-150
static NSString * const KPCKeyKeen         = @"keen";          // 3-8

// ================= 穿透窗口：空白区域不拦截触摸 =================
@interface KPCPassthroughWindow : UIWindow
@end
@implementation KPCPassthroughWindow
- (UIView *)hitTest:(CGPoint)point withEvent:(UIEvent *)event {
    UIView *hit = [super hitTest:point withEvent:event];
    // 触摸没有落在任何子视图上（即落到窗口本身）时，返回 nil → 穿透给下方 App
    if (hit == self) return nil;
    return hit;
}
@end

@interface KPCCursorManager : NSObject
+ (instancetype)sharedInstance;
- (void)start;
@end

@implementation KPCCursorManager {
    UIWindow *_window;
    UIView   *_stripView;     // 底部激活区域（常驻，透明）
    UIView   *_overlayView;   // 光标模式下的全屏控制层
    UIView   *_cursorView;    // 光标本体
    UIButton *_hideButton;    // 隐藏光标按钮

    IOHIDEventSystemClientRef _hidClient;

    // 设置缓存
    BOOL     _enabled;
    NSInteger _side;          // 0=右侧 1=左侧
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

    [self loadPrefs];
    [self buildWindow];
    [self rebuildStrip];
    [[NSNotificationCenter defaultCenter] addObserver:self
        selector:@selector(prefsChanged)
        name:NSUserDefaultsDidChangeNotification object:nil];
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

    // 防御非法值
    _cursorSize   = MAX(10, MIN(30, _cursorSize));
    _activeHeight = MAX(200, MIN(1000, _activeHeight));
    _dragDistance = MAX(50, MIN(150, _dragDistance));
    _keen         = MAX(3, MIN(8, _keen));
}

- (void)prefsChanged {
    [self loadPrefs];
    if (!_enabled) {
        [self hideCursor];
    }
    [self rebuildStrip];
}

// ---------- 界面搭建 ----------
- (void)buildWindow {
    CGRect bounds = [UIScreen mainScreen].bounds;
    _window = [[KPCPassthroughWindow alloc] initWithFrame:bounds];
    _window.windowLevel = UIWindowLevelStatusBar + 1; // 高于 App 内容，低于系统弹窗
    _window.userInteractionEnabled = YES;
    _window.hidden = NO;

    // 激活区域（常驻、拦截触摸；直接挂窗口上，避免被父视图禁用拦截）
    _stripView = [[UIView alloc] initWithFrame:CGRectZero];
    _stripView.backgroundColor = [UIColor clearColor];
    _stripView.userInteractionEnabled = YES;
    UIPanGestureRecognizer *stripPan =
        [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(stripPan:)];
    [_stripView addGestureRecognizer:stripPan];
    [_window addSubview:_stripView];

    // 光标模式全屏控制层（默认隐藏）
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

    // 光标本体
    _cursorView = [[UIView alloc] initWithFrame:CGRectZero];
    _cursorView.userInteractionEnabled = NO;
    [_overlayView addSubview:_cursorView];

    // 隐藏按钮（光标右上角）
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

// 根据设置重建激活区域的位置与大小
- (void)rebuildStrip {
    if (!_stripView) return;
    CGRect bounds = [UIScreen mainScreen].bounds;
    CGFloat h = _activeHeight;
    CGRect frame;
    if (_side == 1) { // 左侧
        frame = CGRectMake(0, bounds.size.height - h, bounds.size.width / 2.0, h);
    } else {          // 右侧
        frame = CGRectMake(bounds.size.width / 2.0, bounds.size.height - h, bounds.size.width / 2.0, h);
    }
    _stripView.frame = frame;
    _stripView.hidden = !_enabled || _cursorActive;
    _stripView.userInteractionEnabled = _enabled && !_cursorActive;
}

// ---------- 手势：底部上滑唤出 ----------
- (void)stripPan:(UIPanGestureRecognizer *)g {
    if (!_enabled) return;
    CGPoint t = [g translationInView:_window];

    if (g.state == UIGestureRecognizerStateBegan) {
        _lastPanTranslation = t;
        return;
    }
    if (g.state == UIGestureRecognizerStateChanged) {
        // 上滑距离超过阈值 → 唤出光标（默认出现在屏幕中央）
        if (!_cursorActive && -t.y >= _dragDistance) {
            [self showCursorAt:CGPointMake(CGRectGetMidX(_window.bounds),
                                           CGRectGetMidY(_window.bounds))];
        }
    }
    // 唤出后激活区域随即隐藏（当前滑动手势会被系统取消），
    // 之后在任意位置拖动即可移动光标。
}

// ---------- 光标模式：拖动 = 移动光标 ----------
- (void)overlayPan:(UIPanGestureRecognizer *)g {
    if (!_cursorActive) return;
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
}

// ---------- 光标模式：轻点 = 模拟点击 ----------
- (void)overlayTap:(UITapGestureRecognizer *)g {
    if (!_cursorActive) return;
    CGPoint p = [g locationInView:_overlayView];
    // 点在隐藏按钮上 → 只隐藏，不点击
    if (CGRectContainsPoint(_hideButton.frame, p)) return;
    [self clickAt:_cursorCenter];
}

// ---------- 光标显隐与移动 ----------
- (void)showCursorAt:(CGPoint)center {
    _cursorCenter = [self clampCenter:center];
    _cursorActive = YES;
    [self rebuildStrip]; // 隐藏激活区域，避免抢占触摸
    _overlayView.hidden = NO;
    _overlayView.userInteractionEnabled = YES;
    [self layoutCursor];
}

- (void)hideCursor {
    _cursorActive = NO;
    _overlayView.hidden = YES;
    _overlayView.userInteractionEnabled = NO;
    [self rebuildStrip];
}

- (void)moveCursorBy:(CGPoint)delta {
    if (!_cursorActive) return;
    CGFloat mult = _keen / 2.0; // 灵敏度 3~8 → 移动倍率 1.5x~4x
    _cursorCenter = [self clampCenter:CGPointMake(_cursorCenter.x + delta.x * mult,
                                                  _cursorCenter.y + delta.y * mult)];
    [self layoutCursor];
}

- (CGPoint)clampCenter:(CGPoint)c {
    CGRect b = _window.bounds;
    CGFloat half = _cursorSize / 2.0 + 12; // 给隐藏按钮留出边缘余量
    c.x = MAX(half, MIN(b.size.width - half, c.x));
    c.y = MAX(half, MIN(b.size.height - half, c.y));
    return c;
}

- (void)layoutCursor {
    CGFloat d = _cursorSize;
    _cursorView.frame = CGRectMake(_cursorCenter.x - d/2, _cursorCenter.y - d/2, d, d);
    _cursorView.layer.cornerRadius = d/2;
    _cursorView.backgroundColor = [UIColor colorWithWhite:0.15 alpha:0.9];
    _cursorView.layer.borderColor = [UIColor whiteColor].CGColor;
    _cursorView.layer.borderWidth = 2;

    _hideButton.frame = CGRectMake(_cursorCenter.x + d/2 - 14,
                                   _cursorCenter.y - d/2 - 14, 22, 22);
    _hideButton.layer.cornerRadius = 11;
}

// ---------- 模拟点击（IOHIDEvent 注入） ----------
- (void)clickAt:(CGPoint)pt {
    // 注入期间让悬浮层不拦截触摸，注入的触摸会落到光标下方的 App
    _overlayView.userInteractionEnabled = NO;

    [self injectTouchAt:pt phase:0]; // down
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        [self injectTouchAt:pt phase:2]; // up
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.03 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{
            if (self->_cursorActive) {
                self->_overlayView.userInteractionEnabled = YES;
            }
        });
    });
}

// phase: 0=按下 1=移动 2=抬起
- (void)injectTouchAt:(CGPoint)pt phase:(int)phase {
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
        0, 0, 0, 0, 0,   // x, y, z, tipPressure, barrelPressure（double）
        true, true, 0);  // range, touch, options

    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerX, pt.x * scale);
    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerY, pt.y * scale);
    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerIndex, 0);
    IOHIDEventSetFloatValue(event, kIOHIDEventFieldDigitizerIdentity, 1);

    IOHIDEventSystemClientDispatchEvent(_hidClient, event);
    CFRelease(event);
}

@end

// ================= Logos 注入入口 =================
%hook SpringBoard

- (void)applicationDidFinishLaunching:(id)application {
    %orig;
    dispatch_async(dispatch_get_main_queue(), ^{
        [[KPCCursorManager sharedInstance] start];
    });
}

%end
