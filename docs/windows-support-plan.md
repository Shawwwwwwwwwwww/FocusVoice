# Windows 支持评估（v0.10.6）

## 结论

**当前 FocusVoice 是 macOS 原生应用，不能直接编译出 Windows 版本。**

代码依赖：

- Swift / SwiftUI / AppKit（`NSStatusItem`、`NSPanel`、`NSGlassEffectView`）
- macOS Accessibility API（`AXUIElement`、焦点输入框定位）
- CoreGraphics 事件注入（⌘V 粘贴、全局鼠标长按）
- ScreenCaptureKit / AVAudioEngine / Speech
- macOS 专用 dylib（sherpa-onnx darwin arm64）

这些在 Windows 上没有等价实现，无法用现有工程“打个 Windows 包”。

## 可行的 Windows 路线

推荐 **Tauri 2（Rust）+ sherpa-onnx C API**：

| 模块 | macOS 现状 | Windows 对应 |
|---|---|---|
| 外壳 | SwiftUI/AppKit | Tauri 2 + WebView2 |
| 全局按键/长按 | CGEvent + NSEvent | `rdev` / `windows` crate 低级钩子 |
| 前台输入框 | AXUIElement | UI Automation (UIA) |
| 粘贴 | CGEvent ⌘V | `SendInput` Ctrl+V |
| 音频 | AVAudioEngine | WASAPI / cpal |
| 识别 | sherpa-onnx C API | 同一 C API（win-x64 dll） |
| 模型下载 | URLSession | reqwest，同一套模型 URL |
| 托盘/浮层 | NSStatusItem/NSPanel | Tauri Tray + 无边框置顶窗口 |

工程估算：外壳重写 + 音频/输入法注入 + 打包（NSIS/MSI）约 **1–2 周**；识别内核可复用 sherpa-onnx 和下载逻辑。

## 当前可复用资产

- SenseVoice 模型下载地址、校验与安装目录逻辑（可移植到 Rust/Node）。
- 音效资源（`Resources/Sounds`）与音效目录。
- 声纹视觉规范、设置页信息架构。
- 模型不随安装包分发的轻量化策略。

## 状态

**Windows 端尚未实现**，本文档是迁移方案，不是交付声明。若确认要做，建议先做一个最小 Windows 原型：托盘 + 长按录音 + 本地 SenseVoice 转写 + Ctrl+V 插入。
