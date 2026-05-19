# Full smoke iteration: extract latest slim zip, launch 3UI, run all smokes.
param(
    [string]$ZipPath = "",
    [string]$ExtractRoot = "E:\AI\hermes\HermesGo-slim-verify-iter",
    [switch]$SkipExtract,
    [switch]$SkipLaunch
)

$ErrorActionPreference = "Stop"
$repoRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$devHermes = Join-Path $repoRoot "HermesGo"
$scriptsDir = Join-Path $devHermes "scripts"
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not $ZipPath) {
    $dist = Join-Path $repoRoot "dist"
    $ZipPath = Get-ChildItem -LiteralPath $dist -Filter "HermesGo-*-green-3ui-slim.zip" |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1 -ExpandProperty FullName
}
if (-not (Test-Path -LiteralPath $ZipPath)) {
    throw "Zip not found: $ZipPath"
}

$pkgParent = $ExtractRoot
$pkgRoot = Join-Path $pkgParent "HermesGo"
if (-not $SkipExtract) {
    Get-Process -Name "python","Hermes" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    if (Test-Path -LiteralPath $pkgRoot) {
        Remove-Item -LiteralPath $pkgRoot -Recurse -Force
    }
    New-Item -ItemType Directory -Path $pkgParent -Force | Out-Null
    Write-Host "=== Extract $($ZipPath) -> $pkgParent ==="
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $pkgParent -Force
}

$appRoot = Join-Path $pkgRoot "app"
if (-not (Test-Path -LiteralPath (Join-Path $appRoot "runtime\python311\python.exe"))) {
    throw "Invalid package layout: missing app\runtime\python311\python.exe"
}
$homeDir = Join-Path $appRoot "home"
$py = Join-Path $appRoot "runtime\python311\python.exe"
$launcher = Join-Path $appRoot "scripts\Start-HermesGo.ps1"
if (-not (Test-Path -LiteralPath $launcher)) {
    $launcher = Join-Path $pkgRoot "Start-HermesGo.ps1"
}

# Overlay latest launcher + smoke scripts from dev tree.
$devLauncher = Join-Path $devHermes "Start-HermesGo.ps1"
if (Test-Path -LiteralPath $devLauncher) {
    New-Item -ItemType Directory -Path (Split-Path $launcher) -Force | Out-Null
    Copy-Item -LiteralPath $devLauncher -Destination $launcher -Force
}
$appScripts = Join-Path $appRoot "scripts"
New-Item -ItemType Directory -Path $appScripts -Force | Out-Null
foreach ($name in @(
        "check_dashboard_gateway.py",
        "smoke_portable_connect.py",
        "smoke_portable_desktop.py",
        "smoke_kanban_all_ui.py",
        "smoke_kanban_api.py",
        "smoke_hello_all_ui.py"
    )) {
    $src = Join-Path $scriptsDir $name
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination (Join-Path $appScripts $name) -Force
    }
}

# Seed auth from profile if missing.
New-Item -ItemType Directory -Path $homeDir -Force | Out-Null
$profileHermes = Join-Path $env:USERPROFILE ".hermes"
foreach ($pair in @(@("auth.json", "auth.json"), @(".env", ".env"))) {
    $src = Join-Path $profileHermes $pair[0]
    $dst = Join-Path $homeDir $pair[1]
    if ((Test-Path -LiteralPath $src) -and -not (Test-Path -LiteralPath $dst)) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
        Write-Host "Seeded $($pair[1]) from profile"
    }
}

$agentRoot = Join-Path $appRoot "runtime\hermes-agent"
$devAgent = Join-Path $devHermes "runtime\hermes-agent"
foreach ($rel in @(
        "hermes_constants.py",
        "hermes_cli\web_server.py",
        "hermes_cli\kanban_db.py",
        "hermes_cli\kanban.py"
    )) {
    $src = Join-Path $devAgent $rel
    $dst = Join-Path $agentRoot $rel
    if (Test-Path -LiteralPath $src) {
        Copy-Item -LiteralPath $src -Destination $dst -Force
    }
}

if (-not $SkipLaunch) {
    Get-Process -Name "python","Hermes" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Remove-Item Env:HERMESGO_HEADLESS -ErrorAction SilentlyContinue
    Write-Host "=== Launch gateway + Dashboard + WebUI + Desktop ==="
    & $psExe -NoProfile -ExecutionPolicy Bypass -File $launcher -NoOpenBrowser -NoOpenChat
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher failed: $LASTEXITCODE"
    }
    Write-Host "=== Wait for dashboard/webui + gateway pid ==="
    $deadline = (Get-Date).AddSeconds(90)
    $portsOk = $false
    $gwCheck = @"
import sys
sys.path.insert(0, r'$agentRoot')
import os
os.environ['HERMES_HOME'] = r'$homeDir'
from gateway.status import get_running_pid
raise SystemExit(0 if get_running_pid() else 1)
"@
    while ((Get-Date) -lt $deadline) {
        $d = Test-NetConnection 127.0.0.1 -Port 9119 -WarningAction SilentlyContinue
        $w = Test-NetConnection 127.0.0.1 -Port 8787 -WarningAction SilentlyContinue
        $gw = $false
        & $py -c $gwCheck 2>$null | Out-Null
        if ($LASTEXITCODE -eq 0) { $gw = $true }
        if ($gw -and $d.TcpTestSucceeded -and $w.TcpTestSucceeded) {
            $portsOk = $true
            Write-Host "OK gateway pid + ports 9119, 8787"
            break
        }
        Start-Sleep -Seconds 2
    }
    if (-not $portsOk) {
        throw "Services not ready (gateway pid + 9119/8787) after 90s"
    }
    Start-Sleep -Seconds 3
}

$env:HERMESGO_TEST_PACKAGE_ROOT = $pkgRoot
$env:HERMESGO_TEST_APP_ROOT = $appRoot
$env:HERMESGO_VERIFY_DESKTOP_ONLY = "1"

# Ensure kanban schema exists before API smokes.
$initKanban = @"
import sys
sys.path.insert(0, r'$agentRoot')
import os
os.environ['HERMES_HOME'] = r'$homeDir'
os.environ['HERMES_PORTABLE_APP_ROOT'] = r'$appRoot'
from hermes_cli import kanban_db as kb
kb.init_db()
print('kanban init ok')
"@
& $py -c $initKanban 2>&1 | ForEach-Object { Write-Host $_ }

$smokes = @(
    @{ Name = "check_dashboard_gateway"; Path = "check_dashboard_gateway.py" },
    @{ Name = "smoke_portable_desktop"; Path = "smoke_portable_desktop.py" },
    @{ Name = "smoke_portable_connect"; Path = "smoke_portable_connect.py" },
    @{ Name = "smoke_kanban_api"; Path = "smoke_kanban_api.py" },
    @{ Name = "smoke_kanban_all_ui"; Path = "smoke_kanban_all_ui.py" },
    @{ Name = "smoke_hello_all_ui"; Path = "smoke_hello_all_ui.py" }
)

$failed = @()
foreach ($smoke in $smokes) {
    $scriptPath = Join-Path $appScripts $smoke.Path
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        $scriptPath = Join-Path $scriptsDir $smoke.Path
    }
    if (-not (Test-Path -LiteralPath $scriptPath)) {
        Write-Host "SKIP $($smoke.Name): script missing"
        continue
    }
    Write-Host ""
    Write-Host "=== RUN $($smoke.Name) ==="
    & $py $scriptPath
    if ($LASTEXITCODE -ne 0) {
        $failed += $smoke.Name
        Write-Host "FAIL $($smoke.Name) exit=$LASTEXITCODE"
    } else {
        Write-Host "OK $($smoke.Name)"
    }
}

Write-Host ""
Write-Host "=== FULL SMOKE SUMMARY ==="
Write-Host "ZIP: $ZipPath"
Write-Host "Package: $pkgRoot"
if ($failed.Count -gt 0) {
    Write-Host "FAILED: $($failed -join ', ')"
    exit 1
}
Write-Host "ALL SMOKES PASSED"
exit 0
