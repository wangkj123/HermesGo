# Launch portable Hermes (headless) and run connectivity smoke tests.
param(
    [string]$PackageRoot = "",
    [string[]]$Launch = @("dashboard", "webui")
)

$ErrorActionPreference = "Stop"
$psExe = Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe"

if (-not $PackageRoot) {
    $here = Split-Path -Parent $PSScriptRoot
    $candidates = @(
        (Join-Path $here "..\HermesGo-slim-test-v014\HermesGo"),
        (Join-Path $here "..")
    )
    foreach ($c in $candidates) {
        $resolved = (Resolve-Path -LiteralPath $c -ErrorAction SilentlyContinue)
        if ($resolved -and (Test-Path -LiteralPath (Join-Path $resolved "HermesGo.bat"))) {
            $PackageRoot = $resolved.Path
            break
        }
    }
}

if (-not $PackageRoot -or -not (Test-Path -LiteralPath (Join-Path $PackageRoot "HermesGo.bat"))) {
    throw "PackageRoot not found (pass -PackageRoot or extract test zip)"
}

$appRoot = Join-Path $PackageRoot "app"
$launcher = Join-Path $appRoot "scripts\Start-HermesGo.ps1"
if (-not (Test-Path -LiteralPath $launcher)) {
    $launcher = Join-Path $PackageRoot "Start-HermesGo.ps1"
}

$env:HERMESGO_HEADLESS = "1"
$env:HERMESGO_ALLOW_HEADLESS = "1"
$env:HERMESGO_LAUNCH = ($Launch -join ",")

Write-Host "=== HermesGo portable self-test ==="
Write-Host "Package: $PackageRoot"
& $psExe -NoProfile -ExecutionPolicy Bypass -File $launcher
if ($LASTEXITCODE -ne 0) {
    throw "Launcher failed with exit code $LASTEXITCODE"
}

$py = Join-Path $appRoot "runtime\python311\python.exe"
$smoke = Join-Path $appRoot "scripts\smoke_portable_connect.py"
if (-not (Test-Path -LiteralPath $smoke)) {
    $smoke = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\smoke_portable_connect.py"
}

$env:HERMESGO_TEST_APP_ROOT = $appRoot
& $py $smoke
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

$hello = Join-Path (Split-Path -Parent $PSScriptRoot) "scripts\smoke_hello_all_ui.py"
if (-not (Test-Path -LiteralPath $hello)) {
    $hello = Join-Path $appRoot "scripts\smoke_hello_all_ui.py"
}
if (Test-Path -LiteralPath $hello) {
    Write-Host "=== hello smoke (CLI + Dashboard + WebUI + Desktop WS) ==="
    $env:PYTHONIOENCODING = "utf-8"
    & $py $hello
}
exit $LASTEXITCODE
