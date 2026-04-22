# HermesGo 教程目录

这个目录放给新手看的图文教程。每张图都按编号命名，方便按顺序学习。

## 图文件命名

- `01-*.png`：启动器主界面
- `02-*.png`：Cloud / GPT-5.4 mini
- `03-*.png`：本地模型切换
- `04-*.png`：自检和日志
- `05-*.png`：自定义动作

## 录像文件命名

- `01-*.mp4`：启动器主界面与默认启动
- `02-*.mp4`：Cloud / GPT-5.4 mini 与浏览器登录入口
- `03-*.mp4`：本地模型切换
- `04-*.mp4`：自检和日志
- `05-*.mp4`：自定义动作

## 当前录像清单

录像都放在 `tutorial/recordings/`。

| 文件 | 作用 |
|---|---|
| `01-启动器主界面.mp4` | 默认启动器界面 |
| `02-Cloud-GPT-5.4-mini.mp4` | Cloud / GPT-5.4 mini 选择页 |
| `02-Cloud-GPT-5.4-mini-login.mp4` | Cloud 路线的登录流程演示 |
| `03-Expert-Dashboard-Only.mp4` | 仅启动 Dashboard 的高级模式 |
| `04-本地模型切换.mp4` | 切换本地 Ollama 模型 |
| `05-自检和日志.mp4` | 自检与日志入口 |
| `06-Codex-登录.mp4` | 直接进入 Codex 登录入口 |
| `07-打开-home-目录.mp4` | 打开 home 目录 |
| `08-打开-logs-目录.mp4` | 打开 logs 目录 |
| `09-自定义动作.mp4` | 打开自定义动作文件 |

## 学习顺序

1. 先看 `01-启动器主界面.png`
2. 再看 `02-Cloud-GPT-5.4-mini.png`
3. 然后看 `03-本地模型切换.png`
4. 接着看 `04-自检和日志.png`
5. 最后看 `05-自定义动作.png`

## 这个目录教什么

- 菜鸟可以直接看 `启动器`，按菜单顺序完成最常见的启动流程。
- `Cloud / GPT-5.4 mini` 会先检查 Codex 登录状态，不满足时先引导登录页，再继续启动。
- `本地模型切换` 用来切换 Ollama 本地模型。
- `自检和日志` 用来确认包是否完整、运行是否正常。
- `自定义动作` 用来学习怎么在 `home/launcher-actions.txt` 里加自己的菜单项。

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
py -3 .\Record-HermesGoTutorial.py --output .\recordings\01-启动器主界面.mp4
py -3 .\Record-HermesGoTutorial.py --screen --output .\recordings\02-Cloud-GPT-5.4-mini.mp4
```

如果你要一次生成全部录像，直接运行 `Make-HermesGoTutorialRecordings.ps1`。

```powershell
.\Make-HermesGoTutorialRecordings.ps1
```

## 约定

- 图片文件名必须带编号，便于排序。
- 图片里只保留 HermesGo 界面，不保留无关桌面内容。
- 每张图都建议配一句说明，放在同目录 `README.md` 里。
- 录像里建议保留完整步骤，不要只截结果。
- 如果是登录类步骤，优先录全屏，方便看到浏览器窗口。
- 自动录制脚本会把录像归档到 `tutorial/recordings/`，不会覆盖图片目录。
