---
name: focusvoice-toolchain-limits
description: 本机只有 Command Line Tools 没有 Xcode；ChatGPT 生成的 Swift 源码踩过的坑需在编译和签名时注意
metadata:
  node_type: memory
  type: project
  originSessionId: session_a29a32b8bef6aa6af109aee1e17c99bd
---

本机开发 macOS Swift 项目的环境约束（关系到 FocusVoice 及后续同类项目）：

- 只有 `/Library/Developer/CommandLineTools`（Swift 6.3），**没有完整 Xcode**，`xcodebuild` 不可用，只能用 `swift build` 构建。
- ChatGPT 生成的 FocusVoice 源码首次无法编译：`Preferences` 标了 `@MainActor`，但非隔离的 `static func` 直接访问其属性（Swift 6 并发隔离错误）。
- 把 `swift build` 产物拷进 `.app` 后，原 ad-hoc/linker 签名失效（"code has no resources but signature indicates they must be present"），必须对整个 bundle 重新 `codesign --force --sign - --identifier ...` 后再 `codesign --verify --strict`。
- 复制带有 `.build` 的工程目录到新路径后，ModuleCache 的路径会失效，需要先删除 `.build` 再编译。
- 对 Swift 文件做局部编辑前必须先用 Read 工具读取（Edit 要求），写文件失败后读取再改。

相关：[[focusvoice-project]]
