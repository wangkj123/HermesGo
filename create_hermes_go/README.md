# create_hermes_go

这个目录负责两件事：

1. 记录如何把当前仓库里的 Hermes 做成 Windows 单目录包
2. 用脚本生成仓库外的独立 `hermes-release/HermesGo`

## 当前路线

- 官方 Hermes 源码
- 当前工作环境里的依赖
- 官方 embeddable Python 取代原始 venv
- 默认切到 Ollama 本地模型，避免 token
- Ollama 运行时和包内模型仓都会被复制进独立 release 目录，只保留目录内自举能力；GPU 专用后端、安装器 ZIP 和前端源码不会进入发行包

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
