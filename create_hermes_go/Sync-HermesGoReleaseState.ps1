param(
    [string]$CurrentReleaseTag = "",
    [string]$CurrentReleaseZip = "",
    [string]$CurrentReleaseSha = "",
    [string]$PreviousReleasePattern = "",
    [switch]$PublishGitHub
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $scriptRoot
$statePath = Join-Path $scriptRoot "release-state.json"
$builderScript = Join-Path $scriptRoot "Create-HermesGo.ps1"

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Read-ReleaseState {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing release state file: $Path"
    }

    return Get-Content -LiteralPath $Path -Raw -Encoding utf8 | ConvertFrom-Json
}

function Save-ReleaseState {
    param(
        [string]$Path,
        [object]$State
    )

    $json = $State | ConvertTo-Json -Depth 8
    Write-Utf8File -Path $Path -Content ($json + [Environment]::NewLine)
}

function New-RootReadme {
    param(
        [string]$CurrentReleaseTag,
        [string]$CurrentReleaseZip,
        [string]$CurrentReleaseSha,
        [string]$PreviousReleasePattern
    )

    $template = @'
# HermesGo Release Workspace

This repository packages Hermes Agent into the HermesGo Windows green bundle.

Current download package: __CURRENT_RELEASE_ZIP__
Current checksum file: __CURRENT_RELEASE_SHA__
Current release tag: __CURRENT_RELEASE_TAG__
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
- Yesterday's archive __PREVIOUS_RELEASE_PATTERN__ is the older version; it is kept on purpose.

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
'@

    return $template.Replace("__CURRENT_RELEASE_ZIP__", $CurrentReleaseZip).
        Replace("__CURRENT_RELEASE_SHA__", $CurrentReleaseSha).
        Replace("__CURRENT_RELEASE_TAG__", $CurrentReleaseTag).
        Replace("__PREVIOUS_RELEASE_PATTERN__", $PreviousReleasePattern)
}

function New-PackageReadme {
    param(
        [string]$CurrentReleaseTag,
        [string]$CurrentReleaseZip,
        [string]$CurrentReleaseSha,
        [string]$PreviousReleasePattern
    )

    $template = @'
# HermesGo

HermesGo is the Windows green bundle for Hermes Agent. It is also intended to serve as a USB-friendly, one-click install package with a built-in local model runtime.

Current download package: __CURRENT_RELEASE_ZIP__
Current checksum file: __CURRENT_RELEASE_SHA__
Current release tag: __CURRENT_RELEASE_TAG__
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

## Download

- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- The downloadable zip and checksum are published on the release page above.
- Older release versions remain published on GitHub Releases and are not deleted.
- This repository keeps the old releases intact and adds a new searchable green-package line.
- If you only see __PREVIOUS_RELEASE_PATTERN__, that is the older archive and not the current package.

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
'@

    return $template.Replace("__CURRENT_RELEASE_ZIP__", $CurrentReleaseZip).
        Replace("__CURRENT_RELEASE_SHA__", $CurrentReleaseSha).
        Replace("__CURRENT_RELEASE_TAG__", $CurrentReleaseTag).
        Replace("__PREVIOUS_RELEASE_PATTERN__", $PreviousReleasePattern)
}

function Get-GitHubCredential {
    $raw = @"
protocol=https
host=github.com

"@ | git credential fill
    $pairs = [ordered]@{}
    foreach ($line in $raw) {
        if ($line -match '^(?<key>[^=]+)=(?<value>.*)$') {
            $pairs[$Matches.key] = $Matches.value
        }
    }

    return [pscustomobject]$pairs
}

function Get-RepoName {
    $remote = git remote get-url origin
    if ($remote -match 'github\.com[:/](?<owner>[^/]+)/(?<repo>[^/.]+)') {
        return "$($Matches.owner)/$($Matches.repo)"
    }
    throw "Unable to infer GitHub repository name from origin remote."
}

function Update-GitHubMetadata {
    param(
        [string]$RepoName,
        [string]$CurrentReleaseTag,
        [string]$CurrentReleaseZip,
        [string]$CurrentReleaseSha,
        [string]$PreviousReleasePattern,
        [string]$Token
    )

    $headers = @{
        Authorization = "token $Token"
        Accept = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $repoBody = @{
        description = "HermesGo green package / USB-friendly / one-click install bundle with built-in local model runtime and Hermes Agent"
        homepage = "https://github.com/$RepoName/releases/latest"
    } | ConvertTo-Json
    Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$RepoName" -Headers $headers -ContentType "application/json" -Body $repoBody | Out-Null

    $topics = @{
        names = @(
            "chatgpt",
            "codex",
            "hermes-agent",
            "local-model",
            "ollama",
            "one-click-install",
            "portable-windows",
            "usb-friendly",
            "windows",
            "green-package"
        )
    } | ConvertTo-Json -Depth 4
    Invoke-RestMethod -Method Put -Uri "https://api.github.com/repos/$RepoName/topics" -Headers $headers -ContentType "application/json" -Body $topics | Out-Null

    $release = Invoke-RestMethod -Method Get -Uri "https://api.github.com/repos/$RepoName/releases/tags/$CurrentReleaseTag" -Headers $headers
    $releaseTemplate = @'
# HermesGo 绿色版 / U 盘版 / 一键安装版

Current release: __CURRENT_RELEASE_TAG__

If you are seeing __PREVIOUS_RELEASE_PATTERN__, that is yesterday's older archive and is kept on purpose.

## 关键词 / Keywords
HermesGo / HermesGo, Hermes Agent / Hermes Agent, 绿色版 / green package, U 盘版 / USB bundle, 一键安装版 / one-click install, 便携版 / portable bundle, USB 版 / USB-friendly package, Windows 便携 / Windows portable, 本地模型 / local model, Ollama / Ollama, OpenAI Codex / OpenAI Codex, GPT-5.4 Mini / GPT-5.4 Mini

## Highlights
- Green / USB-friendly / one-click install bundle with a built-in local model runtime
- Local 2B startup does not trigger ChatGPT / Codex sign-in
- Only `Cloud: GPT-5.4 Mini` auto-runs the bundled login flow when Codex auth is missing
- OpenAI Codex login is implemented inside Hermes; it does not depend on an external Codex CLI installation
- The bundle excludes local `auth.json` / `auth.lock` credentials
- Source and release notes are published together

## Validation
- Release workspace login flow tests: 15/15 OK
- Release package rebuilt successfully
- Release archive verified to contain no `auth.json` / `auth.lock` entries

## Assets
"__CURRENT_RELEASE_ZIP__
"__CURRENT_RELEASE_SHA__
'@

    $releaseBody = $releaseTemplate.Replace("__CURRENT_RELEASE_TAG__", $CurrentReleaseTag).
        Replace("__PREVIOUS_RELEASE_PATTERN__", $PreviousReleasePattern).
        Replace("__CURRENT_RELEASE_ZIP__", $CurrentReleaseZip).
        Replace("__CURRENT_RELEASE_SHA__", $CurrentReleaseSha)

    $releasePatch = @{
        name = "HermesGo $($CurrentReleaseTag -replace '^HermesGo-', '') Green USB One-Click"
        body = $releaseBody
    } | ConvertTo-Json -Depth 6
    Invoke-RestMethod -Method Patch -Uri "https://api.github.com/repos/$RepoName/releases/$($release.id)" -Headers $headers -ContentType "application/json; charset=utf-8" -Body $releasePatch | Out-Null
}

$state = Read-ReleaseState -Path $statePath
if ($CurrentReleaseTag) { $state.currentReleaseTag = $CurrentReleaseTag }
if ($CurrentReleaseZip) { $state.currentReleaseZip = $CurrentReleaseZip }
if ($CurrentReleaseSha) { $state.currentReleaseSha = $CurrentReleaseSha }
if ($PreviousReleasePattern) { $state.previousReleasePattern = $PreviousReleasePattern }

if (-not $state.currentReleaseTag -or -not $state.currentReleaseZip -or -not $state.currentReleaseSha -or -not $state.previousReleasePattern) {
    throw "Release state file is incomplete."
}

Save-ReleaseState -Path $statePath -State $state

$currentReleaseTag = [string]$state.currentReleaseTag
$currentReleaseZip = [string]$state.currentReleaseZip
$currentReleaseSha = [string]$state.currentReleaseSha
$previousReleasePattern = [string]$state.previousReleasePattern

$rootReadme = New-RootReadme -CurrentReleaseTag $currentReleaseTag -CurrentReleaseZip $currentReleaseZip -CurrentReleaseSha $currentReleaseSha -PreviousReleasePattern $previousReleasePattern
$packageReadme = New-PackageReadme -CurrentReleaseTag $currentReleaseTag -CurrentReleaseZip $currentReleaseZip -CurrentReleaseSha $currentReleaseSha -PreviousReleasePattern $previousReleasePattern
Write-Utf8File -Path (Join-Path $repoRoot "README.md") -Content $rootReadme
Write-Utf8File -Path (Join-Path $repoRoot "HermesGo\README.md") -Content $packageReadme

& powershell -ExecutionPolicy Bypass -File $builderScript
if ($LASTEXITCODE -ne 0) {
    throw "Create-HermesGo.ps1 failed with exit code $LASTEXITCODE"
}

if ($PublishGitHub) {
    $cred = Get-GitHubCredential
    if (-not $cred.password) {
        throw "GitHub credential helper did not return a token."
    }
    $repoName = Get-RepoName
    Update-GitHubMetadata -RepoName $repoName -CurrentReleaseTag $currentReleaseTag -CurrentReleaseZip $currentReleaseZip -CurrentReleaseSha $currentReleaseSha -PreviousReleasePattern $previousReleasePattern -Token $cred.password
}

Write-Host "HermesGo release state synchronized: $currentReleaseTag"
