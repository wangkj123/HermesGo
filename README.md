# HermesGo 绿色版交付仓库

这个仓库的目标是把 Hermes Agent 做成可下载、可直接运行、可独立测试和可重复发布的 Windows 绿色版。

## 你应该先看什么

- 如果你只是想直接用，先看 [HermesGo/README.md](HermesGo/README.md)
- 如果你想下载现成版本，直接下完整离线包：`HermesGo-2026.4.21.zip`
- 如果你想重新打包，先看 [create_hermes_go/README.md](create_hermes_go/README.md)
- 如果你想独立测试修改，先看 [create_hermes_go/test/README.md](create_hermes_go/test/README.md)

## 仓库结构

| 路径 | 作用 |
|---|---|
| `HermesGo/` | 绿色版交付目录的说明和使用指南 |
| `create_hermes_go/` | 绿色版构建流程、输出目录和测试工作区 |
| `create_hermes_go/output/HermesGo/` | 最终交付包的本地输出 |
| `create_hermes_go/test/` | 独立测试工作区，用来反复迭代 |
| `docs/` | 项目文档 |
| `tests/` | 测试代码和验证脚本 |

## 发布版

最新发布页：

- <https://github.com/wangkj123/HermesGo/releases/latest>

直接下载完整离线包：

- [HermesGo-2026.4.21.zip](https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.4.21.zip)
- [HermesGo-2026.4.21.sha256.txt](https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.4.21.sha256.txt)

这个完整包体积大约 1.6GB，包含 HermesGo 直接运行所需的运行时、Dashboard 和内置 Ollama 模型仓。

## 这个仓库怎么工作

1. 开发和修复先在仓库里完成。
2. 绿色版产物在 `create_hermes_go/output/HermesGo/`。
3. 测试修改先复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox/`。
4. 验证通过后，再把产物打包上传到 GitHub Releases。

## 独立测试流程

我已经跑通过以下流程：

```powershell
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Prepare-HermesGoTestWorkspace.ps1 -Clean
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Verify-HermesGoTestWorkspace.ps1
```

结果是通过的。这个流程的目的，是让你在单独沙箱里改动和验证，不污染正式交付目录。

## 说明

- 这个仓库里所有“直接下载就能用”的说明，都应该面向 HermesGo 绿色版。
- 如果你要改的是打包、启动、验证或发布流程，优先看 `HermesGo/` 和 `create_hermes_go/`。
