param(
    [string]$ExePath = (Join-Path $PSScriptRoot "..\HermesGo.exe"),
    [int]$StartupTimeoutSec = 20,
    [int]$ActionTimeoutSec = 8
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class NativeInput
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetCursorPos(int x, int y);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SetFocus(IntPtr hWnd);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "SendMessageW")]
    public static extern IntPtr SendMessageText(IntPtr hWnd, uint msg, IntPtr wParam, string lParam);

    public const uint MOUSEEVENTF_LEFTDOWN = 0x0002;
    public const uint MOUSEEVENTF_LEFTUP = 0x0004;
    public const uint BM_CLICK = 0x00F5;
    public const uint WM_KEYDOWN = 0x0100;
    public const uint WM_KEYUP = 0x0101;
    public const uint WM_SETTEXT = 0x000C;
}
"@

function Wait-Until {
    param(
        [Parameter(Mandatory = $true)]
        [scriptblock]$Condition,
        [int]$TimeoutSec = 5,
        [int]$DelayMs = 150
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $result = & $Condition
        if ($null -ne $result -and $false -ne $result) {
            return $result
        }
        Start-Sleep -Milliseconds $DelayMs
    }

    return $null
}

function Ensure-ProcessHealthy {
    param(
        [Parameter(Mandatory = $true)]
        [System.Diagnostics.Process]$Process,
        [Parameter(Mandatory = $true)]
        [string]$Step
    )

    if ($Process.HasExited) {
        throw "process exited during [$Step], exit=$($Process.ExitCode)"
    }

    if (-not $Process.Responding) {
        throw "process not responding during [$Step]"
    }
}

function Click-Point {
    param(
        [Parameter(Mandatory = $true)]
        [int]$X,
        [Parameter(Mandatory = $true)]
        [int]$Y
    )

    [NativeInput]::SetCursorPos($X, $Y) | Out-Null
    Start-Sleep -Milliseconds 80
    [NativeInput]::mouse_event([NativeInput]::MOUSEEVENTF_LEFTDOWN, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [NativeInput]::mouse_event([NativeInput]::MOUSEEVENTF_LEFTUP, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 220
}

function Click-RectCenter {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Rect
    )

    Click-Point -X ([int]($Rect.Left + ($Rect.Width / 2))) -Y ([int]($Rect.Top + ($Rect.Height / 2)))
}

function Invoke-ButtonClick {
    param(
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle
    )

    [NativeInput]::SetFocus($Handle) | Out-Null
    Start-Sleep -Milliseconds 100
    [NativeInput]::SendMessage($Handle, [NativeInput]::BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 250
}

function Parse-Rect {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    $parts = $Value.Split(",")
    if ($parts.Count -ne 4) {
        throw "invalid rect: $Value"
    }

    return @{
        Left = [int]$parts[0]
        Top = [int]$parts[1]
        Width = [int]$parts[2]
        Height = [int]$parts[3]
    }
}

function Parse-Handle {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Value
    )

    return [IntPtr]([Int64]::Parse($Value))
}

function Read-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    $map = @{}
    foreach ($line in Get-Content -LiteralPath $Path -Encoding utf8) {
        if ([string]::IsNullOrWhiteSpace($line)) {
            continue
        }
        $index = $line.IndexOf("=")
        if ($index -lt 0) {
            continue
        }
        $key = $line.Substring(0, $index)
        $value = $line.Substring($index + 1)
        $map[$key] = $value
    }

    return $map
}

function Wait-Snapshot {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [int]$TimeoutSec = 10
    )

    $snapshot = Wait-Until -TimeoutSec $TimeoutSec -Condition {
        if (Test-Path -LiteralPath $Path) {
            $data = Read-Snapshot -Path $Path
            if ($data.ContainsKey("rect.presetBox") -and $data.ContainsKey("provider.current") -and $data.ContainsKey("model.current")) {
                return $data
            }
        }
        return $null
    }

    if (-not $snapshot) {
        throw "snapshot not ready: $Path"
    }

    return $snapshot
}

function Wait-SnapshotValue {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,
        [Parameter(Mandatory = $true)]
        [string]$Key,
        [Parameter(Mandatory = $true)]
        [string]$ExpectedValue,
        [int]$TimeoutSec = 8
    )

    $snapshot = Wait-Until -TimeoutSec $TimeoutSec -Condition {
        $data = Read-Snapshot -Path $Path
        if ($data.ContainsKey($Key) -and $data[$Key] -eq $ExpectedValue) {
            return $data
        }
        return $null
    }

    if (-not $snapshot) {
        throw "snapshot key [$Key] did not become [$ExpectedValue]"
    }

    return $snapshot
}

function Send-Keys {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Keys,
        [int]$DelayMs = 150
    )

    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    Start-Sleep -Milliseconds $DelayMs
}

function Set-ProviderByClick {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Rect,
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,
        [Parameter(Mandatory = $true)]
        [string]$Provider
    )

    Click-RectCenter -Rect $Rect
    [NativeInput]::SetFocus($Handle) | Out-Null
    Start-Sleep -Milliseconds 80
    [NativeInput]::SendMessageText($Handle, [NativeInput]::WM_SETTEXT, [IntPtr]::Zero, $Provider) | Out-Null
    Start-Sleep -Milliseconds 120
    Send-Keys -Keys "{TAB}" -DelayMs 250
}

function Select-ComboIndexByClick {
    param(
        [Parameter(Mandatory = $true)]
        [hashtable]$Rect,
        [Parameter(Mandatory = $true)]
        [IntPtr]$Handle,
        [Parameter(Mandatory = $true)]
        [int]$Index
    )

    Click-RectCenter -Rect $Rect
    [NativeInput]::SetFocus($Handle) | Out-Null
    Start-Sleep -Milliseconds 120
    [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYDOWN, [IntPtr]36, [IntPtr]::Zero) | Out-Null
    [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYUP, [IntPtr]36, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 90
    for ($i = 0; $i -lt $Index; $i++) {
        [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYDOWN, [IntPtr]40, [IntPtr]::Zero) | Out-Null
        [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYUP, [IntPtr]40, [IntPtr]::Zero) | Out-Null
        Start-Sleep -Milliseconds 90
    }
    [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYDOWN, [IntPtr]13, [IntPtr]::Zero) | Out-Null
    [NativeInput]::SendMessage($Handle, [NativeInput]::WM_KEYUP, [IntPtr]13, [IntPtr]::Zero) | Out-Null
    Start-Sleep -Milliseconds 220
}

$resolvedExePath = [System.IO.Path]::GetFullPath($ExePath)
if (-not (Test-Path -LiteralPath $resolvedExePath)) {
    throw "launcher not found: $resolvedExePath"
}

$appRoot = Split-Path -Parent $resolvedExePath
$logsDir = Join-Path $appRoot "logs"
New-Item -ItemType Directory -Path $logsDir -Force | Out-Null
$reportPath = Join-Path $logsDir "launcher-clicktest.log"
$snapshotPath = Join-Path $logsDir "launcher-clicktest.snapshot"
$openedUrlPath = Join-Path $logsDir "launcher-clicktest.open-url.txt"
if (Test-Path -LiteralPath $snapshotPath) {
    Remove-Item -LiteralPath $snapshotPath -Force
}
if (Test-Path -LiteralPath $openedUrlPath) {
    Remove-Item -LiteralPath $openedUrlPath -Force
}

$report = New-Object System.Collections.Generic.List[string]
$report.Add("time=$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
$report.Add("exe=$resolvedExePath")
$report.Add("snapshot=$snapshotPath")
$report.Add("openedUrlPath=$openedUrlPath")

$process = $null
try {
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $resolvedExePath
    $psi.UseShellExecute = $false
    $psi.EnvironmentVariables["HERMESGO_CONTROL_MAP_PATH"] = $snapshotPath
    $psi.EnvironmentVariables["HERMESGO_SUPPRESS_EXTERNAL_OPEN"] = "1"
    $psi.EnvironmentVariables["HERMESGO_SUPPRESS_DASHBOARD_START"] = "1"
    $psi.EnvironmentVariables["HERMESGO_LAST_OPEN_URL_PATH"] = $openedUrlPath

    $process = [System.Diagnostics.Process]::Start($psi)
    $snapshot = Wait-Snapshot -Path $snapshotPath -TimeoutSec $StartupTimeoutSec
    Ensure-ProcessHealthy -Process $process -Step "startup"

    $mainHandle = Wait-Until -TimeoutSec $StartupTimeoutSec -Condition {
        $process.Refresh()
        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            return $process.MainWindowHandle
        }
        return $null
    }
    if (-not $mainHandle) {
        throw "main window handle not ready"
    }
    [NativeInput]::SetForegroundWindow($mainHandle) | Out-Null
    Start-Sleep -Milliseconds 250

    $presetRect = Parse-Rect -Value $snapshot["rect.presetBox"]
    $providerRect = Parse-Rect -Value $snapshot["rect.providerBox"]
    $modelRect = Parse-Rect -Value $snapshot["rect.modelBox"]
    $codexRect = Parse-Rect -Value $snapshot["rect.codexButton"]
    $exitRect = Parse-Rect -Value $snapshot["rect.exitButton"]
    $presetHandle = Parse-Handle -Value $snapshot["handle.presetBox"]
    $providerHandle = Parse-Handle -Value $snapshot["handle.providerBox"]
    $modelHandle = Parse-Handle -Value $snapshot["handle.modelBox"]
    $codexHandle = Parse-Handle -Value $snapshot["handle.codexButton"]

    for ($index = 0; $index -lt 4; $index++) {
        Ensure-ProcessHealthy -Process $process -Step "preset-$index-before"
        Select-ComboIndexByClick -Rect $presetRect -Handle $presetHandle -Index $index
        Ensure-ProcessHealthy -Process $process -Step "preset-$index-after"
        Start-Sleep -Milliseconds 300
        $snapshot = Read-Snapshot -Path $snapshotPath
        $report.Add("presetIndex=$index preset=$($snapshot['preset.current']) provider=$($snapshot['provider.current']) model=$($snapshot['model.current'])")
    }

    foreach ($provider in @("ollama", "openai-codex", "openrouter")) {
        Ensure-ProcessHealthy -Process $process -Step "provider-$provider-before"
        Set-ProviderByClick -Rect $providerRect -Handle $providerHandle -Provider $provider
        $snapshot = Wait-SnapshotValue -Path $snapshotPath -Key "provider.current" -ExpectedValue $provider -TimeoutSec $ActionTimeoutSec
        Ensure-ProcessHealthy -Process $process -Step "provider-$provider-after"

        $models = @()
        if ($snapshot.ContainsKey("models.$provider")) {
            $models = @($snapshot["models.$provider"].Split("|") | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        }
        if ($models.Count -eq 0) {
            throw "no models found for provider $provider"
        }

        $report.Add("provider=$provider itemCount=$($models.Count)")
        for ($index = 0; $index -lt $models.Count; $index++) {
            Ensure-ProcessHealthy -Process $process -Step "provider-$provider-model-$index-before"
            Select-ComboIndexByClick -Rect $modelRect -Handle $modelHandle -Index $index
            $snapshot = Wait-SnapshotValue -Path $snapshotPath -Key "model.current" -ExpectedValue $models[$index] -TimeoutSec $ActionTimeoutSec
            Ensure-ProcessHealthy -Process $process -Step "provider-$provider-model-$index-after"
            $report.Add("select provider=$provider model=$($snapshot['model.current'])")
        }
    }

    Ensure-ProcessHealthy -Process $process -Step "codex-button-before"
    Invoke-ButtonClick -Handle $codexHandle
    $openedUrl = Wait-Until -TimeoutSec $ActionTimeoutSec -Condition {
        if (-not (Test-Path -LiteralPath $openedUrlPath)) {
            return $null
        }

        $value = (Get-Content -LiteralPath $openedUrlPath -Raw -Encoding utf8).Trim()
        if ([string]::IsNullOrWhiteSpace($value)) {
            return $null
        }

        return $value
    }
    Ensure-ProcessHealthy -Process $process -Step "codex-button-after"
    if ($openedUrl -ne "http://127.0.0.1:9119/env?oauth=openai-codex") {
        throw "unexpected Codex dashboard URL: $openedUrl"
    }
    $report.Add("codexUrl=$openedUrl")

    Click-RectCenter -Rect $exitRect
    $null = Wait-Until -TimeoutSec 5 -Condition {
        if ($process.HasExited) {
            return $true
        }
        return $null
    }

    if (-not $process.HasExited) {
        $process.CloseMainWindow() | Out-Null
        Start-Sleep -Milliseconds 300
    }

    $report.Add("result=pass")
}
catch {
    $report.Add("result=fail")
    $report.Add("error=$($_.Exception.Message)")
    if ($process -and -not $process.HasExited) {
        try {
            $process.CloseMainWindow() | Out-Null
            Start-Sleep -Milliseconds 300
        } catch {
        }
        if (-not $process.HasExited) {
            $process.Kill()
        }
    }
    throw
}
finally {
    [System.IO.File]::WriteAllLines($reportPath, [string[]]$report, [System.Text.UTF8Encoding]::new($false))
    Write-Output "report=$reportPath"
}
