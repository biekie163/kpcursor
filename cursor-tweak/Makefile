# Makefile — 便捷光标 (KPCursor)
# 使用 Theos 构建；rootless 打包方案（Dopamine / iOS 15+ 适用）

# ---- rootless 打包方案（关键，勿删）----
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
# 必须同时出 arm64e：A12 及以上机型的 SpringBoard 是 arm64e 进程，
# 只编 arm64 的话 dylib 根本不会被加载（表现为「装了完全没反应」）。
ARCHS = arm64 arm64e

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
