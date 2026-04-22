param(
    [string]$WindowTitle = "HermesGo 启动器",
    [string]$OutputPath = "",
    [int]$TimeoutSec = 30
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Drawing

$nativeCode = @"
using System;
using System.Runtime.InteropServices;

public static class NativeMethods
{
    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll", SetLastError = true)]
    public static extern bool PrintWindow(IntPtr hWnd, IntPtr hdcBlt, uint nFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }
}
"@

if (-not ("NativeMethods" -as [type])) {
    Add-Type -TypeDefinition $nativeCode
}

function Get-LauncherWindow {
    param(
        [string]$Title,
        [int]$TimeoutSec
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $process = Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.MainWindowHandle -ne [IntPtr]::Zero -and (
                $_.MainWindowTitle -eq $Title -or
                $_.MainWindowTitle -like "*$Title*"
            )
        } | Select-Object -First 1

        if ($process) {
            return $process
        }

        Start-Sleep -Milliseconds 250
    }

    throw "等待窗口超时：$Title"
}

function Save-WindowScreenshot {
    param(
        [System.Diagnostics.Process]$Process,
        [string]$Path
    )

    if ($Process.MainWindowHandle -eq [IntPtr]::Zero) {
        throw "进程没有可见主窗口。"
    }

    $rect = New-Object NativeMethods+RECT
    if (-not [NativeMethods]::GetWindowRect($Process.MainWindowHandle, [ref]$rect)) {
        throw "GetWindowRect 调用失败。"
    }

    $width = $rect.Right - $rect.Left
    $height = $rect.Bottom - $rect.Top
    if ($width -le 0 -or $height -le 0) {
        throw "窗口尺寸无效。"
    }

    $bitmap = New-Object System.Drawing.Bitmap $width, $height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $hdc = $graphics.GetHdc()
        try {
            $printed = [NativeMethods]::PrintWindow($Process.MainWindowHandle, $hdc, 2)
            if (-not $printed) {
                $graphics.ReleaseHdc($hdc)
                $hdc = [IntPtr]::Zero
                $graphics.CopyFromScreen($rect.Left, $rect.Top, 0, 0, $bitmap.Size)
            }
        }
        finally {
            if ($hdc -ne [IntPtr]::Zero) {
                $graphics.ReleaseHdc($hdc)
            }
        }
        $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    }
    finally {
        $graphics.Dispose()
        $bitmap.Dispose()
    }
}

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $imagesDir = Join-Path $PSScriptRoot "images"
    New-Item -ItemType Directory -Force -Path $imagesDir | Out-Null
    $OutputPath = Join-Path $imagesDir "01-启动器主界面.png"
}
else {
    $targetDir = Split-Path -Parent $OutputPath
    if (-not [string]::IsNullOrWhiteSpace($targetDir)) {
        New-Item -ItemType Directory -Force -Path $targetDir | Out-Null
    }
}

$process = Get-LauncherWindow -Title $WindowTitle -TimeoutSec $TimeoutSec
Save-WindowScreenshot -Process $process -Path $OutputPath
Write-Host ("已保存截图：{0}" -f $OutputPath)
