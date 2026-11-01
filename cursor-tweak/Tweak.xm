// Tweak.xm — 便捷光标 (KPCursor) v1.0-5 PROBE
//
// 这是一个「探针」版本，唯一目的：判断上一次黑屏到底是
//   (A) dylib 根本没能被加载（dyld 绑定/签名/路径问题），还是
//   (B) 加载成功了，但我们的 SpringBoard 逻辑把系统搞死。
//
// 做法：
//   1. 注入目标从 com.apple.springboard 改成 com.apple.Preferences（设置 App）。
//      所以就算加载失败，也只是「打开设置闪退」，不会黑屏、不会需要强制重启。
//   2. 本文件里**不出现任何 IOHID 私有符号**，也不建窗口、不加手势、不 hook 任何方法。
//      换句话说：如果这一版还崩，那跟我们的业务代码一点关系都没有，
//      只可能是 dylib 的加载环节出了问题——而且崩溃日志会直接写明原因。
//   3. %ctor 里干的事只有一件：往日志里写一行，证明「我进来了」。
//
// 日志：/var/mobile/Library/Logs/KPCursor.log

#import <Foundation/Foundation.h>
#include <dlfcn.h>
#include <unistd.h>

static NSString *const KPCLogFile = @"/var/mobile/Library/Logs/KPCursor.log";

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
    NSString *kpcLine = [NSString stringWithFormat:@"[%@] [pid %d] " fmt "\n", \
        [[NSDate date] descriptionWithLocale:nil], getpid(), ##__VA_ARGS__]; \
    KPCWriteLine(kpcLine); \
    NSLog(@"[KPCursor-probe] " fmt, ##__VA_ARGS__); \
} while (0)

%ctor {
    @autoreleasepool {
        // 第一行：证明 dylib 的构造函数真的跑了。
        KPLog(@"PROBE loaded into %@", [[NSProcessInfo processInfo] processName]);

        // 第二行：把 dylib 自己的路径打出来，确认是从 /var/jb 加载的、没有被别的副本顶掉。
        Dl_info info = {0};
        if (dladdr((void *)&KPCWriteLine, &info) && info.dli_fname) {
            KPLog(@"PROBE self image: %s", info.dli_fname);
        } else {
            KPLog(@"PROBE self image: <dladdr failed>");
        }

        // 第三行：确认 substrate 兼容层在不在（ElleKit 会提供 CydiaSubstrate 这个符号）。
        BOOL hasSubstrate = (dlsym(RTLD_DEFAULT, "MSHookMessageEx") != NULL);
        KPLog(@"PROBE substrate symbol MSHookMessageEx: %@", hasSubstrate ? @"present" : @"MISSING");

        // 第四行：顺手记录几个 IOHID 私有符号在当前系统的可见性。
        // 注意：这里只用 dlsym 探测，**不链接、不调用**，所以哪怕符号不存在也不会崩。
        const char *names[] = {
            "IOHIDEventSystemClientCreateWithType",
            "IOHIDEventSystemClientCreate",
            "IOHIDEventSystemClientScheduleWithRunLoop",
            "IOHIDEventSystemClientDispatchEvent",
            "IOHIDEventCreateDigitizerEvent",
            "IOHIDEventSetIntegerValue",
            "IOHIDEventSetFloatValue",
        };
        for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++) {
            void *sym = dlsym(RTLD_DEFAULT, names[i]);
            KPLog(@"PROBE symbol %-40s %@", names[i], sym ? @"present" : @"MISSING");
        }

        KPLog(@"PROBE done");
    }
}
