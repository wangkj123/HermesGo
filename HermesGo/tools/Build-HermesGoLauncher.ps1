param(
    [string]$OutputExe = (Join-Path (Split-Path -Parent $PSScriptRoot) 'HermesGo.exe')
)

$ErrorActionPreference = 'Stop'

$repoRoot = Split-Path -Parent $PSScriptRoot
$source = Join-Path $repoRoot 'tools\gui\HermesGoLauncher.cs'
$iconIco = Join-Path $repoRoot 'assets\HermesGo.ico'
$iconPng = Join-Path $env:TEMP 'HermesGo-icon.png'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe'

if (-not (Test-Path -LiteralPath $source)) {
    throw "Missing source file: $source"
}

Add-Type -AssemblyName System.Drawing

function New-RoundedPath {
    param(
        [int]$X,
        [int]$Y,
        [int]$Width,
        [int]$Height,
        [int]$Radius
    )

    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $d = $Radius * 2
    $path.AddArc($X, $Y, $d, $d, 180, 90)
    $path.AddArc($X + $Width - $d, $Y, $d, $d, 270, 90)
    $path.AddArc($X + $Width - $d, $Y + $Height - $d, $d, $d, 0, 90)
    $path.AddArc($X, $Y + $Height - $d, $d, $d, 90, 90)
    $path.CloseFigure()
    return $path
}

function Write-IcoFile {
    param(
        [string]$PngPath,
        [string]$IcoPath
    )

    $png = [System.IO.File]::ReadAllBytes($PngPath)
    $stream = New-Object System.IO.MemoryStream
    $writer = New-Object System.IO.BinaryWriter($stream)
    $writer.Write([uint16]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]1)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([byte]0)
    $writer.Write([uint16]1)
    $writer.Write([uint16]32)
    $writer.Write([uint32]$png.Length)
    $writer.Write([uint32](6 + 16))
    $writer.Write($png)
    $writer.Flush()
    [System.IO.File]::WriteAllBytes($IcoPath, $stream.ToArray())
    $writer.Close()
    $stream.Close()
}

function New-HermesGoIcon {
    $bitmap = New-Object System.Drawing.Bitmap 256, 256
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $graphics.Clear([System.Drawing.Color]::Transparent)

    $rect = New-Object System.Drawing.Rectangle 16, 16, 224, 224
    $bgBrush = New-Object System.Drawing.Drawing2D.LinearGradientBrush($rect, [System.Drawing.Color]::FromArgb(247, 154, 52), [System.Drawing.Color]::FromArgb(224, 110, 24), 45)
    $roundPath = New-RoundedPath -X 16 -Y 16 -Width 224 -Height 224 -Radius 52
    $graphics.FillPath($bgBrush, $roundPath)
    $bgBrush.Dispose()
    $roundPath.Dispose()

    $clipPath = New-RoundedPath -X 16 -Y 16 -Width 224 -Height 224 -Radius 52
    $graphics.SetClip($clipPath)
    $highlight = New-Object System.Drawing.Drawing2D.LinearGradientBrush((New-Object System.Drawing.Rectangle 32, 24, 176, 176), [System.Drawing.Color]::FromArgb(70, 255, 255, 255), [System.Drawing.Color]::FromArgb(0, 255, 255, 255), 25)
    $graphics.FillEllipse($highlight, 52, 28, 150, 100)
    $highlight.Dispose()
    $graphics.ResetClip()
    $clipPath.Dispose()

    $horsePoints = @(
        (New-Object System.Drawing.PointF 76, 182),
        (New-Object System.Drawing.PointF 88, 152),
        (New-Object System.Drawing.PointF 108, 122),
        (New-Object System.Drawing.PointF 132, 100),
        (New-Object System.Drawing.PointF 158, 84),
        (New-Object System.Drawing.PointF 184, 82),
        (New-Object System.Drawing.PointF 205, 90),
        (New-Object System.Drawing.PointF 220, 106),
        (New-Object System.Drawing.PointF 222, 126),
        (New-Object System.Drawing.PointF 212, 144),
        (New-Object System.Drawing.PointF 196, 156),
        (New-Object System.Drawing.PointF 186, 170),
        (New-Object System.Drawing.PointF 180, 196),
        (New-Object System.Drawing.PointF 164, 208),
        (New-Object System.Drawing.PointF 142, 202),
        (New-Object System.Drawing.PointF 122, 188),
        (New-Object System.Drawing.PointF 104, 168),
        (New-Object System.Drawing.PointF 92, 160)
    )
    $horsePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $horsePath.AddClosedCurve($horsePoints)
    $horseBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(17, 17, 17))
    $graphics.FillPath($horseBrush, $horsePath)
    $horseBrush.Dispose()
    $horsePath.Dispose()

    $maneBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(245, 235, 224))
    $manePath = New-Object System.Drawing.Drawing2D.GraphicsPath
    $manePath.AddBezier(122, 118, 144, 96, 162, 88, 186, 90)
    $manePath.AddBezier(186, 90, 176, 102, 166, 118, 160, 140)
    $graphics.DrawPath((New-Object System.Drawing.Pen($maneBrush, 6)), $manePath)
    $manePath.Dispose()
    $maneBrush.Dispose()

    $wheelBrush = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(17, 17, 17))
    $graphics.FillEllipse($wheelBrush, 158, 160, 58, 58)
    $wheelBrush.Dispose()

    $wheelPen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(247, 154, 52), 4)
    $graphics.DrawEllipse($wheelPen, 166, 168, 42, 42)
    $graphics.DrawLine($wheelPen, 177, 189, 197, 189)
    $graphics.DrawLine($wheelPen, 187, 179, 187, 199)
    $graphics.DrawLine($wheelPen, 173, 175, 201, 203)
    $graphics.DrawLine($wheelPen, 173, 203, 201, 175)
    $wheelPen.Dispose()

    $graphics.Dispose()
    $bitmap.Save($iconPng, [System.Drawing.Imaging.ImageFormat]::Png)
    $bitmap.Dispose()
    Write-IcoFile -PngPath $iconPng -IcoPath $iconIco
}

New-HermesGoIcon

if (-not (Test-Path -LiteralPath $csc)) {
    throw "Missing compiler: $csc"
}

& $csc /nologo /target:winexe /optimize+ /utf8output /win32icon:$iconIco /out:$OutputExe /r:System.Windows.Forms.dll /r:System.Drawing.dll $source
if ($LASTEXITCODE -ne 0) {
    throw "Launcher compilation failed with exit code $LASTEXITCODE"
}

Write-Host "Built: $OutputExe"
