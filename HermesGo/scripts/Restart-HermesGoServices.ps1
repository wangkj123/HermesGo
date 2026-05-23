# Stop HermesGo gateway/dashboard/webui/desktop so the next launch reloads Python code (e.g. web_search/ddgs).
param([string]$AppRoot = "")

Set-StrictMode -Version Latest
$ErrorActionPreference = "Continue"

function Resolve-AppRoot {
    param([string]$ScriptRoot)
    foreach ($candidate in @($ScriptRoot, (Join-Path $ScriptRoot ".."), (Join-Path $ScriptRoot "..\.."))) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        if (Test-Path -LiteralPath (Join-Path $full "runtime\python311\python.exe")) {
            return $full
        }
    }
    throw "HermesGo app root not found."
}

$root = if ($AppRoot) { [System.IO.Path]::GetFullPath($AppRoot) } else { Resolve-AppRoot -ScriptRoot $PSScriptRoot }
$appNorm = $root.Replace("\", "/").ToLowerInvariant()

function Test-HermesPythonProcess {
    param($Proc)
    if (-not $Proc.CommandLine) { return $false }
    $cmd = $Proc.CommandLine
    if ($cmd -notlike "*$($root.Replace('\','\\'))*" -and $cmd.Replace("\", "/").ToLowerInvariant() -notlike "*$appNorm*") {
        return $false
    }
    return (
        $cmd -like "*hermes_cli*main*" -or
        $cmd -like "*hermes_cli.main*" -or
        $cmd -like "*hermes_cli\\main.py*" -or
        $cmd -like "*hermes_cli/main.py*"
    )
}

Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
    Where-Object {
        $_.CommandLine -and (
            (Test-HermesPythonProcess $_) -or
            $_.CommandLine -like "*Hermes.exe*" -or
            $_.CommandLine -like "*hermes-desktop*"
        )
    } |
    ForEach-Object {
        Write-Host "[HermesGo] Stopping PID $($_.ProcessId): $($_.Name)"
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }

foreach ($port in 9119, 8787, 8642) {
    try {
        Get-NetTCPConnection -LocalPort $port -State Listen -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty OwningProcess -Unique |
            ForEach-Object {
                if ($_ -and $_ -ne $PID) {
                    Write-Host "[HermesGo] Stopping listener on :$port PID $_"
                    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
                }
            }
    } catch {
        # Get-NetTCPConnection may be unavailable
    }
}

Start-Sleep -Seconds 2
Write-Host "[HermesGo] Services stopped. Start HermesGo.bat or HermesDesktop.bat again."
