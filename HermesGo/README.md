# HermesGo

HermesGo is the Windows green bundle for Hermes Agent.

## Download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- Full offline package: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.zip>
- Checksum file: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.sha256.txt>

The full package is about 1.6 GB and includes everything needed to run directly:

- Hermes Agent runtime
- Dashboard
- Portable Python
- Portable Ollama runtime
- Default Ollama 2B model store
- `HermesGo.exe` with a horse-head icon
- Bundled `codex.cmd` compatibility launcher

## How to use

1. Download the full zip. It keeps the top-level `HermesGo/` directory.
2. Extract the whole `HermesGo/` directory. Do not copy only `HermesGo.exe`.
3. Double-click `HermesGo.exe`. It opens the Dashboard `Config` page in your browser and starts the `HermesGo Chat` window.
4. If you prefer the batch entry, double-click `HermesGo.bat`.
5. For a quick self-check, run `Verify-HermesGo.bat`.
6. To switch the default local model, run `Switch-HermesGoModel.bat`.
7. To configure Codex / account login, use the Dashboard `Config` page or run `codex.cmd login`.

## Directory map

| Path | Purpose |
|---|---|
| `HermesGo.exe` | Main green-bundle entrypoint with the custom icon |
| `HermesGo.bat` | Batch entrypoint for double-click launch |
| `Start-HermesGo.ps1` | Main launcher that starts runtime, Dashboard, and chat |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | Structure and runtime verification |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | Switch the default local model |
| `codex.cmd` | Codex-compatible shim that routes into Hermes login flow |
| `runtime/` | Packaged runtime files |
| `home/` | Persistent config, sessions, state, and memory |
| `data/` | Runtime data |
| `data/ollama/` | Bundled Ollama model store |
| `data/ollama/models/` | Offline model files and manifests |
| `logs/` | Temporary logs |
| `HermesGo-debug.txt` | Root debug log, refreshed on each launch |
| `installers/` | Optional installer drop-in directory, not required for runtime |

## How I tested it

I did not keep editing the published output directly. I used an isolated test workspace:

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. The script copies `create_hermes_go/output/HermesGo` into `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Make changes and launch `HermesGo.exe` / `HermesGo.bat` in the sandbox
4. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

What the verification checks:

- `HermesGo.bat` / `Start-HermesGo.ps1` still start the Dashboard
- The bundled Ollama 2B model store is available
- The portable Python runtime is still the bundled one
- Launch logs are written to `HermesGo-debug.txt`

If you want to keep iterating, do it in the sandbox first and only return to the published package after the sandbox passes.
