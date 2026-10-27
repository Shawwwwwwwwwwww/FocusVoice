---
name: user-is-non-programmer-tester
description: 用户通过 ChatGPT 生成源码、让 ZCode 验证运行；不会自己排查编译问题，需要代理代为编译、运行并完成可自动化的验证
metadata:
  node_type: memory
  type: user
  originSessionId: session_a29a32b8bef6aa6af109aee1e17c99bd
---

用户（sunhui）开发方式：常让 ChatGPT 写完整源码包（zip），再交给 ZCode 检查"能否运行"。用户本人不直接读代码或自己排查编译错误，期望代理把工程拉起来、跑通，并给出"你现在要做什么"的具体步骤。

**How to apply:** 接到这类源码时，主动复制到工作区、修复编译问题、构建、启动，并用辅助功能接口、自测命令行参数、临时测试 App 等手段验证能验证的部分；最终结论要明确区分"已实测"和"需要用户本人操作（如系统隐私授权、麦克风）"。

相关：[[focusvoice-project]]
