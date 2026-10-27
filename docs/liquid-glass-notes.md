# Liquid Glass 落地笔记（FocusVoice v0.8.1）

> 本文件记录本轮 UI 改造的设计依据与实现取舍，避免以后「凭感觉」加玻璃效果。

## 一、查到的官方规范

- [Apple 开发者 · 设计总入口](https://developer.apple.com/cn/design/)
- [HIG · Materials（玻璃与材质）](https://developer.apple.com/design/human-interface-guidelines/materials)
- [SwiftUI GlassButtonStyle](https://developer.apple.com/documentation/swiftui/glassbuttonstyle)
- [SwiftUI GlassProminentButtonStyle](https://developer.apple.com/documentation/swiftui/glassprominentbuttonstyle)
- [AppKit NSGlassEffectView](https://developer.apple.com/documentation/appkit/nsglasseffectview)
- [AppKit NSGlassEffectView.Style](https://developer.apple.com/documentation/appkit/nsglasseffectview/style-swift.enum)

## 二、规范里最关键的三条（直接决定了我们的改法）

1. **Liquid Glass 是「功能层」材质，不用于内容层。**
   > "Liquid Glass forms a distinct functional layer for controls and navigation elements — like tab bars and sidebars — that floats above the content layer."
   > "Don't use Liquid Glass in the content layer."
   内容层（卡片、列表、设置项）应使用标准材质（`.regularMaterial` / `.ultraThinMaterial`）来表达层次。

2. **玻璃效果的变体与可读性。**
   - `regular`：标准变体，会模糊并调整背景亮度，适合文字较多的组件（弹出层、侧栏、提示卡）。
   - `clear`：高透，仅适合覆盖在图片/视频等视觉丰富背景上的组件，必要时加 35% 暗化层。
   - 我们全部使用 `regular`。

3. **只有交互/导航元素才用玻璃，且要克制。**
   - 系统组件（按钮、标签栏、工具栏）在 macOS 26 会自动获得 Liquid Glass 外观。
   - 自定义控件用 `.glassEffect()` / `NSGlassEffectView` 时要少而精；强调色只给主操作。

## 三、FocusVoice 的映射表

| 位置 | 层级 | 采用方案 |
|---|---|---|
| 录音 HUD / 插入提示小卡 / 蓄力环 | 浮动功能层 | macOS 26：`NSGlassEffectView`（cornerRadius + regular）；旧系统：`NSVisualEffectView` 毛玻璃 + 顶部 sheen + 细描边 |
| 设置窗口背景 | 窗口层 | `fullSizeContentView` + 透明标题栏 + `.underWindowBackground` 标准材质 |
| 设置导航（5 个分页） | 导航层 | 自定义 `GlassTabBar`：玻璃胶囊容器 + 选中项 `matchedGeometryEffect` 滑动胶囊（iPhone 标签栏手感） |
| 设置内容卡片 | 内容层 | **标准材质** `.regularMaterial` + 1px 白色描边（不用玻璃，避免 glass-on-glass） |
| 滑块（触发时长 / 音量） | 控件层 | 自定义 `GlassSlider`：玻璃轨道 + 渐变进度 + 白色圆钮 + 拖拽手势 |
| 主按钮（打开系统设置等） | 控件层 | macOS 26 `.buttonStyle(.glassProminent)`；旧系统 `.borderedProminent` |
| 次级按钮（试听等） | 控件层 | macOS 26 `.buttonStyle(.glass)`；旧系统 `.bordered` |

## 四、实现落点

- SwiftUI 兼容层：`fvContentCard` / `fvGlassCapsule` / `fvGlassButton` / `fvGlassProminentButton`（FocusVoice.swift）。
- AppKit 兼容层：`GlassBackgroundFactory.make(cornerRadius:tint:)`，内部 `if #available(macOS 26.0, *)` 选择 `NSGlassEffectView` 或 `NSVisualEffectView`。
- 自定义组件：`GlassTabBar`、`GlassSlider`、`WindowGlassBackground`、`ToastHUD`、`HoldRingHUD`。
- 可用性回退：工程 deployment target 仍是 macOS 13，所有 macOS 26 API 都有 availability 分支，旧系统不会崩。

## 五、验收方式（自动化 + 人工）

- 自动：`--settings-preview`（设置窗口截图）、`--ui-demo`（蓄力环 / 录音 HUD / 插入小卡截图）、`--selftest-sanitize`。
- 人工：真实长按手感、提示音听感、微信/飞书内实际插入。


## 六、v0.8.2 追加：交互细节

- **滑块拉伸**：拖动时圆钮按位移速度横向拉伸（最大 +12pt），松手 spring 回弹；圆钮使用 `NSVisualEffectView` 折射背景 + 渐变描边，模拟玻璃折射。
- **分页 morph**：`matchedGeometryEffect` + `spring(response: 0.30, damping: 0.58)`，选中胶囊在分页间滑动并带轻微回弹。
- **焦点环**：设置根视图与分页按钮统一 `focusEffectDisabled`（macOS 14+），点击分页后清除 first responder，避免高亮环残留。
- **蓄力环**：属于浮动功能层，使用自绘 CAShapeLayer/CAGradientLayer（比整块玻璃更轻），蓄满时冲击波 + 粒子爆散作为状态反馈。


## 七、v0.8.3：动画哲学

- **一个动作只表达一件事**：蓄力环只做「画线」；画满即成功，所以成功反馈是「环本身闪亮一下 + 高光扫过」，而不是粒子爆炸/整屏闪。
- 控件动效同理：滑块拉伸只发生在拖动时，松手立即回弹；分页胶囊只做位移 morph，不叠加缩放/闪烁。
- 材料层级不变：环/提示卡/导航条是功能层（玻璃），内容卡片仍用标准材质。


## 八、v0.8.4：窗口裁切与「线条发光」

- 自绘浮层必须给光效留出窗口余量：环视觉 38pt，但窗口用 96pt；阴影/扫光不会碰到窗口边界，避免「被正方形裁掉」。
- 发光要绑定到具体图层（CAShapeLayer 线条的 shadow），而不是给整个 contentView 加阴影/缩放。
- 音频同理：低频要有身体感（50–150Hz）+ 慢起音，高频只做一点点空气感，避免「哔」的电子味。


## 九、v0.8.5：胶囊与缓动

- 原生感的关键是「少层级」：一枚胶囊 = 一个材质 + 一个图标 + 一行文字；不要再叠图标底座、副标题、进度条。
- 动效统一使用 ease-in（先慢后快）表达「蓄力/启动」，比线性或 ease-out 更有力量感；总时长保持不变。


## 十、v0.8.6：声音设计原则

- 低频要「有重量但不脏」：50–150Hz 正弦 + 2 倍频泛音，避免任何 noise generator（沙沙声来源）。
- 时长比「哔」更从容：0.7–1.5s，用慢起音 + 长衰减制造电影感；开始音再乘 0.7 增益。
- 不引入外部音频文件：避免版权、署名与包体问题，也便于精确控制无噪声。


## 十一、v0.8.7：动效必须与手势时长对齐

- 手势触发的动效，时长要以「触发时刻」为截止倒排：出现延迟 + 绘制时长 ≤ 手势时长，否则用户永远看不到完整动画。
- 环动感来自「图层整体旋转」：旋转 + 进度绘制叠加，比单条静态弧更"活"，且不增加层级。
- 成功闪亮只占 0.30s，避免拖尾到录音开始之后。


## 十二、v0.8.8：中低频的可听性

- 笔记本扬声器在 100Hz 以下衰减明显：纯低频"听感高级"但实际听不到。落点应在 100–250Hz 基频。
- 用「基音 + 五度 + 八度」的和弦代替单一正弦，厚度与悦耳度都更好；泛音控制在 600Hz 内，避免铃声感。
- 导出 WAV 实测时长/峰值，是验证"时长、音量、削波"最直接的方式。


## 十三、v0.8.9：科技助手提示音

- 参考同类结构而非采样：短（0.1–0.7s）、中频（400–1000Hz）、软起音、弱泛音、干净无噪声。
- 双音/三音的上行或下行形成"唤醒 / 确认"语义；开始用上行双音，结束用上行双音（G→C），轻点用于极短反馈。
- 响度归一化到统一峰值，避免不同音色听起来忽大忽小。


## 十四、v0.9.2：透明圆角窗口的阴影陷阱

- 透明无边框窗口若开 `hasShadow`，系统阴影按**矩形窗口边界**计算，会在圆角外露出方框。
- 正确做法：`hasShadow=false`；窗口留透明边距；内容容器 `cornerRadius + masksToBounds`；用独立图层 + `shadowPath` 画圆角阴影。
- 另外：NSGlassEffectView/NSVisualEffectView 的 layer 上也别加矩形 shadow，否则同样会露出直角。
- 让用户可调「毛玻璃程度 / 投影 / 液态玻璃」时，用一层 windowBackgroundColor 蒙版模拟材质厚度，避免直接改系统材质导致不可预期。


## 十五、v0.9.4：窗口级毛玻璃与胶囊/圆角阴影

- 设置窗口：`NSVisualEffectView(.underWindowBackground)` 作为 contentView，SwiftUI HostingView 透明叠上去，才是真正的整窗毛玻璃。
- 胶囊/圆角浮层的投影：窗口开透明边距，用 `shadowPath` 指定胶囊/圆角路径，避免系统按矩形窗口投影。
- 导航条里滑动的胶囊：外层必须裁切（Capsule clip），否则弹簧过冲会越界。
