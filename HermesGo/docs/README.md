# HermesGo Technical Documentation

This directory is for technical and developer-facing documentation.

## Documentation Rules

- Root-level `README.md` and `使用说明.txt` are user-facing only.
- Keep setup details, file paths, command examples, and troubleshooting notes here.
- Do not place implementation details in the root user guide.

## Launcher Overview

- Main entry point: `HermesGo.exe`
- Source code: `tools/gui/HermesGoLauncher.cs`
- Build script: `tools/Build-HermesGoLauncher.ps1`
- Maintenance scripts: `tools/`

## Configuration Model

The launcher edits the Hermes home configuration and exposes these model fields:

- `provider`
- `default`
- `base_url`

The launcher persists them in `home/config.yaml`.

## Codex Login

The launcher can start the Codex login flow from the GUI.

- GUI button: `登录 Codex`
- Under the hood: `python.exe -m hermes_cli.main login --provider openai-codex`
- Auth storage: `home/auth.json`

The dashboard also exposes the provider login flow through `Provider Logins`.

## API Keys

If a provider requires an API key, store it in `home/.env`.

## Model Switching

The launcher supports switching models in two ways:

1. Change the fields in the GUI and save the config.
2. Use the Hermes CLI model switch command.

## Launcher and Maintenance Entry

The repository keeps `tools/Start-HermesGo.ps1` and `tools/Verify-HermesGo.ps1` for maintenance and automation.
User-facing documentation should not refer to these scripts as the normal launch path.
