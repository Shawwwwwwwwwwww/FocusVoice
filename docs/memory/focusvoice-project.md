---
name: focusvoice-project
description: FocusVoice 是用户的 macOS 全局语音输入工具；v0.10.3（2026-10-25）接入 DSH 同款 SenseVoice、Liquid Glass UI、声纹视觉、粘贴优先插入、本地结构化整理、三引擎实时预览
metadata:
  node_type: memory
  type: project
  originSessionId: session_a29a32b8bef6aa6af109aee1e17c99bd
---

用户（sunhui）2026-10-20 让 ChatGPT 生成 FocusVoice 源码，交给代理验证并持续迭代。**当前版本 0.10.3（2026-10-25）**，已安装至 `/Applications/FocusVoice.app`，工程在 `/Users/sunhui/dpsk/FocusVoice`。

## v0.8.0 架构现状（用户已确认「交互非常好」）

1. **默认识别引擎 = DSH 同款本地 SenseVoice**
   - sherpa-onnx 1.13.8（darwin arm64）+ SenseVoiceSmall int8 + Silero VAD，CPU 推理。
   - 运行时来自 DSH 的 `app.asar.unpacked/dsh/node_modules/sherpa-onnx-darwin-arm64`，模型来自 `~/.dsh/speech-to-text/sensevoice/models`（230MB，打包进 App 的 `Contents/Resources/models/sensevoice/`）。
   - 实现：`Sources/CSherpa`（C shim）+ `Sources/FocusVoice/SenseVoiceEngine.swift`（`warmUp/begin/push/finish/cancel/onUpdate`，VAD 句级分段 + ~450ms partial 重识别，首段回捞 300ms 防裁首词）。
   - 实测：加载 0.36–0.43s，4s 音频整段 73ms（RTF 0.018），首个 partial 380–394ms，finish 27–122ms，常驻 RSS≈0.9GB。
2. **触发交互**
   - 主触发：长按左键 **0.6s** + 光标旁**蓄力环**（按下 120ms 即出现），松手后继续说话；松手时校验按键仍按下，防「松手后凭空录音」。
   - AX 落点探测全部移到后台串行队列 + `AXUIElementSetMessagingTimeout(0.25)` + Chromium `AXManualAccessibility`；AX 失败**不再阻止录音**（旧版静默失败是「按了没反应」第一因）。
   - 可选：⌥+单击（默认关）、严格文本模式（默认关）、说完自动结束（默认关）、`⌥ Space` 保留。
   - 排除：真实 AXTitleBar 帧、控制件、滚动条、菜单栏、桌面；不再用「顶部 42pt」几何一刀切。
3. **注入策略**
   - 单通道：AX selectedText 写入（先折叠选区到末尾，避免覆盖已选内容）→ 回读校验 → 失败才 ⌘V 到目标 PID → 仍失败才 AppleScript 一次（旧版三路同发会重复/串 App）。
   - 剪贴板：默认保留转录文字（随时 ⌘V）；关闭后粘贴完恢复原剪贴板。
   - 非可编辑目标也会主动尝试 ⌘V（飞书/微信自绘输入框 AX 识别不到但能收粘贴）；无目标 App 才纯剪贴板兜底。
4. **HUD 实时预览**：470×150，目标 App 名 + 计时 + 4 行文字（confirmed 96% 白 / partial 52% 白）+ 来源 chip + 取消/完成；录音中可切外录/内录。
5. **提示音**：AVAudioEngine 合成（开始单声轻「嗒」880Hz，完成 G5→D6 上行，失败下行），音量滑杆 + 试听；替代系统 Tink/Pop（用户反馈系统音不好听）。
6. **诊断**：`~/Library/Application Support/FocusVoice/diagnostic.log` 记录每次 capture（focused role/editable/app）与 insert；CLI 自测 `--selftest-stt`、`--selftest-insert`、`--hud-live`、`--transcribe`。

## v0.8.1 追加（2026-10-25）

- 转写清洗：`TranscriptSanitizer`（去句尾 yeah/Okay 等英文幻觉词、重复/混合标点、汉字间空格、句首标点、控制标签）；引擎尾部静音先裁再解码，全静音不解码。
- 提示音：4 种合成音色（轻点/水滴/木质/系统）+ 静音，音量 + 试听，在设置→通用。
- 蓄力环 v2：conic 渐变光环 + 自转 + 中央呼吸点 + 弹簧弹入。
- 插入提醒：52pt 两行小玻璃卡，「已插入」+「文字也留在剪贴板 · 随时 ⌘V 再用」（关闭保留时显示已恢复）。
- Liquid Glass：按 HIG（玻璃只用于导航/控件/悬浮层，内容层标准材质）；设置页玻璃导航条 + iPhone 式滑块；HUD/Toast/Ring 在 macOS 26 用 `NSGlassEffectView`。详见 docs/liquid-glass-notes.md。

## v0.8.2 追加

- 音效：`SoundPreset` 22 项（8 合成 + 13 系统 + 静音），开始/结束独立选择并各自试听；开始音 ×0.65 增益；默认 呼吸/风铃。
- 蓄力环：5 种外观（极光/雷达/机械/粒子/极简），设置内预览；蓄满冲击波 + 12 粒子爆散（可关）。
- 设置页：移除残留焦点高亮环；分页 spring morph；滑块玻璃圆钮可按速度拉伸并回弹（折射背景）。

## v0.8.3 追加

- 蓄力环 v4：只保留 3 种「线性绘制」外观（流光/锋线/双弧），去掉粒子/冲击波；蓄满时仅圆环辉光脉冲 + 高光沿环扫过。
- 已插入提示 v3：圆角方块 + 严格居中的 checkmark；底部自动消失进度线；宽度自适应。
- 音效 23 项（8 合成 + 14 系统 + 静音），开始/结束独立选择并试听；开始音 ×0.65。
- 滑块拉伸折射、分页 spring morph、焦点环修复。

## v0.8.4 追加

- 蓄力环方框裁切修复：窗口 44→96 画布，环 38pt 居中；去掉整层缩放与填充面，发光只在线条。
- 蓄力环 v5 三外观：流光（渐变线 + 笔尖）/ 锋线（单色线 + 高光段）/ 双弧（内外反向双线）。
- 音效新增 5 个中低频合成音：启动 / 低鸣 / 影院 / 引擎 / 深海；总数 28；开始/结束独立选择与试听。
- 用户已选音色保留，不强制迁移。

## v0.8.5 追加

- 删除「流光」；蓄力环 5 种：锋线（默认）/ 双弧 / 刻度 / 电弧 / 轨道；全部 ease-in（先慢后快，总时长不变）。
- 已插入提示：36pt 原生风胶囊（小对勾 + 单行文案 + 透明度层级），去掉图标底座/副标题/进度线。
- 默认外观「锋线」，非法旧值自动回退。

## v0.8.6 追加

- 移除全部 Apple 系统音效与含噪声合成音；音色库 = 8 个纯低频合成音 + 静音（0.74–1.48s，50–150Hz，纯正弦，无沙沙声）。
- 开始/结束独立选择，默认 启动 / 余韵；旧音色一次性迁移（didMigrateLowFreqSoundsV086）。
- 参考电影 UI 音效库结构（低频缓起+轻冲击+长尾），但选择 App 内合成而非外链音频（离线、无版权）。

## v0.8.7 追加

- 蓄力环时序对齐：50ms 出现、`holdDelay−0.05s` 画完、闪亮 0.30s，整体贴合 0.6s 触发窗口。
- 环动：内容层在绘制时长内 easeIn 旋转 0→0.85rad。
- 删除「轨道」；现存 4 套：锋线（默认）/ 双弧 / 刻度 / 电弧；旧值自动回退。

## v0.8.8 追加

- 音效上移到中低频：基频 82–233Hz + 五度/八度泛音（最高约 590Hz），和弦式暖音，0.76–1.50s；峰值 0.36–0.56 不削波；无铃声高频。
- 新增 `--export-sounds <dir>` 导出 WAV 试听（已导出到 ~/Desktop/FocusVoice-音效试听）。
- 用户已选音色保留。

## v0.8.9 追加

- 音色库改为「科技助手提示音」：轻启/讯息/唤醒/确认/轻点/波纹 + 静音；频率 392–1046Hz，软起音、无噪声、无刺耳高频；响度归一（0.52 / 轻点 0.34）。
- 默认 开始=轻启、结束=确认；旧音色一次性迁移（didMigrateAssistantSoundsV089）。
- `--export-sounds` 已导出到 ~/Desktop/FocusVoice-音效试听。

## v0.9.2 追加

- 音效：科技助手 6 + 低频 8 + Apple 原声 8 + 静音；默认 收到信息 / iMessage 已发送；Apple 运行时读取并带回退。
- 蓄力环：新增「声纹」（12 根粗刻度，蓝青紫渐次点亮），默认；其余 4 种保留。
- 菜单栏：录音时圆环+红点呼吸；HUD 修复四角（18pt 边距 + 圆角 shadowPath，去矩形窗口阴影）。
- 设置新增「浮层外观」：液态玻璃开关 / 毛玻璃程度 / 投影强度 / 预览。
- 已插入胶囊定稿，锚定录音开始点。

## v0.9.4 追加

- 声纹环缩小（84pt 画布/31pt 环），删除背景轨道细线；其余外观同步收细。
- 已插入胶囊：12pt 透明边距 + capsule shadowPath，窗口不再有矩形阴影。
- 设置页分页胶囊加 Capsule 裁切；设置窗口改为 NSVisualEffectView 整窗毛玻璃。

## v0.9.6 追加

- 插入改为「⌘V 优先 + 回读校验 + AX 回退」；修复 Electron AX 假成功导致不插入。
- 删除 Controller 残留的 Tink，开始音效走用户选择。
- 声纹环改为蓝→青连续渐变；App 图标与菜单栏统一为声纹视觉。

## v0.9.7 追加

- App 图标 / 菜单栏图标 / 蓄力环统一为同一枚声纹环：同组刻度比例 + 蓝青渐变；菜单栏 12 根迷你刻度，录音态加红点。
- 蓄力环渐变视觉同步；插入粘贴优先修复与开始音效修复保持。

## v0.10.2 追加

- 设置窗口固定 760×620；语音模型页引擎摘要/语言行重排。
- 智能整理新增本地结构化（分段/换行/列举逐行）；配置 LLM 时用模型、失败回退本地。

## v0.10.3 追加

- 删除 Apple 引擎；腾讯云仅 16k_zh；引擎卡片等高。
- whisper 增加增量实时预览；S/V/Tencent/API 均接入静音 1.8s 自动结束。
- 已插入 Toast 固定主屏底部居中。
- 设置均即时生效；首次模型加载有等待。

## 已知遗留（未做，供后续迭代）

- 腾讯云实时通道历史 bug 未重做（`voice_text_str` 被覆盖只留最后一句、`16k_zh_large` 可能不在实时接口列表、签名未严格 %编码）；默认已切 SenseVoice，建议保留但弱化宣传。
- whisper 冷启动/进程回收；内存空闲卸载（≈0.9GB）；锁屏/SecureEventInput 判定；多屏 AX 坐标实测；主线程插入阶段仍有带超时的 AX 调用。

相关：[[focusvoice-local-model]]、[[focusvoice-toolchain-limits]]、[[user-is-non-programmer-tester]]
