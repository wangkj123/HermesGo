# HermesGo Pinokio Go版方案与实装结果

**文档编号**：024

**生成日期**：2026-04-16

**最后修改**：2026-04-16

**参考文档**：
- docs/022-2026-04-16-HermesGo团队化自动开发流程方案.md
- docs/023-2026-04-16-HermesGo团队化自动开发流程验证报告.md

**目的**：记录 HermesGo 从 Docker/WSL 偏向方案收敛为 Windows Pinokio Go 版入口的原因、实现方式和当前实装结果。

## 1. 路线调整

1.1 Hermes 官方安装文档正式支持的是 Linux、macOS、WSL2 和 Termux。

1.2 用户当前目标不是 WSL2，而是 Windows 可用版。

1.3 因此 HermesGo 当前改为 Windows 上最现实的成功路线：

- Pinokio
- Hermes Agent app

## 2. 当前实现

2.1 `HermesGo.bat`

- 优先检测本机是否已安装 Pinokio
- 若已安装，则直接启动 Pinokio
- 若未安装，则优先使用 `installers/Pinokio/Pinokio.exe`
- 若安装包缺失，则自动从官方稳定链接下载

2.2 `HermesGo-NextSteps.txt`

- 每次运行后生成下一步操作说明
- 明确提示用户在 Pinokio 中搜索 `Hermes Agent` 并点击 `Install`

2.3 `HermesGo.config.bat`

- 保存 Pinokio 官方下载地址和 Hermes Pinokio 指南链接

2.4 `Verify-HermesGo.ps1`

- 验证 bundled installer 路径
- 验证 installed Pinokio 路径

2.5 `Verify-HermesGoSupervisor.ps1`

- 验证 supervisor 成功、失败和重试路径

## 3. 当前结果

3.1 已下载官方 Pinokio Windows 安装包到：

- `HermesGo/installers/Pinokio/Pinokio.exe`

3.2 当前安装包大小约为：

- `126,914,976` bytes

3.3 自动化流程最新运行目录：

- `workflow/runs/20260416-111302-HermesGo/`

3.4 当前审查结论：

- `approve`

## 4. 这版的意义

4.1 现在的 HermesGo 不再是假装直接运行 Hermes 本体。

4.2 它的角色被收敛为：

- Windows Go 版入口
- Pinokio 安装与启动辅助器
- Hermes 安装下一步说明器

4.3 这比之前的 Docker/WSL 偏向方案更符合当前用户目标。

## 5. 后续

5.1 如果后面要继续做“更像成品”的 Go 版，可继续补：

- 更明确的 GUI 状态面板
- 自动检测 Pinokio 安装完成状态
- 自动打开 Pinokio 后的 Hermes 搜索/应用页

5.2 但以当前阶段看，这版已经完成了从“错误路线”到“正确 Windows 路线”的收敛。
