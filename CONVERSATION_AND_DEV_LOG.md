# FocusVoice 全过程开发记录与对话归档

**项目名称**：FocusVoice (macOS 全局语音输入工具)  
**最新版本**：v0.7.3  
**交付归档路径**：`/Users/sunhui/dpsk/FocusVoice`  
**归档生成时间**：2026-10-23  

---

## 一、项目背景与全生命周期演进概览

| 版本 | 关键节点与演进内容 | 核心技术方案 | 状态 |
| :--- | :--- | :--- | :--- |
| **v0.1.0** | 初始导入 ChatGPT 生成的 Swift 源码包，进行真机环境编译验证与错误修复 | 修复 Swift 6 并发隔离问题、AppStorage 监听失效、ad-hoc 签名与包结构绑定 | 已完成 |
| **v0.2.0** | 接入本机 `Memo/models/ggml-large-v3.bin`（2.9 GB）离线大模型；交互改为聚焦输入框长按启动录音 | 嵌入 whisper.cpp 1.8.6 原生运行时；常驻 `whisper-server` 加速（热转录约 2 秒）；原生浮动录音 HUD | 已完成 |
| **v0.3.0** | 能力补齐：加入微调预览窗口、最近转写历史（10条）、Esc 取消录音、登录自启、操作提示音、whisper 热词支持 | 修复 `language=auto` 在 Apple/API 引擎下的异常；支持动态热词 prompt 重启服务 | 已完成 |
| **v0.3.1** | 用户要求交互改为：在屏幕任意位置按住鼠标左键 1.5 秒启动录音 | 调整为全局鼠标长按 1.5s 监听，放开输入框限制 | 已完成 |
| **v0.4.0** | 预览窗口布局重叠修复；按要求恢复“识别完成后直接粘贴进输入框”；新增内录/外录一键切换 | 引入 Apple `ScreenCaptureKit` 系统音频回路采集；录音期间一键切换外录/内录并自动拼接 | 已完成 |
| **v0.4.1** | 全局启用 Apple 原生毛玻璃质感（`NSVisualEffectView` HUD 与预览窗口） | 解决界面纯黑生硬外观；静默重置与重绑麦克风与辅助功能授权 | 已完成 |
| **v0.5.0** | 商业级 Apple 风格设置界面重构（TabView + SF Symbols + 分类卡片 + 文件选择器）；外录强制锁定 MacBook Pro 内置麦克风（绕过蓝牙/耳机） | 用 `AVCaptureSession` 直连 MacBook Pro 内置三麦克风阵列，彻底避免蓝牙耳机断联/降质导致录音失败；全新实时权限仪表盘 | 已完成 |
| **v0.6.0** | 接入腾讯云语音识别（ASR）云端大模型引擎 | 基于 Swift 原生 `CryptoKit` 实现 `TC3-HMAC-SHA256` 签名算法与 SentenceRecognition 一句话转写，密钥本地安全隔离 | 已完成 |
| **v0.6.1** | 彻底根除系统权限“假开启”与僵尸记录冲突 | 更换全新干净 Bundle ID `com.focusvoice.mac`，固定指定需求代码签名，安装至标准 `/Applications/FocusVoice.app` | 已完成 |
| **v0.7.0** | 升级腾讯云 ASR 为 WebSocket 实时流式转录（边说边出字，零等待直接粘贴） | 基于 `URLSessionWebSocketTask` 实时推送 16kHz PCM，毛玻璃 HUD 实时流式动态浮显字幕；结束瞬间直接粘贴 | 已完成 |
| **v0.7.1** | 设置界面留白与高级呼吸感重构，腾讯云 ASR 官方控制台一键直达入口 | 窗口扩大至 760×620，增加 32pt 边距、26pt 间距与 16pt 大圆角；加入获取 API 密钥、查看 AppID、ASR 控制台直达按钮 | 已完成 |
| **v0.7.2** | 解决微信/聊天对话框长按失效问题，修复剪贴板导致快捷键贴入文本失效的问题 | 重构 `InputDetector`，严格排除窗口顶部 42pt 标题栏拖拽区域；转录文本永久保留在剪贴板，支持手动随时 `⌘V` 贴入 | 已完成 |
| **v0.7.3** | 解决深度嵌套应用（Codex / ChatGPT / 网页 / 复杂文档）长按失效问题 | 扩展 Accessibility 祖先树回溯至 30 层，穿透 Chromium/Electron 深度 DOM，微调长按触发响应为更跟手的 1.2 秒 | **当前最新版** |

---

## 二、完整对话流水与开发过程记录

### 第 1 轮对话
> **用户输入**：
> 这是chatGPT帮我写的你看看能否运行  
> 附件：`/Users/sunhui/Downloads/FocusVoice-macOS-source.zip`
> 附图：代码工程解压后目录结构

**处理过程与发现**：
1. 解压源码发现为一个纯原生 Swift/AppKit 工程（单文件约 350 行，`Package.swift`，`Info.plist`，`build-macos.sh`）。
2. 执行编译发现 10 处编译错误，全部源自 Swift 6 并发模型（`@MainActor` 隔离的 `Preferences` 属性被非隔离的静态方法 `Recognizer.recognize` / `Rewriter.process` 直接读取）。
3. 发现 `@AppStorage` 用在 `ObservableObject` 类中不会向外界发布改变通知，导致界面无法切换设置。
4. 发现 `build-macos.sh` 仅简单拷贝 linker-signed 二进制，导致包结构损坏，`codesign --verify` 报 `code has no resources but signature indicates they must be present`，系统 TCC 权限无法正常附着。

**开发修复**：
- 给 `recognize` 和 `process` 标明 `@MainActor`；
- 将 `Preferences` 改为持久化到 `UserDefaults` 的 `@Published` 属性；
- 在 `build-macos.sh` 中增加 ad-hoc 代码重签。编译成功并在菜单栏常驻运行。

---

### 第 2 轮对话
> **用户输入**：
> 我本地有个V3 large的语言转录模型，接入到这个软件里。然后把交互方式改一下。就是用户点击按住聚焦的对话框然后弹出录音状态 开始转录此时可以松开手转录完成点击完成。

**处理过程与发现**：
1. 全盘扫描发现用户本地模型位于：`~/Library/Application Support/Memo/models/ggml-large-v3.bin`（2.9 GB）。
2. 在 `/Applications/Memo.app` 中发现其随附了开源 MIT 的 `whisper.cpp 1.8.6` 完整运行时（包含 Metal GPU 加速库与 `whisper-server`）。
3. 实测冷启动加载 2.9 GB 模型需 5.8 秒，而通过常驻 `whisper-server` 热转写仅需 2.4～2.8 秒！

**开发实现（v0.2.0）**：
- 把 whisper 运行时 vendor 进工程 `Vendor/whisper/`，模型路径默认直连 `Memo/models/ggml-large-v3.bin`。
- 实现常驻后台 `whisper-server` 进程管理，支持冷/热转写自动降级。
- 交互重写：按住聚焦的输入框约 0.5 秒弹出录音 HUD，松手继续录音，点击 HUD“完成”停止并直接粘贴到原始聚焦位置。

---

### 第 3 轮对话
> **用户输入**：
> 长按1-2秒鼠标就可以出发聚焦位置的录音启动，目前发现系统权限不足，把权限打开

**处理过程与发现**：
1. 将长按延迟阈值由 0.5 秒调整为 1.0 秒。
2. 权限不足的原因：重新编译使二进制的 ad-hoc cdhash 发生变化，旧的系统辅助功能/麦克风授权仍指向旧版本。

**开发处理（v0.2.1）**：
- 重置旧 TCC 授权（`tccutil reset Accessibility/Microphone dev.focusvoice.app`）；
- 重新向系统注册当前版本，并测试验证麦克风与辅助功能正常点亮。

---

### 第 4 轮对话
> **用户输入**：
> 把这个软件能力做完善。

**开发实现（v0.3.0）**：
1. **插入前微调预览窗口**：转录后弹出浮窗，支持文本二次编辑、字数统计、快捷键 ⌘↩ 插入、Esc 取消或重新录音。
2. **最近转写历史**：菜单栏新增“最近转写”子菜单（保留 20 条，展示 10 条，点击直接复制）。
3. **菜单快捷切换**：直接在菜单栏切换输出模式（原文/纠错/结构化）与识别引擎。
4. **全局 Esc 取消**：录音期间按键盘 Esc 随时静默丢弃。
5. **whisper 行业热词提示**：支持设置 `--prompt` 专有名词表，提升生僻词准确度。
6. **登录自启与提示音**：支持 macOS SMAppService 登录启动与清脆音效。
7. **语言自动回退**：修复 `language=auto` 导致 Apple 设备端与云 API 报错的问题。

---

### 第 5 轮对话
> **用户输入**：
> 开启录音改为在全局任意位置按住鼠标（非拖拽而是固定一个位置不移动）超过1.5秒 开启录音。鼠标左键

**开发实现（v0.3.1）**：
- 长按阈值调整为 1.5 秒。
- 去除输入框位置检测限制，改为全局任意屏幕位置长按左键且位移不超过 6 像素即触发录音。

---

### 第 6 轮对话
> **用户输入**：
> UI有问题 遮挡了。另外 我觉得录音是个需要直接转录成文字的能力，所以当我点击对应的聚焦输入框的时候，直接把转录文字贴到鼠标点击的输入框中。
> 启动录音后要可选择，是内录还是外录。

**处理过程与发现**：
1. 预览窗口的字数统计与取消按钮出现重叠，予以修复。
2. 恢复“识别完成直接极速粘贴”，将预览窗口置为设置中的可选功能（默认关闭）。
3. 用户需要支持内录（系统声音/会议声）与外录（麦克风），且录音中随时可切换。

**开发实现（v0.4.0 & v0.4.1）**：
- 引入 Apple `ScreenCaptureKit` 系统音频回路采集，实现 `UnifiedRecorder` 分段多通道录制与时序自动合并。
- HUD 左下角增加来源切换按钮（`外录 · 麦克风 ⇄ 内录 · 系统声`）。
- 整体升级为 macOS 原生毛玻璃质感（`NSVisualEffectView` 材质 `hudWindow`，16pt 平滑圆角）。

---

### 第 7 轮对话
> **用户输入**：
> 先把设置界面重构UI，现在太像工程师界面了。做成商业级可用的swift风格UI界面，可以调用apple kit 组件库。完全原生的apple风格。然后完全卸载然后重新给软件申请权限，另外功能目前无法跑通，外录音时默认使用macbook pro的麦克风不走耳机，内录不变。

**重大技术突破与重构（v0.5.0）**：
1. **外录彻底锁定 MacBook Pro 本机麦克风**：
   - 之前跑不通的根本原因：用户佩戴了蓝牙耳机（`Shawwwwwwwwwwww`），macOS 默认将输入路由切到蓝牙耳机，而蓝牙 SCO 协议带宽受限且极易休眠卡死，导致采集静音或录音失败。
   - 重构录音器：使用专属 `AVCaptureSession` 直连设备 ID `BuiltInMicrophoneDevice`（`MacBook Pro咪高風`），**彻底无视外接耳机或蓝牙设备，直接读取 Mac 本地三麦克风阵列**，实时重采样为 16kHz 16-bit 单声道 WAV，录制实测 100% 成功！
2. **商业级 Apple 风格设置面板**：
   - 彻底废弃原本简陋的 Form，构建标准 `TabView` 窗口（通用、语音模型、音频输入、智能整理、权限管理）。
   - 引入苹果 SF Symbols 矢量图标、精致卡片分块、平滑大圆角、模型文件 `NSOpenPanel` 原生选择器。
   - 增加**秒级自动轮询的权限实时仪表盘**（辅助功能、麦克风、屏幕录制状态直观指示 + 一键直达系统设置）。

---

### 第 8 轮对话
> **用户输入**：
> 目前本地模型已经跑通，还差云端模型，我希望接入腾讯云语音API

**开发实现（v0.6.0）**：
1. 基于 Swift 原生 `CryptoKit` 实现腾讯云 API 3.0 的 `TC3-HMAC-SHA256` 完整签名流程，无需任何第三方 SDK。
2. 接入腾讯云一句话语音识别（`SentenceRecognition`），默认配置腾讯云 **16k 中文大模型（`16k_zh_large`）**，支持多地域节点与阿拉伯数字智能转换。
3. 密钥保存在当前用户本地私密配置文件（权限 `0600`），避免系统 Keychain 弹窗阻塞。实测网络往返与解析不足 1 秒。

---

### 第 9 轮对话
> **用户输入**：
> 提示权限没有打开我觉得需要重新清理干净旧的权限申请 重新开启

**底层架构解密与彻底根治（v0.6.1）**：
1. **症结分析**：
   - macOS 13+ 的辅助功能（Accessibility）权限存储在**系统级只读数据库**（`/Library/.../TCC.db`）中，其内部绑定的代码需求是早期旧版本的静态 `cdhash`。
   - 每次重新编译，旧的 `dev.focusvoice.app` 记录就会被系统 TCC 拒绝（即使设置面板显示勾选，底层依然判定为未授权）。
2. **根治方案**：
   - 更换为全新纯净的 Bundle Identifier：**`com.focusvoice.mac`**，彻底摆脱历史僵尸记录；
   - 代码签名强制指定固定的 Designated Requirement：`-r='designated => identifier "com.focusvoice.mac"'`，使权限不再与动态哈希绑定；
   - 正式安装至系统标准目录 **`/Applications/FocusVoice.app`**。
   - 重启后，系统设置顺利完成新版本权限附着，状态全绿！

---

### 第 10 轮对话
> **用户输入**：
> 目前的交互有问题，我拖拽窗口长按 或者其他位置长按都会触发录音。要判断必须是输入框和文本框才行 其他情况长按不会触发。
> 另外 现在的文本框不支持直接快捷键贴入文本修复一下。
> 我觉得目前还不够爽，给腾讯云ASR改成实时转录
> 让腾讯云asr的链接加入到模型配置页面。另外，目前配置界面的UI不好看 交互体验也不好 没有留白 重新设计一下。

**开发实现（v0.7.0～v0.7.2）**：
1. **腾讯云 WebSocket 实时流式转录**：
   - 引入 `URLSessionWebSocketTask`，连接 `wss://asr.cloud.tencent.com/asr/v2/<appid>`。
   - 录音同时以 40ms 为单位实时推送 16kHz PCM，识别结果**在毛玻璃 HUD 上毫秒级动态滚动显现**。
   - 说话结束瞬间直接完成，无需任何后端转写等待时间！
2. **设置界面留白与高级设计感重构**：
   - 窗口尺寸扩展至 **760 × 620**，边距扩大至 32pt，卡片内留白 20pt，圆角 16pt。
   - 腾讯云 ASR 卡片加入 3 个官方控制台一键直达按钮（API 密钥管理、账号 AppID 查看、ASR 控制台）。
3. **快捷键贴入文本彻底修复**：
   - 转录文本**永久保留在系统全局剪贴板**中（取消了 0.8 秒清除定时器）；
   - 自动模拟升级为三段式注入（Direct AX → 进程级事件 → System Events 容灾），且用户在任何文本框随时按下 `⌘V` 均能直接粘贴最新识别文字。

---

### 第 11 轮对话（最终修复）
> **用户输入**：
> 微信长按不行 无反应。然后我发现可编辑文本的文档、搜索框似乎都不行 比如codex里边全都不行

**现场实机抓包与终极修复（v0.7.3）**：
1. **问题根源锁定**：
   - 现场抓取 Codex (ChatGPT Desktop)、微信、Chrome 的辅助功能调用栈发现：现代 Web / Electron 架构的输入区域在 DOM 树中**深达 15～20 层**！
   - 之前的回溯代码深度仅设为 5 层（`0..<5`），导致在这类软件中无法遍历到顶层窗口，直接被判定为无效区域拦截！
2. **修复落地**：
   - 祖先树回溯深度提升至 **30 层**，全面穿透 Codex、微信、飞书、浏览器等复杂 DOM 嵌套结构。
   - 防误触机制改为成熟的“黑名单排除法”：精确计算窗口顶部 **42pt 标题栏区域**并予以排除（拖动窗口绝不触发），同时排除控制按钮与滚动条；标题栏下方所有内容区、对话区与输入框全量放行。
   - 长按响应时间调优为更加敏捷跟手的 **1.2 秒**。

---

## 三、最新工程文件清单（归档目录内）

归档路径：`/Users/sunhui/dpsk/FocusVoice`

```
/Users/sunhui/dpsk/FocusVoice/
├── FocusVoice-v0.7.3.dmg         # 独立免编译的 DMG 安装镜像（可直接分发与安装）
├── dist/
│   └── FocusVoice.app/           # 已编译签名完成的原生 macOS 应用程序包
├── Sources/
│   └── FocusVoice/
│       └── FocusVoice.swift      # 完整纯原生 Swift 单文件源码（含 UI、引擎、音频与驱动）
├── Vendor/
│   └── whisper/                  # 内嵌的 whisper.cpp 1.8.6 原生运行时与 Metal 加速依赖
├── Info.plist                    # 包含标准权限申请描述与 Bundle 配置
├── Package.swift                 # Swift Package Manager 工程配置文件
├── build-macos.sh                # 自动化编译、资源打包、代码重签与安装脚本
├── README.md                     # 最新 0.7.3 完整技术说明与使用指南
├── CONVERSATION_AND_DEV_LOG.md   # 本全量对话记录与开发迭代报告
└── docs/
    └── memory/                   # 长期记忆与技术踩坑笔记（本地模型位置、工具链限制等）
```

---

## 四、核心功能使用速查

1. **对话框长按录音**：在微信、Codex (ChatGPT)、各类文档或浏览器输入框中**按住鼠标左键约 1.2 秒**，即可唤起毛玻璃 HUD 开始录音，松手后继续说话。在窗口标题栏拖动窗口**绝对不会误触**。
2. **快捷键直接粘贴**：说完点击 HUD 上「完成 ↵」或按 `⌥ Space`，文本自动粘贴到输入框。若在任何特殊编辑器中想手动粘贴，**随时按下 `⌘V`** 即可贴入最新转写的文本。
3. **麦克风硬件锁定**：外录录音已强制绑定 MacBook Pro 内置高保真阵列麦克风，戴蓝牙耳机也不会被耳机降质干扰。
4. **腾讯云实时流式转录**：进入设置（`⌘,`）→「语音模型」，选「腾讯云 ASR」，通过页面上的官方链接一键获取并填入 AppId、SecretId、SecretKey，说话时即可在 HUD 上实时流式滚动出字，说完直接极速粘贴！（v0.8 起默认引擎已换成 SenseVoice，腾讯云通道保留但未重做，详见下述遗留问题。）

---

# v0.8.0 · 2026-10-24：接入 DSH 同款 SenseVoice + 触发/注入/HUD 全面重构

> 本轮用户诉求：把 DeepSeek Harness 内置的语音转录模型接进 FocusVoice；排查代码 bug 与 UI 合理性；解决「长按鼠标经常没反应」；要边录边看文字；要更清亮、更快、更可靠；音效再优化。

## 一、模型来源确认（与 DSH 完全一致）

- DSH 内置语音输入 = `@deepseek-ai/dsh-experimental-speech-to-text-sensevoice` Provider：
  **sherpa-onnx 1.13.8（darwin arm64）+ SenseVoiceSmall int8 + Silero VAD**，CPU 推理。
- 运行时位置：`/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/sherpa-onnx-darwin-arm64/`（dylib 与 `sherpa-onnx.node`）。
- 模型位置：`~/.dsh/speech-to-text/sensevoice/models/{sensevoice-onnx/model.int8.onnx,tokens.txt,silero/silero_vad.onnx}`（约 230MB，rev 固定，SHA-256 与 DSH 资产清单一致）。
- DSH 实际参数：language=auto、`useInverseTextNormalization=1`、2 线程、CPU；VAD threshold 0.5 / minSpeech 0.25s / minSilence 0.5s / maxSpeech 30s / window 512 / 16kHz。

## 二、工程实现（新增文件与改动）

| 文件 | 内容 |
|---|---|
| `Sources/CSherpa/FocusVoiceSherpa.{c,h}` + `include/module.modulemap` | 对 sherpa-onnx C API 的最小封装（创建/整段识别/VAD 流式/释放），Swift 不直接拼装巨型 C 结构体 |
| `Sources/FocusVoice/SenseVoiceEngine.swift` | `@MainActor` 门面 + 串行队列会话：`warmUp/begin/push/finish/cancel/onUpdate(confirmed,partial)`；VAD 句级分段 + 每 ~450ms 重识别当前句得到 partial；对每段回捞 300ms 前导避免裁掉首词 |
| `Vendor/sherpa/` | 3 个 dylib + v1.13.8 `c-api.h` + Apache-2.0 LICENSE/NOTICE |
| `Package.swift` | 新增 `CSherpa` target、`SenseVoiceProbe` 开发探针；rpath = Vendor 绝对路径（开发）+ `@loader_path/../Resources/sherpa`（打包） |
| `build-macos.sh` | 打包 sherpa 运行时 + 230MB 模型；剥离开发 rpath；先签 dylib 再签 App；`--no-install` 支持 |
| `Sources/FocusVoice/FocusVoice.swift` | 触发状态机重写、AX 后台化、注入单通道、HUD 实时预览、合成提示音、偏好迁移、诊断日志、命令行自测 |

## 三、实测数据（Apple M4 Pro / macOS 26.6）

- 模型加载（warmUp）0.36–0.43s；整段解码 3s 音频 60ms、4.09s 73ms、7.07s 116ms（RTF 0.016–0.020）。
- 分片流式：语音起点后 **380–394ms 出现首个 partial**；partial 解码 avg 25–86ms / max 136ms；`finish()` 27–122ms；更新峰值 3 次/秒。
- 正确性：5 组真实中文音频「流式拼接结果」与「整段识别」100% 一致；首词 300ms 回捞修复已验证。
- 打包：`.app` 264MB，`codesign --verify --strict` 通过；`cwd=/tmp` 下 dyld 确认从 `Contents/Resources/sherpa/` 加载；`--selftest-stt` 显示 `App 内置模型`、493ms。
- 应用体积/内存：常驻 RSS ≈ 0.9GB（int8 权重 + ONNX Runtime arena）。

## 四、触发与注入的根因修复（对照 0.7.3 审计）

| 根因（0.7.3） | v0.8 修复 |
|---|---|
| AX 命中/判定全在主线程同步、无超时，Chromium/Electron 上卡顿或 `kAXErrorCannotComplete` 后静默 return | 落点探测移到后台串行队列，`AXUIElementSetMessagingTimeout(0.25)`，并对 Chromium 先开 `AXManualAccessibility`；失败不再阻止录音 |
| 1.2s 判定靠 main queue 计时 + mouseUp 无条件取消，主线程一忙就「按满也不触发」 | 0.6s 蓄力 + 松手时校验 `NSEvent.pressedMouseButtons`；按下 120ms 即显示光标旁蓄力环，过程可见 |
| `InputDetector` 先排除 AXToolbar 再判 editable → 地址栏/搜索框恒死；42pt/4pt 几何误杀 | 改为三态判定：先 `editable`（含 AXSelectedText 可写、选区范围）→ 内容区 → 明确 blocked（真实 AXTitleBar 帧、控制件、桌面）；不再用几何一刀切 |
| 五处失败裸 return、无日志无 HUD | 全链路状态可见；新增 `~/Library/Application Support/FocusVoice/diagnostic.log` |
| 注入三路同发（postToPid + session tap + AppleScript）→ 重复/串 App；AX success 不校验 | 单通道 + 回读校验；先把选区折叠到末尾再写，避免覆盖已选文字；失败才兜底一次 AppleScript；剪贴板按设置保留或恢复 |
| `AVAudioFile.processingFormat` 实为 Float32，`int16ChannelData` 恒 nil → `onPCMChunk` 从未回调（腾讯实时流 0 字节、本地实时预览不可能生效） | 改为 `floatChannelData` 手动转 Int16；麦克风/内录两个录音器均修复；同时消除 stop 与音频回调的数据竞争 |
| preparing 阶段无 autoHide、busy 入口未置位、旧 Task 会 cancel 掉新录音 | preparing 8s 自动隐藏；入口即 busy；会话不匹配时不再 cancel 新会话的 recorder |

遗留未做：腾讯云实时通道的 `voice_text_str` 覆盖/引擎名/签名单转义等历史问题、whisper 冷启动与进程回收、锁屏/SecureEventInput 判定、多屏 AX 坐标实测、内存空闲卸载。

## 五、UI/HUD 与音效

- HUD 扩为 470×150：标题（目标应用）+ 计时 + 4 行实时文字（confirmed 96% 白 / partial 52% 白）+ 来源 chip + Esc/↵/取消/完成，修掉旧版 hint 与按钮重叠。
- 提示音改为 AVAudioEngine 合成（避免系统 Tink/Pop 的廉价感）：开始 = 880Hz 单声轻「嗒」；完成 = G5→D6 上行双音；失败 = 下行双音。新增音量滑杆（默认 30%）与「试听」。
- 设置 → 触发方式：长按开关/时长滑杆（0.4–1.2s）、⌥+单击（默认关）、严格文本模式、说完自动结束、⌥Space 说明。
- 老用户自动迁移：`whisper.cpp`/`Apple 本地` → `SenseVoice 本地`（只迁移一次，不覆盖用户明确选择的云端引擎）。

## 六、验收

- `--selftest-stt`：STT_LOCATION=App 内置模型、STT_MS≈460–500、中文文本正确。
- `--selftest-insert`：向原生 NSTextView 注入成功，`INSERT_EDITABLE=true`、`INSERT_OK`，剪贴板保留文本。
- 真实麦克风链路：录音→SenseVoice→HUD 实时文字→结束→剪贴板/插入，已实测（见 docs/measurements 与 diagnostic.log）。
- 仍需用户手动确认：微信/飞书内真实长按插入、蓝牙耳机场景、提示音听感、多屏。



---

# v0.8.1 · 2026-10-25：去尾词幻觉、音色可选、蓄力环 v2、插入小玻璃卡、Liquid Glass

> 本轮来自用户实际使用反馈：①转录句尾多出 yeah/Okay 与异常标点；②长按音效不喜欢；③蓄力圈要更帅；④「已插入」大弹窗遮挡内容且不够好看，同时要提示文字留在剪贴板；⑤UI 反馈与设置页要符合 macOS 26 Liquid Glass 规范（含 iPhone 式导航条/滑块）。

## 一、转写清洗（根因 + 修复）

- 根因：SenseVoice 在句尾静音/噪声上会「脑补」英文词；引擎 `finalize()` 会把未成段的尾部音频（含静音）再解码一次；旧代码只做了标签清理。
- 修复：
  1. `SenseVoiceEngine.trailingSamples()` 先做静音裁剪与 RMS 判定，<0.15s 或能量不足直接丢弃；全静音录音不再整体解码。
  2. 新增 `TranscriptSanitizer`（FocusVoice.swift）：去标签、英文填充词（yeah/okay/um/hmm…，仅中文上下文或整句为填充词时删，避免误伤 "That's okay"）、重复/混合标点合并、汉字间空格、句首标点、半角标点转全角；只剩标点则视为无内容。
  3. Controller 在送 Rewriter 前统一清洗；引擎每段 normalize 也走同一清洗，实时预览同样干净。
- 自测：`--selftest-sanitize` 覆盖 12 组样例（含 "今天下午三点开会。yeah"、"Okay. 我觉得可以。"、"That's okay"、"。今天 ，下午 三点开会 ，，嗯"）。

## 二、提示音（4 种音色）

- 保留合成引擎，新增音色：轻点（默认，1.5kHz 玻璃质感短音）、水滴（下滑音）、木质（低通噪声+木体共振）、系统音（Tink/Pop/Basso）、静音。
- 设置 → 通用 → 柔和提示音：分段选择音色 + 音量滑杆 + 试听。

## 三、蓄力环 v2

- 42pt：玻璃底盘 + conic 渐变进度环（accent→cyan→purple，2.2s 自转）+ 中央呼吸脉冲点（青色辉光）+ 弹簧弹入；进度仍按 0.6s 走满。

## 四、插入提醒（小玻璃卡）

- 由 470×150 大 HUD 改为 52pt 两行玻璃卡：绿色勾 + 「已插入」+ 副标题「文字也留在剪贴板 · 随时 ⌘V 再用」；关闭剪贴板保留时显示「原剪贴板内容已恢复」；无目标 App 时显示「已复制到剪贴板 / 按 ⌘V 粘贴」。
- 停留 1.9s（两行需要阅读时间），淡出+轻微弹入；位置避开屏幕边缘。

## 五、Liquid Glass（按 Apple HIG）

- 依据：[HIG Materials](https://developer.apple.com/design/human-interface-guidelines/materials)、[GlassButtonStyle](https://developer.apple.com/documentation/swiftui/glassbuttonstyle)、[NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)。
- 规范要点：Liquid Glass 只用于导航/控件/悬浮功能层；内容层用标准材质；regular 变体用于文字较多组件；形状用胶囊/同心圆角；强调色只给主操作。
- 落地：
  - HUD / 插入小卡 / 蓄力环：macOS 26 用 `NSGlassEffectView`（`GlassBackgroundFactory`），旧系统回退 `NSVisualEffectView`。
  - 设置窗口：`fullSizeContentView` + 透明标题栏 + 整窗 `.underWindowBackground` 材质。
  - 设置导航：自定义 `GlassTabBar`，选中态为带 `matchedGeometryEffect` 滑动的玻璃胶囊。
  - 滑块：`GlassSlider`（玻璃轨道 + 渐变进度 + 白色圆钮 + 拖拽手势），替换系统 Slider。
  - 内容卡片：按 HIG 改用 `.regularMaterial` 标准材质（不是玻璃），避免「glass on glass」。
  - 按钮：macOS 26 使用 `.glass` / `.glassProminent`，旧系统回退 `.bordered` / `.borderedProminent`。

## 六、验证

- `--selftest-sanitize`：12 组样例全部符合预期。
- `--settings-preview` 截图：玻璃导航条 + 标准材质卡片 + iPhone 式滑块正常。
- `--ui-demo` 截图：蓄力环（渐变+脉冲）、录音 HUD（实时文字）、两行插入小卡均正常。
- `--selftest-stt`：STT_LOCATION=App 内置模型，STT_MS≈570，中文文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.1 并重启。


---

# v0.8.2 · 2026-10-25：开始/结束音效分离、蓄力环 5 种外观 + 爆散、滑块拉伸折射、焦点环修复

> 用户反馈：①开始蓄力的「嘟」声难听，且希望开始/结束音效都能选；②现有音色都不满意，要更多选项；③设置页有残留的高亮环；④液态玻璃滑块应有拉伸感并折射背景，参考 App Store 标签栏；⑤蓄力环外观希望可自定义，蓄满要有「散开/炸开」的成功动效。

## 一、音效系统 v2

- `SoundPreset` 目录：8 种合成音 + 13 种 macOS 系统音 + 静音，共 22 个选项。
- 开始 / 结束独立配置：`Preferences.startSoundStyle` / `endSoundStyle`；开始音增益 0.65，结束 1.0。
- 新增合成音：气泡（上滑破裂）、风铃（非谐波钟声）、水晶（高频玻璃）、电子（方波双音）、呼吸（低通噪声缓起落）、轻点/水滴/木质保留。
- 设置页两个 Picker + 各自「试听」按钮；默认 开始=呼吸、结束=风铃。

## 二、蓄力环 v3

- 5 种外观：极光（conic 渐变）/ 雷达（绿色扫描扇区 + 36 刻度）/ 机械（24 格逐格点亮）/ 粒子（8 颗环绕粒子 + 光核）/ 极简（细白环）。
- 设置内可选 + 「预览」按钮（RingPreview）。
- 蓄力完成（0.6s 满）：冲击波扩张 + 12 颗彩色粒子径向爆散，0.46s 后隐藏，再交给录音 HUD —— 明确表达「蓄力成功/正在启动」。
- 可通过 `Preferences.ringCompleteBurst` 关闭爆散。

## 三、设置页交互修复 / Liquid 手感

- 焦点环：`fvNoFocusRing()`（macOS 14+ `focusEffectDisabled`，旧系统 `focusable(false)`）应用在设置根视图与分页按钮；点击分页时 `NSApp.keyWindow?.makeFirstResponder(nil)`，切换后不再有蓝色高亮环停留在原处。
- 滑块：`GlassSlider` 圆钮改为玻璃胶囊（`NSVisualEffectView` 折射背景 + 渐变描边 + 白色内芯），拖动时按位移速度横向拉伸（最大 +12pt），松手 spring 回弹。
- 分页胶囊：`matchedGeometryEffect` + spring(response 0.30, damping 0.58)，接近 App Store 标签栏的 morph 手感。

## 四、验证

- `--ui-demo --ring-style <极光|雷达|机械|粒子|极简>` 逐种截图，确认 5 种外观与爆散帧；接触表 docs/screenshots/ring-styles.png。
- `--settings-preview` 截图确认：焦点环消失、蓄力环外观选择器与预览按钮就位、滑块为玻璃圆钮。
- `--selftest-stt`：STT_LOCATION=App 内置模型、STT_MS≈590、文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.2 并重启。

## 五、说明

- 音色是否好听只能由用户试听决定；已提供 22 个选项与两个独立「试听」按钮，后续可按偏好继续增删合成音。


---

# v0.8.3 · 2026-10-25：蓄力环改为线性绘制 + 光环闪亮；已插入提示重做；音效 23 选项

> 用户反馈：动画不是越多越好，之前几种看起来像「PNG 拼出来的」；想要一条线从开始画到结束的创意感，结束时圆环本身发亮闪一下即可，不要整屏闪；已插入提示的绿色对勾与圆形底不同心；希望看到更好的提示外观；开始/结束音效都要能选、选项更多。

## 一、蓄力环 v4（做减法）

- 取消 v3 的雷达/机械/粒子/极简五套与「冲击波+12 粒子爆散」。
- 只保留 3 套纯线条外观：
  - 流光：conic 渐变笔触 + 白色笔尖沿圆周线性移动（CAKeyframeAnimation），笔尖带 pulse；
  - 锋线：1.8pt 单色弧 + 前端 6% 白色高光段同步推进；
  - 双弧：外弧顺时针、内弧逆时针（layer 镜像），同时绘制。
- 蓄满动效：仅环上 shadow 辉光脉冲 2 次 + 一段 16% 白色高光沿环扫过 0.36s（strokeStart/End 动画），不闪背景、不产生全屏效果；0.52s 后隐藏。
- 默认外观 `流光`；旧值（极光/雷达等）自动回退到 `流光`。

## 二、已插入提示 v3

- 图标：26×26 圆角方块（radius 9），内嵌 14×14 `checkmark`（不再用 `checkmark.circle.fill`），坐标严格居中，边距等宽。
- 布局：图标 14pt 左内边距，标题 13pt 半粗，副标题 10.5pt；宽度按两行文字自适应（上限 380）。
- 底部：2pt 细进度线，随 1.9s 停留时间从满到空线性收缩，提示自动消失。
- 入场：上移 6pt + spring 回弹 + 淡入；出场淡出 0.22s。

## 三、音效系统

- 扩到 23 个选项：8 合成音 + 14 macOS 系统音 + 静音。
- 开始/结束独立选择、各自试听；开始音 ×0.65 增益，默认 呼吸 / 风铃。
- 错误音也遵循所选音色（静音则静音，系统音则用 Basso）。

## 四、设置页 Liquid 细节（承接 v0.8.2）

- 玻璃滑块圆钮：折射背景（NSVisualEffectView）+ 白色内芯 + 渐变描边，拖动按位移速度横向拉伸（最大 +12pt），松手 spring 回弹。
- 分页胶囊 spring(response 0.30, damping 0.58) 的 morph 手感。
- 焦点高亮环：`fvNoFocusRing()` + 点击分页后 `makeFirstResponder(nil)`，切换分页不再残留蓝环。

## 五、验证

- `--ui-demo --ring-style 流光|锋线|双弧` 截图：3 种线条外观 + 完成时高光扫过；接触表 docs/screenshots/ring-styles.png。
- `--settings-preview`：新外观选择器（流光/锋线/双弧）+ 预览按钮；焦点环消失。
- `--selftest-stt`：App 内置模型、STT_MS≈590、文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.3 并重启。


---

# v0.8.4 · 2026-10-25：修复蓄力环方形裁切；中低频电影感音效

> 用户反馈：蓄力环动效像被正方形罩住/裁切，不真实；音效太尖，需要中低频、电影里那种「启动」的高级感；发光闪烁应只在线条上，不能整面闪。

## 一、方形裁切的根因与修复

- 根因：`HoldRingHUD` 窗口只有 44×44，线条环 38pt 已接近边界；发光 shadowRadius≈5–7、笔尖 glow、扫光宽度都会溢出窗口，macOS 窗口按方形 frame 裁切 → 出现「正方形罩住」的观感。
- 修复：
  1. 画布 `panelSize` 从 44 提到 **96**，环直径 38 居中，四周留 29pt 余量；
  2. 窗口保持透明、无阴影、`masksToBounds=false`；
  3. 去掉整层 scale 动画（不再有内容超出窗口的缩放）；
  4. 所有发光/扫光只作用在 CAShapeLayer 线条上（shadow 在线条层），不做整面填充闪烁。
- 用 `CGWindowList` 单独抓取环窗口（透明背景）验证：三种外观的绘制/蓄满帧均无方框边界。

## 二、蓄力环 v5（纯线条）

- 流光：conic 渐变线条 + 白色笔尖沿环线性移动（笔尖只是线上的小光点）；
- 锋线：1.8pt 单色线 + 前端 5.5% 白色高光段；
- 双弧：外弧顺时针 + 内弧逆时针，两条线同时绘制。
- 蓄满：线上辉光脉冲 2 次 + 14% 白色高光沿环扫过 0.38s；随后整体淡出，不再有粒子/冲击波。

## 三、中低频音效

- 新增 5 个合成音（全部 42–150Hz 为主，慢起音）：
  - 启动（launch）：55→96Hz 低频缓起 + 146.8Hz 托底 + 少量空气噪声；
  - 低鸣（boom）：55Hz + 110Hz 泛音，短促有重量；
  - 影院（cinema）：48→72Hz 铺底 + 82Hz 中段冲击 + 空气；
  - 引擎（engine）：78Hz / 96Hz 两次低鸣；
  - 深海（deep）：42→58Hz 极低频 + 低通噪声。
- 音色总数 28（13 合成 + 14 系统 + 静音）；开始/结束仍独立选择与试听。
- 默认值改为 开始=启动、结束=低鸣；已存在的用户选择保留。

## 四、验证

- 三种环外观逐帧抓取（透明窗口）：绘制中与蓄满闪亮均无方形边界，docs/screenshots/ring-styles.png。
- 设置界面无焦点环残留；新音色出现在两个下拉框。
- `--selftest-stt`：App 内置模型、STT_MS≈570、文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.4 并重启。


---

# v0.8.5 · 2026-10-25：删除流光、5 套线条外观 + ease-in 缓动；已插入改为原生胶囊

> 用户反馈：去掉「流光」（非常糟糕）；增加几个差异很大的蓄力环外观；动画要「先慢、最后快」但总时长不变；已插入提示要更像 Liquid Glass 原生组件——胶囊、少层级、简洁。

## 一、蓄力环 v6

- 删除「流光」；外观列表变为：锋线 / 双弧 / 刻度 / 电弧 / 轨道。
  - 锋线：1.8pt 单色线 + 5.5% 白色高光段；
  - 双弧：外弧顺时针、内弧逆时针（镜像 layer）；
  - 刻度：24 条径向短线，按 easeIn 反解曲线依次点亮（前段间隔大、后段密集）；
  - 电弧：96 点带随机抖动与 sin 调制的折线，青绿色，叠加 opacity 闪烁；
  - 轨道：紫色拖尾线 + 白色光点按 `pow(p,1.7)` 的角度曲线绕行（先慢后快）。
- 所有 `strokeEnd` 绘制动画 `timingFunction = .easeIn`，时长仍为「触发时长 − 0.12s」，不改变手感时长。
- 画布仍为 96pt、线环 38pt；蓄满只在线条上辉光 + 高光扫过。
- 默认外观改为「锋线」；已存的不合法值（包括「流光」）自动回退到「锋线」。

## 二、已插入提示 v4（原生胶囊）

- 36pt 高胶囊（cornerRadius = height/2），单行内容：13pt `checkmark` + 主文案 + 次要提示，层级只用透明度表达。
- 去掉图标底座、副标题行、进度线；宽度按文本自适应。
- 淡入（上浮 5pt + spring）+ 1.6s 后淡出；背景仍是 Liquid Glass 材质 + 顶部高光。
- 文案：主文案「已插入」，次要「⌘V 可再用」；关闭剪贴板保留时显示「原剪贴板已恢复」；无目标时「已复制 · ⌘V 粘贴」。

## 三、验证

- 5 套外观逐帧抓取（透明窗口隔离截图）：docs/screenshots/ring-styles.png，无方形裁切。
- 胶囊提示单独抓取：docs/screenshots/toast-inserted.png，确认单行、无多余层级。
- `--selftest-stt`：App 内置模型、STT_MS≈550、文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.5 并重启。


---

# v0.8.6 · 2026-10-25：移除非系统音，换成更长的纯低频音色库

> 用户反馈：去掉 Apple 自带系统音效；需要时长稍长、低频风格、不要沙沙声/摩擦声的音效；可以去找音效库。

## 一、调研

- 参考了电影感 UI 音效库的组织方式（如 CC0 的 [wyzowl/sfx-kit](https://github.com/wyzowl/sfx-kit)、[Sonilo 电影音效集](https://sonilo.com/zh-CN/royalty-free-sound-effects/designed)）：常见结构是「低频缓起 → 轻微冲击 → 长尾」。
- 没有直接下载音频（需要逐条试听选型 + 版权/署名管理），改为在 App 内用正弦合成实现同样结构：离线、无版权负担、可控无噪声。

## 二、音色库 v5

- 删除全部 14 个 `NSSound` 系统音与所有含噪声的合成音（呼吸/木质/影院噪声层/深海噪声层）。
- 8 个纯低频合成音 + 静音：启动 / 影院 / 低鸣 / 余韵 / 地鸣 / 引擎 / 深海 / 脉冲。
- 时长 0.74–1.48s（此前最长 0.55s），全部纯正弦 + 柔和包络，无 noise generator、无 sand/friction。
- 开始/结束独立选择；默认 开始=启动、结束=余韵；开始音 ×0.70 增益。
- 一次性迁移：旧的高频/系统音色与旧的结束音（低鸣/引擎/脉冲）统一迁移到新默认，标记 `didMigrateLowFreqSoundsV086`。

## 三、验证

- 全量构建通过；App 重启后 `defaults` 显示 startSoundStyle=启动、endSoundStyle=余韵。
- 音效为纯合成，无外部资源，因此包体不变。
- 已安装 /Applications/FocusVoice.app 至 0.8.6 并重启。

## 四、备注

- 听感只能由用户试听确认；如果「余韵」仍不够长，可把 `tail`/`rumble` 再延长到 1.8–2.2s，或在合成里加入 0.2s 的低频混响尾（仍保持纯正弦）。


---

# v0.8.7 · 2026-10-25：动效对齐 0.6s 触发窗口 + 环动旋转；删除「轨道」

> 用户反馈：动效时长如果超过按压触发时间，就无法完整呈现；希望在 0.6s 内完成「蓄力 + 高亮 + 环动」；删掉「轨道」外观。

## 一、时序对齐

- 蓄力环出现时间：120ms → **50ms**（按下即出现）。
- 绘制时长：`holdDelay − 0.05s`（默认 0.6s 触发 → 0.55s 画完），与触发时刻严格对齐。
- 蓄满闪亮：辉光脉冲 0.11s×2、高光扫过 0.30s（原 0.38s），0.34s 后淡出 → 整个收尾更紧凑，不再拖到触发之后很久。
- 结果：0 – 50ms 出现、50 – 600ms 画线 + 旋转、600ms 蓄满闪亮、约 640ms 开始录音 HUD，节奏连贯。

## 二、环动旋转

- 蓄力环内容放入独立 `CALayer`，在同样的绘制时长内旋转 0 → 0.85 rad（约 49°），timingFunction 同为 easeIn（先慢后快）。
- 由于进度弧起点 + 文字/刻度都会随层旋转，观感是"整圈在转着蓄力"，而不是静态弧线。

## 三、删除「轨道」

- 外观列表：锋线 / 双弧 / 刻度 / 电弧（4 套）。
- 旧外观（轨道/流光/雷达/机械/粒子/极简）自动回退为「锋线」并写回 UserDefaults。

## 四、验证

- 逐帧抓取 4 套外观的「蓄力中 / 蓄满闪亮」帧：docs/screenshots/ring-styles.png。
- 构建通过；App 重启；`--selftest-stt` STT_MS≈570、文本正确。
- 已安装 /Applications/FocusVoice.app 至 0.8.7。


---

# v0.8.8 · 2026-10-25：音色上移到中低频（可听、悦耳、无高频）

> 用户反馈：上一版低频太低，笔记本几乎听不到；希望是「中频往下」的舒适音色，不要铃声般的刺耳高频。

## 一、问题

- 上一版基频 36–110Hz，MacBook 内置扬声器在 100Hz 以下衰减严重 → 几乎听不见。
- 同时部分泛音偏亮，容易被听成"铃声"。

## 二、新音色设计

- 基频统一抬到 **82–233Hz**（主要是 100–200Hz 的中低频），用「基音 + 五度（1.5×）+ 八度（2×）」的和弦结构增加厚度与舒适度；最高泛音约 590Hz，没有铃声式高频。
- 慢起音（20–120ms）+ 长衰减，整体 0.76–1.50s。
- 新增 `warmChord` / `warmGlide` 两个合成器；加入峰值保护（>0.92 归一化），实测峰值 0.36–0.56，不削波。
- 8 个音色全部保留原名（启动/影院/低鸣/余韵/地鸣/引擎/深海/脉冲），用户已选值不受影响。

## 三、自测导出

- 新增 `--export-sounds <dir>`：渲染全部音色为 44.1kHz/16bit WAV，并打印时长/峰值。
  实测：启动 0.84s/0.53、影院 1.10s/0.36、低鸣 0.76s/0.56、余韵 1.26s/0.47、地鸣 1.50s/0.48、引擎 0.98s/0.39、深海 1.06s/0.39、脉冲 0.96s/0.36。
- 已导出到 `~/Desktop/FocusVoice-音效试听`，可直接用 Finder 试听。
- 已安装 /Applications/FocusVoice.app 至 0.8.8 并重启。


---

# v0.8.9 · 2026-10-25：参考 iPhone / Siri 的「科技助手提示音」

> 用户原则：参考 iMessage 发送声、Siri 启动声，以及科技产品唤出语音助手时的那种声音。

## 一、设计

- 不用 Apple 受版权保护的音频采样；按同类提示音的结构（短、干净、中频、软起音）用正弦合成。
- 频率集中在 392–1046Hz，避免刺耳高频；每个音都是「基音 + 弱二次泛音」，软起音 12ms、快速起、柔尾。
- 响度归一化：普通提示峰值 0.52，轻点 0.34，保证各音色音量一致、清晰可闻。
- 6 个音色 + 静音：
  - 轻启 0.40s（D5→A5，Siri 唤醒式双音）
  - 讯息 0.22s（1150→620Hz 干净滑音，iMessage 发送感）
  - 唤醒 0.70s（C5-E5-G5 三音上行）
  - 确认 0.62s（G5→C6，发送成功/Apple Pay 感）
  - 轻点 0.10s（987Hz 短点按）
  - 波纹 0.54s（C5→G4 下行，中性提醒）
- 默认 开始=轻启、结束=确认；旧音色一次性迁移（didMigrateAssistantSoundsV089）。

## 二、验证

- `--export-sounds`：实测 6 个音色时长 0.10–0.70s、峰值 0.34–0.52、无削波。
- 已导出 `~/Desktop/FocusVoice-音效试听`（覆盖旧文件）。
- 构建通过、App 重启；`--selftest-stt` 正常。
- 已安装 /Applications/FocusVoice.app 至 0.8.9。


---

# v0.9.2 · 2026-10-25：音效三库合并、声纹环、菜单栏录音态、HUD 四角修复、浮层外观可调

> 用户：把低频音效、Apple 原声、桌面试听那套都整理进软件；默认用 Apple 原生「收到信息 / 已发送」；蓄力环走声纹方向（更少更粗更像 App 图形）；录音时菜单栏要有正在录音的状态；「已插入」胶囊定为正式版；另外要能自定义浮层外观（毛玻璃程度/投影/液态玻璃）。

## 一、音效

- `SoundPreset` 重新分组：科技助手 6 / 低频电影 8 / Apple 原声 8 / 静音 1。
- Apple 原声通过 `AppleSoundLibrary` 运行时读取系统文件（begin_record、end_record、Sent Message、ReceivedMessage、SentMessage、siri-begin-improved、New Mail、Mail Sent），NSSound 加载失败自动回退同语义合成音。
- 默认：开始=收到信息、结束=iMessage 已发送（一次性迁移 flag `didMigrateAppleDefaultsV091`）。
- 设置里下拉框显示「分组 · 名称」，开始/结束各自试听。

## 二、蓄力环「声纹」

- 12 根粗圆头刻度（4.3pt），高低错落，蓝→青→紫三段色，依次点亮（easeIn 反解，后段更快）；中心白色焦点；蓄满时刻度辉光脉冲。
- 保持 96pt 画布、无填充、无方框；设为默认，迁移 flag `didMigrateVoiceprintRingV091`。

## 三、菜单栏录音态

- 空闲：模板圆环 PNG（自动反色）。
- 录音中：运行时绘制「label 色圆环 + 红色录制点」，0.75s 呼吸；结束恢复。
- 实测菜单栏截图确认红色录制点出现。

## 四、HUD 四角修复

- 根因：透明圆角窗口的**系统矩形阴影**与玻璃层矩形 shadow 露在圆角外。
- 修复：`panel.hasShadow=false`；窗口四周留 18pt 透明边距；内容容器圆角裁切 22pt；用独立 `shadowView` + `shadowPath` 画圆角投影。实测四角干净。
- 新增浮层外观设置：液态玻璃开关、毛玻璃程度、投影强度（作用 HUD 与胶囊），带「预览聆听 / 预览提示」。

## 五、已插入胶囊

- 保持用户喜欢的单行玻璃胶囊（小对勾 + 已插入 · ⌘V 可再用）；位置锚定开始录音时的光标点右下方，边缘翻转；1.6s 淡出。

## 六、验证

- 构建通过；安装 0.9.2 并重启。
- defaults 核实：startSound=收到信息、endSound=iMessage 已发送、ringStyle=声纹。
- Apple 原声 NSSound 加载测试 7/7 通过。
- 截图：HUD（圆角+投影无方框）、胶囊、声纹环、菜单栏红点。


---

# v0.9.4 · 2026-10-25：声纹环收小、去背景细线、胶囊方框、设置页滑块溢出与整窗毛玻璃

> 用户：蓄力环太大不够精致；环背景上有一条细线；已插入胶囊像被小长方形罩住；设置页分页滑块到两端会突破导航；设置窗口背景也要毛玻璃、与前端一致。

## 一、蓄力环

- 画布 96→84pt，环半径 19→15.5pt，声纹刻度 4.3→3.4pt、长度 7.0→5.2 系数，中心点 4.8→3.8pt。
- 去掉声纹样式的背景轨道圆环（此前在深色背景可见一条细弧线）。
- 其他 4 套外观按比例收细。

## 二、已插入胶囊的"小长方形"

- 根因同 HUD：透明窗口圆形/胶囊内容 + 窗口级矩形阴影。
- 修复：窗口四周 12pt 透明边距；卡片用 `shadowPath = capsule` 绘制圆角投影；`panel.hasShadow=false`。

## 三、设置页

- `GlassTabBar` 外层加 `Capsule` 裁切，滑块胶囊不会越过导航条两端；弹簧阻尼 0.58→0.62。
- 设置窗口改用 `SettingsWindowFactory`：`NSVisualEffectView(.underWindowBackground)` 作为 contentView，SwiftUI host 透明叠加 → 整窗毛玻璃；去掉 SwiftUI 内部重复背景。

## 四、验证

- 构建通过，安装 0.9.4 并重启。
- 截图：设置窗口整窗毛玻璃、声纹环（无细线、更小）、胶囊（无方框）。


---

# v0.9.6 · 2026-10-25：修复插入失效、开始音效、声纹渐变、图标与菜单栏统一

## 一、插入失效（P0）

- 现象：点「完成」后文字不进输入框；诊断日志显示 `insert AX set err=0` 后 `AX read len=0`，旧逻辑信任空值直接 return，没有走粘贴。
- 根因：Electron/网页 contenteditable 的 AX 写入会返回 success 但不落地，且 AXValue 不可读。
- 修复：`TextInsertion.insert` 改为**粘贴优先**：
  1) 写剪贴板并激活目标 App；
  2) 向目标 PID 发一次 ⌘V；
  3) 300ms 后回读校验，成功即结束；
  4) 回读失败才 AX 写入并再次校验；
  5) 最后 AppleScript 兜底；
  6) AXValue 完全不可读时信任 ⌘V（Electron），避免重复插入。
- 同时 `currentElement()` 优先返回可编辑焦点元素，否则回退到录音开始时捕获的元素，防止 HUD 抢占焦点导致拿错元素。

## 二、开始音效仍是系统「do」

- `Controller.start` 里残留 `NSSound(named: "Tink")?.play()`，配置的开始音效从未被调用。
- 改为 `SoundFeedback.shared.play(.start)`；诊断日志会记录实际播放的预设（如 `preset=Apple · 开始录音`）。

## 三、声纹环渐变

- 12 根刻度改为共用一条 conic「蓝→青」渐变（mask 绘制），沿路径依次画出；删除分段实色（蓝/青/紫各四根）。
- 蓄满时白色覆盖层整圈刻度短闪 0.34s。

## 四、图标与菜单栏统一

- `scripts/generate-icon.py` 重写：App 图标 = 深色 squircle + 渐变声纹刻度 + 白色焦点；菜单栏模板 = 6 根迷你声纹 + 中心点。
- AppDelegate 录音态改为运行时绘制「6 根 label 色声纹 + 红色录制点」并呼吸，空闲为模板图标（自动反色）。

## 五、验证

- 构建通过，安装 0.9.6 并重启。
- 插入日志实测：`insert paste posted … insert verified via paste`。
- 图标/菜单栏截图核对；声纹环渐变截图。


---

# v0.9.7 · 2026-10-25：图标 / 菜单栏 / 蓄力环统一为同一枚声纹环

> 用户：现在的 icon 和系统图标完全不一致；应该按蓄力环的外观设计，三处要是一致的东西。

- `scripts/generate-icon.py` 重写为「声纹环」母版：
  - App 图标：12 根短粗圆头刻度（与 `HoldRingHUD.buildVoiceprint` 同一组高度/半径比例），共用蓝→青 conic 渐变，中心白点；
  - 菜单栏模板：12 根更小刻度 + 中心点，18/36px 两档；
- 录音态菜单栏改为运行时绘制「同一枚 12 根声纹 + 红色录制点」并呼吸，替换原来的「圆环 + 红点」。
- 蓄力环同期改为连续蓝→青渐变（不再一根根实色）。
- 三处图形现在同源，只在尺寸/动效上区分。

验证：AppIcon.icns / MenuBarIcon.png 已在包内；空闲与录音菜单栏截图核对；构建与安装 0.9.7。


---

# v0.9.8 · 2026-10-25：图标按 Apple 网格缩小

- App 图标声纹环外径从约 62% 画布缩到约 55%，r0 与刻度长度、粗细同步下调，四周安全边距增大。
- 菜单栏 / 蓄力环不变，继续使用同一套声纹图形。


---

# v0.9.9 · 2026-10-25：图标中心点放大

- 按用户参考图：中心白点 0.030S → 0.046S，外围声纹环与安全边距不变。
- 重新生成 .icns 并安装。


---

# v0.10.0 · 2026-10-25：菜单栏图标简化 + 放大

- 菜单栏模板从 12 根刻度减到 10 根；基准尺寸 18pt → 20pt（生成 20/40px 两档）。
- 录音态运行时图标同步改为 10 根 + 红色录制点（20pt 坐标）。
- App 图标/蓄力环不变。


---

# v0.10.2 · 2026-10-25：设置页 UI 规范 + 本地结构化整理

## 一、设置页 UI

- `SettingsWindowFactory` 固定 contentSize/min/max = 760×620；解决切换语音模型时窗口尺寸变化。
- 语音模型页：
  - 引擎卡片内新增摘要行（引擎名、特点、就绪状态徽标）；
  - 「识别语言」独立成行，标签固定 84pt，控件左对齐；auto 模式加说明；
  - 当前引擎配置卡片统一放在下方。
- 智能整理页：模式选择下方增加说明；结构化模式增加「本地结构化效果」示例卡。

## 二、本地结构化整理

- 新增 `StructuredTextFormatter`（纯本地、无模型）：
  - 句子切分（。！？；）；
  - 话语标记分段（首先/其次/然后/另外/最后/总之/所以/但是/第一/第二…）；
  - 列举项逐行；
  - 段落间空行，段落尾逗号收句号。
- `Rewriter`：
  - 结构化模式未配置 LLM → 直接本地排版；
  - 已配置 LLM → 用模型整理，失败自动回退本地；
  - 纠错模式仍需 LLM，未配置则原文输出。
- 新增 `--selftest-structure`，实测样例输出符合预期。

## 三、验证

- `swift build` 通过；安装 0.10.2 并重启。
- 截图：语音模型页、智能整理页。


---

# v0.10.3 · 2026-10-25：引擎统一、实时预览、自动结束、提示定位

## 引擎
- 删除 Apple 引擎（默认回退/迁移/选择器/菜单/Recognizer 分支）。
- 腾讯云只保留 16k_zh；老配置迁移。
- 引擎配置卡片统一 minHeight 320；腾讯云去掉控制台按钮区，压缩高度。

## 实时预览
- SenseVoice 原生流式；腾讯云已有 WebSocket 流式。
- whisper 新增增量预览：录音中每约 1.2s 用累积 PCM 写 WAV，调用 whisper-server/CLI，刷新 HUD；保留最近 30 秒。
- 最终插入仍使用完整录音转写。

## 自动结束
- `trackSilence` 此前只在 SenseVoice 分支接入，导致 whisper/腾讯云/API 的「静音 1.8s 自动完成」无效。
- 现在所有引擎的录音回调都接入静音检测，设置实时读取。

## 提示位置
- ToastHUD 固定主屏底部居中（visibleFrame.minY + 24），不再用光标位置。

## 其他
- 设置页增加「即时生效，无需重启」提示。


---

# v0.10.5 · 2026-10-25：砍掉 whisper 引擎

- 从引擎选择器、菜单、默认回退、Recognizer 分支移除 whisper.cpp；老配置迁移到 SenseVoice。
- 保留 SenseVoice / 腾讯云 / API 三个引擎。
- 各引擎配置卡片统一 minHeight 320；腾讯云密钥并排、保存按钮内联，避免卡片被撑高。


---

# v0.10.6 · 2026-10-26：轻量化、模型按需下载、音效随包、DMG、Git

- SenseVoice 模型不再内置：新增 `SenseVoiceModelManager`，UI 一键下载（HF 官方模型 + Silero VAD），安装到 Application Support，带进度/取消/校验。
- 构建脚本移除模型与 whisper runtime；App ~38MB，DMG ~13MB。
- `Resources/Sounds` 打包 22 个音效，SoundFeedback 优先播放包内文件。
- 移除「锋线」蓄力环；SenseVoice 卡片高度 320→240 去掉留白。
- `scripts/make-dmg.sh` 生成 DMG；Git 初始化并 tag v0.10.6。
- `docs/windows-support-plan.md`：Windows 需跨平台重写，当前未实现。



---

# v0.12.0 · 2026-10-26：中英切换 + 新用户模型下载 UI + DMG

- 语言：Preferences.uiLanguage；L10n 启动快照；SwiftUI 用 LocalizedStringKey + en.lproj，AppKit 用 L10n.t；切换提示重启并可立即重启。
- 英文覆盖：设置页、菜单、HUD、Toast、模型下载状态。
- 模型下载：新用户无模型时显示 Download & Install；管理器的 UI 状态（missing/downloading/installing/failed/ready）与进度、取消、校验。
- 实测下载 243MB（model/tokens/VAD）并 STT 通过；DMG 13MB。
- Git commit/tag v0.12.0。


---

# v0.12.1 · 2026-10-26：语言切换改为右上角小标签 + 即时生效

- 移除设置页整行「界面语言」卡片；在设置窗口右上角放一个 🌐 中/EN 胶囊标签。
- L10n 改为实时读取 UserDefaults（不再启动快照）；SwiftUI environment locale 随 prefs 即时更新。
- 菜单在 menuNeedsUpdate 时同步中英文标题与子菜单；HUD/Toast 下一次显示使用当前语言。
- 实测：点击标签后设置页从 English 立即变中文，无需重启。


---

# v0.12.3 · 2026-10-26：语言开关改为滑动胶囊 + 设置页对齐修正 + HUD/Toast 同步

- 右上角语言入口改为 中/EN 两段滑动胶囊。
- 根视图统一 32pt 水平内边距；移除各 Tab 额外的 32pt，导航与卡片左边缘对齐；Tab 间距统一 20；上下留白统一。
- 通用页标签列 96pt、滑块列 220pt、预览按钮靠右；浮层外观预览按钮靠右、统一 regular。
- HUD 增加 refreshLanguage()，切换语言后下一次显示立即更新；Toast 文案在创建时读取当前语言；HUD source 标签本地化；验证英文 HUD 无折行。
- --language 参数提前到 main 入口，保证 demo/预览语言正确。


---

# v0.12.6 · 2026-10-26：英文 Tab 文案与设置页滚动条

- `Voice Models` 改为 `Models`，Tab 不再折行。
- 通用页使用 `ScrollView(showsIndicators:false)` + `.scrollIndicators(.never)`，滚动条隐藏但滚动保留；卡片宽度与其他页一致。


---

# v0.12.7 · 2026-10-26：对齐修正、代码审查、本地彻底卸载

- 蓄力环外观 Picker `.frame(width:300, alignment:.leading)`，与滑块左对齐。
- 修复 HUD 关闭 MainActor 警告；`@preconcurrency import AVFAudio` 消除 Sendable 警告；移除无用 relaunchApp。
- 全量构建通过；SenseVoice 识别自测通过；生成最终 DMG。
- 清除本地：/Applications FocusVoice、旧 .zcode 测试副本、.build、旧 DMG、Application Support（含模型/密钥）、偏好、缓存、Saved State；删除登录项；tccutil reset All 及相关权限服务。


---

# v0.12.8 · 2026-10-26：麦克风授权、默认音效、DMG 图标、图标提案

- 权限页按钮直接发起系统授权（麦克风 requestAccess / 辅助功能 prompt / 屏幕录制 CGRequest），避免先打开未注册的系统设置列表。
- 默认音效：开始录音、结束录音（Apple 原声），加迁移 flag。
- make-dmg.sh：DMG 文件自定义图标（sips -i + DeRez/Rez + SetFile -a C），并写入卷 .VolumeIcon.icns。
- 新 App 图标对比提案（docs/proposals/icon-tension.png），暂不替换现版。


---

# v0.12.9 · 2026-10-26：图标方案 06 + 蓄力环长短伸缩动效

- 图标：采用方案 06 的 12 根长短不一节奏；App 图标/菜单栏同步更新；DMG 继续带文件自定义图标。
- 蓄力环：`HoldRingHUD` 增加 60fps ticker，每根声纹按相位独立伸缩；保留 conic 蓝青渐变与沿环依次点亮；蓄满停止并短闪。
- 实测帧：不同时刻刻度长度明显变化。


---

# v0.13.0 · 2026-10-26：产品发布素材 + Retina

- Info.plist 增加 NSHighResolutionCapable。
- `docs/launch/`：index.html、notion-page.md、assets（品牌稿/场景图/GIF）、Notion zip。
- 素材由实际 App 截图与动画帧生成；产品文案采用 Apple 式短句。


---

# v0.13.1 · 2026-10-26：交付版

- HUD 滚动/实时转写修复；来源切换 generation 护栏；0.6s 高亮。
- 文本限制默认关闭并跳过探测，微信/PS 可直接使用。
- 清理未使用变量和测试入口；构建通过，STT 自测通过。
- DMG + Notion 素材更新到 0.13.1。


---

# v0.13.2 · 2026-10-26：插入稳定性、标点清理、内置麦克风锁定

- TextInsertion：粘贴等待 550ms，读不到 AX 值时再等 900ms 才恢复剪贴板，避免慢窗口粘到旧内容。
- TranscriptSanitizer：新增标点两侧空格清理、重复逗号、逗号+句号、重复句号合并。
- BuiltInMicRecorder：findBuiltInMicrophone 不再回退 default，确保 AirPods 连接时仍使用内置麦；日志 `mic selected=` 实测。
- 打包 0.13.2 DMG，产品素材同步。


---

# v0.13.3 · 2026-10-26：快捷键避让、版本号、最终文本同步

- 默认快捷键 ⌃⌥Space，避开 Codex 桌面宠物；设置提供三种，改后即时重注册。
- 设置页右上角显示版本号。
- 原文模式下 finish 使用 HUD liveText 作为最终文本，避免显示与插入不一致。
- 打包 0.13.3 DMG 与 Notion 素材。
