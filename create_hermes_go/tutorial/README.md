# HermesGo 教程目录

这个目录放给新手看的图文教程。每张图和每段录像都按编号命名，方便按顺序学习。

当前 launcher 是经典版：保留 `Beginner: Local Start`、`Cloud: GPT-5.4 Mini`、`Expert: Dashboard / Config` 和各类工具动作；下面列出的旧录像里，本地模型切换、自检和自定义动作都已经回到当前入口。

## 图文件命名

- `01-*.png`：启动器主界面
- `02-*.png`：Cloud / GPT-5.4 mini
- `03-*.png`：更新功能

## 录像文件命名

- `01-*.mp4`：启动器主界面与默认启动
- `02-*.mp4`：Cloud / GPT-5.4 mini 与浏览器登录入口
- `03-*.mp4`：更新功能

## 当前录像清单

录像都放在 `tutorial/recordings/`。

| 文件 | 作用 |
|---|---|
| `01-Local-Start.mp4` | 默认本地 Ollama 2B 启动 |
| `02-Cloud-GPT-5.4-mini.mp4` | Cloud / GPT-5.4 mini 选择项 |
| `02-Cloud-GPT-5.4-mini-login.mp4` | Cloud 路线的登录流程演示 |

## 学习顺序

1. 先看 `01-Local-Start.mp4`
2. 再看 `02-Cloud-GPT-5.4-mini.mp4`
3. 然后看 `02-Cloud-GPT-5.4-mini-login.mp4`

## 这个目录教什么

- 菜鸟可以先直接看 `启动器主界面`，按菜单顺序完成最常见的启动流程。
- `Cloud / GPT-5.4 Mini` 会先检查 Codex 登录状态，不满足时先引导登录页，再继续启动。
- `更新功能` 用来检查并应用 HermesGo 更新。
- 旧录像文件保留作历史归档，方便对照早期版本。

## 截图生成方式

使用 `Capture-HermesGoTutorial.ps1` 生成教程图。

默认会把图片保存到 `tutorial/images/`，并使用带编号的文件名。

示例：

```powershell
.\Capture-HermesGoTutorial.ps1
.\Capture-HermesGoTutorial.ps1 -OutputPath .\images\02-Cloud-GPT-5.4-mini.png
```

## 录像生成方式

使用 `Record-HermesGoTutorial.py` 生成教程录像。

录像默认保存到 `tutorial/recordings/`。每个录像都按编号命名，方便和图片一一对应。

示例：

```powershell
py -3 .\Record-HermesGoTutorial.py --output .\recordings\01-Local-Start.mp4
py -3 .\Record-HermesGoTutorial.py --screen --output .\recordings\02-Cloud-GPT-5.4-mini-login.mp4
```

如果你要一次生成全部录像，直接运行 `Make-HermesGoTutorialRecordings.ps1`。

```powershell
.\Make-HermesGoTutorialRecordings.ps1
```

## 约定

- 文件名必须带编号，便于排序。
- 图片里只保留 HermesGo 界面，不保留无关桌面内容。
- 每张图都建议配一句说明，放在同目录 `README.md` 里。
- 录像里建议保留完整步骤，不要只截结果。
- 如果是登录类步骤，优先录全屏，方便看到浏览器窗口。
- 自动录制脚本会把录像归档到 `tutorial/recordings/`，不会覆盖图片区。
