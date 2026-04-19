param(
    [switch]$KeepTemp
)

$ErrorActionPreference = "Stop"

$toolsDir = $PSScriptRoot
$repoRoot = Split-Path -Parent $toolsDir
$tmpLogDir = Join-Path $repoRoot "logs\tmp"
$debugLog = Join-Path $repoRoot "HermesGo-debug.txt"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard-supervisor.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard-supervisor.err.txt"

function Write-Step {
    param([string]$Message)
    Write-Host $Message
}

function Assert-Contains {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected file: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($content -notmatch [regex]::Escape($Needle)) {
        throw "Assertion failed for $Label. Needle not found: $Needle"
    }
}

function Reset-Logs {
    New-Item -ItemType Directory -Path $tmpLogDir -Force | Out-Null
    Remove-Item -LiteralPath $debugLog, $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
}

function Invoke-Supervisor {
    param([string[]]$Arguments)

    & powershell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $toolsDir "HermesGoSupervisor.ps1") @Arguments | Out-Null
    return $LASTEXITCODE
}

$originalPopup = $env:HERMESGO_SUPERVISOR_NO_POPUP

try {
    $env:HERMESGO_SUPERVISOR_NO_POPUP = "1"

    Write-Step "Verify supervisor step 1: success path."
    Reset-Logs
    $successExit = Invoke-Supervisor -Arguments @("-NoPause", "-RelaunchOnFailure", "-MaxRestarts", "0")
    if ($successExit -ne 0) {
        throw "Supervisor success path failed with exit code $successExit"
    }
    Assert-Contains $debugLog "Supervisor marked startup as successful." "supervisor-success"
    Assert-Contains $debugLog "Supervisor finished with exit code 0." "supervisor-success-exit"
    Assert-Contains $debugLog "HermesGo finished with exit code 0." "launcher-success"

    Write-Step "Verify supervisor step 2: failure path."
    Reset-Logs
    $env:HERMESGO_PYTHON_EXE = Join-Path $repoRoot "runtime\missing-python.exe"
    $failureExit = Invoke-Supervisor -Arguments @("-NoPause", "-RelaunchOnFailure", "-MaxRestarts", "1")
    if ($failureExit -eq 0) {
        throw "Supervisor failure path unexpectedly succeeded."
    }
    Assert-Contains $debugLog "Supervisor will relaunch after failure." "supervisor-retry"
    Assert-Contains $debugLog "Supervisor finished with exit code 1." "supervisor-failure-exit"
    Assert-Contains $debugLog "HermesGo startup failed: Required path not found:" "launcher-failure"

    Write-Step "HermesGo supervisor verification passed."
}
finally {
    Remove-Item Env:HERMESGO_PYTHON_EXE -ErrorAction SilentlyContinue

    if ($null -eq $originalPopup) {
        Remove-Item Env:HERMESGO_SUPERVISOR_NO_POPUP -ErrorAction SilentlyContinue
    }
    else {
        $env:HERMESGO_SUPERVISOR_NO_POPUP = $originalPopup
    }

    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $debugLog, $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
    }
}
