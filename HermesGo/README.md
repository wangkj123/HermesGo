# HermesGo

这是这个工程的使用说明，不是上游 Hermes Agent 的通用介绍。

`HermesGo/` 目录里放的是可交付的 Windows 绿色包。`create_hermes_go/` 负责生成它，`create_hermes_go/test/` 负责独立测试和反复迭代。

## 怎么用

1. 把整个 `HermesGo/` 目录原样复制到目标机器，不要只拷贝 `HermesGo.exe`。
2. 双击 `HermesGo.bat`。
3. 如果你想直接看启动脚本，运行 `Start-HermesGo.ps1`。
4. 如果你想换默认本地模型，运行 `Switch-HermesGoModel.bat` 或 `Switch-HermesGoModel.ps1`。
5. 如果你想先检查包是否完整，运行 `Verify-HermesGo.bat` 或 `Verify-HermesGo.ps1`。

## 目录说明

- `HermesGo.bat`：Windows 双击入口
- `Start-HermesGo.ps1`：真正的启动脚本
- `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1`：切换本地模型
- `Verify-HermesGo.bat` / `Verify-HermesGo.ps1`：自检入口
- `runtime/`：随包携带的运行时
- `home/`：配置、会话、状态和持久化数据
- `data/ollama/models/`：离线本地模型缓存
- `installers/`：可选安装器，不是启动必需项
- `HermesGo-debug.txt`：启动和排障日志
- `logs/tmp/`：临时日志

## 自测结果

我已经在本机跑过这套包的测试工作区流程：

- `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
- `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

结果是通过的。也就是说，`create_hermes_go/output/HermesGo` 可以被复制到独立沙箱里继续改，不会破坏交付结构。

## 独立迭代

如果你要改包，不要直接在正式 `HermesGo/` 里反复试。

1. 先运行 `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`。
2. 它会把 `create_hermes_go/output/HermesGo` 复制到 `create_hermes_go/test/workspaces/HermesGo-sandbox`。
3. 在这个沙箱里修改、启动、验证。
4. 每次改完后运行 `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`。

## 打包来源

如果你想重新生成这个绿色包，入口在 `create_hermes_go/` 目录。
那个目录下面的 `README.md` 和 `test/README.md` 说明了构建和验证流程。
