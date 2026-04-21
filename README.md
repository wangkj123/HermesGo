# HermesGo Release Workspace

This repository packages Hermes Agent into a Windows green bundle called HermesGo.

## What users should download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- Full offline package: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.zip>
- SHA256 checksum: <https://github.com/wangkj123/HermesGo/releases/download/v2026.4.21/HermesGo-2026.04.21-1531.sha256.txt>

## What this repo contains

- Source and packaging scripts for the HermesGo green package
- The standalone test workspace under `create_hermes_go/test`
- Release notes, packaging docs, and build scripts

## How to work on it safely

Do not edit the release directory directly. Use the isolated test workspace instead:

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. Make your change in `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`
4. Rebuild the package from the source scripts when the sandbox passes

## Release behavior

The shipped `HermesGo` package is intended to run without installing a separate Python runtime or Ollama bundle. The main launcher opens the Dashboard in a browser and starts the chat window. The packaged `HermesGo.exe` has a custom horse-head icon. The downloadable zip keeps the top-level `HermesGo/` folder intact so the package can be extracted directly.
