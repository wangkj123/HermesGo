# HermesGo Docker优先绿色便携方案

**文档编号**：011

**生成者**：AI Codex GPT-5.4

**生成日期**：2026-04-16-0950

**最后修改**：2026-04-16-0950

**参考文档**：
- docs/001-2026-04-16-0825-AI更好编程与可理解性总纲.md
- docs/004-2026-04-15-2146-HermesAgent与OpenHarness工程路径评估.md
- docs/010-2026-04-16-0837-HermesGo绿色便携入口方案.md
- Hermes 官方 Docker 指南
- Hermes 官方本地模型指南
- Hermes 官方 Web UI 指南
- Hermes 官方 GitHub 仓库 README

**目的**：把 HermesGo 定义成一个可复制、可本地启动、尽量不污染系统环境的 Windows 便携运行目录。当前优先级不是“安装器”，而是“绿色启动包”。

**状态**：已被 `docs/015` 取代，保留作历史记录。

## 1. 方案结论

1.1 Hermes 官方明确说明 Windows 原生不支持，推荐的 Windows 路径是 WSL2 或容器化运行。

1.2 为了满足“不要依赖 WSL2、目录可整体复制、本地数据留在目录里”的要求，HermesGo 当前采用 Docker Compose 优先方案。

1.3 如果本机有 Docker，HermesGo 先启动本地 `ollama`，再拉取 `hermes3`，然后启动 Hermes 容器，并打开 `http://localhost:3000`。

1.4 如果没有 Docker，HermesGo 回退到本机 Pinokio。

1.5 如果 Docker 和 Pinokio 都没有，HermesGo 只打开官方文档，不会强行把安装文件写进系统目录。

## 2. 目录结构

2.1 `HermesGo/HermesGo.bat`

2.1.1 Windows 一键启动入口。

2.1.2 负责检测 Docker、启动容器、回退 Pinokio、写日志。

2.2 `HermesGo/docker-compose.yml`

2.2.1 定义 `ollama` 和 `hermes` 两个服务。

2.2.2 通过本地卷保存模型缓存和 Hermes 配置。

2.3 `HermesGo/data/`

2.3.1 保存 Hermes 和 Ollama 的持久化数据。

2.3.2 复制整个目录时，数据也一起带走。

2.4 `HermesGo/images/`

2.4.1 保存可搬运的 Docker 镜像归档。

2.4.2 目标机器启动时可优先从这里加载镜像。

2.5 `HermesGo/logs/`

2.5.1 保存启动日志。

## 3. 当前实现

3.1 `HermesGo.bat` 会优先检测 `docker compose`，其次检测 `docker-compose`。

3.2 发现 Docker 后，脚本会按顺序执行：

3.2.1 启动 `ollama`

3.2.2 拉取 `hermes3`

3.2.3 启动 `hermes`

3.2.4 打开 `http://localhost:3000`

3.3 如果用户设置 `HERMESGO_TEST=1`，脚本会跳过浏览器打开步骤，方便做本地自测。

3.4 如果 Docker 不存在，脚本会尝试查找本机 Pinokio。

3.5 如果两者都不存在，脚本会打开 Hermes 官方 Docker 指南和 Pinokio 指南。

## 4. 绿色版边界

4.1 这里的“绿色版”是便携运行目录，不是把 Hermes 重新编译成 Windows 原生程序。

4.2 绿色版的关键是：

4.2.1 配置和缓存都放在目录内

4.2.2 入口是单个 `bat`

4.2.3 拷贝目录后还能继续用

4.2.4 不依赖 WSL2

4.3 如果要做到更强的离线拷贝即用，还需要进一步固定 Docker 镜像、模型缓存和初始化脚本。

## 5. 验证状态

5.1 已验证目录结构只保留在 `HermesGo/` 下，没有散落到仓库根目录。

5.2 已用本地假 `docker.cmd` 桩验证 Docker 分支，确认脚本会依次执行 `up -d ollama`、`exec -T ollama ollama pull hermes3`、`up -d hermes`。

5.3 已在 `HERMESGO_TEST=1` 下验证测试模式会跳过浏览器启动。

5.4 已在没有 Docker 的当前机器上验证回退分支会停在“Docker not found / No Docker or Pinokio launcher found.”。

5.5 已验证 `HermesGo/data/hermes/config.yaml` 与 Hermes 的本地 Ollama 配置一致。

5.6 已新增 `images/` 目录和镜像加载逻辑，用于把 Docker 镜像也纳入便携包。

5.7 当前机器没有真实 Docker，因此无法做真实容器运行；如果你后面要做完整搬运验证，仍建议在有 Docker 的机器上再跑一次实机启动和镜像导出。

## 6. 后续建议

6.1 如果后面要提升为真正可搬运的离线包，优先固定 Hermes 镜像版本和 Ollama 模型版本。

6.2 如果你希望继续压缩用户操作，可以在 `HermesGo.bat` 外再加一个更短的同级启动别名。

6.3 如果后续要支持完全离线，还需要把 Docker 镜像导出、模型文件预下载、以及本地卷初始化一起打包。
