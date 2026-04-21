# create_hermes_go

这个目录负责 HermesGo 的构建和测试。

## 当前路线

- 用官方 Hermes 源码和当前工作区依赖生成绿色包
- 用官方 embeddable Python 替换本机系统 Python
- 默认切换到 Ollama 本地模型，避免云端 token 依赖
- `create_hermes_go/output/HermesGo` 是最终交付目录，复制整个目录即可离线运行
- 生成时会带上 `HermesGo.exe` 的应用图标和 `codex.cmd` 兼容入口，并把测试工作区放到独立沙箱里验证

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
- `test/Prepare-HermesGoTestWorkspace.ps1`
- `test/Verify-HermesGoTestWorkspace.ps1`
