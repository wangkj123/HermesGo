# create_hermes_go

这个目录负责 HermesGo 绿色版 / U 盘版 / 一键安装版的构建、测试和 release 产物生成。

## 这条线的关键词

- HermesGo
- Hermes Agent
- 绿色版
- U 盘版
- 一键安装版
- 便携版
- USB 版
- Windows 便携
- 本地模型
- Ollama
- OpenAI Codex
- GPT-5.4 Mini

## 当前目标

- 用官方 Hermes 源码和当前工作区生成绿色包
- 用 embeddable Python 替换本机 Python
- 默认切换到 Ollama 本地模型，减少云端 token 依赖
- 把最终交付目录固定输出到 `create_hermes_go/output/HermesGo`
- 生成 `HermesGo.exe`、`HermesGo.bat`、`Verify-HermesGo.bat`、`Switch-HermesGoModel.bat`
- 带上 `tutorial/`、构建说明和 release notes，方便新用户直接上手

## 这条 release 线的规则

- 本地 2B 启动不触发 ChatGPT / Codex 登录
- 只有 `Cloud: GPT-5.4 Mini` 在缺少授权时才自动进入登录流程
- OpenAI Codex 不依赖外部安装的 Codex CLI，认证也走 Hermes 自带链路
- 发布包不携带本地 `auth.json`、`auth.lock` 这类账号凭据
- 老版本继续保留在 GitHub Releases，不删除、不覆盖

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
- `test/Prepare-HermesGoTestWorkspace.ps1`
- `test/Verify-HermesGoTestWorkspace.ps1`
