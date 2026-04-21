# HermesGo

HermesGo 是 Hermes Agent 的 Windows 绿色版交付目录。

## 下载

- 最新发布页：<https://github.com/wangkj123/HermesGo/releases/latest>
- 完整离线包：<https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.zip>
- 校验文件：<https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.sha256.txt>

完整包大约 1.6 GB，包含直接运行所需的全部内容：

- Hermes Agent 运行时
- Dashboard
- 便携 Python
- 便携 Ollama 运行时
- 默认 Ollama 2B 模型仓
- 带马头图标的 `HermesGo.exe`

## 怎么用

1. 下载完整 zip 包，压缩包会保留最上层的 `HermesGo/` 目录。
2. 解压整个 `HermesGo/` 目录，不要只拷贝 `HermesGo.exe`。
3. 优先双击 `HermesGo.exe`；它会显示应用图标，并启动 Dashboard 浏览器页面和 `HermesGo Chat` 窗口。
4. 如果你习惯批处理入口，也可以双击 `HermesGo.bat`。
5. 需要做快速自检时，运行 `Verify-HermesGo.bat`。
6. 需要切换默认本地模型时，运行 `Switch-HermesGoModel.bat`。
7. 如果要改 Codex / 账号登录，直接走 Hermes 内置浏览器登录流程，不需要单独安装额外的 CLI 软件。

## 目录说明

| 路径 | 作用 |
|---|---|
| `HermesGo.exe` | 绿色版主入口，带应用图标 |
| `HermesGo.bat` | 兼容入口，双击即可启动 |
| `Start-HermesGo.ps1` | 主启动器，负责拉起运行时、Dashboard 和聊天窗口 |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | 结构与运行自检 |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | 切换默认本地模型 |
| `runtime/` | 打包进来的运行时文件 |
| `home/` | 持久配置、会话、状态与记忆 |
| `data/` | 运行数据 |
| `data/ollama/` | 随包带入的 Ollama 模型仓 |
| `data/ollama/models/` | 离线模型文件和 manifest |
| `logs/` | 临时日志目录 |
| `HermesGo-debug.txt` | 根目录调试日志，每次启动会刷新 |
| `installers/` | 可选安装器投放目录，不是运行必需 |

## 我是怎么测试的

我没有直接在正式发布目录里反复改，而是用独立测试目录做的：

1. 运行 `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. 脚本把 `create_hermes_go/output/HermesGo` 复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. 在沙箱里改文件、启动 `HermesGo.exe` / `HermesGo.bat`
4. 运行 `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

验证内容包括：

- `HermesGo.bat` / `Start-HermesGo.ps1` 是否仍能拉起 Dashboard
- 本地 Ollama 2B 模型仓是否可用
- 便携 Python 是否还是包内版本
- 启动日志是否写入 `HermesGo-debug.txt`

如果你要继续迭代，优先在沙箱里改，确认没问题后再回到正式包。
