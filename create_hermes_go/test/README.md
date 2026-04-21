# HermesGo 测试工作区

这个目录不放正式产物，只放给“想改、想测、想反复迭代”的人用。

## 用法

1. 先确认 `create_hermes_go/output/HermesGo` 已经生成。
2. 执行 `Prepare-HermesGoTestWorkspace.ps1`，复制出一个独立测试工作区。
3. 在测试工作区里改文件、跑验证、反复迭代。
4. 执行 `Verify-HermesGoTestWorkspace.ps1`，确认工作区仍然符合交付边界。

## 设计目标

- 不污染正式交付目录
- 让别人拿到仓库后，可以直接从脚本开始验证
- 支持多轮修改，不需要每次都手工重建目录
