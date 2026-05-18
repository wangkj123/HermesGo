# Build portable Hermes Desktop (win-unpacked, no NSIS installer) for HermesGo.
# Output: HermesGo/runtime/hermes-desktop/  (Hermes.exe + resources)
param(
    [string]$Branch = "bb/gui",
    [string]$OutDir = "",
    [switch]$SkipFetch
)

$ErrorActionPreference = "Stop"
$HermesGoDir = Split-Path $PSScriptRoot -Parent
$RepoRoot = Split-Path $HermesGoDir -Parent
if (-not $OutDir) {
    $OutDir = Join-Path $HermesGoDir "runtime\hermes-desktop"
}
$BuildRoot = Join-Path $RepoRoot ".build\hermes-agent-desktop"
$ZipPath = Join-Path $BuildRoot "src.zip"
$SrcRoot = Join-Path $BuildRoot "src"

function Ensure-Dir([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

Write-Host "Hermes Desktop portable build"
Write-Host "  Branch: $Branch"
Write-Host "  Output: $OutDir"

Ensure-Dir $BuildRoot

if (-not $SkipFetch) {
    $zipUrl = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/$($Branch -replace '/','-').zip"
    if ($Branch -eq "bb/gui") {
        $zipUrl = "https://github.com/NousResearch/hermes-agent/archive/refs/heads/bb/gui.zip"
    }
    Write-Host "Downloading $zipUrl ..."
    Invoke-WebRequest -Uri $zipUrl -OutFile $ZipPath -UseBasicParsing
    if (Test-Path -LiteralPath $SrcRoot) {
        Remove-Item -LiteralPath $SrcRoot -Recurse -Force
    }
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $BuildRoot -Force
    $extracted = Get-ChildItem -LiteralPath $BuildRoot -Directory | Where-Object { $_.Name -like "hermes-agent-*" } | Select-Object -First 1
    if (-not $extracted) {
        throw "Extracted source folder not found under $BuildRoot"
    }
    Rename-Item -LiteralPath $extracted.FullName -NewName "src" -Force
}

if (-not (Test-Path -LiteralPath (Join-Path $SrcRoot "apps\desktop\package.json"))) {
    throw "apps/desktop not found in $SrcRoot — wrong branch?"
}

$env:NPM_CONFIG_REGISTRY = "https://registry.npmmirror.com"
$env:ELECTRON_MIRROR = "https://npmmirror.com/mirrors/electron/"
$env:ELECTRON_BUILDER_BINARIES_MIRROR = "https://npmmirror.com/mirrors/electron-builder-binaries/"

Push-Location $SrcRoot
try {
    Write-Host "npm install (repo root, npmmirror) ..."
    npm install --no-audit --no-fund
    Push-Location "apps\desktop"
    try {
        Write-Host "npm run pack (electron-builder --dir) ..."
        npm run pack
        $unpacked = Join-Path (Get-Location) "release\win-unpacked"
        if (-not (Test-Path -LiteralPath (Join-Path $unpacked "Hermes.exe"))) {
            throw "win-unpacked missing Hermes.exe at $unpacked"
        }
        if (Test-Path -LiteralPath $OutDir) {
            Remove-Item -LiteralPath $OutDir -Recurse -Force
        }
        Ensure-Dir (Split-Path $OutDir -Parent)
        Copy-Item -LiteralPath $unpacked -Destination $OutDir -Recurse -Force
        Write-Host "OK: copied to $OutDir"
    } finally {
        Pop-Location
    }
} finally {
    Pop-Location
}
