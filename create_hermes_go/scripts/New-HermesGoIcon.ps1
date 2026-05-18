# Generates HermesGo.ico (exe icon) and HermesGo-logo.png (launcher UI).
param(
    [string]$AssetsRoot = (Join-Path (Split-Path -Parent $PSScriptRoot) "assets")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function New-HermesGoIcon {
    param(
        [string]$OutputPath,
        [string]$PngOutputPath
    )

    Add-Type -AssemblyName System.Drawing

    $size = 256
    if ([string]::IsNullOrWhiteSpace($PngOutputPath)) {
        $pngPath = [System.IO.Path]::ChangeExtension($OutputPath, ".png")
    } else {
        $pngPath = $PngOutputPath
    }
    $bitmap = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    try {
        $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $graphics.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $graphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $graphics.Clear([System.Drawing.Color]::Transparent)

        $backgroundPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $backgroundPath.AddEllipse(6, 6, 244, 244)
        $backgroundBrush = New-Object System.Drawing.Drawing2D.PathGradientBrush $backgroundPath
        $backgroundBrush.CenterColor = [System.Drawing.Color]::FromArgb(255, 255, 214, 102)
        $backgroundBrush.SurroundColors = @([System.Drawing.Color]::FromArgb(255, 255, 106, 74))
        $graphics.FillPath($backgroundBrush, $backgroundPath)

        $ringPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(66, 255, 255, 255), 6)
        $graphics.DrawPath($ringPen, $backgroundPath)

        $manePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(255, 255, 244, 214), 16)
        $manePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $manePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $manePen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

        $maneAccentPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(180, 255, 255, 255), 8)
        $maneAccentPen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $maneAccentPen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $maneAccentPen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round

        $horsePath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $horsePath.AddPolygon(@(
            (New-Object System.Drawing.Point 104, 46)
            (New-Object System.Drawing.Point 127, 28)
            (New-Object System.Drawing.Point 149, 34)
            (New-Object System.Drawing.Point 164, 52)
            (New-Object System.Drawing.Point 179, 77)
            (New-Object System.Drawing.Point 184, 104)
            (New-Object System.Drawing.Point 175, 127)
            (New-Object System.Drawing.Point 183, 146)
            (New-Object System.Drawing.Point 170, 167)
            (New-Object System.Drawing.Point 149, 183)
            (New-Object System.Drawing.Point 123, 192)
            (New-Object System.Drawing.Point 94, 188)
            (New-Object System.Drawing.Point 73, 173)
            (New-Object System.Drawing.Point 61, 149)
            (New-Object System.Drawing.Point 63, 121)
            (New-Object System.Drawing.Point 76, 96)
            (New-Object System.Drawing.Point 91, 73)
        ))
        $graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), $horsePath)

        $neckPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $neckPath.AddPolygon(@(
            (New-Object System.Drawing.Point 82, 160)
            (New-Object System.Drawing.Point 56, 224)
            (New-Object System.Drawing.Point 118, 224)
            (New-Object System.Drawing.Point 138, 191)
        ))
        $graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), $neckPath)

        $ear1 = New-Object System.Drawing.Drawing2D.GraphicsPath
        $ear1.AddPolygon(@(
            (New-Object System.Drawing.Point 120, 36)
            (New-Object System.Drawing.Point 111, 10)
            (New-Object System.Drawing.Point 137, 28)
        ))
        $graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), $ear1)

        $ear2 = New-Object System.Drawing.Drawing2D.GraphicsPath
        $ear2.AddPolygon(@(
            (New-Object System.Drawing.Point 150, 40)
            (New-Object System.Drawing.Point 168, 14)
            (New-Object System.Drawing.Point 176, 45)
        ))
        $graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), $ear2)

        $graphics.DrawBezier($manePen, 88, 58, 70, 86, 66, 120, 82, 145)
        $graphics.DrawBezier($maneAccentPen, 101, 59, 82, 80, 79, 102, 91, 124)

        $graphics.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::White)), 136, 99, 10, 10)
        $graphics.FillEllipse((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), 139, 102, 4, 4)

        $muzzlePath = New-Object System.Drawing.Drawing2D.GraphicsPath
        $muzzlePath.AddPolygon(@(
            (New-Object System.Drawing.Point 151, 113)
            (New-Object System.Drawing.Point 188, 121)
            (New-Object System.Drawing.Point 196, 137)
            (New-Object System.Drawing.Point 184, 154)
            (New-Object System.Drawing.Point 160, 149)
            (New-Object System.Drawing.Point 149, 133)
        ))
        $graphics.FillPath((New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(255, 28, 36, 66))), $muzzlePath)

        $shinePen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 255, 255, 255), 6)
        $shinePen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
        $shinePen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
        $graphics.DrawBezier($shinePen, 145, 78, 160, 90, 156, 104, 146, 116)
    } finally {
        $graphics.Dispose()
    }

    try {
        $bitmap.Save($pngPath, [System.Drawing.Imaging.ImageFormat]::Png)
    } finally {
        $bitmap.Dispose()
    }

    $pngBytes = [System.IO.File]::ReadAllBytes($pngPath)
    $stream = [System.IO.File]::Open($OutputPath, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
    try {
        $writer = New-Object System.IO.BinaryWriter($stream)
        $writer.Write([UInt16]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]1)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([byte]0)
        $writer.Write([UInt16]1)
        $writer.Write([UInt16]32)
        $writer.Write([Int32]$pngBytes.Length)
        $writer.Write([Int32]22)
        $writer.Write($pngBytes)
        $writer.Flush()
    } finally {
        $stream.Dispose()
    }
}

$iconsDir = Join-Path $AssetsRoot "icons"
New-Item -ItemType Directory -Path $iconsDir -Force | Out-Null
$iconPath = Join-Path $iconsDir "HermesGo.ico"
$pngPath = Join-Path $AssetsRoot "HermesGo-logo.png"
New-HermesGoIcon -OutputPath $iconPath -PngOutputPath $pngPath
Write-Host "[New-HermesGoIcon] $iconPath"
Write-Host "[New-HermesGoIcon] $pngPath"
