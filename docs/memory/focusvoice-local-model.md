---
name: focusvoice-local-model
description: 本机可用的本地语音模型与运行时位置：Memo 的 ggml-large-v3.bin 及 sherpa-onnx
  模型，whisper.cpp 运行时在 Memo.app 内
metadata:
  node_type: memory
  type: reference
  originSessionId: session_a29a32b8bef6aa6af109aee1e17c99bd
---

本机（Apple M4 Pro / 48 GB / macOS 26）已有的本地语音资源：

- whisper.cpp 模型：`~/Library/Application Support/Memo/models/ggml-large-v3.bin`（2.9 GB，用户说的"V3 large"就是它），同目录还有 `ggml-tiny.bin`。
- sherpa-onnx 模型：`~/Library/Application Support/Memo/models/sherpa-onnx-whisper-large-v3/`（ONNX int8，带 test_wavs 测试音频）；压缩包在 `~/Downloads/memo_download/sherpa-onnx-whisper-large-v3.tar.bz2`。
- whisper.cpp 1.8.6 运行时（whisper-cli / whisper-server / dylibs，带 Metal）位于 `/Applications/Memo.app/Contents/Resources/addon/whisper/bin/1.8.6/`，仅用 `@loader_path` 依赖，可复制出来单独使用。
- 本机**没有安装** Homebrew、whisper.cpp 可执行文件、本地 LLM（Ollama/LM Studio 均无响应）。

实测性能：large-v3 冷启动加载约 1–2 秒，常驻 server 热转写 4.6 秒中文音频约 2–3 秒；每次 App 会话首次识别（加载 2.9 GB 模型）约 5–10 秒；CLI 路径单次约 7–8 秒。

相关：[[focusvoice-project]]
