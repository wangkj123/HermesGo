# Codex 规则：指向 Cursor 规则文件

本项目的 AI 行为规则与 Cursor 共用同一套配置，Codex 应读取并严格遵循 Cursor 的规则文件。

## 规则文件位置

**主规则文件（必读）**：项目根目录下的 **`.cursorrules`**

- 路径：`<项目根>/\.cursorrules`
- 每次对话开始时，必须先读取该文件并应用其中全部规则。
- 与 Cursor 使用同一文件，保证行为一致。

**修复即更新规则（必读，alwaysApply）**：`.cursor/rules/lessons-learned-auto-update.mdc`

- 每次修好可复现 bug 后，必须把教训追加到对应 `.mdc`，避免同类错误重复出现。

**HermesGo 打包/自测已知坑（改打包或启动前必读）**：`.cursor/rules/hermesgo-packaging-selftest.mdc`

- Provider 名、Codex 探测、便携 PATH、Dashboard token、PS 5.1 启动等已列清单；新问题按 `lessons-learned-auto-update.mdc` 追加。

**COM4/COM7 串口自治规则（必读）**：`.cursor/rules/usbcdc-com4-com7-autonomy.mdc`

- 路径：`<项目根>/.cursor/rules/usbcdc-com4-com7-autonomy.mdc`
- 与 Cursor 共用，包含 COM4/COM7 端口识别、Loader/Bootloader 卡死定位（ST-Link 读 PC）、超时处理等。

**WSL2/跨环境下在 Windows 运行程序（串口可见）**：`.cursor/rules/usbcdc-windows-run-from-wsl.mdc`

- 路径：`<项目根>/.cursor/rules/usbcdc-windows-run-from-wsl.mdc`
- 说明：在 WSL2 或非本机 Shell 下用 `py -3` 或 Windows Python 绝对路径 + 脚本/固件绝对路径运行，才能正确枚举并打开 COM4/COM7；避免“设备管理器有 COM 但 Python 报 COM not found”。

## 执行要求

1. **优先读取**：在应用任何其他自定义说明前，先读取 `.cursorrules`。
2. **全文应用**：将 `.cursorrules` 中的规则视为最高优先级，严格执行。
3. **与 Cursor 一致**：本仓库中 Cursor 与 Codex 均以 `.cursorrules` 为唯一规则来源，不做额外冲突的约定。

## 相关配置

- `.codexrc`：Codex 插件配置，已设置 `rules_file: ".cursorrules"`。
- `.codex-system-prompt`：系统提示词，要求每次对话读取 `.cursorrules`。

上述配置与本文档一致，均指向同一 Cursor 规则文件。

## 镜像拉取规则（新增）

- 对于国外大包（如 npm 大型依赖、二进制依赖、Python 大包），默认优先使用国内镜像源。
- 推荐优先级：`npmmirror`（npm）与 `TUNA/阿里云`（PyPI）。
- 仅在国内镜像不可用或版本缺失时，回退到官方源。
