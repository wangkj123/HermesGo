# HermesGo + Visual Studio Code（绿色版）

在 **Microsoft Visual Studio Code** 里用 Hermes 编程助手（便携 `hermes.cmd`，配置在 `app\home`）。

**不启动 Cursor** — 请用本包自带的 `HermesVSCode.bat`。

## 前提

1. 解压完整绿色包到**英文路径**。
2. 已安装 [Visual Studio Code](https://code.visualstudio.com/download)（Windows 用户版或系统版均可）。
3. 建议先运行一次 `HermesGo.bat` 配好 DeepSeek 等 Key（或已写好 `app\home\.env`）。

## 一键启动

在包根目录（与 `HermesGo.exe` 同级）：

```bat
HermesVSCode.bat
```

会自动：

- 写入 `app\workspace\.vscode\settings.json`（指向本包 `hermes.cmd`）
- 尝试安装 VS Code 扩展 **ACP Client**（`formulahendry.acp-client`，连接 Hermes 用）
- **打开 Visual Studio Code** 并加载 `app\workspace`

## 在 VS Code 里连接 Hermes

1. 侧栏打开 Hermes / ACP 面板（扩展安装后可见）。
2. `Ctrl+Shift+P` → 搜索 **Connect** → 选择 **HermesGo**。
3. 开始对话；改文件、终端、diff 在 VS Code 内完成。

## 可选参数

```bat
HermesVSCode.bat -NoLaunchEditor
HermesVSCode.bat -WorkspaceRoot D:\my-project
```

## 故障排除

| 现象 | 处理 |
|------|------|
| 只闪黑框、没 VS Code | 未安装 VS Code；安装后重跑 `HermesVSCode.bat` |
| 打开了 Cursor | 请用 `HermesVSCode.bat`，不要用 Cursor 代替 |
| 连不上 Hermes | 确认 `app\home\.env` 有 `DEEPSEEK_API_KEY` |
| 扩展未安装 | VS Code 扩展市场搜索 **ACP Client** 手动安装 |

设置模板：`app\editor\vscode\hermes-vscode.settings.json`
