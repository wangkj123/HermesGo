param(
    [int]$StartupTimeoutSec = 180,
    [int]$PollIntervalMs = 1000,
    [switch]$RelaunchOnFailure,
    [int]$MaxRestarts = 1,
    [switch]$PopupOnFailure,
    [switch]$NoPause
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$toolsDir = $PSScriptRoot
$appRoot = Split-Path -Parent $toolsDir
$launcher = Join-Path $appRoot "tools\Start-HermesGo.ps1"
$debugLog = Join-Path $appRoot "HermesGo-debug.txt"

function Write-SupervisorLine {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[${timestamp}] $Message"
    Add-Content -LiteralPath $debugLog -Value $line -Encoding utf8
    Write-Host $line
}

function Get-DeltaLines {
    param(
        [string]$Path,
        [ref]$KnownCount
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $lines = @(Get-Content -LiteralPath $Path -Encoding utf8)
    if ($lines.Count -le $KnownCount.Value) {
        return @()
    }

    $startIndex = $KnownCount.Value
    $KnownCount.Value = $lines.Count
    return @($lines[$startIndex..($lines.Count - 1)])
}

function Get-ObservedState {
    param([string[]]$Lines)

    $state = [ordered]@{
        Success = $false
        Failure = $false
        ExitCode = $null
        Reason = ""
    }

    foreach ($line in $Lines) {
        if ($line -match "HermesGo finished with exit code (\d+)") {
            $state.ExitCode = [int]$Matches[1]
            if ($state.ExitCode -eq 0) {
                $state.Success = $true
                $state.Reason = "Launcher reported exit code 0."
            }
            else {
                $state.Failure = $true
                $state.Reason = "Launcher reported exit code $($state.ExitCode)."
            }
        }

        if ($line -match "Hello probe succeeded") {
            $state.Success = $true
            if (-not $state.Reason) {
                $state.Reason = "Hello probe succeeded."
            }
        }

        if (
            $line -match "startup failed" -or
            $line -match "Docker Compose command failed" -or
            $line -match "Hello probe failed"
        ) {
            $state.Failure = $true
            $state.Reason = $line
        }
    }

    return [pscustomobject]$state
}

function Show-FailurePopup {
    param([string]$Message)

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        $Message,
        "HermesGo Supervisor",
        [System.Windows.Forms.MessageBoxButtons]::OK,
        [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
}

if (-not (Test-Path -LiteralPath $launcher)) {
    Write-SupervisorLine "Supervisor failed: launcher not found at $launcher"
    if ($PopupOnFailure) {
        Show-FailurePopup "HermesGo launcher not found.`r`n$launcher"
    }
    exit 1
}

$maxAttempts = 1
if ($RelaunchOnFailure) {
    $maxAttempts += [Math]::Max($MaxRestarts, 0)
}

$finalExitCode = 1
$attempt = 0

Remove-Item -LiteralPath $debugLog -Force -ErrorAction SilentlyContinue

while ($attempt -lt $maxAttempts) {
    $attempt += 1
    Write-SupervisorLine "Supervisor attempt $attempt/$maxAttempts starting."

    $knownCount = 0
    if (Test-Path -LiteralPath $debugLog) {
        $knownCount = @(Get-Content -LiteralPath $debugLog -Encoding utf8).Count
    }

    $previousHeadless = $env:HERMESGO_HEADLESS
    $previousAppendDebugLog = $env:HERMESGO_APPEND_DEBUG_LOG
    $env:HERMESGO_HEADLESS = "1"
    $env:HERMESGO_APPEND_DEBUG_LOG = "1"

    $process = Start-Process -FilePath "powershell.exe" -ArgumentList @(
        "-NoProfile",
        "-ExecutionPolicy",
        "Bypass",
        "-File",
        $launcher,
        "-NoOpenBrowser",
        "-NoOpenChat"
    ) -WorkingDirectory $appRoot -PassThru -WindowStyle Hidden
    Write-SupervisorLine "Supervisor started PID $($process.Id)."

    $observedLines = New-Object System.Collections.Generic.List[string]
    $deadline = (Get-Date).AddSeconds($StartupTimeoutSec)
    $attemptFailed = $false
    $attemptReason = ""

    try {
        while ($true) {
            foreach ($line in (Get-DeltaLines -Path $debugLog -KnownCount ([ref]$knownCount))) {
                $observedLines.Add($line)
                Write-Host "[HermesGo] $line"
            }

            $state = Get-ObservedState -Lines $observedLines.ToArray()

            if ($state.Failure) {
                $attemptFailed = $true
                $attemptReason = $state.Reason
                if (-not $process.HasExited) {
                    Stop-Process -Id $process.Id -Force
                }
                break
            }

            if ($process.HasExited) {
                if ($state.Success -and ($null -eq $state.ExitCode -or $state.ExitCode -eq 0)) {
                    $attemptReason = if ($state.Reason) { $state.Reason } else { "Process exited cleanly." }
                    $finalExitCode = 0
                    Write-SupervisorLine "Supervisor marked startup as successful. $attemptReason"
                    break
                }

                $attemptFailed = $true
                if ($state.ExitCode -ne $null) {
                    $attemptReason = "Process exited before successful startup with exit code $($state.ExitCode)."
                }
                else {
                    $attemptReason = "Process exited before writing a successful completion marker."
                }
                break
            }

            if ((Get-Date) -ge $deadline) {
                $attemptFailed = $true
                $attemptReason = "Startup did not finish within $StartupTimeoutSec seconds."
                Stop-Process -Id $process.Id -Force
                break
            }

            Start-Sleep -Milliseconds $PollIntervalMs
        }
    }
    finally {
        if ($null -eq $previousHeadless) {
            Remove-Item Env:HERMESGO_HEADLESS -ErrorAction SilentlyContinue
        }
        else {
            $env:HERMESGO_HEADLESS = $previousHeadless
        }

        if ($null -eq $previousAppendDebugLog) {
            Remove-Item Env:HERMESGO_APPEND_DEBUG_LOG -ErrorAction SilentlyContinue
        }
        else {
            $env:HERMESGO_APPEND_DEBUG_LOG = $previousAppendDebugLog
        }
    }

    if (-not $attemptFailed -and $finalExitCode -eq 0) {
        break
    }

    $finalExitCode = 1
    Write-SupervisorLine "Supervisor detected startup failure. $attemptReason"

    if ($attempt -lt $maxAttempts) {
        Write-SupervisorLine "Supervisor will relaunch after failure."
        Start-Sleep -Seconds 2
        continue
    }

    if ($PopupOnFailure) {
        Show-FailurePopup "HermesGo startup failed.`r`n$attemptReason`r`n`r`nSee:`r`n$debugLog"
    }
}

Write-SupervisorLine "Supervisor finished with exit code $finalExitCode."
if ($NoPause) {
    exit $finalExitCode
}

exit $finalExitCode
