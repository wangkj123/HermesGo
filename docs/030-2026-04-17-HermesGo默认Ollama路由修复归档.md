# 030-HermesGo默认Ollama路由修复归档

## 元信息

- 编号：030
- 日期：2026-04-17
- 参考：`.cursorrules`、`create_hermes_go/Create-HermesGo.ps1`、`HermesGo/runtime/hermes-agent/run_agent.py`
- 目的：让 `HermesGo.bat` 对应的独立输出包默认走本地 Ollama，不再被 Codex/OpenRouter 路由污染。

## 问题现象

用户要求直接测试 bat 版 HermesGo，并发送 `hello` 走本地 Ollama。

实测中出现了 3 类问题：

1. 输出包 `home/auth.json` 会在错误路由后被自动迁入 Codex 登录态，破坏“独立运行”。
2. `AIAgent` 在只给 `base_url` 或只依赖 `config.yaml` 的情况下，没有正确把本地 Ollama 作为主推理端点。
3. 输出包默认 `home/config.yaml` 写的是 `http://127.0.0.1:11434`，而这套 OpenAI-compatible 请求链路实际需要 `http://127.0.0.1:11434/v1`。

## 根因

### 1. `run_agent.py` 的初始化分支过窄

- 旧逻辑只有在同时拿到 `api_key` 和 `base_url` 时，才把它视作显式运行时。
- 对本地 Ollama 这种“无 key、本地 base_url”的情况，会退回通用 provider router。
- 一旦退回通用 router，就可能因为现有登录态走到 Codex/OpenRouter。

### 2. `runtime_provider.py` 对 `ollama` 只做了半套归一化

- `resolve_provider()` 里把 `ollama` 视为 `custom`。
- 但 `resolve_requested_provider()` 和 `_get_model_config()` 没把 `model.provider: ollama` 统一归一到 `custom`。
- 结果是运行时虽然知道“请求像 custom”，却仍按 `cfg_provider != custom` 处理，最终落回 OpenRouter 默认值。

### 3. 输出包默认配置缺少 `/v1`

- Ollama 原生 API 在 `11434`。
- Hermes 当前走的是 OpenAI-compatible `chat/completions` 路径，需要配置成 `http://127.0.0.1:11434/v1`。
- 否则默认链路会请求 `http://127.0.0.1:11434/chat/completions`，直接 404。

## 修改

### 1. 运行时本地 provider 归一化

- 修改 [run_agent.py](/e:/AI/hermes/HermesGo/runtime/hermes-agent/run_agent.py)
- 新增本地 provider 别名集合：`ollama`、`lmstudio`、`vllm`、`llama.cpp` 等统一视作 `custom`
- `AIAgent` 初始化时优先调用 `resolve_runtime_provider()`，不再要求必须同时提供 `api_key + base_url`
- 对仅 `base_url` 的本地端点自动补 `no-key-required`

### 2. 配置读取归一化

- 修改 [runtime_provider.py](/e:/AI/hermes/HermesGo/runtime/hermes-agent/hermes_cli/runtime_provider.py)
- `resolve_requested_provider()` 与 `_get_model_config()` 现在都会把 `ollama` 归一化为 `custom`
- 修复后，`config.yaml` 中的本地 provider 能稳定带出 `base_url=http://127.0.0.1:11434/v1`

### 3. 输出包 home 状态清理

- 修改 [Create-HermesGo.ps1](/e:/AI/hermes/create_hermes_go/Create-HermesGo.ps1)
- 新增 `Reset-OutputHomeState`
- 每次构建输出包前，主动删除 `auth.json`、`state.db*`、`sessions/`、`memories/`、`logs/` 等运行态残留

### 4. 默认 Ollama URL 修正

- 修改 [Create-HermesGo.ps1](/e:/AI/hermes/create_hermes_go/Create-HermesGo.ps1)
- 输出包默认配置改为：

```yaml
model:
  provider: "ollama"
  default: "hermes3"
  base_url: "http://127.0.0.1:11434/v1"
```

## 验证

### 1. 构建与独立性

- `powershell -NoProfile -ExecutionPolicy Bypass -File .\create_hermes_go\Create-HermesGo.ps1 -Clean`
- `powershell -NoProfile -ExecutionPolicy Bypass -File .\create_hermes_go\output\HermesGo\Verify-HermesGo.ps1`

结果：

- 构建成功
- 验证成功
- 重建后 `output/HermesGo/home/` 初始仅包含 `.env` 与 `config.yaml`

### 2. bat 直启

- `cmd /c "call ...\HermesGo.bat -NoOpenBrowser -NoOpenChat"`

结果：

- 启动器成功拉起 Dashboard
- 日志探针成功

### 3. 本地 Ollama 直连

- `ollama.exe serve`
- `ollama.exe run tinyllama "hello"`

结果：

- 本地 `127.0.0.1:11434` 正常提供服务
- `hello` 可返回文本

### 4. Hermes 默认配置走本地 Ollama

测试代码要点：

- `HERMES_HOME` 指向输出包 `home/`
- 使用输出包自带 `python.exe`
- 直接实例化 `AIAgent(model='tinyllama', persist_session=False, skip_context_files=True, skip_memory=True)`

结果：

- provider：`custom`
- base_url：`http://127.0.0.1:11434/v1`
- api_mode：`chat_completions`
- `agent.chat("hello")` 返回文本，确认默认配置链路已走本地 Ollama

## 结论

当前输出包已经满足以下条件：

1. `HermesGo.bat` 可直接运行
2. 输出包不依赖系统 Python
3. 默认模型路由优先落到本地 Ollama
4. `hello` 的真实请求已经通过本地 Ollama 跑通

剩余注意点只有模型质量：

- 当前演示模型是 `tinyllama`
- 它能证明链路可用，但回复质量较差，容易跑题
- 如果需要更稳定的人类可读回包，建议换更好的本地小模型继续测
