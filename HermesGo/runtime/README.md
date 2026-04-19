# runtime

This folder contains the bundled runtime used by HermesGo.
本目录包含 HermesGo 使用的打包运行时。

## Top-level entries / 顶层条目

- `hermes-agent/`
- `python311/`
  - Bundled portable Python runtime used by HermesGo
  - Main Hermes Agent runtime, Python environment, and CLI package / Hermes Agent 主运行时、Python 环境和 CLI 包
- `hermes-agent-src/`
  - Source snapshot for rebuilds and inspections / 用于重建和查看的源码快照
- `ollama/`
  - Bundled Ollama executable and support files / 打包好的 Ollama 可执行文件和配套文件
- `pypi-check/`
  - Cached wheel(s) used for package sanity checks / 用于包完整性检查的 wheel 缓存
- `hermes-agent-codeload.zip`, `hermes-agent-main.zip`
  - Source archives kept for rebuild provenance / 保留的源码压缩包，便于追溯
- `hermes-minimal-files.txt`, `hermes-web-files.txt`
  - File lists used during packaging / 打包过程中使用的文件清单
- `range-test.bin`
  - Small test artifact used by packaging or verification steps / 打包或验证步骤用的小测试文件

## Notes / 说明

- This folder is the portable runtime payload, not the user state store / 这里是便携运行时载荷，不是用户状态目录
- The user state lives in `home/` / 用户状态放在 `home/`
