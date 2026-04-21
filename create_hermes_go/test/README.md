# HermesGo 测试工作区

这个目录只做独立测试和反复迭代，不放正式交付物。

## 它的作用

- 从 `create_hermes_go/output/HermesGo` 复制出一个独立沙箱
- 让你在沙箱里改文件、启动、验证
- 每轮修改后都能检查交付边界有没有被破坏

## 我实际跑过的流程

1. 运行 `Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. 脚本把 `create_hermes_go/output/HermesGo` 复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. 在 `HermesGo-sandbox` 里改文件
4. 运行 `Verify-HermesGoTestWorkspace.ps1`
5. 验证通过后，再回到正式包继续迭代

我已经在本机跑过这一套，结果是通过的。

## 具体命令

```powershell
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Prepare-HermesGoTestWorkspace.ps1 -Clean
powershell -ExecutionPolicy Bypass -File .\create_hermes_go\test\Verify-HermesGoTestWorkspace.ps1
```

## 工作区目录

- `Prepare-HermesGoTestWorkspace.ps1`：复制正式输出包，创建沙箱
- `Verify-HermesGoTestWorkspace.ps1`：检查沙箱是否仍满足交付结构
- `workspaces/HermesGo-sandbox/`：实际测试目录

## 使用建议

- 改动都先在沙箱里试，确认没问题再回正式包。
- 不要直接在正式输出目录里反复试错。
- 如果想重来一遍，重新执行 `Prepare-HermesGoTestWorkspace.ps1 -Clean` 就行。
