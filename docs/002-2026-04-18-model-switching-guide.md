# 模型切换指南

- 编号：002
- 日期：2026-04-18
- 适用范围：HermesGo / Hermes Agent
- 目的：说明如何在 Hermes 中切换 GPT 或其他模型，并修正容易误用的旧语法

## 先说结论

Hermes 里有两种不同的切换：

1. `hermes model`：切换全局默认模型，写入 `config.yaml`
2. `/model`：切换当前会话模型，默认只影响当前会话

## 正确语法

### 全局切换

```bash
hermes model
```

进入交互选择器后：

1. 先选 provider
2. 如果要切 GPT，通常选 `openai-codex`
3. 再选具体模型，比如 `gpt-5.4-mini` 或 `gpt-5.4`

这个动作会更新全局配置，后续新会话会继承。

### 当前会话切换

```text
/model gpt-5.4 --provider openai-codex
```

如果想让当前会话也持久化，可以加 `--global`：

```text
/model gpt-5.4 --provider openai-codex --global
```

### 旧写法不要用

不要再按旧示例写成：

```text
/model provider:model
```

现在实际代码走的是 `--provider`，不是冒号语法。

## GPT 切换建议

如果你切的是 OpenAI Codex 这条线，常见做法是：

1. 先确保 `openai-codex` 已登录
2. 用 `hermes model` 选 `openai-codex`
3. 再选你要的 GPT 模型

如果你已经在会话里了，直接：

```text
/model gpt-5.4-mini --provider openai-codex
/model gpt-5.4 --provider openai-codex
```

## 常见失败原因

1. 把 `provider:model` 当成合法语法
2. 选错 provider，例如切 GPT 却选成了 `openai`
3. `openai-codex` 没登录，模型列表拿不到
4. 只改了会话，没有加 `--global`，导致下次启动又回到旧模型

## 本次验证

本次用临时 `HERMES_HOME` 做了两次切换验证，没有污染真实配置：

1. `gpt-5.4-mini` -> `gpt-5.4`
2. `gpt-5.4` -> `gpt-5.4-mini`

验证点：

1. 配置文件里的 `model.default` 会被更新
2. `model.provider` 会保持为 `openai-codex`
3. 切换后下次读取配置能看到新模型

