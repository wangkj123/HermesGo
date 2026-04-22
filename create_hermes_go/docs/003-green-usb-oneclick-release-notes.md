# 003-绿色版 / U 盘版 / 一键安装版更新说明

## 这是什么新版本

这是 Hermes Agent 的 Windows 绿色版新分支，也可以理解为：

- 绿色版
- U 盘版
- 一键安装版
- 便携版
- 自带本地模型的 HermesGo

这个版本不是替换旧版，而是新增一条更适合分发、拷贝和搜索的 release 线。

## 这次更新的重点

- `HermesGo.exe` 仍然是主入口，保留经典启动器，适合新用户直接点击
- 本地 2B 启动只走离线模型，不触发 ChatGPT / Codex 登录
- `Cloud: GPT-5.4 Mini` 只在缺少授权时才自动拉起登录流程
- OpenAI Codex 的登录链路由 Hermes 自己实现，不依赖外部安装的 Codex CLI
- 绿色包不会携带本地 `auth.json`、`auth.lock` 这类账号凭据文件
- 源码和 release 会一起同步到 GitHub，旧版本继续保留，不删除、不覆盖

## 适合搜索的关键词

HermesGo / HermesGo,
Hermes Agent / Hermes Agent,
绿色版 / green package,
U 盘版 / USB bundle,
一键安装版 / one-click install,
便携版 / portable bundle,
USB 版 / USB-friendly package,
Windows 便携 / Windows portable,
本地模型 / local model,
Ollama / Ollama,
OpenAI Codex / OpenAI Codex,
GPT-5.4 Mini / GPT-5.4 Mini

## 用户怎么理解这条线

- 如果只想跑本地模型，直接用本地 2B 入口
- 如果要云端能力，只用 `Cloud: GPT-5.4 Mini`
- 如果要换账号或重新授权，只用 Hermes 自带登录入口

## release 约定

- 新版本只追加，不删除旧版本
- 代码更新、release 更新和说明文档一起发布
- 下载页和仓库首页都保留最新 release 链接
- 当前版本：`HermesGo-2026.04.22-2025`
- 当前 zip：`HermesGo-2026.04.22-2025.zip`
- 当前 checksum：`HermesGo-2026.04.22-2025.zip.sha256.txt`
- `HermesGo-2026.04.21-*` 是昨天的旧包，保留但不是今天的下载项
