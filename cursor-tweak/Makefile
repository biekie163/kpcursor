# Makefile — 便捷光标 (KPCursor)
# 使用 Theos 构建；rootless 打包方案（Dopamine / iOS 15+ 适用）

# ---- rootless 打包方案（关键，勿删）----
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
# 【v1.0-7 起只编 arm64，这是刻意的，别改回去】
# 两份真机崩溃日志（Preferences-2026-11-02-*.ips）都停在 ObjC 元数据映射阶段：
#   1.0-5: +[NSString stringWithFormat:] ← KPCCursor.dylib  (SIGBUS UNKNOWN_0x105)
#   1.0-6: readClass ← map_images_nolock ← dyld4::RuntimeState::notifyLoad
# UNKNOWN_0x105 是 arm64e 指针认证（ptrauth）校验失败的典型签名。
# 拆包看过：arm64e 切片用 LC_DYLD_CHAINED_FIXUPS + DYLD_CHAINED_PTR_ARM64E，
# 而 arm64 切片用的是老的 LC_DYLD_INFO（没有 ptrauth）。
# 也就是 Linux 上这套 Theos 工具链产出的 arm64e 切片在 iOS 16.1.2 上签名验证不过，
# 只要 dyld 去映射它的 ObjC 元数据就崩 —— 跟 Tweak 写了什么无关（纯净探针版一样崩）。
# arm64 切片没有 ptrauth，在 arm64e 进程里照样能 dlopen（App Store 的 App 全是 arm64）。
ARCHS = arm64

include $(THEOS)/makefiles/common.mk

# ---------- 主插件（注入 SpringBoard） ----------
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
