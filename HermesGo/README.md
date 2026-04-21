# HermesGo

HermesGo is the Windows green-package delivery directory for Hermes Agent.

## Download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- Full offline package: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.4.21.zip>
- SHA256 checksum: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.4.21.sha256.txt>

The full package is about 1.6 GB and includes everything needed to run HermesGo directly:

- Hermes Agent runtime
- Dashboard
- bundled Python runtime
- bundled Ollama runtime
- default Ollama 2B model store

## How to use

1. Download the full zip package.
2. Extract the whole `HermesGo/` directory.
3. Double-click `HermesGo.bat`.
4. Use `Verify-HermesGo.bat` if you want a quick integrity check.
5. Use `Switch-HermesGoModel.bat` to change the default local model.

Do not copy only `HermesGo.exe`. Keep the full directory tree together.

## What each folder does

| Path | Purpose |
|---|---|
| `HermesGo.bat` | Windows double-click entry point |
| `Start-HermesGo.ps1` | Main launcher that starts runtime, Dashboard, and chat window |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | Sanity checks for required files and runtime layout |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | Switch the default local model |
| `runtime/` | Bundled runtime files |
| `home/` | Persistent config, sessions, state, and memory |
| `data/` | Runtime data |
| `data/ollama/` | Bundled Ollama model store |
| `data/ollama/models/` | Offline model files and manifests |
| `installers/` | Optional installers, not required for launch |
| `logs/` | Temporary logs |
| `HermesGo-debug.txt` | Root debug log, refreshed on each launch |

## How to build and test

If you want to modify the package, do not work directly in the release folder. Use the dedicated test workspace:

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. It copies `create_hermes_go/output/HermesGo` into `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Make changes inside the sandbox
4. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

I have already run that flow locally and confirmed it passes.
