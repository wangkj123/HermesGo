# HermesGo Release Workspace

This repository packages Hermes Agent into the HermesGo Windows green bundle.

Current download package: HermesGo-2026.04.22-2025.zip
Current checksum file: HermesGo-2026.04.22-2025.zip.sha256.txt
Current release tag: HermesGo-2026.04.22-2025
This page is generated from `create_hermes_go/release-state.json`.
Use `create_hermes_go/Sync-HermesGoReleaseState.ps1` to update the package names and refresh the docs.

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

## What users should download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- The downloadable zip and checksum are published on the release page above.
- Older release versions remain published on GitHub Releases and are not deleted.
- Yesterday's archive HermesGo-2026.04.21-* is the older version; it is kept on purpose.

## What this repo contains

- Source and packaging scripts for the HermesGo green package
- The standalone test workspace under `create_hermes_go/test`
- Release notes, packaging docs, and build scripts
- Searchable release keywords for the green / USB / one-click install line

## How to work on it safely

Do not edit the release directory directly. Use the isolated test workspace instead:

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. Make your change in `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`
4. Rebuild the package from the source scripts when the sandbox passes

## Release behavior

The shipped `HermesGo` package is a green / USB-friendly / one-click install bundle with a built-in local model runtime. It is intended to run without installing a separate Python runtime or Ollama bundle. `HermesGo.exe` opens a classic launcher for beginners, now with a selectable action box for one-click start, GPT-5.4 mini, Dashboard, and utility actions, while the Dashboard remains available for advanced users. The launcher remembers your last selected item, keeps that item at the top on the next start, and can load custom actions from `home/launcher-actions.txt`. The packaged `HermesGo.exe` has a custom horse-head icon.

For OpenAI Codex, this release does not rely on an external Codex CLI installation. Local 2B startup never triggers ChatGPT / Codex sign-in. Only `Cloud: GPT-5.4 Mini` auto-runs the bundled login flow when Codex auth is missing.

The downloadable zip keeps the top-level `HermesGo/` folder intact so the package can be extracted directly. Older release versions stay published on GitHub Releases and are not deleted when a new release is added.