# HermesGo 测试工作区

这个目录只用来做独立测试和反复迭代，不是正式发布区。

## 作用

- 从 `create_hermes_go/output/HermesGo` 复制一份独立沙箱
- 在沙箱里修改、启动、验证，不污染正式输出
- 每次改完都可以重新跑验证脚本，确认没有把交付目录弄坏

## 我实际跑过的流程

1. 执行 `Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. 脚本把正式输出复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. 在沙箱里启动 `HermesGo.exe` 或 `HermesGo.bat`
4. 检查是否能打开 Dashboard 浏览器页面
5. 执行 `Verify-HermesGoTestWorkspace.ps1`

## 具体命令

```powershell
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Prepare-HermesGoTestWorkspace.ps1 -Clean
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Verify-HermesGoTestWorkspace.ps1
```

## 验证重点

- 沙箱里是否保留完整目录结构
- `HermesGo.exe` / `HermesGo.bat` 是否仍然可启动
- Dashboard 是否能正常起来
- 本地 Ollama 2B 模型仓是否可用
- 启动日志是否写入 `HermesGo-debug.txt`

## 目录说明

- `Prepare-HermesGoTestWorkspace.ps1`：复制正式输出并创建沙箱
- `Verify-HermesGoTestWorkspace.ps1`：检查沙箱文件和启动链
- `workspaces/HermesGo-sandbox/`：实际测试目录

## 使用建议

- 所有入口改动先在沙箱里验证，再回到正式输出
- 如果浏览器没弹出来，先看 `HermesGo-debug.txt`
- 如果需要做更大改动，先把测试过程写进这个目录的 README，再提交正式包
