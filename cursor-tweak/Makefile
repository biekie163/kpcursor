# Makefile — 便捷光标 (KPCursor)
# 使用 Theos 构建；rootless 打包方案（Dopamine / iOS 15+ 适用）

# ---- rootless 打包方案（关键，勿删）----
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0

# 【v1.0-9 起的架构与工具链策略，别乱改】
# 1) 必须有 arm64e 切片：A12 以上的系统进程（SpringBoard / 设置）是 arm64e，
#    arm64-only 的 dylib 根本 dlopen 不进去。1.0-7 就是这个问题：设置不崩了，
#    但插件其实没被加载（日志一个字都没有），设置页 bundle 也报「已损坏」。
# 2) arm64e 切片必须由 Apple 的 ld64 链接生成。非 macOS 工具链（Linux CI、
#    iPhone 上的 Theos）产出的 arm64e 切片，指针认证（ptrauth）签名是错的：
#    dyld 一映射 ObjC 元数据、或第一次 objc_msgSend 去取 @"字符串" 的 isa，
#    就 SIGBUS / UNKNOWN_0x105（1.0-5、1.0-6 的崩溃日志就是这个）。
#    参考：https://mikiyan1978.hatenablog.com/entry/20260730/1785340871
#    theos.dev 文档也写明「新 ABI 的 arm64e 链接需要闭源的 Apple ld64」。
# 3) 所以：构建放到 macOS（GitHub Actions 的 macos-14 runner，Xcode 自带 ld64），
#    本文件里不要再加 -Wl,-no_fixup_chains 之类的旁门左道 —— 那只关掉了
#    chained fixups，签名问题一点没解决（1.0-8 在 Linux 上直接编译失败）。
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ---------- 主插件（注入 SpringBoard / 设置） ----------
TWEAK_NAME = KPCCursor
KPCCursor_FILES = Tweak.xm
KPCCursor_FRAMEWORKS = UIKit
KPCCursor_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-function
# IOHID* 是私有符号，靠 dynamic_lookup 在运行时解析
KPCCursor_LDFLAGS = -undefined dynamic_lookup

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 Bundle ----------
BUNDLE_NAME = KPCCursorPrefs
KPCCursorPrefs_FILES = KPCCursorRootListController.m
KPCCursorPrefs_INSTALL_PATH = /Library/PreferenceBundles
KPCCursorPrefs_FRAMEWORKS = UIKit
KPCCursorPrefs_PRIVATE_FRAMEWORKS = Preferences
KPCCursorPrefs_CFLAGS = -fobjc-arc

include $(THEOS_MAKE_PATH)/bundle.mk

# 安装后注销，使插件生效
internal-after-install::
	install.exec "killall -9 SpringBoard"
