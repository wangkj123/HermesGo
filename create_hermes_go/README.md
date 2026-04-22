# create_hermes_go

这个目录负责 HermesGo 的构建和测试，也包含这条绿色版 / U 盘版 / 一键安装版 release 线的生成脚本。

## 当前路线

- 用官方 Hermes 源码和当前工作区依赖生成绿色包
- 用官方 embeddable Python 替换本机系统 Python
- 默认切换到 Ollama 本地模型，避免云端 token 依赖
- `create_hermes_go/output/HermesGo` 是最终交付目录，复制整个目录即可离线运行
- 生成时会带上 `HermesGo.exe` 的应用图标、经典启动器和 `codex.cmd` 兼容入口，并把测试工作区放到独立沙箱里验证
- 生成时也会把 `tutorial/` 一起带上，方便新手按编号图片学习使用
- 这条 release 线不依赖外部安装的 Codex CLI；本地 2B 不会触发 ChatGPT / Codex 登录，只有 Cloud 路线在缺少授权时才自动登录
- 当前版本信息来自 `create_hermes_go/release-state.json`
- 更新下载包名、checksum 和 release tag 时，先改 `Sync-HermesGoReleaseState.ps1` 使用的状态文件，再重新生成
- 当前发布版本：`HermesGo-2026.04.22-2025`
- 当前 zip：`HermesGo-2026.04.22-2025.zip`
- 当前 checksum：`HermesGo-2026.04.22-2025.zip.sha256.txt`

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
- `test/Prepare-HermesGoTestWorkspace.ps1`
- `test/Verify-HermesGoTestWorkspace.ps1`