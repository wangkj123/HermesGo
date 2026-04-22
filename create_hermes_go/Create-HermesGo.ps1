param(
    [string]$OutputDir = "",
    [switch]$Clean,
    [string]$PythonEmbedVersion = "3.11.9"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$builderRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $builderRoot
if (-not $OutputDir) {
    $OutputDir = Join-Path $builderRoot "output\HermesGo"
}

$sourceHermes = Join-Path $repoRoot "HermesGo\runtime\hermes-agent"
$sourceOllama = Join-Path $repoRoot "HermesGo\runtime\ollama"
$sourceBundledOllamaData = Join-Path $repoRoot "HermesGo\data\ollama"
$sourceBundledOllamaModels = Join-Path $sourceBundledOllamaData "models"
$sourceOllamaZip = Join-Path $repoRoot "HermesGo\installers\ollama-windows-amd64.zip"
$sourceSitePackages = Join-Path $sourceHermes "venv\Lib\site-packages"
$docsDir = Join-Path $builderRoot "docs"
$cacheDir = Join-Path $builderRoot "cache"
$embedPythonZip = Join-Path $cacheDir ("python-{0}-embed-amd64.zip" -f $PythonEmbedVersion)
$embedPythonTemp = "$embedPythonZip.part"
$embedPythonSourceMeta = "$embedPythonZip.source.txt"
$progressLog = Join-Path $repoRoot "logs\agent-progress.md"
$portableDefaultsPath = Join-Path $repoRoot "HermesGo\home\portable-defaults.txt"

function Get-PortableDefaults {
    param([string]$Path)

    $defaults = [ordered]@{
        DEFAULT_OLLAMA_PROVIDER = "ollama"
        DEFAULT_OLLAMA_MODEL = "gemma:2b"
        DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434/v1"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$defaults
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $key = $parts[0].Trim()
        if (-not $defaults.Contains($key)) {
            continue
        }

        $value = $parts[1].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $defaults[$key] = $value
    }

    return [pscustomobject]$defaults
}

$portableDefaults = Get-PortableDefaults -Path $portableDefaultsPath
$defaultOllamaModel = $portableDefaults.DEFAULT_OLLAMA_MODEL
$defaultOllamaProvider = $portableDefaults.DEFAULT_OLLAMA_PROVIDER
$defaultOllamaBaseUrl = $portableDefaults.DEFAULT_OLLAMA_BASE_URL
$currentReleaseTag = "HermesGo-2026.04.22-2025"
$currentReleaseZip = "HermesGo-2026.04.22-2025.zip"
$currentReleaseSha = "HermesGo-2026.04.22-2025.zip.sha256.txt"
$previousReleasePattern = "HermesGo-2026.04.21-*"

function Write-Step {
    param([string]$Message)
    Write-Host "[create_hermes_go] $Message"
}

function Copy-Tree {
    param(
        [string]$Source,
        [string]$Destination,
        [string[]]$ExcludeDirectories = @()
    )

    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    $args = @($Source, $Destination, "/E", "/NFL", "/NDL", "/NJH", "/NJS", "/NP")
    if ($ExcludeDirectories.Count -gt 0) {
        $args += "/XD"
        $args += $ExcludeDirectories
    }

    & robocopy @args | Out-Null
    $code = $LASTEXITCODE
    if ($code -gt 7) {
        throw "robocopy failed ($code): $Source -> $Destination"
    }
}

function Remove-PathIfExists {
    param([string]$Path)

    if (Test-Path -LiteralPath $Path) {
        Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-Utf8File {
    param(
        [string]$Path,
        [string]$Content
    )

    New-Item -ItemType Directory -Path (Split-Path -Parent $Path) -Force | Out-Null
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $utf8NoBom)
}

function Stop-ProcessesUnderPath {
    param([string]$PathPrefix)

    $normalized = ($PathPrefix.TrimEnd('\') + '\').ToLowerInvariant()
    Get-CimInstance Win32_Process | Where-Object {
        $_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($normalized)
    } | ForEach-Object {
        Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
    }
}

function Test-ValidZip {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $archive = [System.IO.Compression.ZipFile]::OpenRead($Path)
        try {
            return $archive.Entries.Count -gt 0
        } finally {
            $archive.Dispose()
        }
    } catch {
        return $false
    }
}

function Add-ProgressRecord {
    param(
        [string]$Action,
        [string]$Tool,
        [string]$Result,
        [string]$Next
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lines = @(
        "",
        "### $timestamp",
        "- Action: $Action",
        "- Tool: $Tool",
        "- Result: $Result",
        "- Next: $Next"
    )
    Add-Content -LiteralPath $progressLog -Value ($lines -join [Environment]::NewLine) -Encoding utf8
}

function Get-EmbedPythonCandidates {
    param([string]$Version)

    return @(
        [pscustomobject]@{
            Tier = "domestic"
            Label = "sdu-python-mirror"
            Url = "https://mirrors.sdu.edu.cn/python-release/$Version/python-$Version-embed-amd64.zip"
            DisableProxy = $true
        }
        [pscustomobject]@{
            Tier = "foreign-direct"
            Label = "python-org-official"
            Url = "https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip"
            DisableProxy = $false
        }
        [pscustomobject]@{
            Tier = "foreign-proxy"
            Label = "ghproxy-python-org"
            Url = "https://ghproxy.link/https://www.python.org/ftp/python/$Version/python-$Version-embed-amd64.zip"
            DisableProxy = $false
        }
    )
}

function Invoke-DownloadFile {
    param(
        [string]$Url,
        [string]$Destination,
        [bool]$DisableProxy = $false
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Force
    }

    $arguments = @(
        "--location",
        "--fail",
        "--retry", "5",
        "--retry-all-errors",
        "--retry-delay", "5",
        "--ssl-no-revoke",
        "--output", $Destination,
        $Url
    )
    if ($DisableProxy) {
        $arguments = @("--noproxy", "*") + $arguments
    }

    & curl.exe @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "curl exit code $LASTEXITCODE"
    }
}

function Ensure-EmbedPythonZip {
    if ((Test-ValidZip -Path $embedPythonZip) -and (Test-Path -LiteralPath $embedPythonSourceMeta)) {
        Write-Step "Reusing embeddable Python zip $embedPythonZip"
        $sourceUrl = (Get-Content -LiteralPath $embedPythonSourceMeta -Raw -Encoding utf8).Trim()
        return [pscustomobject]@{
            Source = "cache"
            Url = $sourceUrl
        }
    }

    if (Test-Path -LiteralPath $embedPythonZip) {
        Remove-Item -LiteralPath $embedPythonZip -Force -ErrorAction SilentlyContinue
    }
    if (Test-Path -LiteralPath $embedPythonSourceMeta) {
        Remove-Item -LiteralPath $embedPythonSourceMeta -Force -ErrorAction SilentlyContinue
    }

    New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
    foreach ($candidate in (Get-EmbedPythonCandidates -Version $PythonEmbedVersion)) {
        Write-Step "Trying embeddable Python source [$($candidate.Tier)] $($candidate.Label)"
        try {
            Invoke-DownloadFile -Url $candidate.Url -Destination $embedPythonTemp -DisableProxy $candidate.DisableProxy
            if (-not (Test-ValidZip -Path $embedPythonTemp)) {
                throw "Downloaded file is not a valid zip archive."
            }
            Move-Item -LiteralPath $embedPythonTemp -Destination $embedPythonZip -Force
            Set-Content -LiteralPath $embedPythonSourceMeta -Value $candidate.Url -Encoding utf8
            Add-ProgressRecord -Action "Download embeddable Python" -Tool "curl.exe --ssl-no-revoke" -Result ("tier={0}; source={1}; success" -f $candidate.Tier, $candidate.Label) -Next "Extract embeddable Python into output package."
            return [pscustomobject]@{
                Source = $candidate.Label
                Url = $candidate.Url
            }
        } catch {
            Remove-Item -LiteralPath $embedPythonTemp -Force -ErrorAction SilentlyContinue
            Add-ProgressRecord -Action "Download embeddable Python" -Tool "curl.exe --ssl-no-revoke" -Result ("tier={0}; source={1}; failed={2}" -f $candidate.Tier, $candidate.Label, $_.Exception.Message) -Next "Switch to the next Python source."
        }
    }

    throw "Unable to download a valid embeddable Python zip for $PythonEmbedVersion"
}

function Expand-EmbedPython {
    param([string]$Destination)

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $embedPythonZip -DestinationPath $Destination -Force
}

function Remove-UnwantedSitePackagesArtifacts {
    param([string]$SitePackagesDir)

    Get-ChildItem -LiteralPath $SitePackagesDir -Force -Filter "__editable__*" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Write-EmbeddedPythonPathFile {
    param([string]$PythonDir)

    $pthPath = Join-Path $PythonDir "python311._pth"
    $lines = @(
        "python311.zip"
        "."
        "Lib\site-packages"
        "..\hermes-agent"
    )
    [System.IO.File]::WriteAllLines($pthPath, $lines, (New-Object System.Text.UTF8Encoding($false)))
}

function Prune-PortablePackage {
    param([string]$RootDir)

    $pathsToRemove = @(
        (Join-Path $RootDir "installers\ollama-windows-amd64.zip"),
        (Join-Path $RootDir "runtime\ollama\cublas64_11.dll"),
        (Join-Path $RootDir "runtime\ollama\cublasLt64_11.dll"),
        (Join-Path $RootDir "runtime\ollama\cudart64_110.dll"),
        (Join-Path $RootDir "runtime\ollama\rocm"),
        (Join-Path $RootDir "runtime\ollama\ollama_runners\cuda_v11.3"),
        (Join-Path $RootDir "runtime\ollama\ollama_runners\rocm_v5.7"),
        (Join-Path $RootDir "runtime\hermes-agent\web"),
        (Join-Path $RootDir "runtime\hermes-agent\__pycache__"),
        (Join-Path $RootDir "runtime\hermes-agent\scripts"),
        (Join-Path $RootDir "runtime\hermes-agent\hermes_agent.egg-info"),
        (Join-Path $RootDir "runtime\hermes-agent\README.md"),
        (Join-Path $RootDir "runtime\hermes-agent\LICENSE"),
        (Join-Path $RootDir "runtime\hermes-agent\MANIFEST.in"),
        (Join-Path $RootDir "runtime\hermes-agent\package.json"),
        (Join-Path $RootDir "runtime\hermes-agent\package-lock.json"),
        (Join-Path $RootDir "runtime\hermes-agent\pyproject.toml"),
        (Join-Path $RootDir "runtime\hermes-agent\requirements.txt"),
        (Join-Path $RootDir "runtime\hermes-agent\uv.lock"),
        (Join-Path $RootDir "runtime\hermes-agent\.env.example"),
        (Join-Path $RootDir "runtime\hermes-agent\cli-config.yaml.example"),
        (Join-Path $RootDir "runtime\hermes-agent\hermes")
    )

    foreach ($path in $pathsToRemove) {
        Remove-PathIfExists -Path $path
    }

    Get-ChildItem -LiteralPath $RootDir -Recurse -Directory -Filter "__pycache__" -ErrorAction SilentlyContinue | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
    }

    Get-ChildItem -LiteralPath $RootDir -Recurse -File -ErrorAction SilentlyContinue | Where-Object {
        $_.Extension -in @(".pyc", ".pyo")
    } | ForEach-Object {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-FrameworkCscPath {
    $candidates = @(
        (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }

    throw "Unable to locate csc.exe."
}

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

    try {
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
    } finally {
        if (-not $PngOutputPath -and (Test-Path -LiteralPath $pngPath)) {
            Remove-Item -LiteralPath $pngPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Build-HermesGoExe {
    param(
        [string]$SourcePath,
        [string]$OutputPath,
        [string]$IconPath
    )

    $csc = Get-FrameworkCscPath
    if (-not (Test-Path -LiteralPath $IconPath)) {
        throw "Required icon missing: $IconPath"
    }
    $frameworkDir = Split-Path -Parent $csc
    $referencePaths = @(
        (Join-Path $frameworkDir "System.dll"),
        (Join-Path $frameworkDir "System.Core.dll"),
        (Join-Path $frameworkDir "System.Net.Http.dll"),
        (Join-Path $frameworkDir "System.IO.Compression.dll"),
        (Join-Path $frameworkDir "System.IO.Compression.FileSystem.dll"),
        (Join-Path $frameworkDir "System.Web.Extensions.dll"),
        (Join-Path $frameworkDir "System.Drawing.dll"),
        (Join-Path $frameworkDir "System.Windows.Forms.dll")
    )

    foreach ($referencePath in $referencePaths) {
        if (-not (Test-Path -LiteralPath $referencePath)) {
            throw "Required compiler reference missing: $referencePath"
        }
    }

    $arguments = @(
        "/nologo",
        "/target:winexe",
        "/langversion:5",
        "/optimize+",
        "/platform:anycpu",
        ("/win32icon:{0}" -f $IconPath),
        ("/out:{0}" -f $OutputPath)
    )

    foreach ($referencePath in $referencePaths) {
        $arguments += ("/reference:{0}" -f $referencePath)
    }

    $arguments += $SourcePath

    Write-Step "Compiling HermesGo.exe from $SourcePath"
    & $csc @arguments
    if ($LASTEXITCODE -ne 0) {
        throw "csc.exe failed with exit code $LASTEXITCODE"
    }

    if (-not (Test-Path -LiteralPath $OutputPath)) {
        throw "HermesGo.exe was not created at $OutputPath"
    }
}

function Get-OllamaManifestRelativePath {
    param([string]$ModelName)

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $null
    }

    $parts = $ModelName.Trim() -split ':', 2
    if ($parts.Count -ne 2) {
        return $null
    }

    return Join-Path "manifests\registry.ollama.ai\library\$($parts[0])" $parts[1]
}

function Test-OllamaModelPresent {
    param(
        [string]$ModelsDir,
        [string]$ModelName
    )

    if (-not (Test-Path -LiteralPath $ModelsDir)) {
        return $false
    }

    $manifestRelativePath = Get-OllamaManifestRelativePath -ModelName $ModelName
    if (-not $manifestRelativePath) {
        return $false
    }

    return Test-Path -LiteralPath (Join-Path $ModelsDir $manifestRelativePath)
}

function Reset-OutputHomeState {
    param([string]$HomeDir)

    $pathsToRemove = @(
        "auth.json",
        "auth.lock",
        "models_dev_cache.json",
        "state.db",
        "state.db-shm",
        "state.db-wal",
        ".hermes_history",
        ".tirith-install-failed",
        "bin",
        "cron",
        "logs",
        "memories",
        "sandboxes",
        "sessions"
    )

    foreach ($relativePath in $pathsToRemove) {
        $target = Join-Path $HomeDir $relativePath
        if (Test-Path -LiteralPath $target) {
            Remove-Item -LiteralPath $target -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

$runtimePythonDir = Join-Path $OutputDir "runtime\python311"
$runtimeHermesDir = Join-Path $OutputDir "runtime\hermes-agent"
$runtimeOllamaDir = Join-Path $OutputDir "runtime\ollama"
$outputOllamaDataDir = Join-Path $OutputDir "data\ollama"
$outputOllamaModelsDir = Join-Path $outputOllamaDataDir "models"
$installersDir = Join-Path $OutputDir "installers"
$embedSource = Ensure-EmbedPythonZip

if ($Clean) {
    Write-Step "Cleaning previous output."
    Stop-ProcessesUnderPath -PathPrefix $OutputDir
    Remove-Item -LiteralPath $OutputDir -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Step "Expanding embeddable Python from $($embedSource.Source)"
Expand-EmbedPython -Destination $runtimePythonDir

Write-Step "Copying Hermes dependencies from current venv"
Copy-Tree -Source $sourceSitePackages -Destination (Join-Path $runtimePythonDir "Lib\site-packages")
Remove-UnwantedSitePackagesArtifacts -SitePackagesDir (Join-Path $runtimePythonDir "Lib\site-packages")
Write-EmbeddedPythonPathFile -PythonDir $runtimePythonDir
Write-Utf8File -Path (Join-Path $runtimePythonDir "SOURCE.txt") -Content @"
Embeddable Python source: $($embedSource.Url)
Version: $PythonEmbedVersion
"@

Write-Step "Copying official Hermes source tree"
Copy-Tree -Source $sourceHermes -Destination $runtimeHermesDir -ExcludeDirectories @("venv", "web", "__pycache__")

if (Test-Path -LiteralPath $sourceOllama) {
    Write-Step "Copying bundled Ollama runtime"
    Copy-Tree -Source $sourceOllama -Destination $runtimeOllamaDir
} else {
    Write-Step "Bundled Ollama runtime not found at $sourceOllama"
}

if (Test-OllamaModelPresent -ModelsDir $sourceBundledOllamaModels -ModelName $defaultOllamaModel) {
    Write-Step "Copying bundled Ollama models"
    Copy-Tree -Source $sourceBundledOllamaData -Destination $outputOllamaDataDir
}
else {
    throw "Bundled Ollama model missing: $defaultOllamaModel under $sourceBundledOllamaModels"
}

Write-Step "Pruning runtime-only artifacts"
Prune-PortablePackage -RootDir $OutputDir

$launcherBat = @'
@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
'@

$setupOllamaBat = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion

set "ROOT=%~dp0"
set "MODEL_NAME=__DEFAULT_OLLAMA_MODEL__"
if exist "%ROOT%home\portable-defaults.txt" (
    for /f "usebackq tokens=1,* delims==" %%A in ("%ROOT%home\portable-defaults.txt") do (
        if /i "%%~A"=="DEFAULT_OLLAMA_MODEL" set "MODEL_NAME=%%~B"
    )
)
set "MODEL_LIBRARY="
set "MODEL_TAG="
for /f "tokens=1,2 delims=:" %%A in ("%MODEL_NAME%") do (
    set "MODEL_LIBRARY=%%~A"
    set "MODEL_TAG=%%~B"
)
if not defined MODEL_LIBRARY set "MODEL_LIBRARY=gemma"
if not defined MODEL_TAG set "MODEL_TAG=2b"
set "OLLAMA_MODELS=%ROOT%data\ollama\models"
set "OLLAMA_EXE="

if exist "%ROOT%runtime\ollama\ollama.exe" set "OLLAMA_EXE=%ROOT%runtime\ollama\ollama.exe"
if not defined OLLAMA_EXE (
    for %%P in (
        "%LOCALAPPDATA%\Programs\Ollama\ollama.exe"
        "%ProgramFiles%\Ollama\ollama.exe"
    ) do (
        if not defined OLLAMA_EXE if exist "%%~fP" set "OLLAMA_EXE=%%~fP"
    )
)
if not defined OLLAMA_EXE (
    for /f "delims=" %%P in ('where.exe ollama 2^>nul') do (
        if not defined OLLAMA_EXE set "OLLAMA_EXE=%%~fP"
    )
)

if defined OLLAMA_EXE goto :have_ollama

echo Bundled Ollama runtime was not found.
echo This package is expected to be self-contained.
echo Restore runtime\ollama\ or install Ollama locally.
exit /b 1

:have_ollama
echo Using Ollama: %OLLAMA_EXE%
if not exist "%OLLAMA_MODELS%" mkdir "%OLLAMA_MODELS%"
start "Ollama Serve" cmd.exe /k "set OLLAMA_MODELS=%OLLAMA_MODELS%&&\"%OLLAMA_EXE%\" serve"
if exist "%OLLAMA_MODELS%\manifests\registry.ollama.ai\library\%MODEL_LIBRARY%\%MODEL_TAG%" (
    echo Bundled model already present: %MODEL_NAME%
) else (
    echo Bundled model missing: %MODEL_NAME%
    echo This package is expected to stay offline.
    exit /b 1
)
exit /b 0
'@

$startHermesPs1 = @'
param(
    [switch]$NoOpenBrowser,
    [switch]$NoOpenChat,
    [string]$OAuthProvider = "",
    [int]$DashboardTimeoutSec = 45
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Resolve-PortablePath {
    param([string]$Path)

    if ([string]::IsNullOrWhiteSpace($Path)) {
        return $Path
    }

    $trimmed = $Path.Trim()
    if ($trimmed -match '^[\\]{2}tsclient[\\/](?<drive>[A-Za-z])(?<rest>(?:[\\/].*)?)$') {
        $rest = ($matches.rest -replace '/', '\')
        return ("{0}:{1}" -f $matches.drive.ToUpperInvariant(), $rest)
    }

    return $trimmed
}

$root = Resolve-PortablePath -Path $PSScriptRoot
$pythonExe = Join-Path $root "runtime\python311\python.exe"
$runtimeDir = Join-Path $root "runtime\hermes-agent"
$homeDir = Join-Path $root "home"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
$tmpLogDir = Join-Path $root "logs\tmp"
$debugLog = Join-Path $root "HermesGo-debug.txt"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$dashboardBrowserUrl = "http://127.0.0.1:9119/env?oauth=openai-codex"
$headless = $env:HERMESGO_HEADLESS -eq "1"
$preserveDebugLog = $env:HERMESGO_APPEND_DEBUG_LOG -eq "1"
$proxyBypassDefaults = @(
    "localhost",
    "127.0.0.1",
    "::1",
    "0.0.0.0",
    ".local",
    ".localhost",
    ".cn",
    ".com.cn",
    ".net.cn",
    ".org.cn",
    ".edu.cn",
    ".gov.cn",
    ".mil.cn",
    ".ac.cn",
    ".npmmirror.com",
    ".aliyun.com",
    ".aliyuncs.com",
    ".tuna.tsinghua.edu.cn",
    ".sdu.edu.cn",
    ".ustc.edu.cn"
)

function Write-LauncherLine {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[${timestamp}] $Message"
    Add-Content -LiteralPath $debugLog -Value $line -Encoding utf8
    Write-Host $Message
}

function Add-DebugBlock {
    param(
        [string]$Label,
        [string]$Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        Write-LauncherLine "$Label file not found: $Path"
        return
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ([string]::IsNullOrWhiteSpace($content)) {
        Write-LauncherLine "$Label file empty: $Path"
        return
    }

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $debugLog -Value "[${timestamp}] $Label begin: $Path" -Encoding utf8
    foreach ($line in ($content -split "`r?`n")) {
        if ($line.Length -gt 0) {
            Add-Content -LiteralPath $debugLog -Value "[${timestamp}] [$Label] $line" -Encoding utf8
        }
    }
    Add-Content -LiteralPath $debugLog -Value "[${timestamp}] $Label end: $Path" -Encoding utf8
}

function Get-MergedNoProxyList {
    param([string[]]$AdditionalEntries)

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($source in @($env:NO_PROXY, $env:no_proxy, ($AdditionalEntries -join ","))) {
        if ([string]::IsNullOrWhiteSpace($source)) {
            continue
        }

        foreach ($entry in ($source -split '[,;]')) {
            $trimmedEntry = $entry.Trim()
            if ($trimmedEntry.Length -eq 0) {
                continue
            }
            if (-not $entries.Contains($trimmedEntry)) {
                [void]$entries.Add($trimmedEntry)
            }
        }
    }

    return $entries.ToArray()
}

function Apply-ProxyBypassEnvironment {
    $mergedEntries = Get-MergedNoProxyList -AdditionalEntries $proxyBypassDefaults
    $joinedEntries = [string]::Join(",", $mergedEntries)
    $env:NO_PROXY = $joinedEntries
    $env:no_proxy = $joinedEntries
    Write-LauncherLine "NO_PROXY: $joinedEntries"
}

function Invoke-DirectHttpRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = "",
        [string]$ContentType = "application/json",
        [int]$TimeoutSec = 3
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        $httpMethod = switch ($Method.ToUpperInvariant()) {
            "POST" { [System.Net.Http.HttpMethod]::Post; break }
            default { [System.Net.Http.HttpMethod]::Get }
        }

        $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
        if ($httpMethod -ne [System.Net.Http.HttpMethod]::Get -and -not [string]::IsNullOrEmpty($Body)) {
            $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $ContentType)
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Test-ListeningPort {
    param([int]$Port)

    return $null -ne (Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue)
}

function Get-PortOwnerPath {
    param([int]$Port)

    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue |
        Select-Object -First 1
    if (-not $listener) {
        return $null
    }

    $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $listener.OwningProcess) -ErrorAction SilentlyContinue
    return $process.ExecutablePath
}

function Get-OllamaManifestRelativePath {
    param([string]$ModelName)

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return $null
    }

    $parts = $ModelName.Trim() -split ':', 2
    if ($parts.Count -ne 2) {
        return $null
    }

    return Join-Path "manifests\registry.ollama.ai\library\$($parts[0])" $parts[1]
}

function Test-BundledOllamaModel {
    param([string]$ModelName)

    $manifestRelativePath = Get-OllamaManifestRelativePath -ModelName $ModelName
    if (-not $manifestRelativePath) {
        return $false
    }

    return Test-Path -LiteralPath (Join-Path $ollamaModelsDir $manifestRelativePath)
}

function Ensure-BundledOllamaModel {
    param(
        [string]$OllamaExe,
        [string]$ModelName
    )

    if ([string]::IsNullOrWhiteSpace($ModelName)) {
        return
    }

    if (Test-BundledOllamaModel -ModelName $ModelName) {
        Write-LauncherLine "Bundled Ollama model ready: $ModelName"
        return
    }

    Write-LauncherLine "Bundled Ollama model missing, pulling into package store: $ModelName"
    Write-LauncherLine "Ollama pull target store: $ollamaModelsDir"
    $env:OLLAMA_MODELS = $ollamaModelsDir

    & $OllamaExe pull $ModelName 2>&1 | ForEach-Object {
        if ($_ -ne $null) {
            Write-LauncherLine ("ollama pull: " + $_.ToString())
        }
    }

    if ($LASTEXITCODE -ne 0) {
        throw "Ollama model download failed: $ModelName (exit $LASTEXITCODE)"
    }

    if (-not (Test-BundledOllamaModel -ModelName $ModelName)) {
        throw "Ollama model download finished but manifest is still missing: $ModelName"
    }

    Write-LauncherLine "Bundled Ollama model downloaded: $ModelName"
}

function Get-LocalOllamaConfig {
    $configPath = Join-Path $homeDir "config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $null
    }

    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $providerMatch = [regex]::Match($configText, '(?m)^\s*provider:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    if (-not $providerMatch.Success) {
        return $null
    }

    $provider = $providerMatch.Groups["v"].Value.Trim().ToLowerInvariant()
    if ($provider -ne "ollama") {
        return $null
    }

    $baseUrlMatch = [regex]::Match($configText, '(?m)^\s*base_url:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    $modelMatch = [regex]::Match($configText, '(?m)^\s*default:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    $baseUrl = if ($baseUrlMatch.Success) { $baseUrlMatch.Groups["v"].Value.Trim() } else { "" }
    $model = if ($modelMatch.Success) { $modelMatch.Groups["v"].Value.Trim() } else { "" }

    if ([string]::IsNullOrWhiteSpace($baseUrl)) {
        return $null
    }

    try {
        $uri = [Uri]$baseUrl
    }
    catch {
        return $null
    }

    if ($uri.Host -notin @("127.0.0.1", "localhost")) {
        return $null
    }

    return [pscustomobject]@{
        BaseUrl = $baseUrl
        Port = if ($uri.Port -gt 0) { $uri.Port } else { 11434 }
        Model = $model
    }
}

function Ensure-LocalOllamaReady {
    $ollamaConfig = Get-LocalOllamaConfig
    if (-not $ollamaConfig) {
        return
    }

    $ollamaExe = Join-Path $root "runtime\ollama\ollama.exe"
    if (-not (Test-Path -LiteralPath $ollamaExe)) {
        Write-LauncherLine "Local Ollama not listening and bundled runtime missing: $ollamaExe"
        return
    }

    New-Item -ItemType Directory -Path $ollamaModelsDir -Force | Out-Null
    $env:OLLAMA_MODELS = $ollamaModelsDir

    $ollamaReady = $false
    if (Test-ListeningPort -Port $ollamaConfig.Port) {
        $ownerPath = Resolve-PortablePath -Path (Get-PortOwnerPath -Port $ollamaConfig.Port)
        if ($ownerPath -and $ownerPath.ToLowerInvariant() -eq $ollamaExe.ToLowerInvariant()) {
            Write-LauncherLine "Local Ollama already listening: $($ollamaConfig.BaseUrl)"
            $ollamaReady = $true
        } else {
            if ($ownerPath) {
                Write-LauncherLine "Stopping external Ollama listener to switch to bundled runtime: $ownerPath"
            } else {
                Write-LauncherLine "Stopping unknown listener on Ollama port $($ollamaConfig.Port)"
            }

            $listeners = Get-NetTCPConnection -LocalPort $ollamaConfig.Port -State Listen -ErrorAction SilentlyContinue
            if ($listeners) {
                $listeners | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
                    if ($_ -and $_ -ne $PID) {
                        Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
                    }
                }
                Start-Sleep -Seconds 1
            }
        }
    }

    if (-not $ollamaReady) {
        $ollamaProcess = Start-Process -FilePath $ollamaExe `
            -ArgumentList "serve" `
            -WorkingDirectory (Split-Path -Parent $ollamaExe) `
            -WindowStyle Hidden `
            -PassThru
        Write-LauncherLine "Local Ollama launched: PID $($ollamaProcess.Id)"

        $deadline = (Get-Date).AddSeconds(15)
        while ((Get-Date) -lt $deadline) {
            if (Test-ListeningPort -Port $ollamaConfig.Port) {
                Write-LauncherLine "Local Ollama ready: $($ollamaConfig.BaseUrl)"
                $ollamaReady = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $ollamaReady) {
        throw "Local Ollama failed to start on $($ollamaConfig.BaseUrl)"
    }

    Ensure-BundledOllamaModel -OllamaExe $ollamaExe -ModelName $ollamaConfig.Model
}

function Test-DashboardReady {
    try {
        $response = Invoke-DirectHttpRequest -Uri $dashboardUrl -TimeoutSec 3
        return $response.StatusCode -eq 200 -and $response.Content -match "<title>Hermes Agent</title>"
    } catch {
        return $false
    }
}

function Start-DashboardProcess {
    param([string]$OAuthProvider = "")

    if (Test-DashboardReady -and [string]::IsNullOrWhiteSpace($OAuthProvider)) {
        Write-LauncherLine "Dashboard already reachable: $dashboardUrl"
        return
    }

    $listener = Get-NetTCPConnection -LocalPort 9119 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $listener | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
            if ($_ -and $_ -ne $PID) {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Remove-Item -LiteralPath $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
    $dashboardArguments = @("-m", "hermes_cli.main", "dashboard", "--host", "127.0.0.1", "--port", "9119", "--no-open")
    if (-not [string]::IsNullOrWhiteSpace($OAuthProvider)) {
        $dashboardArguments += @("--oauth-provider", $OAuthProvider)
    }

    $process = Start-Process -FilePath $pythonExe `
        -ArgumentList $dashboardArguments `
        -WorkingDirectory $runtimeDir `
        -RedirectStandardOutput $dashboardOutLog `
        -RedirectStandardError $dashboardErrLog `
        -PassThru `
        -WindowStyle Hidden
    Write-LauncherLine "Dashboard process started: PID $($process.Id)"

    $deadline = (Get-Date).AddSeconds($DashboardTimeoutSec)
    while ((Get-Date) -lt $deadline) {
        if (Test-DashboardReady) {
            Write-LauncherLine "Dashboard probe succeeded."
            Add-DebugBlock -Label "dashboard stdout" -Path $dashboardOutLog
            Add-DebugBlock -Label "dashboard stderr" -Path $dashboardErrLog
            return
        }
        Start-Sleep -Seconds 1
    }

    $errTail = ""
    if (Test-Path -LiteralPath $dashboardErrLog) {
        $errTail = (Get-Content -LiteralPath $dashboardErrLog -Tail 20 -Encoding utf8) -join " "
    }
    Add-DebugBlock -Label "dashboard stdout" -Path $dashboardOutLog
    Add-DebugBlock -Label "dashboard stderr" -Path $dashboardErrLog
    throw "Dashboard probe failed. $errTail".Trim()
}

function Start-ChatWindow {
    $existing = Get-Process -Name "cmd" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "*HermesGo Chat*" } |
        Select-Object -First 1
    if ($existing) {
        Write-LauncherLine "Chat window already running: PID $($existing.Id)"
        return
    }

    $command = 'set PYTHONHOME=' +
        '&&set PYTHONPATH=' +
        '&&set PATH=' + $root + ';' + (Join-Path $root "runtime\bin") + ';%PATH%' +
        '&&set HERMES_HOME=' + $homeDir +
        '&&set OLLAMA_MODELS=' + $ollamaModelsDir +
        '&&set NO_PROXY=' + $env:NO_PROXY +
        '&&set no_proxy=' + $env:no_proxy +
        '&&set PYTHONUTF8=1' +
        '&&set PYTHONIOENCODING=utf-8' +
        '&&chcp 65001>nul' +
        '&&title HermesGo Chat' +
        '&&"' + $pythonExe + '" -m hermes_cli.main'

    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/k", $command -WorkingDirectory $root -PassThru
    Write-LauncherLine "Chat window launched: PID $($process.Id)"
}

function Open-DashboardBrowser {
    param([string]$Url)

    $attempts = @(
        @{
            Name = "Start-Process url"
            Action = {
                Start-Process -FilePath $Url
            }
        }
        @{
            Name = "cmd start"
            Action = {
                Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "start", "", $Url -WindowStyle Hidden
            }
        }
        @{
            Name = "explorer"
            Action = {
                Start-Process -FilePath "explorer.exe" -ArgumentList $Url
            }
        }
    )

    foreach ($attempt in $attempts) {
        try {
            & $attempt.Action
            Write-LauncherLine "Browser launched: $Url via $($attempt.Name)"
            return
        } catch {
            Write-LauncherLine "Browser launch failed via $($attempt.Name): $($_.Exception.Message)"
        }
    }

    throw "Unable to launch browser for $Url"
}

try {
    New-Item -ItemType Directory -Path $tmpLogDir -Force | Out-Null
    if (-not $preserveDebugLog) {
        Remove-Item -LiteralPath $debugLog -Force -ErrorAction SilentlyContinue
    }
    Remove-Item -LiteralPath $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue

    Write-LauncherLine "HermesGo launcher started."
    Write-LauncherLine "Debug file: $debugLog"
    Write-LauncherLine ("Debug log mode: {0}" -f ($(if ($preserveDebugLog) { "append" } else { "reset" })))
    Write-LauncherLine "App root: $root"
    Write-LauncherLine "Runtime dir: $runtimeDir"
    Write-LauncherLine "Home dir: $homeDir"
    Write-LauncherLine "Ollama model store: $ollamaModelsDir"
    Write-LauncherLine "Dashboard URL: $dashboardUrl"
    Write-LauncherLine "Dashboard browser URL: $dashboardBrowserUrl"
    Write-LauncherLine "Dashboard temp stdout: $dashboardOutLog"
    Write-LauncherLine "Dashboard temp stderr: $dashboardErrLog"

    foreach ($requiredPath in @($pythonExe, $runtimeDir, $homeDir)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required path not found: $requiredPath"
        }
    }

    Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    Apply-ProxyBypassEnvironment
    $env:PATH = [string]::Join(';', @($root, (Join-Path $root "runtime\bin"), $env:PATH))
    $env:HERMES_HOME = $homeDir
    $env:OLLAMA_MODELS = $ollamaModelsDir
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    Write-LauncherLine "Portable target: standard Hermes runtime with portable Python."

    Ensure-LocalOllamaReady
    Start-DashboardProcess -OAuthProvider $OAuthProvider

    if (-not $headless) {
        if (-not $NoOpenBrowser) {
            Open-DashboardBrowser -Url $dashboardBrowserUrl
        }
        if (-not $NoOpenChat) {
            Start-ChatWindow
        }
    }

    Write-LauncherLine "HermesGo finished with exit code 0."
    exit 0
} catch {
    Write-LauncherLine "HermesGo startup failed: $($_.Exception.Message)"
    Write-LauncherLine "HermesGo finished with exit code 1."
    exit 1
}
'@

$verifyBat = @'
@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
'@

$verifyPs1 = @'
$ErrorActionPreference = "Stop"

$root = $PSScriptRoot
$pythonExe = Join-Path $root "runtime\python311\python.exe"
$runtimeBinDir = Join-Path $root "runtime\bin"
$launcherLog = Join-Path $root "HermesGo-debug.txt"
$tmpLogDir = Join-Path $root "logs\tmp"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$configPath = Join-Path $root "home\config.yaml"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
$iconPath = Join-Path $root "HermesGo.ico"
$codexCmd = Join-Path $root "codex.cmd"
$proxyBypassDefaults = @(
    "localhost",
    "127.0.0.1",
    "::1",
    "0.0.0.0",
    ".local",
    ".localhost",
    ".cn",
    ".com.cn",
    ".net.cn",
    ".org.cn",
    ".edu.cn",
    ".gov.cn",
    ".mil.cn",
    ".ac.cn",
    ".npmmirror.com",
    ".aliyun.com",
    ".aliyuncs.com",
    ".tuna.tsinghua.edu.cn",
    ".sdu.edu.cn",
    ".ustc.edu.cn"
)

$env:PATH = [string]::Join(';', @($root, $runtimeBinDir, $env:PATH))

function Assert-Contains {
    param([string]$Path, [string]$Needle)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Missing expected file: $Path" }
    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($content -notmatch [regex]::Escape($Needle)) {
        throw "Assertion failed. Needle not found: $Needle"
    }
}

function Stop-PortListeners {
    param([int]$Port)
    $listeners = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue
    if ($listeners) {
        $listeners | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
            if ($_ -and $_ -ne $PID) {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        }
        Start-Sleep -Seconds 1
    }
}

function Get-PortOwnerPath {
    param([int]$Port)
    $listener = Get-NetTCPConnection -LocalPort $Port -State Listen -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $listener) { return $null }
    $proc = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $listener.OwningProcess)
    return $proc.ExecutablePath
}

function Get-MergedNoProxyList {
    param([string[]]$AdditionalEntries)

    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($source in @($env:NO_PROXY, $env:no_proxy, ($AdditionalEntries -join ","))) {
        if ([string]::IsNullOrWhiteSpace($source)) { continue }
        foreach ($entry in ($source -split '[,;]')) {
            $trimmedEntry = $entry.Trim()
            if ($trimmedEntry.Length -eq 0) { continue }
            if (-not $entries.Contains($trimmedEntry)) {
                [void]$entries.Add($trimmedEntry)
            }
        }
    }

    return $entries.ToArray()
}

function Apply-ProxyBypassEnvironment {
    $mergedEntries = Get-MergedNoProxyList -AdditionalEntries $proxyBypassDefaults
    $joinedEntries = [string]::Join(",", $mergedEntries)
    $env:NO_PROXY = $joinedEntries
    $env:no_proxy = $joinedEntries
}

function Get-ConfiguredModelName {
    if (-not (Test-Path -LiteralPath $configPath)) { return "" }
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $modelMatch = [regex]::Match($configText, '(?m)^\s*default:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    if (-not $modelMatch.Success) { return "" }
    return $modelMatch.Groups["v"].Value.Trim()
}

function Get-OllamaManifestRelativePath {
    param([string]$ModelName)
    if ([string]::IsNullOrWhiteSpace($ModelName)) { return $null }
    $parts = $ModelName.Trim() -split ':', 2
    if ($parts.Count -ne 2) { return $null }
    return Join-Path "manifests\registry.ollama.ai\library\$($parts[0])" $parts[1]
}

function Invoke-DirectHttpRequest {
    param(
        [string]$Uri,
        [string]$Method = "GET",
        [string]$Body = "",
        [string]$ContentType = "application/json",
        [int]$TimeoutSec = 5
    )

    Add-Type -AssemblyName System.Net.Http
    $handler = New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy = $false
    $client = New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout = [TimeSpan]::FromSeconds($TimeoutSec)

    try {
        $httpMethod = switch ($Method.ToUpperInvariant()) {
            "POST" { [System.Net.Http.HttpMethod]::Post; break }
            default { [System.Net.Http.HttpMethod]::Get }
        }

        $request = New-Object System.Net.Http.HttpRequestMessage($httpMethod, $Uri)
        if ($httpMethod -ne [System.Net.Http.HttpMethod]::Get -and -not [string]::IsNullOrEmpty($Body)) {
            $request.Content = New-Object System.Net.Http.StringContent($Body, [System.Text.Encoding]::UTF8, $ContentType)
        }

        $response = $client.SendAsync($request).GetAwaiter().GetResult()
        $content = $response.Content.ReadAsStringAsync().GetAwaiter().GetResult()
        return [pscustomobject]@{
            StatusCode = [int]$response.StatusCode
            Content = $content
        }
    }
    finally {
        $client.Dispose()
        $handler.Dispose()
    }
}

function Invoke-OllamaCompatProbe {
    param([string]$ModelName)

    $body = @{
        model = $ModelName
        messages = @(
            @{
                role = "user"
                content = "hello"
            }
        )
        max_tokens = 12
    } | ConvertTo-Json -Depth 6

    $response = Invoke-DirectHttpRequest -Uri "http://127.0.0.1:11434/v1/chat/completions" `
        -Method POST `
        -ContentType "application/json" `
        -Body $body `
        -TimeoutSec 120

    return $response.Content | ConvertFrom-Json
}

New-Item -ItemType Directory -Path $tmpLogDir -Force | Out-Null
Remove-Item -LiteralPath $launcherLog, $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Missing expected file: $iconPath"
}
$oldPythonHome = $env:PYTHONHOME
$oldPythonPath = $env:PYTHONPATH
$oldHeadless = $env:HERMESGO_HEADLESS
$oldOllamaModels = $env:OLLAMA_MODELS
try {
    $env:HERMESGO_HEADLESS = "1"
    Apply-ProxyBypassEnvironment
    $env:OLLAMA_MODELS = $ollamaModelsDir
    Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    Stop-PortListeners -Port 9119
    Stop-PortListeners -Port 11434

    $configuredModel = Get-ConfiguredModelName
    $manifestRelativePath = Get-OllamaManifestRelativePath -ModelName $configuredModel
    if (-not $manifestRelativePath) {
        throw "Unable to resolve bundled Ollama manifest for model: $configuredModel"
    }
    $manifestPath = Join-Path $ollamaModelsDir $manifestRelativePath
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Bundled Ollama model missing: $configuredModel ($manifestPath)"
    }

    $probeJson = & $pythonExe -c "import json, sys, fastapi, uvicorn, yaml, anyio, hermes_cli.main; print(json.dumps({'exe': sys.executable, 'path': sys.path}))"
    if ($LASTEXITCODE -ne 0) { throw 'Portable Python import probe failed.' }
    $probe = ($probeJson | Select-Object -Last 1 | ConvertFrom-Json)
    if ($probe.exe -ine $pythonExe) {
        throw "Portable Python exe mismatch: $($probe.exe)"
    }
    if (($probe.path | Where-Object { $_ -like 'C:\Users\Administrator\AppData\Local\Programs\Python\Python311*' }).Count -gt 0) {
        throw "sys.path still contains the system Python installation."
    }
    if (($probe.path | Where-Object { $_ -like '*\runtime\hermes-agent\venv\Lib\site-packages*' }).Count -gt 0) {
        throw "sys.path still contains the source venv site-packages."
    }

    $codexResolved = Get-Command codex -ErrorAction SilentlyContinue
    if (-not $codexResolved) {
        throw "codex compatibility launcher not found in PATH."
    }
    $codexOutput = & cmd /c "call `"$codexCmd`"" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "codex compatibility launcher failed with exit code $LASTEXITCODE"
    }
    $codexText = ($codexOutput -join "`n")
    if ($codexText -notmatch "HermesGo codex compatibility launcher") {
        throw "codex compatibility launcher did not print the expected banner."
    }
    $codexLoginHelpOutput = & cmd /c "call `"$codexCmd`" login --help" 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "codex login help probe failed with exit code $LASTEXITCODE"
    }
    $codexLoginHelpText = ($codexLoginHelpOutput -join "`n")
    if ($codexLoginHelpText -match "unrecognized arguments:\s+login") {
        throw "codex login compatibility launcher still leaks the login subcommand into Hermes."
    }
    if ($codexLoginHelpText -notmatch "Add a pooled credential") {
        throw "codex login help probe did not reach the Hermes auth add command."
    }

    cmd /c "call `"$root\HermesGo.bat`" -NoOpenBrowser -NoOpenChat"
    if ($LASTEXITCODE -ne 0) { throw "HermesGo.bat failed with exit code $LASTEXITCODE" }
    Assert-Contains $launcherLog "HermesGo finished with exit code 0."
    Assert-Contains $launcherLog "Ollama model store: $ollamaModelsDir"
    Assert-Contains $launcherLog "Dashboard browser URL: http://127.0.0.1:9119/env?oauth=openai-codex"
    $response = Invoke-DirectHttpRequest -Uri $dashboardUrl -TimeoutSec 5
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch "<title>Hermes Agent</title>") {
        throw "Dashboard probe did not return the Hermes UI."
    }
    $ollamaProbe = Invoke-OllamaCompatProbe -ModelName $configuredModel
    if (-not $ollamaProbe.choices -or $ollamaProbe.choices.Count -lt 1) {
        throw "Bundled Ollama OpenAI-compatible probe returned no choices."
    }
    $ownerPath = Get-PortOwnerPath -Port 9119
    if ($ownerPath -ine $pythonExe) {
        throw "Dashboard listener is not owned by portable python.exe. Owner: $ownerPath"
    }
    Write-Host "Portable HermesGo verification passed."
} finally {
    Stop-PortListeners -Port 9119
    Stop-PortListeners -Port 11434
    if ($null -eq $oldHeadless) {
        Remove-Item Env:HERMESGO_HEADLESS -ErrorAction SilentlyContinue
    } else {
        $env:HERMESGO_HEADLESS = $oldHeadless
    }
    if ($null -eq $oldPythonHome) {
        Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONHOME = $oldPythonHome
    }
    if ($null -eq $oldPythonPath) {
        Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    } else {
        $env:PYTHONPATH = $oldPythonPath
    }
    if ($null -eq $oldOllamaModels) {
        Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue
    } else {
        $env:OLLAMA_MODELS = $oldOllamaModels
    }
}
'@

$packageReadme = @'
# HermesGo

HermesGo is the Windows green bundle for Hermes Agent. It is also intended to serve as a USB-friendly, one-click install package with a built-in local model runtime.

## Download

- Current download package: `__CURRENT_RELEASE_ZIP__`
- Current checksum file: `__CURRENT_RELEASE_SHA__`
- Current release tag: `__CURRENT_RELEASE_TAG__`
- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- The downloadable zip and checksum are published on the release page above.
- Older release versions remain published on GitHub Releases and are not deleted.
- Yesterday's archive `__PREVIOUS_RELEASE_PATTERN__` is the older version; it is kept on purpose.

The full package is about 1.6 GB and includes everything needed to run directly:

- Hermes Agent runtime
- Dashboard
- Portable Python
- Portable Ollama runtime
- Default Ollama 2B model store
- `HermesGo.exe` with a horse-head icon, a classic beginner launcher, a selectable action box, and a contextual explanation area under the selection
- Bundled `codex.cmd` compatibility launcher for the release package, not an external Codex CLI dependency
- `tutorial/` with numbered screenshots and usage notes for new users

## How to use

1. Download the full zip. It keeps the top-level `HermesGo/` directory.
2. Extract the whole `HermesGo/` directory. Do not copy only `HermesGo.exe`.
3. Double-click `HermesGo.exe`. It opens the classic launcher with a selectable action box for beginner start, OpenAI GPT-5.4 mini, Dashboard / Config, and utility actions for model switching, self-check, logs, config folders, and custom launcher actions from `home/launcher-actions.txt`.
4. If you prefer the direct entry, double-click `HermesGo.bat`.
5. For a quick self-check, run `Verify-HermesGo.bat`.
6. To switch the default local model, run `Switch-HermesGoModel.bat`.
7. Local 2B startup does not trigger ChatGPT / Codex sign-in. Only `Cloud: GPT-5.4 Mini` auto-runs the bundled login flow when Codex auth is missing.
8. If you are learning the package, open `tutorial/README.md` first and follow the numbered screenshots.

## Directory map

| Path | Purpose |
|---|---|
| `HermesGo.exe` | Classic launcher entrypoint with beginner, cloud, advanced, utility, and custom choices |
| `HermesGo.bat` | Direct entrypoint for the full runtime |
| `Start-HermesGo.ps1` | Main launcher that starts runtime, Dashboard, and chat |
| `Verify-HermesGo.bat` / `Verify-HermesGo.ps1` | Structure and runtime verification |
| `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1` | Switch the default local model |
| `codex.cmd` | Bundled Codex-compatible shim used by the release package |
| `runtime/` | Packaged runtime files |
| `home/` | Persistent config, sessions, state, and memory |
| `data/` | Runtime data |
| `data/ollama/` | Bundled Ollama model store |
| `data/ollama/models/` | Offline model files and manifests |
| `tutorial/` | Numbered usage screenshots and notes for new users |
| `logs/` | Temporary logs |
| `HermesGo-debug.txt` | Root debug log, refreshed on each launch |
| `installers/` | Optional installer drop-in directory, not required for runtime |

## How I tested it

I did not keep editing the published output directly. I used an isolated test workspace:

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. The script copies `create_hermes_go/output/HermesGo` into `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Make changes and launch `HermesGo.exe` / `HermesGo.bat` in the sandbox
4. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

What the verification checks:

- The launcher remembers the last selected item, loads custom actions from `home/launcher-actions.txt`, and shows state-aware explanations for each menu item
- Cloud / GPT-5.4 mini checks Codex login state before launch and opens the browser login page only when credentials are missing
- Local start and local model switching still work
- `HermesGo.bat` / `Start-HermesGo.ps1` still start the Dashboard flow
- The bundled Ollama 2B model store is available
- The portable Python runtime is still the bundled one
- Launch logs are written to `HermesGo-debug.txt`
- Tutorial screenshots live in `tutorial/`
- Release packaging excludes local `auth.json` / `auth.lock` credentials from the ship-ready bundle

If you want to keep iterating, do it in the sandbox first and only return to the published package after the sandbox passes.
'@

$installerReadme = @'
# installers

可选外部安装器投放目录。

## 推荐文件

- 这里默认不再随包附带额外的 Ollama 安装器压缩包。
- 如果你想替换系统级 Ollama，可以自行放入 `OllamaSetup.exe`。

## 目的

- HermesGo 自身已经把离线运行所需内容打包在本目录内
- `runtime/ollama/` 已经包含可直接启动的本地运行时
- `data/ollama/models/` 里已有默认模型时，不需要联网 `pull`
'@

$homeConfig = @'
model:
  provider: "__DEFAULT_OLLAMA_PROVIDER__"
  default: "__DEFAULT_OLLAMA_MODEL__"
  base_url: "__DEFAULT_OLLAMA_BASE_URL__"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
'@

$codexCmd = @'
@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "PYTHON_EXE=%ROOT%runtime\python311\python.exe"
set "RUNTIME_BIN=%ROOT%runtime\bin"
set "HERMES_HOME=%ROOT%home"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PATH=%ROOT%;%RUNTIME_BIN%;%PATH%"
set "PYTHONHOME="
set "PYTHONPATH="

if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)

if /i "%~1"=="login" (
    "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~2 %~3 %~4 %~5 %~6 %~7 %~8 %~9
    exit /b %ERRORLEVEL%
)

if /i "%~1"=="auth" if /i "%~2"=="login" (
    "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~3 %~4 %~5 %~6 %~7 %~8 %~9
    exit /b %ERRORLEVEL%
)

echo HermesGo codex compatibility launcher
echo.
echo This package includes a Codex-compatible launcher so you do not need to
echo install a separate codex CLI.
echo.
echo Use:
echo   codex login
echo.
echo Or open HermesGo and use the Web Dashboard Config page.
exit /b 0
'@

$builderReadme = @'
# create_hermes_go

这个目录负责 HermesGo 的构建和测试，也包含这条绿色版 / U 盘版 / 一键安装版 release 线的生成脚本。

## 当前路线

- 用官方 Hermes 源码和当前工作区依赖生成绿色包
- 用官方 embeddable Python 替换本机系统 Python
- 默认切换到 Ollama 本地模型，避免云端 token 依赖
- `create_hermes_go/output/HermesGo` 是最终交付目录，复制整个目录即可离线运行
- 生成时会带上 `HermesGo.exe` 的应用图标、经典启动器和 `codex.cmd` 兼容入口，并把测试工作区放到独立沙箱里验证
- 生成时也会把 `tutorial/` 一起带上，方便新手按编号图片学习使用
- 这条 release 线不依赖外部安装的 Codex CLI；本地 2B 不会触发 ChatGPT / Codex 登录，只有 Cloud 路线在缺少授权时才自动登录
- 当前发布版本：`__CURRENT_RELEASE_TAG__`
- 当前 zip：`__CURRENT_RELEASE_ZIP__`
- 当前 checksum：`__CURRENT_RELEASE_SHA__`

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
- `test/Prepare-HermesGoTestWorkspace.ps1`
- `test/Verify-HermesGoTestWorkspace.ps1`
'@

$doc003 = @'
# 003-绿色版 / U盘版 / 一键安装版更新说明

## 这次新版本是什么

这是 Hermes Agent 的 Windows 绿色版新分支，也可以理解为 U 盘版、一键安装版、自带大模型版。

这版的目标不是替换旧版本，而是新增一条更适合便携分发的发布线：

- 绿色版，解压即用
- U 盘版，整包可直接拷贝运行
- 一键安装版，自带本地 Ollama 大模型
- 不依赖系统里另外安装 Python、Ollama 或外部 Codex CLI

## 新版本特性

- `HermesGo.exe` 是主入口，保留经典启动器，适合新手直接点选。
- 本地 2B 启动只走离线模型，不会触发 ChatGPT / Codex 登录。
- `Cloud: GPT-5.4 Mini` 只有在未登录时才会自动发起 Codex 登录。
- OpenAI Codex 登录走的是 Hermes 自己内置的浏览器 / 认证流程，不依赖外部安装的 Codex CLI。
- 绿色包不会携带本地 `auth.json`、`auth.lock` 这类账号凭据文件。
- 原来的版本保留在 GitHub Releases，不删除、不覆盖。

## 兼容性说明

- 旧版继续可用，适合已经习惯原工作流的用户。
- 新版新增的是绿色版 / U 盘版 / 一键安装版的便携体验。
- 如果你只想跑本地大模型，直接用本地 2B 入口即可。
- 如果你要云端能力，只在 `Cloud: GPT-5.4 Mini` 里登录一次即可。

## 发布约定

- 源码会和 release 一起同步到 GitHub。
- 新版只追加，不删除旧版。
- 代码更新说明会明确写出：绿色版、U 盘版、一键安装版、自带大模型、OpenAI Codex 登录路径。
- 当前版本：`__CURRENT_RELEASE_TAG__`
- 当前 zip：`__CURRENT_RELEASE_ZIP__`
- 当前 checksum：`__CURRENT_RELEASE_SHA__`
- `__PREVIOUS_RELEASE_PATTERN__` 是昨天的旧包，保留但不是今天的下载项。
'@

$doc001 = @'
# 001-当前状态与标准边界

## 当前判断

- 当前能跑起来的是官方 Hermes v0.10.0 代码和官方 Dashboard。
- `create_hermes_go` 的目标是把这条工作链固化成脚本，并生成新的独立目录。
- 当前输出包的 Python 运行时来自官方 embeddable package，而不是本机系统 Python。
- 当前输出包的交付目录就是 `create_hermes_go/output/HermesGo`，可以整目录复制到别的机器直接使用。

## 标准部分

- `python -m hermes_cli.main`
- `dashboard`
- `runtime/hermes-agent/web_dist`

## 非标准补层

- 便携 Python
- Windows bat 启动链
- Ollama 本地模型预配置
- 绿色包交付目录
'@

$doc002 = @'
# 002-便携构建步骤与后续工作

## 当前脚本做的事

1. 下载并解包官方 embeddable Python
2. 复制 Hermes 依赖
3. 复制官方 Hermes 源码
4. 生成新的 `HermesGo.bat`、`Setup-Ollama.bat`、`Verify-HermesGo.bat`
5. 生成默认的本地模型配置
6. 生成 `HermesGo.exe` 的马头图标
7. 把最终绿色包固定输出到 `create_hermes_go/output/HermesGo`

## 当前还能改进的地方

1. 在干净 Win11 机器上继续做无缓存冷启动验证
2. 进一步补齐 Git for Windows / MinGit 的便携检测
3. 视需要增加 Python embeddable 的更多国内镜像候选
4. 给绿色包增加一个目录白名单校验，防止升级后多出杂文件
5. 继续补强 Dashboard / 浏览器启动兼容性
'@

$packageReadme = $packageReadme.Replace("__CURRENT_RELEASE_TAG__", $currentReleaseTag)
$packageReadme = $packageReadme.Replace("__CURRENT_RELEASE_ZIP__", $currentReleaseZip)
$packageReadme = $packageReadme.Replace("__CURRENT_RELEASE_SHA__", $currentReleaseSha)
$packageReadme = $packageReadme.Replace("__PREVIOUS_RELEASE_PATTERN__", $previousReleasePattern)

$builderReadme = $builderReadme.Replace("__CURRENT_RELEASE_TAG__", $currentReleaseTag)
$builderReadme = $builderReadme.Replace("__CURRENT_RELEASE_ZIP__", $currentReleaseZip)
$builderReadme = $builderReadme.Replace("__CURRENT_RELEASE_SHA__", $currentReleaseSha)

$doc003 = $doc003.Replace("__CURRENT_RELEASE_TAG__", $currentReleaseTag)
$doc003 = $doc003.Replace("__CURRENT_RELEASE_ZIP__", $currentReleaseZip)
$doc003 = $doc003.Replace("__CURRENT_RELEASE_SHA__", $currentReleaseSha)
$doc003 = $doc003.Replace("__PREVIOUS_RELEASE_PATTERN__", $previousReleasePattern)

$setupOllamaBat = $setupOllamaBat.Replace("__DEFAULT_OLLAMA_MODEL__", $defaultOllamaModel)
$homeConfig = $homeConfig.Replace("__DEFAULT_OLLAMA_PROVIDER__", $defaultOllamaProvider)
$homeConfig = $homeConfig.Replace("__DEFAULT_OLLAMA_MODEL__", $defaultOllamaModel)
$homeConfig = $homeConfig.Replace("__DEFAULT_OLLAMA_BASE_URL__", $defaultOllamaBaseUrl)

Write-Step "Writing portable package files"
Write-Utf8File -Path (Join-Path $OutputDir "HermesGo.bat") -Content $launcherBat
Write-Utf8File -Path (Join-Path $OutputDir "Setup-Ollama.bat") -Content $setupOllamaBat
Write-Utf8File -Path (Join-Path $OutputDir "Start-HermesGo.ps1") -Content $startHermesPs1
Write-Utf8File -Path (Join-Path $OutputDir "Verify-HermesGo.bat") -Content $verifyBat
Write-Utf8File -Path (Join-Path $OutputDir "Verify-HermesGo.ps1") -Content $verifyPs1
Copy-Item -LiteralPath (Join-Path $repoRoot "HermesGo\Switch-HermesGoModel.ps1") -Destination (Join-Path $OutputDir "Switch-HermesGoModel.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "HermesGo\Switch-HermesGoModel.bat") -Destination (Join-Path $OutputDir "Switch-HermesGoModel.bat") -Force
Write-Utf8File -Path (Join-Path $OutputDir "codex.cmd") -Content $codexCmd
Write-Utf8File -Path (Join-Path $OutputDir "README.md") -Content $packageReadme
Write-Utf8File -Path (Join-Path $OutputDir "installers\README.md") -Content $installerReadme
if (Test-Path -LiteralPath (Join-Path $builderRoot "tutorial")) {
    Copy-Tree -Source (Join-Path $builderRoot "tutorial") -Destination (Join-Path $OutputDir "tutorial")
}
Reset-OutputHomeState -HomeDir (Join-Path $OutputDir "home")
Write-Utf8File -Path (Join-Path $OutputDir "home\portable-defaults.txt") -Content @"
; Portable fallback defaults for HermesGo
DEFAULT_OLLAMA_PROVIDER=$defaultOllamaProvider
DEFAULT_OLLAMA_MODEL=$defaultOllamaModel
DEFAULT_OLLAMA_BASE_URL=$defaultOllamaBaseUrl
"@
Write-Utf8File -Path (Join-Path $OutputDir "home\config.yaml") -Content $homeConfig
Write-Utf8File -Path (Join-Path $OutputDir "home\.env") -Content ""
Write-Step "Creating HermesGo application icon"
$iconPath = Join-Path $OutputDir "HermesGo.ico"
New-HermesGoIcon -OutputPath $iconPath -PngOutputPath (Join-Path $OutputDir "HermesGo-logo.png")
Build-HermesGoExe -SourcePath (Join-Path $builderRoot "HermesGoBootstrap.cs") -OutputPath (Join-Path $OutputDir "HermesGo.exe") -IconPath $iconPath
Write-Utf8File -Path (Join-Path $builderRoot "README.md") -Content $builderReadme
Write-Utf8File -Path (Join-Path $docsDir "001-当前状态与标准边界.md") -Content $doc001
Write-Utf8File -Path (Join-Path $docsDir "002-便携构建步骤与后续工作.md") -Content $doc002
Write-Utf8File -Path (Join-Path $docsDir "003-green-usb-oneclick-release-notes.md") -Content $doc003

Write-Step "Portable HermesGo output created at $OutputDir"
