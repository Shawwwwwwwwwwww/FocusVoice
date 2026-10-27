# SenseVoice 本地语音引擎接入（FocusVoice）

> 目标：FocusVoice 使用与 DeepSeek Harness 内置语音输入**完全相同**的本地模型栈
> （sherpa-onnx 1.13.8 + SenseVoiceSmall int8 + Silero VAD，纯 CPU 推理），
> 进程内常驻、支持「边说边出字」的分段落实时预览。
>
> 本文件是引擎侧契约与实测记录；`Sources/FocusVoice/FocusVoice.swift` 的控制器集成由 Lead 负责。

---

## 1. 结论速览

| 项目 | 实测值 |
|---|---|
| 运行时 | sherpa-onnx **1.13.8**（darwin arm64 预编译 dylib），ONNX Runtime CPU |
| 模型 | SenseVoiceSmall **int8**（239,233,841 B）+ Silero VAD（1,807,522 B） |
| 模型加载 | **0.36–0.46 s**（冷启动，228 MB int8） |
| 整段识别 | 3.00 s 音频 **60 ms**（RTF 0.020）；4.62 s **85 ms**（0.018）；7.07 s **116 ms**（0.016） |
| 首个 partial | 语音起点后 **380–394 ms**（目标 <700 ms） |
| partial 解码 | 平均 25–86 ms，最大 136 ms |
| `finish()` | **27–122 ms**（目标 ≤500 ms） |
| 更新频率 | 峰值 **3 次/秒**（契约 ≤5 次/秒） |
| 内存 | 冷启动加载后常驻 RSS **约 0.90 GB**（同进程先跑过整段识别时会到 1.1 GB，见 §9） |
| 正确性 | 4 组真实中文音频，流式结果与整段识别 **100% 一致**（无丢字/无重复） |
| 打包体积 | `.app` 约 **264 MB**（模型 230 MB + dylib 34 MB） |

测试机：Apple M4 Pro / 48 GB / macOS 26.6 (25G72) / Swift 6.3.3 工具链（仅 CommandLineTools，无 Xcode）。

---

## 2. Vendored 运行时（`Vendor/sherpa/`）

从 DeepSeek Harness 应用包内的 `sherpa-onnx-node@1.13.8` 预编译产物复制（只读、不再下载）：

原始位置：
`/Applications/DeepSeek Harness.app/Contents/Resources/app.asar.unpacked/dsh/node_modules/sherpa-onnx-darwin-arm64/`

| 文件 | 大小 | SHA-256 |
|---|---|---|
| `libsherpa-onnx-c-api.dylib` | 4.3 MB | `1e7d6e8eff33bda265e7b4301698f45dbbfdba53b9636b2e557cb15b61d3ebdf` |
| `libsherpa-onnx-cxx-api.dylib` | 179 KB | `6fa44b37439378aa039142d764f545bd024278cdd4401eb7a86cde337c57be26` |
| `libonnxruntime.dylib` | 29.0 MB | `a41520634cc5a2535a8fad10820072f12a877940da8b2df6de0f30b7bec4adea` |
| `include/c-api.h` | 4,723 行 | 取自 `https://raw.githubusercontent.com/k2-fsa/sherpa-onnx/v1.13.8/sherpa-onnx/c-api/c-api.h`（tag `v1.13.8` 存在，与 dylib 版本一致；`fv_sherpa_version()` 实测返回 `1.13.8`） |
| `LICENSE` | Apache-2.0 | sherpa-onnx 仓库 v1.13.8 LICENSE；onnxruntime 为 MIT（打包在 dylib 内） |
| `NOTICE.md` | — | 来源、版本、rpath 约定说明 |

三个 dylib 的 install name 均为 `@rpath/...`，且 `libsherpa-onnx-c-api.dylib` 依赖
`@rpath/libonnxruntime.dylib`。因此加载方二进制必须带 `LC_RPATH`：

- 开发（`.build/release/*`、`swift run`）：绝对路径 `<repo>/Vendor/sherpa`（由 `Package.swift` 注入）
- 打包后（`FocusVoice.app`）：`@loader_path/../Resources/sherpa`

模型文件（本机 `~/.dsh` 已有，打包时复制，不重新下载）：

| 文件 | 大小 | SHA-256（与 DSH `assets.json` 一致） |
|---|---|---|
| `sensevoice-onnx/model.int8.onnx` | 239,233,841 B | `c71f0ce00bec95b07744e116345e33d8cbbe08cef896382cf907bf4b51a2cd51` |
| `sensevoice-onnx/tokens.txt` | 315,894 B | `f449eb28dc567533d7fa59be34e2abca8784f771850c78a47fb731a31429a1dc` |
| `silero/silero_vad.onnx` | 1,807,522 B | `a35ebf52fd3ce5f1469b2a36158dba761bc47b973ea3382b3186ca15b1f5af28` |

---

## 3. 工程结构与打包布局

### 3.1 新增/修改文件

```
FocusVoice/
├── Package.swift                                   # +CSherpa target、+SenseVoiceProbe、链接参数
├── Sources/
│   ├── CSherpa/
│   │   ├── FocusVoiceSherpa.c                      # C shim 实现
│   │   └── include/
│   │       ├── FocusVoiceSherpa.h                  # C shim 公开头
│   │       └── module.modulemap                    # SwiftPM C 模块映射
│   ├── FocusVoice/SenseVoiceEngine.swift           # Swift 引擎（app target 内）
│   └── SenseVoiceProbe/main.swift                  # 开发用 C 层探针（非 app 组成）
├── scripts/
│   ├── make-test-audio.sh                          # say + afconvert 生成 16k/mono/16bit 测试音频
│   ├── build-engine-probe.sh                       # swiftc 编译引擎级探针（不占 SwiftPM 锁）
│   └── sensevoice-engine-probe/ProbeMain.swift     # 分片流式/延迟/内存实测 harness
├── Vendor/sherpa/                                  # 3 个 dylib + c-api.h + LICENSE + NOTICE.md
└── docs/sensevoice-integration.md                  # 本文档
```

`Sources/FocusVoice/FocusVoice.swift`（Lead 独占）未被本次改动修改。

### 3.2 `.app` 内布局（打包契约）

```
FocusVoice.app/Contents/
├── MacOS/FocusVoice                  # LC_RPATH 只保留 @loader_path/../Resources/sherpa
├── Info.plist
└── Resources/
    ├── sherpa/
    │   ├── libsherpa-onnx-c-api.dylib
    │   ├── libsherpa-onnx-cxx-api.dylib
    │   ├── libonnxruntime.dylib
    │   ├── LICENSE
    │   └── NOTICE.md
    └── models/sensevoice/           # 必须保留 DSH 原始嵌套层级
        ├── sensevoice-onnx/{model.int8.onnx,tokens.txt}
        └── silero/silero_vad.onnx
```

打包步骤（`build-macos.sh` 由 Lead 维护，这里记录已验证过的顺序，**顺序不能变**）：

```zsh
# 1) 资源
mkdir -p "$APP/Contents/Resources/sherpa" "$APP/Contents/Resources/models"
cp Vendor/sherpa/*.dylib "$APP/Contents/Resources/sherpa/"
cp Vendor/sherpa/LICENSE Vendor/sherpa/NOTICE.md "$APP/Contents/Resources/sherpa/"
cp -R "$HOME/.dsh/speech-to-text/sensevoice/models/sensevoice-onnx" \
      "$HOME/.dsh/speech-to-text/sensevoice/models/silero" \
      "$APP/Contents/Resources/models/sensevoice/"
# 2) 剥离开发用绝对 rpath（必须在 codesign 之前）
install_name_tool -delete_rpath "$PWD/Vendor/sherpa" "$APP/Contents/MacOS/FocusVoice" 2>/dev/null || true
# 3) 先签 dylib，再签 app
for d in "$APP/Contents/Resources/sherpa/"*.dylib; do codesign --force --sign - "$d"; done
codesign --force --sign - -r='designated => identifier "com.focusvoice.mac"' --identifier com.focusvoice.mac "$APP"
codesign --verify --strict "$APP"
```

已在临时 bundle 上端到端验证（cwd=`/tmp`，`DYLD_PRINT_LIBRARIES=1`）：
dyld 实际从 `App/Contents/Resources/sherpa/` 加载 `libsherpa-onnx-c-api.dylib` 与 `libonnxruntime.dylib`，
`codesign --verify --strict` 通过，`--selftest-stt` 返回 `STT_LOCATION: App 内置模型`、`STT_MS: 493`、文本正确。

### 3.3 `Package.swift` 关键点

- 新增 C target `CSherpa`（`publicHeadersPath: "include"`，自带 `module.modulemap`）。
- 新增开发用可执行 target `SenseVoiceProbe`（`swift run -c release SenseVoiceProbe [模型目录] [wav]`）。
- app target `FocusVoice` 依赖 `CSherpa`。
- 链接参数（三个 target 共用）：

```swift
let packageDirectory = String(#filePath.dropLast("Package.swift".count))  // 不用 import Foundation
let sherpaVendorDirectory = packageDirectory + "Vendor/sherpa"
.unsafeFlags([
    "-L", sherpaVendorDirectory,
    "-lsherpa-onnx-c-api",
    "-Xlinker", "-rpath", "-Xlinker", sherpaVendorDirectory,             // 开发期
    "-Xlinker", "-rpath", "-Xlinker", "@loader_path/../Resources/sherpa", // .app 内
])
```

> ⚠️ Manifest 里**不要** `import Foundation`：SwiftPM 编译 manifest 时会在系统 clang module cache
> 里建 `Darwin` 模块，部分沙箱环境（如本工程的 DSH 会话）会因 `/var/folders/.../ModuleCache` 只读而失败。
> 用 `#filePath` + 纯字符串拼接即可得到绝对路径。
>
> 另外本沙箱里 `swift build` 的 manifest 编译会触发 `sandbox-exec: sandbox_apply: Operation not permitted`，
> 需加 `--disable-sandbox`；这是环境限制，与代码无关。

---

## 4. C shim API（`Sources/CSherpa/include/FocusVoiceSherpa.h`）

设计目的：Swift 侧不直接拼装 `SherpaOnnxOfflineRecognizerConfig`（几十个字段、多层嵌套结构体），
只用稳定的小接口。全部函数**同步、非线程安全**，必须固定在同一串行队列调用。

| 函数 | 说明 |
|---|---|
| `const char *fv_sherpa_version(void)` | 返回运行时版本字符串（实测 `1.13.8`） |
| `FVSherpa *fv_sherpa_create(model, tokens, vad, threads, maxSpeechSeconds, err, errLen)` | 加载 SenseVoice 识别器 + Silero VAD；`threads<=0` → 2，`maxSpeech<=0` → 20 s；失败返回 NULL 并写错误文本 |
| `void fv_sherpa_destroy(FVSherpa *)` | 释放（模型内存随之释放） |
| `char *fv_sherpa_recognize_float(handle, samples, n, language)` | 整段识别 16 kHz float32 PCM → malloc UTF-8；`language=NULL` 保持当前语言 |
| `char *fv_sherpa_recognize_pcm16(handle, samples, n, language)` | 同上，输入 little-endian int16 |
| `void fv_sherpa_free_text(char *)` | 释放识别文本 |
| `void fv_sherpa_stream_reset(handle, language)` | 重置 VAD、应用语言（`auto`/`zh`/`en`/`yue`/`ja`/`ko`） |
| `void fv_sherpa_stream_feed(handle, samples, n)` | 送入 PCM；完成的分段通过下面两个接口取出 |
| `int32_t fv_sherpa_stream_has_segment(handle)` | 是否有已完成分段 |
| `char *fv_sherpa_stream_take_segment(handle, *start, *n)` | 取出并**识别**最早分段（供探针/整段风格调用） |
| `int32_t fv_sherpa_stream_take_segment_audio(handle, *start, *n, **samples)` | 取出分段但**不解码**，返回 malloc 的 float 样本（引擎用它加 onset padding 后自行解码） |
| `void fv_sherpa_free_samples(float *)` | 释放分段样本 |
| `void fv_sherpa_stream_flush(handle)` | 先补 512 样本静音把缓冲尾巴推进 VAD，再 flush 出最后一段（保证不丢最后几十毫秒） |
| `void fv_sherpa_stream_clear(handle)` | 丢弃排队分段（cancel 用） |
| `int32_t fv_sherpa_stream_detected(handle)` | 当前是否处于语音中 |

内部固定参数（与 DSH `worker.js` 对齐）：

```
featConfig: sampleRate 16000, featureDim 80
senseVoice: language=auto(或会话语言), useInverseTextNormalization=1
modelConfig: numThreads=2, provider=cpu, debug=0
decoding_method=greedy_search
VAD: threshold=0.5, minSpeech=0.25s, minSilence=0.5s, windowSize=512, sampleRate=16000,
     maxSpeech=20s（DSH 为 30s，见 §9 说明）
```

---

## 5. Swift API 契约（最终版，控制器可直接调用）

```swift
@MainActor
final class SenseVoiceEngine {
    // 可用性 / 展示
    static var isAvailable: Bool { get }              // 包内模型或 ~/.dsh 缓存存在
    static var locationDescription: String { get }    // "App 内置模型" / "DSH 本地模型缓存" / "自定义模型目录" / "未找到模型"
    static var modelPathsDescription: String { get }  // 诊断用完整路径
    static func transcribeFile(_ url: URL) async throws -> String
                                                      // 整段识别（--selftest stt 用），内部独立加载一次模型

    init()
    func warmUp() async                               // 后台加载 228MB 模型；失败只写 lastError，不崩溃
    private(set) var lastError: String?               // 最近一次失败描述
    private(set) var isReady: Bool                    // 模型已常驻
    private(set) var modelLoadSeconds: TimeInterval   // 上次加载耗时
    private(set) var lastPartialDecodeMilliseconds: Double  // 诊断

    var onUpdate: ((_ confirmed: String, _ partial: String) -> Void)?
                                                      // 主线程回调，≤5 次/秒；confirmed + partial 即完整预览
    func begin(language: String = "auto")             // 开始一次会话（重置 VAD/缓冲）；可反复调用
    func push(_ pcm16: Data)                          // 16 kHz / 16-bit / mono / LE；仅入队，不阻塞主线程
    func finish() async -> String                     // flush + 尾段补识别，返回最终全文；可再次 begin 复用
    func cancel()                                     // 放弃本次会话（已产生的文本不返回）
}
```

语义约定：

- `begin` 之后 `onUpdate` 依次收到 `(confirmed, partial)`；`confirmed` 是已定稿分段拼接，
  `partial` 是当前未完成语音的临时结果；展示时用 `confirmed + partial`。
- `finish()` 返回的全文 == 最后一次 `onUpdate` 的 `confirmed`（之后 `partial` 清空）。
- `finish()` / `cancel()` 之后引擎回到可复用状态，模型不重复加载（实测再次 `begin` 到出结果 66–359 ms）。
- 未 `warmUp` 就 `begin/push` 会被忽略并把原因写入 `lastError`；控制器的正确顺序是 `warmUp` → `begin` → `push*` → `finish`。
- `push` 的入参必须是 **16 kHz、16-bit、单声道、小端** PCM；采样率不符请先转换（`transcribeFile` 内部支持任意
  AVAudioFile 可读格式并转 16k，但实时链路不做重采样）。

### 5.1 模型定位顺序

`SenseVoiceModelLocator`（引擎内）：

1. 环境变量 `FOCUSVOICE_SENSEVOICE_DIR`（测试/自定义）
2. `Bundle.main.resourceURL/models/sensevoice`（打包后的 App）
3. `~/.dsh/speech-to-text/sensevoice/models`（DSH 缓存，`swift run` / selftest 回退）

每个目录同时支持**扁平**（`model.int8.onnx` + `tokens.txt` + `silero_vad.onnx`）和
**DSH 嵌套**（`sensevoice-onnx/...` + `silero/silero_vad.onnx`）两种布局；打包使用嵌套布局。

---

## 6. 流式分段策略

```
mic PCM16 ──push──▶ 串行队列 ──▶ Float32 ──▶ Silero VAD ──┬─▶ 完成分段 ──▶ 识别一次 ──▶ confirmed
                                     │                    │
                                     └─▶ history 缓冲 ─────┴─▶ 未完成语音每 ~450ms 重识别 ──▶ partial
```

1. **confirmed（定稿）**：VAD 每切出一个完成语音段，只识别一次并缓存；相邻分段按 CJK 规则拼接
   （中文之间不加空格，ASCII 单词之间加一个空格）。
2. **partial（预览）**：对「上一个定稿段结束 → 当前」的音频重新识别。
   - 先用能量阈值（|x| > 0.008）找语音起点，向前留 150 ms，避免把长静音送去解码；
   - 解码窗口不足 350 ms 时不解码（太短会让 SenseVoice 输出单字幻觉）；
   - 节奏自适应：`interval = clamp(上次解码耗时 × 2.5, 0.45 s, 1.5 s)`；
   - 若还有 >0.5 s 音频在队列里排队（解码跟不上），本次 partial 直接跳过，防止延迟滚雪球；
   - 总更新频率另外限制在 ≤5 次/秒（`emit` 200 ms 节流 + 文本未变化不重发）。
3. **onset padding（关键修复）**：Silero VAD 触发需要累计语音，原始 `segment.start` 会晚于真实语音起点。
   DSH worker 参数 `vadOnsetPaddingSeconds=0.3` 就是为此。本引擎对**每个**分段都从 history 里回捞
   `segment.start - 300 ms` 的音频（但不越过上一个分段结束位置，因此不会重复转写）。
   实测没有这 300 ms 时：
   - 3.00 s「明天上午十点开产品评审会」→「**天**上午10点开产品评审会」
   - 4.62 s「麻烦你下班之前…」→「**伴**你下班之前…」
   - 7.07 s「我们需要在本周之前…」→「**需要**在本周之前…」
   加 padding 后三组全部与整段识别一致。
4. **finish 收尾**：`stream_flush()` 先补 512 样本静音（把 VAD 内部残留的 <32 ms 尾巴推进窗口）再 flush，
   识别最后一段；若仍有未被分段覆盖的尾巴（>125 ms）则补识别一次；若整场没有任何分段但采集到音频
   （极短语音），则整段补识别作为兜底。实测三组音频结果与整段识别 **完全一致**（无丢字、无重复）。
5. **cancel**：清空 VAD 队列与缓冲、递增会话代数；旧会话的回调因代数不匹配被丢弃，不会串到新会话。

---

## 7. 实测数据（2026-10-24，Apple M4 Pro / macOS 26.6 / 48 GB）

音频：`say -v Tingting` 合成 → `afconvert -f WAVE -d LEI16@16000 -c 1`（16 kHz / mono / 16-bit）。
所有数字来自实际运行，未做估算。

### 7.1 模型加载（冷启动）

| 场景 | 耗时 |
|---|---|
| C 探针 `fv_sherpa_create`（仅 C 层加载） | 402–458 ms |
| Swift `warmUp()`（进程干净，含 VAD） | **390 ms**（RSS 905 MB） |
| 打包后 App `--selftest-stt`（加载 + 4.09 s 识别） | 493 ms |

### 7.2 整段识别（纯解码，C 探针，不含加载）

| 音频 | 时长 | 解码耗时 | RTF |
|---|---|---|---|
| zh_3s | 3.00 s | **60 ms** | 0.020 |
| zh_4s | 4.09 s | **73 ms** | 0.018 |
| zh_5s | 4.62 s | **85 ms** | 0.018 |
| zh_7s | 7.07 s | **116 ms** | 0.016 |

（RTF = 解码耗时 / 音频时长，越小越快；同一音频重复运行波动约 ±5%）

### 7.3 分片流式（200 ms 一片、按实时节奏送入，前置 500 ms 静音模拟「按下热键后开口」）

| 音频 | 首个 partial（自语音起点） | partial 解码 avg / max | `finish()` | 流式==整段 | 更新峰值 |
|---|---|---|---|---|---|
| zh_3s (3.00 s) | 394 ms（“明天。”） | 51 / 73 ms | 61 ms | ✅ | 2 次/秒 |
| zh_4s (4.09 s) | 380 ms（“今天。”） | 61 / 96 ms | 90 ms | ✅ | 3 次/秒 |
| zh_5s (4.62 s) | 394 ms（“麻烦。”） | 68 / 102 ms | 89 ms | ✅ | 3 次/秒 |
| zh_7s (7.07 s) | 394 ms（“我们。”） | 86 / 136 ms | 122 ms | ✅ | 3 次/秒 |
| zh_short (0.85 s) | 380 ms（“好的。”） | 25 / 29 ms | 27 ms | ✅ | 3 次/秒 |

partial 序列示例（zh_4s）：
`今天。 → 今天下午。 → 今天下午3点开。 → 今天下午3点开会。 → 今天下午3点开会，记得带。 → …项目文档。`
最后一个 partial 之后 78 ms，confirmed 一次性给出完整句（VAD minSilence=0.5 s 后触发分段识别）。

### 7.4 会话复用（同一实例，模型常驻）

| 场景 | 结果 |
|---|---|
| `finish()` 后再 `begin()` 再喂 4.62 s 音频（快进） | 164 ms 出全文，MATCH |
| `cancel()` 之后 `finish()` | 返回空串（符合预期） |
| `cancel()` 再 `begin()` 复用 | 正常识别，MATCH |
| `finish()` 后再 `begin()`（zh_7s） | 352 ms 出全文，MATCH |

### 7.5 内存

| 场景 | RSS |
|---|---|
| 进程启动 | 10 MB |
| `warmUp()` 完成（干净进程） | **905 MB**（peak 905 MB） |
| 先跑过一次 `transcribeFile`（独立模型实例）再 `warmUp` | 0.87–1.11 GB（分配器未把已释放页归还系统） |
| 连续多会话（模型常驻复用） | 不再增长 |

---

原始测量日志（本次交付实际运行的 stdout）保存在 `docs/measurements/`：
`engine-probe-zh_{3s,4s,5s,7s,short}.log`、`bundle-selftest.log`。

## 8. 复现与验证命令

```bash
cd /Users/sunhui/dpsk/FocusVoice

# 1) 编译（本沙箱需要 --disable-sandbox；普通终端可省略）
swift build -c release --disable-sandbox

# 2) 生成真实中文测试音频（3s / 4.09s / 4.62s / 7.07s / 0.85s）
./scripts/make-test-audio.sh

# 3) C 层探针（验证 dylib 可加载 + 模型可识别 + VAD 分段 + 纯解码耗时）
swift run -c release --disable-sandbox SenseVoiceProbe \
    "$HOME/.dsh/speech-to-text/sensevoice/models" /tmp/focusvoice-audio/zh_4s.wav

# 4) 引擎级探针（200ms 分片实时流、首 partial 延迟、finish 耗时、会话复用、内存）
#    用 swiftc 直接编译引擎源文件，不占 SwiftPM 构建锁
./scripts/build-engine-probe.sh /tmp/focusvoice-audio/zh_4s.wav
./scripts/build-engine-probe.sh /tmp/focusvoice-audio/zh_7s.wav

# 5) 打包后验证（Lead 的 build-macos.sh 产物）
/Applications/FocusVoice.app/Contents/MacOS/FocusVoice --selftest-stt /tmp/focusvoice-audio/zh_4s.wav
#   期望：STT_LOCATION: App 内置模型 / STT_MS 约 500 / 文本正确
```

---

## 9. 已知风险与注意事项

1. **内存约 0.9 GB**：int8 权重 228 MB + ONNX Runtime CPU arena 常驻。与 DSH 内置语音输入同源，
   但作为常驻菜单栏 App 属于偏高水位。当前无「空闲卸载」逻辑（卸载后再次 `warmUp` 需 ~0.4 s）。
   若后续要降水位，可在 `SenseVoiceEngine` 增加 `unload()`（`SherpaRecognizerCore.unload()` 已就绪）。
2. **`transcribeFile` 会再加载一份模型**：它是独立实例（供 `--selftest stt`），在已经 `warmUp` 的进程里调用
   会短暂占用两份模型。实时链路不会调用它。
3. **模型 230 MB 需随包分发**：`.app` 约 264 MB；DMG 生成与传输会变慢。模型权重固定 revision，
   可用 `~/.dsh` 缓存或离线包，不要每次构建重新下载。
4. **仅 arm64 macOS**：vendored dylib 是 `sherpa-onnx-darwin-arm64`；Intel Mac 需另取 x86_64 产物。
5. **VAD 参数与 DSH 的差异**：`maxSpeechDuration` 用 **20 s**（DSH 为 30 s）。原因：partial 需要重识别
   整个未完成段，30 s 段一次解码 ~0.5 s，会让预览节奏变慢；20 s 强制切段后 confirmed 仍然完整，
   交互延迟更稳。其余参数（threshold 0.5 / minSpeech 0.25 / minSilence 0.5 / window 512）与 DSH 完全一致。
6. **onset padding 是每个分段都做**（DSH 只对每次请求的首段做）。因为流式会话里每个新分段都可能有同样的
   VAD 触发延迟；回捞范围以「上一分段结束」为下界，不会重复转写。已用 5 组音频验证无重复/无丢字。
7. **语言/ITN**：会话语言由 `begin(language:)` 指定，默认 `auto`（模型自动判别中/英/日/韩/粤），
   `useInverseTextNormalization=1`（数字/标点规范化，例：「今天下午3点」）。
8. **`push` 只接受 16 kHz PCM16**：录音回调务必按 16 kHz / 16-bit / mono / little-endian 输出；
   其它采样率需在录音侧转换，否则识别质量会明显下降。
9. **线程模型**：引擎内部单串行队列（`com.focusvoice.sensevoice.session`），解码不会跑在主线程；
   `onUpdate` 通过 `Task { @MainActor }` 回到主线程。会话状态全部队列内，跨线程只有 3 个计数字段（`NSLock` 保护）。
10. **签名**：`Contents/Resources/sherpa/` 下的 dylib 必须先单独 ad-hoc 签名再签 app，
    否则 `codesign --verify --strict` 会失败；`install_name_tool` 必须在签名前执行。
11. **构建环境**：无 Xcode，只支持 `swift build`（不能用 `xcodebuild`）；沙箱环境需 `--disable-sandbox`。
12. **`Package.swift` 里不要 `import Foundation`**（见 §3.3），否则部分沙箱环境 manifest 直接编译失败。
