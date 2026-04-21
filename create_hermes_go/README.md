# create_hermes_go

这个目录负责两件事：

1. 记录如何把当前仓库里的 Hermes 做成 Windows 单目录包
2. 用脚本生成仓库外的独立 `create_hermes_go/output/HermesGo`

## 绿色包交付方式

- `create_hermes_go/output/HermesGo` 就是最终绿色包
- 对外分发时，直接把整个目录复制或压缩后发出去即可
- 目标机器解压后，双击 `HermesGo.bat` 就能用

## 当前路线

- 官方 Hermes 源码
- 当前工作环境里的依赖
- 官方 embeddable Python 取代原始 venv
- 默认切到 Ollama 本地模型，避免 token
- Ollama 运行时和包内模型仓都会被复制进独立 release 目录，只保留目录内自举能力；GPU 专用后端、安装器 ZIP 和前端源码不会进入发行包
- 绿色包的顶层结构保持稳定，升级只更新包内文件，不改变交付目录的用法

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`

## 测试目录

- `test/`：独立的绿色包测试工作区
- `test/Prepare-HermesGoTestWorkspace.ps1`：把 `output/HermesGo` 复制到隔离工作区，方便反复迭代
- `test/Verify-HermesGoTestWorkspace.ps1`：检查测试工作区是否仍然满足交付边界
