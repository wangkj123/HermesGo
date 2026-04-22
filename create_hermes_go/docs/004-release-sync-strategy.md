# 004-Release Sync Strategy

## Principle

Use scripts as the source of truth. Do not hand-edit release names, download names, or GitHub metadata every time a new package is published.

## Single source of truth

- `create_hermes_go/release-state.json` stores the current release tag, zip name, checksum name, and the previous-release pattern.
- `create_hermes_go/Create-HermesGo.ps1` reads that state file and generates the package plus the generated docs.
- `create_hermes_go/Sync-HermesGoReleaseState.ps1` updates the state file, refreshes the README files, regenerates the package, and can optionally patch GitHub metadata.

## Required workflow

1. Update `create_hermes_go/release-state.json`.
2. Run `create_hermes_go/Sync-HermesGoReleaseState.ps1`.
3. If GitHub metadata changed, let the script update the repository homepage, description, topics, and release body.
4. Keep old releases on GitHub Releases. Never delete them just because a new build exists.

## What gets regenerated

- Repository root `README.md`
- `HermesGo/README.md`
- `create_hermes_go/README.md`
- `create_hermes_go/docs/001-当前状态与标准边界.md`
- `create_hermes_go/docs/002-便携构建步骤与后续工作.md`
- `create_hermes_go/docs/003-green-usb-oneclick-release-notes.md`
- The packaged `create_hermes_go/output/HermesGo` directory

## Why this exists

- It prevents the homepage from drifting back to yesterday's package.
- It keeps the release text, repository description, and package documentation aligned.
- It makes future release updates repeatable without relying on manual copy/paste.

## Archiving

- When a release sync task is finished, record the final state in `logs/agent-progress.md`.
- Keep the strategy, state file, and generated docs in the repository so the next run can repeat the same flow.
- Do not give this release line special handling after completion; follow the same script-driven process every time.

## Search keywords

HermesGo / HermesGo, Hermes Agent / Hermes Agent, 绿色版 / green package, U 盘版 / USB bundle, 一键安装版 / one-click install, 便携版 / portable bundle, USB 版 / USB-friendly package, Windows 便携 / Windows portable, 本地模型 / local model, Ollama / Ollama, OpenAI Codex / OpenAI Codex, GPT-5.4 Mini / GPT-5.4 Mini
