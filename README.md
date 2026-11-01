# 便捷光标 KPCursor 1.0-4

iOS 15 / 16 rootless（Dopamine）插件：从屏幕底部上滑唤出悬浮光标，拖动移动、轻点模拟点击。

> 完整的问题分析与修改理由见 [评审报告.md](评审报告.md)。

## 目录

```
cursor-tweak/
├── Tweak.xm                      # 主插件（注入 SpringBoard）
├── Makefile                      # arm64 + arm64e，rootless 打包
├── control                       # 版本 1.0-4
├── KPCCursor.plist               # 只过滤 com.apple.springboard
├── KPCCursorRootListController.m # 设置页
└── layout/                       # 资源（必须小写 layout，Theos 才能打进 deb）
    └── Library/
        ├── PreferenceBundles/KPCCursorPrefs.bundle/
        └── PreferenceLoader/Preferences/KPCCursorPrefs.plist
.github/workflows/build.yml       # Actions 自动出 deb
```

## 构建

推到 GitHub 等 Actions 产出 `KPCursor-deb-1.0-4`；本地构建：

```bash
cd cursor-tweak
make package FINALPACKAGE=1 ARCHS="arm64 arm64e"
```

## 安装与使用

1. 装 deb，注销（respring）。开关默认是**关**的。
2. 设置 → 便捷光标 → 打开开关（无需注销，即时生效）。
3. 从**屏幕底部右半边**向上滑 → 光标出现。
4. 拖动屏幕移动光标；轻点屏幕任意处 = 在光标位置点一下。
5. 点光标右上角 ✕ 或静置 20 秒退出。

## 出问题了怎么办

| 现象 | 处理 |
|---|---|
| 想立刻停用 | Filza 新建空文件 `/var/mobile/Library/Preferences/com.kpcursor.disabled`，注销 |
| 看日志 | `/var/mobile/Library/Logs/KPCursor.log` |
| 连续 3 次启动失败 | 插件会自动写出上面那个开关文件并停用自己；排查后删掉该文件即可重试 |
| 点击位置偏了 | 把 `Tweak.xm` 里 `injectTouchAt:down:` 的 `scale` 改成 `1.0` |
