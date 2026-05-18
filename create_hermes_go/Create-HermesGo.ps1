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
$sourceUiSuite = Join-Path $repoRoot "exports\selftest-official-run\app\ui-suite"
$sourceUiSuiteScripts = Join-Path $repoRoot "exports\selftest-official-run\app\scripts"
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
$releaseStatePath = Join-Path $builderRoot "release-state.json"
if (-not (Test-Path -LiteralPath $releaseStatePath)) {
    throw "Missing release state file: $releaseStatePath"
}

$releaseState = Get-Content -LiteralPath $releaseStatePath -Raw -Encoding utf8 | ConvertFrom-Json
$currentReleaseTag = [string]$releaseState.currentReleaseTag
$currentReleaseZip = [string]$releaseState.currentReleaseZip
$currentReleaseSha = [string]$releaseState.currentReleaseSha
$previousReleasePattern = [string]$releaseState.previousReleasePattern

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

function Remove-TreeRobust {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return
    }

    $emptySeed = Join-Path ([System.IO.Path]::GetTempPath()) ("hermesgo-empty-" + [guid]::NewGuid().ToString("N"))
    New-Item -ItemType Directory -Path $emptySeed -Force | Out-Null
    try {
        & robocopy $emptySeed $Path /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
        if ($LASTEXITCODE -gt 7) {
            throw "robocopy clean failed ($LASTEXITCODE): $Path"
        }
    } finally {
        Remove-Item -LiteralPath $emptySeed -Recurse -Force -ErrorAction SilentlyContinue
    }

    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
    if (Test-Path -LiteralPath $Path) {
        $longPath = "\\?\$Path"
        & cmd.exe /c "rmdir /s /q `"$longPath`"" | Out-Null
    }

    if (Test-Path -LiteralPath $Path) {
        $parent = Split-Path -Parent $Path
        $name = Split-Path -Leaf $Path
        $stalePath = Join-Path $parent ($name + "-stale-" + (Get-Date -Format "yyyyMMddHHmmss"))
        Move-Item -LiteralPath $Path -Destination $stalePath -Force
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
    $normalizedForCommandLine = $normalized.Replace('\', '\\')
    $currentProcessId = $PID
    Get-CimInstance Win32_Process | Where-Object {
        if ($_.ProcessId -eq $currentProcessId) {
            return $false
        }

        if ($_.ExecutablePath -and $_.ExecutablePath.ToLowerInvariant().StartsWith($normalized)) {
            return $true
        }

        if ($_.CommandLine) {
            $commandLine = $_.CommandLine.ToLowerInvariant()
            return $commandLine.Contains($normalized) -or $commandLine.Contains($normalizedForCommandLine)
        }

        return $false
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

$appDir = Join-Path $OutputDir "app"
$scriptsDir = Join-Path $appDir "scripts"
$toolsDir = Join-Path $appDir "tools"
$docsOutputDir = Join-Path $appDir "docs"
$assetsDir = Join-Path $appDir "assets"
$assetsIconsDir = Join-Path $assetsDir "icons"
$runtimePythonDir = Join-Path $appDir "runtime\python311"
$runtimeHermesDir = Join-Path $appDir "runtime\hermes-agent"
$runtimeOllamaDir = Join-Path $appDir "runtime\ollama"
$outputOllamaDataDir = Join-Path $appDir "data\ollama"
$outputOllamaModelsDir = Join-Path $outputOllamaDataDir "models"
$installersDir = Join-Path $appDir "installers"
$embedSource = Ensure-EmbedPythonZip

if ($Clean) {
    Write-Step "Cleaning previous output."
    Stop-ProcessesUnderPath -PathPrefix $OutputDir
    Remove-TreeRobust -Path $OutputDir
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

$requiresBundledDefaultOllamaModel = [string]::IsNullOrWhiteSpace($defaultOllamaProvider) -or $defaultOllamaProvider -ieq "ollama"
if ($requiresBundledDefaultOllamaModel) {
    if (Test-OllamaModelPresent -ModelsDir $sourceBundledOllamaModels -ModelName $defaultOllamaModel) {
        Write-Step "Copying bundled Ollama models"
        Copy-Tree -Source $sourceBundledOllamaData -Destination $outputOllamaDataDir
    }
    else {
        throw "Bundled Ollama model missing: $defaultOllamaModel under $sourceBundledOllamaModels"
    }
}
elseif (Test-Path -LiteralPath $sourceBundledOllamaData) {
    Write-Step "Copying bundled Ollama data while default provider is $defaultOllamaProvider"
    Copy-Tree -Source $sourceBundledOllamaData -Destination $outputOllamaDataDir
}
else {
    Write-Step "Bundled Ollama data not found at $sourceBundledOllamaData"
}

Write-Step "Pruning runtime-only artifacts"
Prune-PortablePackage -RootDir $appDir

$launcherBat = @'
@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
'@

$setupOllamaBat = @'
@echo off
setlocal EnableExtensions EnableDelayedExpansion

for %%I in ("%~dp0..") do set "ROOT=%%~fI\"
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
    [string]$ChatProvider = "",
    [string]$ChatModel = "",
    [switch]$PlanOnly,
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

$root = Resolve-PortablePath -Path ([System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..")))
$pythonExe = Join-Path $root "runtime\python311\python.exe"
$runtimeDir = Join-Path $root "runtime\hermes-agent"
$homeDir = Join-Path $root "home"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
$tmpLogDir = Join-Path $root "logs\tmp"
$debugLog = Join-Path $root "logs\HermesGo-debug.txt"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard.err.txt"
$commandPlanPath = Join-Path $root "logs\last-start-hermesgo-plan.json"
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

$script:CommandPlan = New-Object System.Collections.Generic.List[object]

function Format-CommandArgument {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }

    if ($Value -match '[\s"`&()]') {
        return '"' + ($Value -replace '"', '\"') + '"'
    }

    return $Value
}

function Join-CommandLine {
    param(
        [string]$FilePath,
        [string[]]$ArgumentList
    )

    $parts = New-Object System.Collections.Generic.List[string]
    [void]$parts.Add((Format-CommandArgument -Value $FilePath))
    foreach ($argument in @($ArgumentList)) {
        [void]$parts.Add((Format-CommandArgument -Value $argument))
    }
    return [string]::Join(" ", $parts)
}

function Save-CommandPlan {
    $plan = [ordered]@{
        schema = 1
        generated_at = (Get-Date).ToString("o")
        plan_only = [bool]$PlanOnly
        source = "Start-HermesGo.ps1"
        root = $root
        commands = @($script:CommandPlan.ToArray())
    }
    $json = ($plan | ConvertTo-Json -Depth 8) -join [Environment]::NewLine
    [System.IO.File]::WriteAllText($commandPlanPath, $json, [System.Text.UTF8Encoding]::new($false))
}

function Add-CommandPlan {
    param(
        [string]$StepName,
        [string]$FilePath,
        [string[]]$ArgumentList,
        [string]$WorkingDirectory,
        [hashtable]$Details = @{}
    )

    if (-not $PlanOnly) {
        return
    }

    $entry = [ordered]@{
        step = $script:CommandPlan.Count + 1
        step_name = $StepName
        file_name = $FilePath
        argument_list = @($ArgumentList)
        working_directory = $WorkingDirectory
        command_line = Join-CommandLine -FilePath $FilePath -ArgumentList $ArgumentList
        details = $Details
    }
    [void]$script:CommandPlan.Add($entry)
    Save-CommandPlan
    Write-LauncherLine ("PlanOnly command {0}: {1}" -f $entry.step, $StepName)
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

    $client = [System.Net.Sockets.TcpClient]::new()
    try {
        $async = $client.BeginConnect("127.0.0.1", $Port, $null, $null)
        if (-not $async.AsyncWaitHandle.WaitOne(500)) {
            return $false
        }
        $client.EndConnect($async)
        return $true
    }
    catch {
        return $false
    }
    finally {
        $client.Close()
    }
}

function Get-ListeningProcessIds {
    param([int]$Port)

    $ids = New-Object System.Collections.Generic.List[int]
    try {
        $lines = & netstat.exe -ano -p tcp 2>$null
    }
    catch {
        return @()
    }

    foreach ($line in $lines) {
        if ($line -notmatch "\sLISTENING\s+(\d+)\s*$") { continue }
        if ($line -notmatch "[:\.]$Port\s+") { continue }
        $pidValue = 0
        if ([int]::TryParse($matches[1], [ref]$pidValue) -and -not $ids.Contains($pidValue)) {
            [void]$ids.Add($pidValue)
        }
    }
    return @($ids)
}

function Get-PortOwnerPath {
    param([int]$Port)

    $ownerId = Get-ListeningProcessIds -Port $Port | Select-Object -First 1
    if (-not $ownerId) {
        return $null
    }

    $process = Get-Process -Id $ownerId -ErrorAction SilentlyContinue
    if ($process -and $process.Path) {
        return $process.Path
    }

    $process = Get-CimInstance Win32_Process -Filter ("ProcessId = {0}" -f $ownerId) -ErrorAction SilentlyContinue
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
        Port = 11434
        CompatPort = if ($uri.Port -gt 0) { $uri.Port } else { 11434 }
        Model = $model
    }
}

function Ensure-OllamaOpenAiProxyReady {
    param(
        [Parameter(Mandatory = $true)]
        $OllamaConfig
    )

    if ($OllamaConfig.CompatPort -eq $OllamaConfig.Port) {
        return
    }

    if ($PlanOnly) {
        Add-CommandPlan `
            -StepName "start-ollama-openai-proxy" `
            -FilePath $pythonExe `
            -ArgumentList @(
                "-m", "hermes_cli.ollama_openai_proxy",
                "--host", "127.0.0.1",
                "--port", [string]$OllamaConfig.CompatPort,
                "--ollama", ("http://127.0.0.1:{0}" -f $OllamaConfig.Port)
            ) `
            -WorkingDirectory $runtimeDir `
            -Details @{ base_url = $OllamaConfig.BaseUrl; model = $OllamaConfig.Model }
        return
    }

    if (Test-ListeningPort -Port $OllamaConfig.CompatPort) {
        try {
            $response = Invoke-DirectHttpRequest -Uri ("http://127.0.0.1:{0}/v1/models" -f $OllamaConfig.CompatPort) -TimeoutSec 3
            if ($response.StatusCode -eq 200) {
                Write-LauncherLine "Ollama OpenAI proxy already listening: $($OllamaConfig.BaseUrl)"
                return
            }
        }
        catch {
        }

        $listenerIds = @(Get-ListeningProcessIds -Port $OllamaConfig.CompatPort)
        if ($listenerIds) {
            Write-LauncherLine "Stopping stale listener on Ollama OpenAI proxy port $($OllamaConfig.CompatPort)"
            $listenerIds | Select-Object -Unique | ForEach-Object {
                if ($_ -and $_ -ne $PID) {
                    Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
                }
            }
            Start-Sleep -Seconds 1
        }
    }

    $proxyOutLog = Join-Path $tmpLogDir "HermesGo-ollama-openai-proxy.out.txt"
    $proxyErrLog = Join-Path $tmpLogDir "HermesGo-ollama-openai-proxy.err.txt"
    Remove-Item -LiteralPath $proxyOutLog, $proxyErrLog -Force -ErrorAction SilentlyContinue
    $proxyProcess = Start-Process -FilePath $pythonExe `
        -ArgumentList @(
            "-m", "hermes_cli.ollama_openai_proxy",
            "--host", "127.0.0.1",
            "--port", [string]$OllamaConfig.CompatPort,
            "--ollama", ("http://127.0.0.1:{0}" -f $OllamaConfig.Port)
        ) `
        -WorkingDirectory $runtimeDir `
        -RedirectStandardOutput $proxyOutLog `
        -RedirectStandardError $proxyErrLog `
        -WindowStyle Hidden `
        -PassThru
    Write-LauncherLine "Ollama OpenAI proxy launched: PID $($proxyProcess.Id), $($OllamaConfig.BaseUrl)"

    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-DirectHttpRequest -Uri ("http://127.0.0.1:{0}/v1/models" -f $OllamaConfig.CompatPort) -TimeoutSec 3
            if ($response.StatusCode -eq 200) {
                Write-LauncherLine "Ollama OpenAI proxy ready: $($OllamaConfig.BaseUrl)"
                return
            }
        }
        catch {
        }
        Start-Sleep -Milliseconds 500
    }

    Add-DebugBlock -Label "ollama proxy stdout" -Path $proxyOutLog
    Add-DebugBlock -Label "ollama proxy stderr" -Path $proxyErrLog
    throw "Ollama OpenAI proxy failed to start on $($OllamaConfig.BaseUrl)"
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

    if ($PlanOnly) {
        Add-CommandPlan `
            -StepName "start-local-ollama" `
            -FilePath $ollamaExe `
            -ArgumentList @("serve") `
            -WorkingDirectory (Split-Path -Parent $ollamaExe) `
            -Details @{ model = $ollamaConfig.Model; models_dir = $ollamaModelsDir; port = $ollamaConfig.Port }
        Ensure-OllamaOpenAiProxyReady -OllamaConfig $ollamaConfig
        return
    }

    New-Item -ItemType Directory -Path $ollamaModelsDir -Force | Out-Null
    $env:OLLAMA_MODELS = $ollamaModelsDir

    $ollamaReady = $false
    if (Test-ListeningPort -Port $ollamaConfig.Port) {
        $ownerPath = Resolve-PortablePath -Path (Get-PortOwnerPath -Port $ollamaConfig.Port)
        if ($ownerPath -and $ownerPath.ToLowerInvariant() -eq $ollamaExe.ToLowerInvariant()) {
            Write-LauncherLine "Local Ollama already listening: http://127.0.0.1:$($ollamaConfig.Port)"
            $ollamaReady = $true
        } else {
            if ($ownerPath) {
                Write-LauncherLine "Stopping external Ollama listener to switch to bundled runtime: $ownerPath"
            } else {
                Write-LauncherLine "Stopping unknown listener on Ollama port $($ollamaConfig.Port)"
            }

            $listenerIds = @(Get-ListeningProcessIds -Port $ollamaConfig.Port)
            if ($listenerIds) {
                $listenerIds | Select-Object -Unique | ForEach-Object {
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
                Write-LauncherLine "Local Ollama ready: http://127.0.0.1:$($ollamaConfig.Port)"
                $ollamaReady = $true
                break
            }
            Start-Sleep -Milliseconds 500
        }
    }

    if (-not $ollamaReady) {
        throw "Local Ollama failed to start on http://127.0.0.1:$($ollamaConfig.Port)"
    }

    Ensure-BundledOllamaModel -OllamaExe $ollamaExe -ModelName $ollamaConfig.Model
    Ensure-OllamaOpenAiProxyReady -OllamaConfig $ollamaConfig
}

function Test-DashboardReady {
    try {
        $response = Invoke-DirectHttpRequest -Uri $dashboardUrl -TimeoutSec 3
        return $response.StatusCode -eq 200 -and $response.Content -match "<title>Hermes Agent(?: - Dashboard)?</title>"
    } catch {
        return $false
    }
}

function Start-DashboardProcess {
    param([string]$OAuthProvider = "")

    if ($PlanOnly) {
        $dashboardArguments = @("-m", "hermes_cli.main", "dashboard", "--host", "127.0.0.1", "--port", "9119", "--no-open")
        if (-not [string]::IsNullOrWhiteSpace($OAuthProvider)) {
            $dashboardArguments += @("--oauth-provider", $OAuthProvider)
        }
        Add-CommandPlan `
            -StepName "start-dashboard" `
            -FilePath $pythonExe `
            -ArgumentList $dashboardArguments `
            -WorkingDirectory $runtimeDir `
            -Details @{ url = $dashboardUrl; oauth_provider = $OAuthProvider }
        return
    }

    if (Test-DashboardReady -and [string]::IsNullOrWhiteSpace($OAuthProvider)) {
        Write-LauncherLine "Dashboard already reachable: $dashboardUrl"
        return
    }

    $listenerIds = @(Get-ListeningProcessIds -Port 9119)
    if ($listenerIds) {
        $listenerIds | Select-Object -Unique | ForEach-Object {
            if ($_ -and $_ -ne $PID) {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }

    Remove-Item -LiteralPath $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
    $dashboardArguments = @("-m", "hermes_cli.main", "dashboard", "--host", "127.0.0.1", "--port", "9119", "--no-open")
    if (-not [string]::IsNullOrWhiteSpace($OAuthProvider)) {
        $dashboardHelp = (& $pythonExe -m hermes_cli.main dashboard --help 2>&1) -join "`n"
        if ($dashboardHelp -match "--oauth-provider") {
            $dashboardArguments += @("--oauth-provider", $OAuthProvider)
        } else {
            Write-LauncherLine "Dashboard does not support --oauth-provider; using config-driven provider selection."
        }
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
    $chatTitle = "HermesGo Chat"
    $chatArgs = ""
    $effectiveProvider = $ChatProvider.Trim()
    $effectiveModel = $ChatModel.Trim()
    if ([string]::IsNullOrWhiteSpace($effectiveProvider) -and $OAuthProvider -ieq "openai-codex") {
        $effectiveProvider = "openai-codex"
        $effectiveModel = "gpt-5.4-mini"
    }
    if (-not [string]::IsNullOrWhiteSpace($effectiveProvider) -and -not [string]::IsNullOrWhiteSpace($effectiveModel)) {
        foreach ($value in @($effectiveProvider, $effectiveModel)) {
            if ($value -notmatch '^[A-Za-z0-9._:/@+-]+$') {
                throw "Unsafe chat argument value: $value"
            }
        }
        $chatTitle = "HermesGo Chat - $effectiveProvider $effectiveModel"
        $chatArgs = " chat --provider $effectiveProvider -m $effectiveModel"
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
        '&&title ' + $chatTitle +
        '&&"' + $pythonExe + '" -m hermes_cli.main' + $chatArgs

    if ($PlanOnly) {
        Add-CommandPlan `
            -StepName "start-chat-window" `
            -FilePath "cmd.exe" `
            -ArgumentList @("/k", $command) `
            -WorkingDirectory $root `
            -Details @{ title = $chatTitle; provider = $effectiveProvider; model = $effectiveModel }
        return
    }

    $existing = Get-Process -Name "cmd" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "*HermesGo Chat*" } |
        Select-Object -First 8
    foreach ($process in $existing) {
        Write-LauncherLine "Closing stale chat window before relaunch: PID $($process.Id)"
        Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue
    }

    $process = Start-Process -FilePath "cmd.exe" -ArgumentList "/k", $command -WorkingDirectory $root -PassThru
    Write-LauncherLine "Chat window launched: PID $($process.Id), title=$chatTitle"
}

function Open-DashboardBrowser {
    param([string]$Url)

    if ($PlanOnly) {
        Add-CommandPlan `
            -StepName "open-dashboard-browser" `
            -FilePath "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", ("Start-Process '" + $Url.Replace("'", "''") + "'")) `
            -WorkingDirectory $root `
            -Details @{ url = $Url }
        return
    }

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
    Write-LauncherLine ("PlanOnly: {0}" -f ($(if ($PlanOnly) { "yes" } else { "no" })))
    if ($PlanOnly) {
        Remove-Item -LiteralPath $commandPlanPath -Force -ErrorAction SilentlyContinue
    }

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

    if ($PlanOnly) {
        Save-CommandPlan
        Write-LauncherLine "PlanOnly command file: $commandPlanPath"
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

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot ".."))
$pythonExe = Join-Path $root "runtime\python311\python.exe"
$runtimeBinDir = Join-Path $root "runtime\bin"
$launcherLog = Join-Path $root "logs\HermesGo-debug.txt"
$tmpLogDir = Join-Path $root "logs\tmp"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$configPath = Join-Path $root "home\config.yaml"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
$iconPath = Join-Path $root "assets\icons\HermesGo.ico"
$codexCmd = Join-Path $root "tools\codex.cmd"
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

function Get-ConfiguredProviderName {
    if (-not (Test-Path -LiteralPath $configPath)) { return "" }
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $providerMatch = [regex]::Match($configText, '(?m)^\s*provider:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    if (-not $providerMatch.Success) { return "" }
    return $providerMatch.Groups["v"].Value.Trim()
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
    Stop-PortListeners -Port 11435

    $configuredModel = Get-ConfiguredModelName
    $configuredProvider = Get-ConfiguredProviderName
    if ([string]::IsNullOrWhiteSpace($configuredModel)) {
        throw "Configured model is empty."
    }
    $requiresBundledOllama = [string]::IsNullOrWhiteSpace($configuredProvider) -or $configuredProvider -ieq "ollama"
    if ($requiresBundledOllama) {
        $manifestRelativePath = Get-OllamaManifestRelativePath -ModelName $configuredModel
        if (-not $manifestRelativePath) {
            throw "Unable to resolve bundled Ollama manifest for model: $configuredModel"
        }
        $manifestPath = Join-Path $ollamaModelsDir $manifestRelativePath
        if (-not (Test-Path -LiteralPath $manifestPath)) {
            throw "Bundled Ollama model missing: $configuredModel ($manifestPath)"
        }
    } else {
        Write-Host "External model verification mode: provider=$configuredProvider model=$configuredModel"
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
    if ($codexLoginHelpText -notmatch "usage:\s+hermes auth add" -or $codexLoginHelpText -notmatch "Provider id") {
        throw "codex login help probe did not reach the Hermes auth add command."
    }

    cmd /c "call `"$root\scripts\HermesGo.bat`" -NoOpenBrowser -NoOpenChat"
    if ($LASTEXITCODE -ne 0) { throw "scripts\\HermesGo.bat failed with exit code $LASTEXITCODE" }
    Assert-Contains $launcherLog "HermesGo finished with exit code 0."
    Assert-Contains $launcherLog "Ollama model store: $ollamaModelsDir"
    Assert-Contains $launcherLog "Dashboard browser URL: http://127.0.0.1:9119/env?oauth=openai-codex"
    $response = Invoke-DirectHttpRequest -Uri $dashboardUrl -TimeoutSec 5
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch "<title>Hermes Agent(?: - Dashboard)?</title>") {
        throw "Dashboard probe did not return the Hermes UI."
    }
    if ($requiresBundledOllama) {
        $ollamaProbe = Invoke-OllamaCompatProbe -ModelName $configuredModel
        if (-not $ollamaProbe.choices -or $ollamaProbe.choices.Count -lt 1) {
            throw "Bundled Ollama OpenAI-compatible probe returned no choices."
        }
    }
    $ownerPath = Get-PortOwnerPath -Port 9119
    if ($ownerPath -ine $pythonExe) {
        throw "Dashboard listener is not owned by portable python.exe. Owner: $ownerPath"
    }
    Write-Host "Portable HermesGo verification passed."
} finally {
    Stop-PortListeners -Port 9119
    Stop-PortListeners -Port 11434
    Stop-PortListeners -Port 11435
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

HermesGo is the Windows green bundle for Hermes Agent.

## Download

- Current download package: `__CURRENT_RELEASE_ZIP__`
- Current checksum file: `__CURRENT_RELEASE_SHA__`
- Current release tag: `__CURRENT_RELEASE_TAG__`
- Current values are sourced from `create_hermes_go/release-state.json`.
- Use `create_hermes_go/Sync-HermesGoReleaseState.ps1` to update the current names, then regenerate docs.
- Latest release page: <https://github.com/wangkj123/HermesGo/releases/latest>
- The downloadable zip and checksum are published on the release page above.
- Older release versions remain published on GitHub Releases and are not deleted.
- Yesterday's archive `__PREVIOUS_RELEASE_PATTERN__` is the older version; it is kept on purpose.

## How to use

1. Download the full zip. It keeps the top-level `HermesGo/` directory.
2. Extract the whole `HermesGo/` directory. Do not copy only `HermesGo.exe`.
3. The top-level contains `HermesGo.exe`, `README.md`, and the `app\` folder.
4. Open `README.md` beside `HermesGo.exe` if you want the package instructions without entering `app\`.
5. Double-click `HermesGo.exe`. It opens the classic launcher with a selectable action box for beginner start, OpenAI GPT-5.4 mini, Dashboard / Config, and utility actions for model switching, self-check, logs, config folders, and custom launcher actions from `home\launcher-actions.txt`. The launcher keeps local start as the default; cloud is still available as an explicit choice.
6. Original HermesGo and the `00-07` suite are both launched from `HermesGo.exe`.
7. The UI suite checkboxes default to on so the packaged selector matches the green bundle screenshot; clear them only when you want a quieter launch.
8. Local 2B startup does not trigger ChatGPT / Codex sign-in. Only `Cloud: GPT-5.4 Mini` auto-runs the bundled login flow when Codex auth is missing, and only after you explicitly choose it.
9. Maintenance assets, docs, screenshots, runtime files, and internal scripts all live under `app\`.

## Directory map

| Path | Purpose |
|---|---|
| `HermesGo.exe` | The only user-facing launcher entry |
| `README.md` | Main package readme beside the launcher |
| `app\docs\README.md` | Internal duplicate of the package readme for in-app browsing |
| `app\scripts\` | Internal maintenance scripts used by `HermesGo.exe` |
| `app\tools\codex.cmd` | Bundled Codex-compatible shim used by the package |
| `app\runtime\` | Packaged runtime files |
| `app\home\` | Persistent config, sessions, state, and memory |
| `app\data\` | Runtime data and bundled Ollama model store |
| `app\tutorial\` | Numbered usage screenshots and notes for new users |
| `app\ui-suite\` | Packaged docs, screenshots, launcher runtime, and the `01-07` UI candidate app directories |
| `app\logs\` | Debug, update, and temporary logs |
| `app\assets\` | Logos and icon assets used by the launcher |
| `app\installers\` | Optional installer drop-in directory, not required for runtime |

## How I tested it

1. Run `create_hermes_go/test/Prepare-HermesGoTestWorkspace.ps1 -Clean`
2. The script copies `create_hermes_go/output/HermesGo` into `create_hermes_go/test/workspaces/HermesGo-sandbox`
3. Make changes and test `HermesGo.exe` plus the internal scripts in the sandbox
4. Run `create_hermes_go/test/Verify-HermesGoTestWorkspace.ps1`

What the verification checks:

- The root directory contains only `HermesGo.exe` and `README.md` as files
- The launcher loads custom actions from `app\home\launcher-actions.txt`; startup stays local-first and cloud remains an explicit choice
- `HermesGo.exe` exposes a visible `UI 套件共 8 项（00 原版 + 01-07）` section instead of hiding the suite behind a utility entry
- `HermesGo.exe --ui-suite 00 --ui-suite-no-browser` can start the original HermesGo UI from the exe itself
- `app\scripts\Start-HermesGoUiSuite.ps1 -List` can enumerate the packaged `00-07` ids
- The bundled Ollama 2B model store is available
- The portable Python runtime is still the bundled one
- Launch logs are written to `app\logs\update\HermesGo-bootstrap.log`
- Tutorial screenshots live in `app\tutorial\`
- The package also carries `app\ui-suite\docs\` and the packaged `app\ui-suite\apps\01-07` directories
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
  provider: "ollama"
  default: "gemma:2b"
  base_url: "http://127.0.0.1:11434/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
'@

$launcherActions = @'
; HermesGo custom launcher actions
; Format: key|title|description|kind|value
; kind: preset, script, folder, url
; Example:
; custom-qwen|Custom: Qwen 3B|Switch to qwen2.5:3b local model|preset|provider=ollama;model=qwen2.5:3b;baseUrl=http://127.0.0.1:11434/v1
; custom-work|Custom: Open Work Folder|Open your own work folder|folder|E:\AI\hermes

; UI 套件主入口已经集成到 HermesGo.exe 里。
; 需要说明时直接打开 app\ui-suite\docs\README.md。
'@

$codexCmd = @'
@echo off
setlocal EnableExtensions

for %%I in ("%~dp0..") do set "ROOT=%%~fI\"
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
    if /i "%~2"=="--device-auth" (
        "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~3 %~4 %~5 %~6 %~7 %~8 %~9
    ) else (
        "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex %~2 %~3 %~4 %~5 %~6 %~7 %~8 %~9
    )
    exit /b %ERRORLEVEL%
)

if /i "%~1"=="auth" if /i "%~2"=="login" (
    if /i "%~3"=="--device-auth" (
        "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~4 %~5 %~6 %~7 %~8 %~9
    ) else (
        "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex %~3 %~4 %~5 %~6 %~7 %~8 %~9
    )
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
- 这条 release 线保留经典启动方式：默认 `Beginner: Local Start`，`Cloud: GPT-5.4 Mini` 仍然可手动选择，另有 `Dashboard / Config` 和各类工具动作
- 更新功能保留在启动器底部，包内配置、日志和 launcher-actions 都写在绿色版目录
- 当前版本信息来自 `create_hermes_go/release-state.json`
- 更新下载包名、checksum 和 release tag 时，先改 `Sync-HermesGoReleaseState.ps1` 使用的状态文件，再重新生成
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

- `HermesGo.exe` 是主入口，启动器默认保持 `Beginner: Local Start`，`Cloud: GPT-5.4 Mini` 仍可手动选择，另有 `Expert: Dashboard / Config` 和各类工具动作。
- `Cloud: GPT-5.4 Mini` 会在缺少授权时先走浏览器登录流程，再继续启动 Dashboard 和聊天窗口。
- OpenAI Codex 登录走的是 Hermes 自己内置的浏览器 / 认证流程，不依赖外部安装的 Codex CLI。
- 绿色包不会携带本地 `auth.json`、`auth.lock` 这类账号凭据文件。
- 更新功能保留在启动器底部，不再暴露其它启动入口。
- 原来的版本保留在 GitHub Releases，不删除、不覆盖。

## 兼容性说明

- 旧版继续可用，适合已经习惯原工作流的用户。
- 新版新增的是绿色版 / U 盘版 / 一键安装版的便携体验。
- 如果你要云端能力，直接选择 `Cloud: GPT-5.4 Mini`；不选云端时，启动器默认保持本地优先。
- 更新功能仍然保留在启动器底部。

## 发布约定

- 源码会和 release 一起同步到 GitHub。
- 新版只追加，不删除旧版。
- 代码更新说明会明确写出：绿色版、U 盘版、一键安装版、自带大模型、OpenAI Codex 登录路径。
- 当前版本信息由 `create_hermes_go/release-state.json` 统一管理。
- 发布或改名时，先更新状态文件，再运行 `Sync-HermesGoReleaseState.ps1`。
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
Write-Utf8File -Path (Join-Path $scriptsDir "HermesGo.bat") -Content $launcherBat
Write-Utf8File -Path (Join-Path $scriptsDir "Setup-Ollama.bat") -Content $setupOllamaBat
Write-Utf8File -Path (Join-Path $scriptsDir "Start-HermesGo.ps1") -Content $startHermesPs1
Write-Utf8File -Path (Join-Path $scriptsDir "Verify-HermesGo.bat") -Content $verifyBat
Write-Utf8File -Path (Join-Path $scriptsDir "Verify-HermesGo.ps1") -Content $verifyPs1
Copy-Item -LiteralPath (Join-Path $repoRoot "HermesGo\Switch-HermesGoModel.ps1") -Destination (Join-Path $scriptsDir "Switch-HermesGoModel.ps1") -Force
Copy-Item -LiteralPath (Join-Path $repoRoot "HermesGo\Switch-HermesGoModel.bat") -Destination (Join-Path $scriptsDir "Switch-HermesGoModel.bat") -Force
Copy-Item -LiteralPath (Join-Path $sourceUiSuiteScripts "Start-HermesGoUiSuite.ps1") -Destination (Join-Path $scriptsDir "Start-HermesGoUiSuite.ps1") -Force
Copy-Item -LiteralPath (Join-Path $sourceUiSuiteScripts "Start-HermesGoUiSuite.bat") -Destination (Join-Path $scriptsDir "Start-HermesGoUiSuite.bat") -Force
Copy-Item -LiteralPath (Join-Path $sourceUiSuiteScripts "Stop-HermesGoUiSuite.ps1") -Destination (Join-Path $scriptsDir "Stop-HermesGoUiSuite.ps1") -Force
Copy-Item -LiteralPath (Join-Path $sourceUiSuiteScripts "Stop-HermesGoUiSuite.bat") -Destination (Join-Path $scriptsDir "Stop-HermesGoUiSuite.bat") -Force
Write-Utf8File -Path (Join-Path $toolsDir "codex.cmd") -Content $codexCmd
Write-Utf8File -Path (Join-Path $docsOutputDir "README.md") -Content $packageReadme
Write-Utf8File -Path (Join-Path $installersDir "README.md") -Content $installerReadme
if (Test-Path -LiteralPath (Join-Path $builderRoot "tutorial")) {
    Copy-Tree -Source (Join-Path $builderRoot "tutorial") -Destination (Join-Path $appDir "tutorial")
}
if (Test-Path -LiteralPath $sourceUiSuite) {
    Copy-Tree -Source $sourceUiSuite -Destination (Join-Path $appDir "ui-suite") -ExcludeDirectories @("01-hermes-agent-desktop")
}
Reset-OutputHomeState -HomeDir (Join-Path $appDir "home")
Write-Utf8File -Path (Join-Path $appDir "home\portable-defaults.txt") -Content @"
; Portable fallback defaults for HermesGo
DEFAULT_OLLAMA_PROVIDER=$defaultOllamaProvider
DEFAULT_OLLAMA_MODEL=$defaultOllamaModel
DEFAULT_OLLAMA_BASE_URL=$defaultOllamaBaseUrl
"@
Write-Utf8File -Path (Join-Path $appDir "home\config.yaml") -Content $homeConfig
Write-Utf8File -Path (Join-Path $appDir "home\.env") -Content ""
Write-Utf8File -Path (Join-Path $appDir "home\launcher-actions.txt") -Content $launcherActions
Write-Step "Creating HermesGo application icon"
New-Item -ItemType Directory -Path $assetsDir, $assetsIconsDir -Force | Out-Null
$iconPath = Join-Path $assetsIconsDir "HermesGo.ico"
New-HermesGoIcon -OutputPath $iconPath -PngOutputPath (Join-Path $assetsDir "HermesGo-logo.png")
Build-HermesGoExe -SourcePath (Join-Path $builderRoot "HermesGoBootstrap.cs") -OutputPath (Join-Path $OutputDir "HermesGo.exe") -IconPath $iconPath
Get-ChildItem -LiteralPath $OutputDir -Force | Where-Object {
    -not (
        ($_.PSIsContainer -and $_.Name -eq "app") -or
        (-not $_.PSIsContainer -and ($_.Name -eq "HermesGo.exe" -or $_.Name -eq "README.md"))
    )
} | ForEach-Object {
    if ($_.PSIsContainer) {
        Remove-TreeRobust -Path $_.FullName
    } else {
        Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
    }
}
Write-Utf8File -Path (Join-Path $OutputDir "README.md") -Content $packageReadme
Write-Utf8File -Path (Join-Path $builderRoot "README.md") -Content $builderReadme
Write-Utf8File -Path (Join-Path $docsDir "001-当前状态与标准边界.md") -Content $doc001
Write-Utf8File -Path (Join-Path $docsDir "002-便携构建步骤与后续工作.md") -Content $doc002
Write-Utf8File -Path (Join-Path $docsDir "003-green-usb-oneclick-release-notes.md") -Content $doc003

Write-Step "Portable HermesGo output created at $OutputDir"
