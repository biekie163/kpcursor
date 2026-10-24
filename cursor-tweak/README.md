# 便捷光标 (KPCursor) — 独立越狱插件工程

从屏幕底部上滑唤出鼠标式光标，拖动控制移动，轻点模拟点击，单手操控更方便。
iOS 15+ rootless 越狱（Dopamine 等）适用，与「快捷面板 3.1」**不冲突**（独立包名、独立配置、不占用对方文件路径）。

## 快速开始（推荐：GitHub Actions 自动构建）

1. 登录 GitHub → 右上角 `+` → **New repository** → 填名字（如 `kpcursor`）→ 选 Public 或 Private → **Create repository**；
2. 在仓库页面点 **uploading an existing file**（或 Add file → Upload files）→ 把这个工程**整个文件夹里的所有文件**拖进去 → **Commit changes**；
3. 打开仓库的 **Actions** 标签页，会自动开始构建（约 3-5 分钟）；
4. 构建显示绿色 ✓ 后，点进该次构建 → 底部 **Artifacts** → 下载 **KPCursor-deb**；
5. 解压出 `.deb` 文件，传到手机，用 **Filza** 打开安装（或 Sileo 本地安装）；
6. 到 **设置 → 便捷光标** 打开「启用功能」，选择激活方向，即可使用（无需注销）。

> 之后每次改代码推送到 GitHub，Actions 都会自动重新构建，产物直接在 Artifacts 下载。

## 本机构建（可选，WSL2 / Linux / macOS）

```bash
# 1. 安装 Theos
git clone --recursive https://github.com/theos/theos.git $THEOS

# 2. 下载 iOS SDK（放至 $THEOS/sdks）
curl -L -o sdk.tar.xz https://github.com/theos/sdks/releases/download/latest/iPhoneOS16.5.sdk.tar.xz
mkdir -p $THEOS/sdks && tar -xJf sdk.tar.xz -C $THEOS/sdks

# 3. 构建
cd 工程目录
make package FINALPACKAGE=1
# 产物在 packages/*.deb
```

## 使用说明

| 操作 | 效果 |
|---|---|
| 在激活区域（屏幕底部左侧/右侧）向上滑 | 唤出光标 |
| 手指在屏幕上拖动 | 移动光标（相对移动，速度=灵敏度/2） |
| 轻点屏幕一下 | 在光标位置模拟点击 |
| 点光标右上角 ✕ | 隐藏光标 |

## 设置项

| 设置 | 默认 | 说明 |
|---|---|---|
| 启用功能 | 关 | 总开关 |
| 激活方向 | 屏幕右侧 | 从左侧或右侧底部上滑 |
| 光标大小 | 12 | 10~30 |
| 激活高度 | 300 | 底部向上多少像素内可激活 |
| 激活灵敏度 | 90 | 上滑超过该距离才显示光标 |
| 光标灵敏度 | 4 | 3~8，移动倍率 = 值/2 |

## 技术说明与已知限制（重要）

- **实现方式**：只注入 `SpringBoard` 进程，悬浮窗口层级高于 App，所以桌面和任意 App 内都能显示；
- **模拟点击**：通过 `IOHIDEventSystemClient` 注入合成触摸事件，点击坐标按屏幕像素换算。这是本插件最需要真机验证的部分：
  - 若点击无反应：确认光标下确实是可点击的控件；查看 SpringBoard 日志（`log stream --predicate 'process == "SpringBoard"'`）确认没有报错；
  - 若点击位置偏移：`Tweak.xm` 中 `pt.x * scale` 的坐标换算可能需要按机型调整；
- **激活区域占用**：启用后，激活方向那一半屏幕的底部区域会被插件截获用于唤出光标（与同类插件一致），可通过调小「激活高度」减小影响；另一侧系统手势不受影响；
- **系统手势**：若与 App 切换/返回桌面的底部手势冲突，请换另一侧激活或调小高度；
- 锁屏界面 / 部分系统弹层可能不响应光标，属预期行为。

## 调试建议

- 装好后先用 Sileo/Zebra 查看是否正常加载（设置里有「便捷光标」入口 = 注入成功）；
- 功能异常时抓取崩溃日志：设置 → 隐私 → 分析与改进 → 分析数据，找 `SpringBoard` 相关的崩溃；
- 首次开发建议在**备用机**上测试，避免影响主力机使用。

## 风险提示

仅供个人学习研究使用；越狱及安装第三方插件存在一定风险，请自行评估并做好备份。
