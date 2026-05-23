# Registers portable Hermes CLI on Windows PATH (User by default) so `hermes` works in new terminals.
# Dot-source from Start-HermesGo.ps1 / Verify-HermesGo.ps1 / Switch-HermesGoModel.ps1

Set-StrictMode -Version Latest

function Get-HermesGoPathScope {
    $raw = $env:HERMESGO_PATH_SCOPE
    if ($raw -eq 'Machine' -or $raw -eq 'User') {
        return [EnvironmentVariableTarget]$raw
    }
    return [EnvironmentVariableTarget]::User
}

function Test-PathEntryPresent {
    param(
        [string]$PathValue,
        [string]$Entry
    )

    if ([string]::IsNullOrWhiteSpace($PathValue) -or [string]::IsNullOrWhiteSpace($Entry)) {
        return $false
    }

    $normalizedEntry = ([System.IO.Path]::GetFullPath($Entry)).TrimEnd('\')
    foreach ($part in ($PathValue -split ';')) {
        $trimmed = $part.Trim().Trim('"')
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        try {
            $candidate = ([System.IO.Path]::GetFullPath($trimmed)).TrimEnd('\')
            if ($candidate -eq $normalizedEntry) {
                return $true
            }
        } catch {
            if ($trimmed -eq $Entry.TrimEnd('\')) {
                return $true
            }
        }
    }

    return $false
}

function Remove-PathEntriesMatching {
    param(
        [string]$PathValue,
        [string[]]$Patterns
    )

    if ([string]::IsNullOrWhiteSpace($PathValue)) {
        return ''
    }

    $kept = New-Object System.Collections.Generic.List[string]
    foreach ($part in ($PathValue -split ';')) {
        $trimmed = $part.Trim()
        if ([string]::IsNullOrWhiteSpace($trimmed)) {
            continue
        }
        $drop = $false
        foreach ($pattern in $Patterns) {
            if ($trimmed -like $pattern) {
                $drop = $true
                break
            }
        }
        if (-not $drop) {
            [void]$kept.Add($trimmed)
        }
    }

    return [string]::Join(';', $kept.ToArray())
}

function Broadcast-EnvironmentChange {
    try {
        Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class HermesGoEnvBroadcast {
    [DllImport("user32.dll", CharSet = CharSet.Auto)]
    public static extern IntPtr SendMessageTimeout(
        IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
        uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
}
"@ -ErrorAction Stop | Out-Null
        $null = [UIntPtr]::Zero
        [HermesGoEnvBroadcast]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1a, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$null) | Out-Null
    } catch {
        # Non-fatal: new terminals still pick up User PATH on their own.
    }
}

function Ensure-PortableHermesCliWrapper {
    param(
        [string]$AppRoot,
        [scriptblock]$LogLine = { param($Message) Write-Host $Message }
    )

    $binDir = Join-Path $AppRoot 'runtime\bin'
    if (-not (Test-Path -LiteralPath $binDir)) {
        New-Item -ItemType Directory -Path $binDir -Force | Out-Null
    }

    $hermesCmd = Join-Path $binDir 'hermes.cmd'
    $pythonExe = Join-Path $AppRoot 'runtime\python311\python.exe'
    if (-not (Test-Path -LiteralPath $pythonExe)) {
        throw "Portable Python not found: $pythonExe"
    }

    $content = @"
@echo off
setlocal EnableExtensions
for %%I in ("%~dp0..\..") do set "HERMESGO_APP=%%~fI"
set "PYTHON_EXE=%HERMESGO_APP%\runtime\python311\python.exe"
set "HERMES_HOME=%HERMESGO_APP%\home"
set "HERMES_PORTABLE_APP_ROOT=%HERMESGO_APP%"
set "HERMESGO_STRICT_PORTABLE=1"
set "HERMES_PORTABLE_STRICT=1"
set "HERMESGO_SKIP_GLOBAL_PATH=1"
set "HERMES_DISABLE_WSL=1"
set "HERMES_PREFER_WINDOWS=1"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONHOME="
set "PYTHONPATH="
if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)
"%PYTHON_EXE%" -m hermes_cli.main %*
exit /b %ERRORLEVEL%
"@

    $existing = $null
    if (Test-Path -LiteralPath $hermesCmd) {
        $existing = Get-Content -LiteralPath $hermesCmd -Raw -Encoding utf8
    }

    if ($existing -ne $content) {
        Set-Content -LiteralPath $hermesCmd -Value $content -Encoding ascii
        & $LogLine "Created portable hermes command: $hermesCmd"
    }
}

function Resolve-HermesGoAppRootFromScript {
    param([string]$ScriptRoot)

    foreach ($candidate in @(
            $ScriptRoot,
            (Join-Path $ScriptRoot '..'),
            (Join-Path $ScriptRoot '..\..')
        )) {
        $full = [System.IO.Path]::GetFullPath($candidate)
        $pythonExe = Join-Path $full 'runtime\python311\python.exe'
        if (Test-Path -LiteralPath $pythonExe) {
            return $full
        }
    }

    throw "Portable HermesGo app root not found near: $ScriptRoot"
}

function Register-HermesGoGlobalPathFromScriptRoot {
    param(
        [string]$ScriptRoot,
        [scriptblock]$LogLine = { param($Message) Write-Host $Message }
    )

    $appRoot = Resolve-HermesGoAppRootFromScript -ScriptRoot $ScriptRoot
    Ensure-HermesGoGlobalPath -AppRoot $appRoot -LogLine $LogLine
}

function Ensure-HermesGoGlobalPath {
    param(
        [string]$AppRoot,
        [scriptblock]$LogLine = { param($Message) Write-Host $Message }
    )

    if ($env:HERMESGO_SKIP_GLOBAL_PATH -eq '1' -or $env:HERMESGO_STRICT_PORTABLE -eq '1' -or $env:HERMES_PORTABLE_STRICT -eq '1') {
        Ensure-PortableHermesCliWrapper -AppRoot ([System.IO.Path]::GetFullPath($AppRoot)) -LogLine $LogLine
        return
    }

    $appRootFull = [System.IO.Path]::GetFullPath($AppRoot)
    $binDir = Join-Path $appRootFull 'runtime\bin'
    $homeDir = Join-Path $appRootFull 'home'

    Ensure-PortableHermesCliWrapper -AppRoot $appRootFull -LogLine $LogLine

    $scope = Get-HermesGoPathScope
    $scopeName = $scope.ToString()

    $currentPath = [Environment]::GetEnvironmentVariable('Path', $scope)
    if ([string]::IsNullOrWhiteSpace($currentPath)) {
        $currentPath = ''
    }

    $previousRoot = [Environment]::GetEnvironmentVariable('HERMES_PORTABLE_APP_ROOT', $scope)
    if (-not [string]::IsNullOrWhiteSpace($previousRoot) -and $previousRoot -ne $appRootFull) {
        $oldBin = Join-Path $previousRoot 'runtime\bin'
        if (Test-PathEntryPresent -PathValue $currentPath -Entry $oldBin) {
            $patterns = @("*$previousRoot*")
            $currentPath = Remove-PathEntriesMatching -PathValue $currentPath -Patterns $patterns
            & $LogLine "Removed previous HermesGo PATH entries for: $previousRoot"
        }
    }

    if (-not (Test-PathEntryPresent -PathValue $currentPath -Entry $binDir)) {
        $newPath = if ([string]::IsNullOrWhiteSpace($currentPath)) { $binDir } else { "$binDir;$currentPath" }
        try {
            [Environment]::SetEnvironmentVariable('Path', $newPath, $scope)
            & $LogLine "Added Hermes CLI to $scopeName PATH: $binDir"
        } catch {
            & $LogLine "WARNING: could not update $scopeName PATH (try running as Administrator for Machine scope): $($_.Exception.Message)"
            return
        }
    } else {
        & $LogLine "Hermes CLI already on $scopeName PATH: $binDir"
    }

    $currentHome = [Environment]::GetEnvironmentVariable('HERMES_HOME', $scope)
    if ($currentHome -ne $homeDir) {
        [Environment]::SetEnvironmentVariable('HERMES_HOME', $homeDir, $scope)
        & $LogLine "Set $scopeName HERMES_HOME=$homeDir"
    }

    [Environment]::SetEnvironmentVariable('HERMES_PORTABLE_APP_ROOT', $appRootFull, $scope)
    $env:HERMES_HOME = $homeDir
    $env:HERMES_PORTABLE_APP_ROOT = $appRootFull

    if (-not (Test-PathEntryPresent -PathValue $env:PATH -Entry $binDir)) {
        $env:PATH = "$binDir;$env:PATH"
    }

    Broadcast-EnvironmentChange
    & $LogLine 'Global CLI ready: open a new terminal and run "hermes --version" (current window may need restart).'
}
