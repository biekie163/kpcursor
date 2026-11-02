# Makefile — 便捷光标 (KPCursor)
# 使用 Theos 构建；rootless 打包方案（Dopamine / iOS 15+ 适用）

# ---- rootless 打包方案（关键，勿删）----
export THEOS_PACKAGE_SCHEME = rootless

TARGET := iphone:clang:latest:15.0
# 【v1.0-8 起的架构策略，别乱改】
# 1) 必须有 arm64e：A12 以上的系统进程（SpringBoard / 设置）是 arm64e，
#    arm64-only 的 dylib 根本 dlopen 不进去。1.0-7 就是这个问题：设置不崩了，
#    但插件其实没被加载（日志一个字都没有），设置页 bundle 也报「已损坏」。
# 2) 但 arm64e 切片不能带 chained fixups：Linux 上这套 Theos 工具链产出的
#    LC_DYLD_CHAINED_FIXUPS + DYLD_CHAINED_PTR_ARM64E 在 iOS 16.1.2 上验签失败，
#    dyld 一映射 ObjC 元数据就 SIGBUS / UNKNOWN_0x105（1.0-5、1.0-6 的崩溃日志）。
#    解法：强制回老式 LC_DYLD_INFO —— 链接参数 -Wl,-no_fixup_chains。
ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

# ---------- 主插件（注入 SpringBoard） ----------
TWEAK_NAME = KPCCursor
KPCCursor_FILES = Tweak.xm
KPCCursor_FRAMEWORKS = UIKit
KPCCursor_CFLAGS = -fobjc-arc -O2 -Wno-deprecated-declarations -Wno-unused-function
# IOHID* 是私有符号，靠 dynamic_lookup 在运行时解析；
# -no_fixup_chains 见文件顶部说明（arm64e 切片必须走 LC_DYLD_INFO）
KPCCursor_LDFLAGS = -undefined dynamic_lookup -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/tweak.mk

# ---------- 设置页 Bundle ----------
BUNDLE_NAME = KPCCursorPrefs
KPCCursorPrefs_FILES = KPCCursorRootListController.m
KPCCursorPrefs_INSTALL_PATH = /Library/PreferenceBundles
KPCCursorPrefs_FRAMEWORKS = UIKit
KPCCursorPrefs_PRIVATE_FRAMEWORKS = Preferences
KPCCursorPrefs_CFLAGS = -fobjc-arc
# 设置页 bundle 也要被装进 arm64e 的「设置」进程，同样不能用 chained fixups
KPCCursorPrefs_LDFLAGS = -Wl,-no_fixup_chains

include $(THEOS_MAKE_PATH)/bundle.mk

# 安装后注销，使插件生效
internal-after-install::
	install.exec "killall -9 SpringBoard"
