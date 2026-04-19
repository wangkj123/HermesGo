# ollama

This folder is the bundled Ollama model store used by HermesGo at startup.
这个目录就是 HermesGo 启动时使用的包内 Ollama 模型仓。

HermesGo sets `OLLAMA_MODELS` to `data/ollama/models` before starting `runtime/ollama/ollama.exe`.
HermesGo 在启动 `runtime/ollama/ollama.exe` 之前，会先把 `OLLAMA_MODELS` 固定到 `data/ollama/models`。

Keep this folder together with the rest of `HermesGo/` when you copy the package to another computer.
把整个 `HermesGo/` 拷到别的电脑时，必须连这个目录一起保留。

The default offline model is `gemma:2b`.
当前默认离线模型是 `gemma:2b`。
