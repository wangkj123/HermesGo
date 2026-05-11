# 070-2026-05-11-GitHub 源码与 Release 发布指南

| 字段 | 内容 |
|------|------|
| 编号 | 070 |
| 日期 | 2026-05-11 |
| 参考 | `HermesGo/build_zip_slim.py`、`HermesGo/build_zip_v3.py`、`docs/069-2026-05-11-HermesGo便携版8787离线与版本号修复.md` |
| 目的 | 说明如何将**源码**推送到 GitHub，以及如何上传**绿色版 zip** 作为 Release 资产供他人下载测试 |

## 1. 仓库与链接（当前 origin）

本工作区默认远程为：

- **仓库主页**：<https://github.com/wangkj123/HermesGo>
- **Releases 列表**：<https://github.com/wangkj123/HermesGo/releases>
- **最新 Release（发布后）**：<https://github.com/wangkj123/HermesGo/releases/latest>
- **克隆源码**：`git clone https://github.com/wangkj123/HermesGo.git`

若你的 fork 或组织仓库不同，把上述路径中的 `wangkj123/HermesGo` 换成自己的 `owner/repo` 即可。

## 2. 源码与绿色包的分工

| 载体 | 内容 | 说明 |
|------|------|------|
| **Git 仓库** | 脚本、启动器、`runtime/hermes-agent` 与 `runtime/hermes-webui` 的**源码**、`create_hermes_go` 构建链等 | 受 `.gitignore` 约束：**不**提交 `runtime/python311`、`venv`、大模型、`*.zip` 等二进制与产物（避免仓库膨胀）。 |
| **GitHub Release 附件** | 本地构建的 **slim** 或 **full** 便携 zip（含嵌入式 Python + venv 等） | 体积可达数百 MB～数 GB，**只作为 Release Asset 上传**，不要 `git add` 进历史。 |

## 3. 本地构建 Release 用 zip

在项目根目录执行（需已具备完整 `HermesGo/runtime/...` 树以便打包）：

**精简绿色版（推荐测试分发，约 1GB 量级，无内置 Ollama / 无预置模型）：**

```text
py -3 HermesGo\build_zip_slim.py
```

输出目录：**`dist/`**（已在 `.gitignore` 中忽略）。桌面会尝试复制同名 zip（若权限允许）。

**全量树 zip（体积大，含重复根目录扫描项时可达 2GB+，仅必要时使用）：**

```text
py -3 HermesGo\build_zip_v3.py
```

可选：编译带自动更新引导的 **`HermesGo.exe`**（再执行 slim/v3 打包以纳入 zip）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "HermesGo\scripts\Compile-HermesGoBootstrap.ps1"
```

## 4. 推送源码到 GitHub

```powershell
cd E:\AI\hermes
git status
git add <你改动的文件>
git commit -m "描述本次改动的完整句子。"
git push origin main
```

若 HTTPS 提示登录：在 GitHub 创建 **Personal Access Token (classic)**，权限至少勾选 `repo`，在密码处粘贴 Token。

若使用 SSH：

```text
git remote set-url origin git@github.com:wangkj123/HermesGo.git
git push origin main
```

## 5. 在网页上创建 Release 并上传 zip

1. 打开：<https://github.com/wangkj123/HermesGo/releases>
2. 点击 **Draft a new release**
3. **Choose a tag**：新建标签，例如 `HermesGo-2026.05.11-slim`（或语义化版本 `v0.13.0-slim`）
4. **Release title**：例如 `HermesGo 绿色版 slim 测试构建`
5. 在说明中写清：解压路径、`HermesGo.bat` / `Start-HermesGo.ps1`、Dashboard **9119**、WebUI **8787**、需自备 API Key 等（可复制 `docs/069` 中验证步骤摘要）
6. **Attach binaries**：将 `dist\HermesGo-*-slim.zip`（或你要发的文件）拖入附件区
7. 若对测试人员可见：不要勾选 *Set as a pre-release* 或按需勾选 **Latest**
8. 点击 **Publish release**

发布后，把 **Release 页面完整 URL**（或 `.../releases/tag/<tag>`）发给测试人员即可。

## 6. 命令行创建 Release（可选）

若已安装 [GitHub CLI](https://cli.github.com/) 且已 `gh auth login`：

```powershell
gh release create v0.13.0-slim "dist\HermesGo-2026.05.11-xxxx-DeepSeek-v13-WebUI-slim.zip" --title "HermesGo slim 测试" --notes "见 docs/069 验证说明。"
```

大文件上传对网络要求较高；失败时可改用语网页上传。

## 7. 给测试人员的一句话说明

可复制发送：

> 请从 Release 下载 **slim** zip，解压后运行 `HermesGo.bat` 或 `Start-HermesGo.ps1`；Dashboard：<http://127.0.0.1:9119>，WebUI：<http://127.0.0.1:8787>。不含本地 Ollama 与预置模型，请配置云端 API Key（如 DeepSeek）。详细验证步骤见仓库 `docs/069-2026-05-11-HermesGo便携版8787离线与版本号修复.md`。
