# 031-HermesGo Codex登录隔离与断开修复归档

## 元信息

- 编号：031
- 日期：2026-04-19
- 参考：`.cursorrules`、`logs/agent-progress.md`、`HermesGo/runtime/hermes-agent/hermes_cli/auth.py`、`HermesGo/runtime/hermes-agent/agent/credential_pool.py`、`HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`、`HermesGo/tools/Start-HermesGo.ps1`
- 目的：把 `openai-codex` 的登录、断开、模型发现全部收敛到 HermesGo 自己目录，彻底切断对 `~/.codex/auth.json` 与 `CODEX_HOME` 的依赖，保证这个 go 版拷贝到哪里都只认自己目录。

## 问题现象

用户在 `http://127.0.0.1:9119/env?oauth=openai-codex` 里执行 Codex 断开后，状态仍然会回到已登录。

现场复测结果如下：

1. `DELETE /api/providers/oauth/openai-codex` 返回 `ok=true`。
2. 紧接着再次读取 `/api/providers/oauth`，`openai-codex.status.logged_in` 又变回 `true`。
3. 用户要求明确约束：这是 go 版，Codex 登录态只能跟本 go 目录相关，不能再受 `~/.codex/auth.json` 影响。

## 根因

### 1. 运行时凭据解析会从家目录导入 Codex token

- 文件：`HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- 旧逻辑在 Hermes 自己的 auth store 缺失时，会尝试读取 `~/.codex/auth.json`，并把外部 token 导回 Hermes auth store。
- 这会导致 Dashboard 看起来“断开成功”，但下一次状态检查又被外部 token 复活。

### 2. 凭据池种子逻辑会再次从家目录补回登录态

- 文件：`HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- 旧逻辑在 `openai-codex` 没有 Hermes 本地 token 时，会从外部 Codex CLI 状态重新 seed 凭据池。
- 即使 `clear_provider_auth()` 已经把 Hermes 本地登录态删掉，凭据池仍能把它补回来。

### 3. 刷新 token 时还会把新 token 写回家目录

- 文件：`HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- 文件：`HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- 旧逻辑会把刷新后的 Codex token 重新写回 `~/.codex/auth.json`。
- 这意味着 HermesGo 虽然想独立，但每次刷新都会再次和外部目录发生耦合。

### 4. CLI 登录链路仍保留“导入外部 Codex 凭据”的入口

- 文件：`HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- 旧逻辑允许导入 `~/.codex/auth.json`，并在某些分支优先尝试依赖 Codex CLI 的登录流程。
- 这和“只认 go 目录”的原则相冲突。

### 5. Codex 模型发现还会回退到家目录缓存

- 文件：`HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`
- 旧逻辑会从 `CODEX_HOME` 或 `~/.codex` 读取 `config.toml` 和 `models_cache.json`。
- 即使认证已隔离，模型候选列表仍会被外部目录影响。

## 修改

### 1. 只保留 HermesGo 自己的 Codex auth store

- 修改 `HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- 修改 `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- `resolve_codex_runtime_credentials()` 现在只读取 HermesGo 自己保存的 `auth.json`
- 删除对 `~/.codex/auth.json` 的自动导入
- 删除刷新后向 `~/.codex/auth.json` 回写 token 的逻辑
- `_login_openai_codex()` 改成只走 HermesGo 自己管理的登录链，不再导入外部 Codex 凭据
- `_codex_cli_browser_login()` 改为显式报错，禁止在 HermesGo 中使用共享的 Codex CLI 登录态

### 2. 凭据池不再从外部目录同步 Codex token

- 修改 `HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- 修改 `create_hermes_go/output/HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- `openai-codex` 的 seed 逻辑只认 HermesGo 本地 auth store
- 删除从 `~/.codex/auth.json` 同步 token 的逻辑
- 删除 refresh 失败后“再去家目录重读 token 重试”的逻辑
- 删除 refresh 成功后向家目录回写 token 的逻辑

### 3. Codex 模型缓存只看 HermesGo 目录

- 修改 `HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`
- 修改 `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`
- `get_codex_model_ids()` 不再读取 `CODEX_HOME` 或 `~/.codex`
- 本地缓存目录改为 `HERMES_HOME/codex`
- 如果本地目录下没有缓存，则回退到 API 或内置默认模型列表

### 4. 错误提示与注释同步收口

- 修改 `HermesGo/runtime/hermes-agent/run_agent.py`
- 修改 `HermesGo/runtime/hermes-agent/hermes_cli/model_switch.py`
- 修改 `HermesGo/runtime/hermes-agent/hermes_cli/main.py`
- 同步更新输出包对应文件
- 用户可见提示从“Codex CLI/VS Code 抢走 token”收口为“被其他进程消费”
- 内部注释改为以 HermesGo 本地 auth store 为唯一可信来源

## 验证

### 1. 语法检查

- 使用 `HermesGo/runtime/python311/python.exe -m py_compile` 检查以下文件：
  - `hermes_cli/auth.py`
  - `agent/credential_pool.py`
  - `hermes_cli/codex_models.py`
  - `hermes_cli/model_switch.py`
  - `hermes_cli/main.py`
  - `run_agent.py`
- 结果：通过

### 2. 隔离复现验证

分别对根目录运行时和输出包运行时做了同一组隔离测试：

1. 构造一个假的 `CODEX_HOME/auth.json`
2. 不写 HermesGo 自己的 auth store
3. 调用 `resolve_codex_runtime_credentials()`
4. 检查 provider status
5. 再写入 HermesGo 自己的 token
6. 执行 `clear_provider_auth("openai-codex")`
7. 再次检查 provider status 和凭据解析

结果：

- 即使假的 `CODEX_HOME/auth.json` 存在，`resolve_codex_runtime_credentials()` 仍返回 `codex_auth_missing`
- `status_before=false`
- 写入 HermesGo 本地 token 后 `status_after_save=true`
- 断开后 `status_after_clear=false`
- 断开后再次解析凭据仍返回 `codex_auth_missing`

### 3. 真实 Dashboard 现场复测

- 用 `HermesGo/tools/Start-HermesGo.ps1 -NoOpenBrowser -NoOpenChat` 重启 9119 Dashboard
- 当前监听进程路径：
  - `E:\AI\hermes\HermesGo\runtime\python311\python.exe`
- 读取 `http://127.0.0.1:9119/api/providers/oauth`
- `openai-codex.status.logged_in=false`

这说明：

1. 旧的“断开后又自动连回去”链路已经被切断
2. 9119 当前实际运行的是修复后的 HermesGo 版本
3. 新登录态只会写到 HermesGo 自己目录

## 产物与影响文件

### 根目录运行时

- `HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- `HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- `HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`
- `HermesGo/runtime/hermes-agent/hermes_cli/model_switch.py`
- `HermesGo/runtime/hermes-agent/hermes_cli/main.py`
- `HermesGo/runtime/hermes-agent/run_agent.py`

### 输出包运行时

- `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/auth.py`
- `create_hermes_go/output/HermesGo/runtime/hermes-agent/agent/credential_pool.py`
- `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/codex_models.py`
- `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/model_switch.py`
- `create_hermes_go/output/HermesGo/runtime/hermes-agent/hermes_cli/main.py`
- `create_hermes_go/output/HermesGo/runtime/hermes-agent/run_agent.py`

## 当前状态

1. Codex 登录态已经与 `~/.codex/auth.json` 脱钩
2. Codex 模型缓存发现已经与 `CODEX_HOME` 脱钩
3. Dashboard 断开状态现在可信，不会再被外部目录自动复活
4. 用户重新登录 Codex 后，新账号只会落在 HermesGo 自己目录

## 归档结论

本轮已经把用户要求的关键原则落地：

- 能独立运行
- Codex 登录只跟本 go 目录有关
- 不再依赖或污染家目录下的 Codex 共享状态

该项可以视为已完成归档。
