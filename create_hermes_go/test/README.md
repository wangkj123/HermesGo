# HermesGo 测试工作区

这个目录只用于测试，不放正式交付物。

## 作用

- 复制 `create_hermes_go/output/HermesGo`，得到一个独立的沙箱
- 允许你在沙箱里反复修改、启动、验证
- 每次迭代后都能检查交付边界有没有被破坏

## 使用步骤

1. 先确认 `create_hermes_go/output/HermesGo` 已经生成。
2. 运行 `Prepare-HermesGoTestWorkspace.ps1 -Clean`。
3. 打开 `create_hermes_go/test/workspaces/HermesGo-sandbox`，在里面改文件。
4. 每次改完后运行 `Verify-HermesGoTestWorkspace.ps1`。
5. 如果要重新开始，继续跑 `Prepare-HermesGoTestWorkspace.ps1 -Clean` 覆盖沙箱。

## 目录说明

- `Prepare-HermesGoTestWorkspace.ps1`：从正式输出包复制一个新沙箱
- `Verify-HermesGoTestWorkspace.ps1`：检查沙箱是否仍满足交付边界
- `workspaces/HermesGo-sandbox/`：实际测试目录

## 这次的验证结果

我已经在本机跑过一次准备和校验，沙箱当前是通过的。
