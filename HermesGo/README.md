# HermesGo

HermesGo 是 Hermes Agent 的 Windows 绿色版交付目录。  
如果你只是想“下载后直接用”，去 GitHub Releases 下载；如果你要改包、重打包、反复验证，就看下面的测试工作区流程。

## 下载发布版

- 最新发布页：<https://github.com/wangkj123/HermesGo/releases/latest>
- 当前可下载资产：`HermesGo-2026.4.21-lite.zip`
- 校验文件：`HermesGo-2026.4.21-lite.sha256.txt`

这个发布版是不需要安装器的。下载 zip，解压整个目录，然后直接双击 `HermesGo.bat`。
如果包内没有默认模型，首次启动会按配置自动拉取默认的 Ollama 模型。

## 这个目录里每个部分干什么

| 路径 | 用途 |
|---|---|
| `HermesGo.bat` | Windows 双击入口，给普通用户用 |
| `Start-HermesGo.ps1` | 真正的启动脚本，负责拉起运行时、Dashboard 和聊天窗口 |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | 启动前的自检入口，检查关键文件和运行边界 |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | 切换默认本地模型 |
| `runtime/` | 随包携带的运行时，包括 Python、Hermes 运行时和 Ollama |
| `home/` | 持久化数据目录，放配置、会话、状态、记忆和运行日志 |
| `data/` | 运行数据目录 |
| `data/ollama/` | 随包携带的 Ollama 模型仓 |
| `data/ollama/models/` | 具体模型文件和 manifest；保留它才能完全离线启动 |
| `installers/` | 可选安装器目录，不是启动必需项 |
| `logs/` | 临时日志和调试输出 |
| `HermesGo-debug.txt` | 根目录调试日志，每次启动都会刷新 |
| `README.md` | 本文件，解释如何使用这个绿色版 |

补充说明文件：

- `home/README.md`：解释 `home/` 里保存的持久化数据
- `data/README.md`：解释 `data/` 目录的职责
- `data/ollama/README.md`：解释内置模型仓和默认模型

## 怎么用

1. 下载 release 里的 zip。
2. 解压后，保留整个 `HermesGo/` 目录结构，不要只拿单个 exe。
3. 双击 `HermesGo.bat`。
4. 如果想先确认目录完整，运行 `Verify-HermesGo.bat`。
5. 如果想切换默认模型，运行 `Switch-HermesGoModel.bat`。

## 目录使用习惯

- `home/` 是用户数据。不要在 Hermes 运行时打开 SQLite sidecar 文件手改。
- `logs/` 和 `HermesGo-debug.txt` 适合排障，可以删，但建议先看内容。
- `data/ollama/models/` 适合离线使用，完整保留才是“拿来就能离线跑”的版本。
- `installers/` 不是必须的。它只是给某些安装/修复场景留的。

## 自测过程

我已经按下面流程把测试目录跑通了：

1. 运行 `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. 它会把 `create_hermes_go/output/HermesGo` 复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. 在 `HermesGo-sandbox` 里改文件、启动、验证
4. 运行 `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

结果通过。这个流程的意义是：你可以在独立沙箱里反复迭代，而不是直接污染正式交付目录。

## 如果你要重新生成绿色包

- 构建入口在 `create_hermes_go/`
- 复制和验证脚本在 `create_hermes_go/test/`
- 正式交付产物在 `create_hermes_go/output/HermesGo`

也就是说，普通用户看 `HermesGo/` 就够了；维护者看 `create_hermes_go/` 和 `create_hermes_go/test/`。
