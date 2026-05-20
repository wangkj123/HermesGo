HermesGo green portable package (v0.14.8, three UIs)
HermesGo 绿色便携包（v0.14.8，三套界面）

Current release tag: v0.14.8-green-3ui-slim
当前发行标签：v0.14.8-green-3ui-slim

Latest releases: https://github.com/wangkj123/HermesGo/releases/latest
最新发布页：https://github.com/wangkj123/HermesGo/releases/latest

================================================================================
QUICK START / 快速开始
================================================================================

Extract the whole HermesGo folder to an English path (not only HermesGo.exe).
将整个 HermesGo 文件夹解压到英文路径（不要只复制 HermesGo.exe）。

Double-click HermesGo.exe — same as HermesGo.bat (Dashboard + WebUI + Desktop).
双击 HermesGo.exe — 与 HermesGo.bat 相同（Dashboard + WebUI + Desktop）。

HermesWebUI.bat — chat / Kanban only at http://127.0.0.1:8787
HermesWebUI.bat — 仅聊天 / 看板 http://127.0.0.1:8787

HermesDesktop.bat — Electron desktop app only
HermesDesktop.bat — 仅 Electron 桌面端

HermesGo.exe --menu — optional launcher menu (verify, update, open folders)
HermesGo.exe --menu — 可选启动菜单（自检、更新、打开目录）

Verify-HermesGo.bat — self-check (under app\scripts\, run from package root shortcuts if added)
自检：运行 app\scripts\Verify-HermesGo.bat（见下方目录说明）

================================================================================
ROOT DIRECTORY (keep minimal) / 根目录（仅保留入口）
================================================================================

HermesGo.exe          Main launcher with horse-head icon; auto-update from GitHub
HermesGo.exe          主启动器（马头图标）；可从 GitHub 自动更新

README.txt            This file (English + Chinese, one line each)
README.txt            本说明文件（英文一行、中文一行）

HermesGo.bat          Start all three UIs (calls app\scripts\Start-HermesGo.ps1)
HermesGo.bat          启动三件套（调用 app\scripts\Start-HermesGo.ps1）

HermesWebUI.bat       WebUI only
HermesWebUI.bat       仅 WebUI

HermesDesktop.bat     Desktop only
HermesDesktop.bat     仅 Desktop

Everything else lives under app\ — do not add loose files at package root.
其余文件均在 app\ 下 — 请勿在包根目录堆放杂项文件。

================================================================================
UNDER app\ / app\ 目录结构
================================================================================

app\scripts\          Start-HermesGo.ps1, Verify-*, Switch-HermesGoModel.*
app\scripts\          主启动脚本、自检、切换模型等

app\tools\            codex.cmd (bundled shim, not external Codex CLI)
app\tools\            内置 codex.cmd 兼容入口（非外部 Codex 安装）

app\assets\           HermesGo-logo.png, icons\HermesGo.ico
app\assets\           启动器用图标与 Logo

app\docs\             PACKAGE-SLIM.md (package notes)
app\docs\             PACKAGE-SLIM.md（包说明）

app\runtime\          python311, hermes-agent, hermes-webui, hermes-desktop, bin
app\runtime\          便携 Python、Agent、WebUI、Desktop 运行时

app\home\             Your config, sessions, launcher-actions.txt (preserved on update)
app\home\             配置与会话（更新时保留）

app\data\             Runtime data (preserved on update)
app\data\             运行数据（更新时保留）

app\logs\             Logs (preserved on update)
app\logs\             日志（更新时保留）

app\workspace\        Workspace files (preserved on update)
app\workspace\        工作区（更新时保留）

app\webui-data\       WebUI data (preserved on update)
app\webui-data\       WebUI 数据（更新时保留）

================================================================================
URLS / 地址
================================================================================

Dashboard (keys, env):  http://127.0.0.1:9119/env?quick=1
Dashboard（配 Key）：     http://127.0.0.1:9119/env?quick=1

WebUI (chat, Kanban):     http://127.0.0.1:8787
WebUI（聊天、看板）：      http://127.0.0.1:8787

================================================================================
SLIM PACKAGE NOTES / 精简包说明
================================================================================

This slim build (~220 MB) does NOT include bundled Ollama or pre-downloaded model blobs.
本精简包（约 220 MB）不含内置 Ollama 与预置大模型文件。

Use cloud API keys on Dashboard, or install Ollama separately for local models.
云端 Key 请在 Dashboard 配置；本地模型请自行安装 Ollama。

v0.14.4 fixes Dashboard Kanban 500 (kanban_db sync + legacy DB migration).
v0.14.4 修复 Dashboard 看板 500（kanban_db 同步 + 旧库迁移顺序）。

Auto-update: HermesGo.exe checks wangkj123/HermesGo for newer *green-3ui-slim* zip.
自动更新：HermesGo.exe 从 wangkj123/HermesGo 拉取新版 *green-3ui-slim* zip。

Skip update: set HERMESGO_SKIP_UPDATE=1
跳过更新：设置 HERMESGO_SKIP_UPDATE=1

================================================================================
REBUILD (developers) / 开发者重新打包
================================================================================

powershell -File scripts\Compile-HermesGoBootstrap.ps1
powershell -File scripts\Compile-HermesGoBootstrap.ps1

py -3 build_zip_slim.py
py -3 build_zip_slim.py

Test tree syncs automatically to match the zip (see repo HermesGo-slim-test-v014).
测试目录会自动与 zip 对齐（仓库内 HermesGo-slim-test-v014）。
