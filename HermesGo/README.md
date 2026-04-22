# HermesGo

HermesGo is the Windows green bundle for Hermes Agent. It is also intended to serve as a USB-friendly, one-click install package with a built-in local model runtime.

Current download package: `HermesGo-2026.04.22-2025.zip`
Current checksum file: `HermesGo-2026.04.22-2025.zip.sha256.txt`
Current release tag: `HermesGo-2026.04.22-2025`

Search keywords:
HermesGo / HermesGo,
Hermes Agent / Hermes Agent,
绿色版 / green package,
U 盘版 / USB bundle,
一键安装版 / one-click install,
便携版 / portable bundle,
USB 版 / USB-friendly package,
Windows 便携 / Windows portable,
本地模型 / local model,
Ollama / Ollama,
OpenAI Codex / OpenAI Codex,
GPT-5.4 Mini / GPT-5.4 Mini.

## Download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- The downloadable zip and checksum are published on the release page above.
- Older release versions remain published on GitHub Releases and are not deleted.
- This repository keeps the old releases intact and adds a new searchable green-package line.
- If you only see `HermesGo-2026.04.21-*`, that is the older archive and not the current package.

The full package is about 1.6 GB and includes everything needed to run directly:

- Hermes Agent runtime
- Dashboard
- Portable Python
- Portable Ollama runtime
- Default Ollama 2B model store
- `HermesGo.exe` with a horse-head icon, a classic beginner launcher, and a selectable action box for fast switching
- Bundled `codex.cmd` compatibility launcher for the release package, not an external Codex CLI dependency
- `tutorial/` with numbered screenshots and usage notes for new users

## How to use

1. Download the full zip. It keeps the top-level `HermesGo/` directory.
2. Extract the whole `HermesGo/` directory. Do not copy only `HermesGo.exe`.
3. Double-click `HermesGo.exe`. It opens the classic launcher with a selectable action box for beginner start, OpenAI GPT-5.4 mini, Dashboard / Config, and utility actions for model switching, self-check, logs, config folders, and custom launcher actions from `home/launcher-actions.txt`.
4. If you prefer the direct entry, double-click `HermesGo.bat`.
5. For a quick self-check, run `Verify-HermesGo.bat`.
6. To switch the default local model, run `Switch-HermesGoModel.bat`.
7. Local 2B startup does not trigger ChatGPT / Codex sign-in. Only `Cloud: GPT-5.4 Mini` auto-runs the bundled login flow when Codex auth is missing.
8. If you are learning the package, open `tutorial/README.md` first and follow the numbered screenshots.

## Directory map

| Path | Purpose |
|---|---|
| `HermesGo.exe` | Classic launcher entrypoint with beginner, cloud, advanced, utility, and custom choices |
| `HermesGo.bat` | Direct entrypoint for the full runtime |
| `Start-HermesGo.ps1` | Main launcher that starts runtime, Dashboard, and chat |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | Structure and runtime verification |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | Switch the default local model |
| `codex.cmd` | Bundled Codex-compatible shim used by the release package |
| `runtime/` | Packaged runtime files |
| `home/` | Persistent config, sessions, state, and memory |
| `data/` | Runtime data |
| `data/ollama/` | Bundled Ollama model store |
| `data/ollama/models/` | Offline model files and manifests |
| `tutorial/` | Numbered usage screenshots and notes for new users |
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

- The launcher remembers the last selected item, loads custom actions from `home/launcher-actions.txt`, and covers both the selectable action box and the legacy button cards for local start, GPT-5.4 mini, and Dashboard
- Cloud / GPT-5.4 mini checks Codex login state before launch and opens the browser login page only when credentials are missing
- `HermesGo.bat` / `Start-HermesGo.ps1` still start the Dashboard flow
- The bundled Ollama 2B model store is available
- The portable Python runtime is still the bundled one
- Launch logs are written to `HermesGo-debug.txt`
- Release packaging excludes local `auth.json` / `auth.lock` credentials from the ship-ready bundle

If you want to keep iterating, do it in the sandbox first and only return to the published package after the sandbox passes.
