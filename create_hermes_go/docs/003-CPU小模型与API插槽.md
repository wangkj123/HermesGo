# 003 CPU小模型与API插槽

## 目标

- 先让 HermesGo 在普通 Windows 11 上尽快可用
- 默认走纯 CPU 小模型，减少对 GPU 和云 token 的依赖
- 同时保留 API provider 插槽，后续可以切换到可用的免费或试用 API

## 当前默认

- `ollama`
- `gemma:2b`
- `http://127.0.0.1:11434`

## 可切换预设

- `qwen2.5-coder:0.5b`
- `openrouter` 模板

## 原则

- 先能用，再变好用
- 先把配置入口做出来，再逐步补充更重的模型和更完整的自动化
