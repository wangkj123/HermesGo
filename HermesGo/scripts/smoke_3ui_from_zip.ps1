# Extract slim zip, seed auth, launch 3 UI stack, run smokes + screenshots.
param(
    [string]$ZipPath = "",
    [string]$ExtractRoot = "E:\AI\hermes\HermesGo-slim-verify-20260518",
    [switch]$SkipExtract,
    [int]$WaitSec = 90
)

$ErrorActionPreference = "Stop"
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not $ZipPath) {
    $dist = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "dist"
    $ZipPath = Get-ChildItem -LiteralPath $dist -Filter "HermesGo-*-green-3ui-slim.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not $ZipPath -or -not (Test-Path -LiteralPath $ZipPath)) {
    throw "Zip not found: $ZipPath"
}

$pkgParent = $ExtractRoot
$pkgRoot = Join-Path $pkgParent "HermesGo"
if (-not $SkipExtract) {
    if (Test-Path -LiteralPath $pkgRoot) {
        Remove-Item -LiteralPath $pkgRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $pkgParent -Force | Out-Null
    Write-Host "Extracting $ZipPath -> $pkgParent"
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $pkgParent -Force
} else {
    Write-Host "SkipExtract: using $pkgRoot"
}

$appRoot = Join-Path $pkgRoot "app"
if (-not (Test-Path -LiteralPath (Join-Path $appRoot "runtime\python311\python.exe"))) {
    $appRoot = $pkgRoot
}
$homeDir = Join-Path $appRoot "home"
$py = Join-Path $appRoot "runtime\python311\python.exe"
$launcher = Join-Path $appRoot "scripts\Start-HermesGo.ps1"
if (-not (Test-Path -LiteralPath $launcher)) {
    $launcher = Join-Path $pkgRoot "Start-HermesGo.ps1"
}
$devLauncher = Join-Path (Split-Path $PSScriptRoot -Parent) "Start-HermesGo.ps1"
if (Test-Path -LiteralPath $devLauncher) {
    Copy-Item -LiteralPath $devLauncher -Destination $launcher -Force
    if (Test-Path -LiteralPath (Join-Path $pkgRoot "Start-HermesGo.ps1")) {
        Copy-Item -LiteralPath $devLauncher -Destination (Join-Path $pkgRoot "Start-HermesGo.ps1") -Force
    }
}

New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
$profileHermes = Join-Path $env:USERPROFILE ".hermes"
foreach ($pair in @(
        @("auth.json", "auth.json"),
        @(".env", ".env")
    )) {
    $src = Join-Path $profileHermes $pair[0]
    $dst = Join-Path $homeDir $pair[1]
    if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "Seeded $($pair[1]) from profile"
    }
}

$bootstrap = @"
import sys
sys.path.insert(0, r'$(Join-Path $appRoot 'runtime\hermes-agent')')
from hermes_cli.portable_bootstrap import ensure_codex_config_if_authed
ensure_codex_config_if_authed()
"@
& $py -c $bootstrap 2>&1 | ForEach-Object { Write-Host $_ }

Get-Process -Name "python","Hermes" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 2

Remove-Item Env:HERMESGO_HEADLESS -ErrorAction SilentlyContinue
$env:HERMESGO_TEST_PACKAGE_ROOT = $pkgRoot
$env:HERMESGO_TEST_APP_ROOT = $appRoot
Write-Host "Launching gateway + Dashboard + WebUI + Desktop..."
& $psExe -NoProfile -ExecutionPolicy Bypass -File $launcher -NoOpenBrowser -NoOpenChat
if ($LASTEXITCODE -ne 0) {
    throw "Launcher failed: $LASTEXITCODE"
}

Start-Sleep -Seconds 15
$scriptsDir = Join-Path (Split-Path $PSScriptRoot -Parent) "scripts"
if (-not (Test-Path -LiteralPath (Join-Path $appRoot "scripts\smoke_portable_desktop.py"))) {
    Copy-Item -LiteralPath (Join-Path $scriptsDir "smoke_portable_desktop.py") -Destination (Join-Path $appRoot "scripts\smoke_portable_desktop.py") -Force
    Copy-Item -LiteralPath (Join-Path $scriptsDir "smoke_portable_connect.py") -Destination (Join-Path $appRoot "scripts\smoke_portable_connect.py") -Force
    Copy-Item -LiteralPath (Join-Path $scriptsDir "check_dashboard_gateway.py") -Destination (Join-Path $appRoot "scripts\check_dashboard_gateway.py") -Force
}

$env:HERMESGO_TEST_PACKAGE_ROOT = $pkgRoot
$env:HERMESGO_TEST_APP_ROOT = $appRoot
& $py (Join-Path $scriptsDir "smoke_portable_desktop.py")
if ($LASTEXITCODE -ne 0) {
    throw "smoke_portable_desktop failed: $LASTEXITCODE"
}
$env:HERMESGO_TEST_APP_ROOT = $appRoot
& $py (Join-Path $scriptsDir "smoke_portable_connect.py")
if ($LASTEXITCODE -ne 0) {
    throw "smoke_portable_connect failed: $LASTEXITCODE"
}

$shotDir = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "exports\ui-trials\2026-05-18-3ui-slim"
New-Item -ItemType Directory -Path $shotDir -Force | Out-Null
$shotScript = Join-Path $scriptsDir "capture_3ui_screenshots.py"
if (Test-Path -LiteralPath $shotScript) {
    & $py $shotScript --out $shotDir
}

Write-Host "OK 3UI verify package=$pkgRoot"
Write-Host "Screenshots: $shotDir"
Write-Host "ZIP: $ZipPath"
