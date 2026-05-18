param(
    [int]$MaxAttempts = 3,
    [int]$SleepSeconds = 3
)

$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$verify = Join-Path $root "Verify-HermesGo.ps1"

if (-not (Test-Path -LiteralPath $verify)) {
    throw "Missing Verify-HermesGo.ps1: $verify"
}

if ($MaxAttempts -lt 1) {
    $MaxAttempts = 1
}

for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
    Write-Host "HermesGo verify attempt $attempt / $MaxAttempts"
    try {
        powershell -NoProfile -ExecutionPolicy Bypass -File $verify
        Write-Host "Verify succeeded."
        exit 0
    } catch {
        Write-Host "Verify failed: $($_.Exception.Message)"
        if ($attempt -lt $MaxAttempts) {
            Start-Sleep -Seconds $SleepSeconds
            continue
        }
        throw
    }
}

