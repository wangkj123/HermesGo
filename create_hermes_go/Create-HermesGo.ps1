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
    $releaseRoot = Join-Path (Split-Path -Parent $repoRoot) "hermes-release"
    $OutputDir = Join-Path $releaseRoot "HermesGo"
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
    Set-Content -LiteralPath $Path -Value $Content -Encoding utf8
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

function Build-HermesGoExe {
    param(
        [string]$SourcePath,
        [string]$OutputPath
    )

    $csc = Get-FrameworkCscPath
    $frameworkDir = Split-Path -Parent $csc
    $referencePaths = @(
        (Join-Path $frameworkDir "System.dll"),
        (Join-Path $frameworkDir "System.Core.dll"),
        (Join-Path $frameworkDir "System.Net.Http.dll"),
        (Join-Path $frameworkDir "System.IO.Compression.dll"),
        (Join-Path $frameworkDir "System.IO.Compression.FileSystem.dll")
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
    if (Test-DashboardReady) {
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
    $process = Start-Process -FilePath $pythonExe `
        -ArgumentList @("-m", "hermes_cli.main", "dashboard", "--host", "127.0.0.1", "--port", "9119", "--no-open") `
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
    $env:HERMES_HOME = $homeDir
    $env:OLLAMA_MODELS = $ollamaModelsDir
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
    Write-LauncherLine "Portable target: standard Hermes runtime with portable Python."

    Ensure-LocalOllamaReady
    Start-DashboardProcess

    if (-not $headless) {
        if (-not $NoOpenBrowser) {
            Start-Process $dashboardUrl
            Write-LauncherLine "Browser launched: $dashboardUrl"
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
$launcherLog = Join-Path $root "HermesGo-debug.txt"
$tmpLogDir = Join-Path $root "logs\tmp"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard-verify.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$configPath = Join-Path $root "home\config.yaml"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
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

    cmd /c "call `"$root\HermesGo.bat`" -NoOpenBrowser -NoOpenChat"
    if ($LASTEXITCODE -ne 0) { throw "HermesGo.bat failed with exit code $LASTEXITCODE" }
    Assert-Contains $launcherLog "HermesGo finished with exit code 0."
    Assert-Contains $launcherLog "Ollama model store: $ollamaModelsDir"
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

这是一个单目录的 Windows Hermes 包。
交付时请直接把整个 `create_hermes_go/output/HermesGo` 目录拷贝出去使用，不要拆文件。

## 当前目标

- 启动官方 Hermes v0.10.0 代码
- 启动官方 Hermes Dashboard
- 默认走本地模型路线，不依赖云端 token
- 默认自带 `data/ollama/models`，断网也能直接用
- 不依赖系统 Python
- 不包含运行时不需要的前端源码、缓存、GPU 专用 Ollama 组件或安装器 ZIP

## 现在怎么用

1. 双击 `HermesGo.bat`
2. 启动器会固定使用包内 `data/ollama/models`
3. 脚本会打开浏览器里的 Dashboard 和一个 `HermesGo Chat` 命令窗口
4. 需要切换默认本地模型时，可以在启动器里点“切换本地模型”，弹窗会标出“可用 / 缺失”，并自动把 provider 切回 `ollama`；缺失模型会在启动时下载到 `data/ollama/models`
5. 需要登录或切换 Codex 账号时，点击启动器里的“登录/换号 Codex”；它会自动打开 Dashboard 的 Codex 登录页
6. `Setup-Ollama.bat` 只是本地 Ollama 检查器，正常情况下不需要手动运行

## 目录说明

- `runtime/python311/`: 便携 Python
- `runtime/hermes-agent/`: 官方 Hermes 运行时内容和 `web_dist`
- `runtime/ollama/`: 便携 Ollama 运行时（CPU 组件 + 必需文件）
- `data/ollama/models/`: 包内 Ollama 模型仓
- `logs/tmp/`: 启动和自检的临时 stdout/stderr，启动前会清空
- `home/config.yaml`: 默认本地模型配置
- `home/portable-defaults.txt`: 默认本地 Ollama provider/model/base_url，可在构建前修改
- `Switch-HermesGoModel.bat` / `Switch-HermesGoModel.ps1`: 切换默认本地模型的命令行入口；GUI 里也有同样功能的按钮
- `installers/`: 可选外部安装器投放目录，不是运行必需
- `HermesGo-debug.txt`: 根目录唯一调试文件，每次启动都会清空重写
- `Verify-HermesGo.bat`: 自检 Dashboard 是否能起来

## 说明

- 这里的 Hermes 核心和 Dashboard 是官方代码，不是自制页面。
- 这里的 Windows 便携包装方式是本仓库自己做的补层，因为上游仍以 WSL2 为正式路径。
- 便携 Python 来源优先走国内镜像，失败后回退到 Python 官方 embeddable package。
- `HermesGo-debug.txt` 会被启动器和 supervisor 共享，只有最顶层启动会清空它。
- 离线运行所需的 Ollama 模型已随包带入，不会在启动时自动下载。
- 如果要发给别人，请直接压缩或复制整个目录；目标机只需要解压后双击 `HermesGo.bat`。
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

$builderReadme = @'
# create_hermes_go

这个目录负责两件事：

1. 记录如何把当前仓库里的 Hermes 做成 Windows 单目录包
2. 用脚本生成仓库外的独立 `create_hermes_go/output/HermesGo`，它就是可直接拷贝的绿色包

## 当前路线

- 官方 Hermes 源码
- 当前工作环境里的依赖
- 官方 embeddable Python 取代原始 venv
- 默认切到 Ollama 本地模型，避免 token
- Ollama 运行时和包内模型仓都会被复制进独立 release 目录，只保留目录内自举能力；GPU 专用后端、安装器 ZIP 和前端源码不会进入发行包
- `create_hermes_go/output/HermesGo` 是最终交付目录，复制整个目录即可离线运行

## 入口

- `Create-HermesGo.bat`
- `Create-HermesGo.ps1`
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
6. 把最终绿色包固定输出到 `create_hermes_go/output/HermesGo`

## 当前还能改进的地方

1. 在干净 Win11 机器上继续做无缓存冷启动验证
2. 进一步补齐 Git for Windows / MinGit 的便携检测
3. 视需要增加 Python embeddable 的更多国内镜像候选
4. 给绿色包增加一个目录白名单校验，防止升级后多出杂文件
'@

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
Write-Utf8File -Path (Join-Path $OutputDir "README.md") -Content $packageReadme
Write-Utf8File -Path (Join-Path $OutputDir "installers\README.md") -Content $installerReadme
Reset-OutputHomeState -HomeDir (Join-Path $OutputDir "home")
Write-Utf8File -Path (Join-Path $OutputDir "home\portable-defaults.txt") -Content @"
; Portable fallback defaults for HermesGo
DEFAULT_OLLAMA_PROVIDER=$defaultOllamaProvider
DEFAULT_OLLAMA_MODEL=$defaultOllamaModel
DEFAULT_OLLAMA_BASE_URL=$defaultOllamaBaseUrl
"@
Write-Utf8File -Path (Join-Path $OutputDir "home\config.yaml") -Content $homeConfig
Write-Utf8File -Path (Join-Path $OutputDir "home\.env") -Content ""
Build-HermesGoExe -SourcePath (Join-Path $builderRoot "HermesGoBootstrap.cs") -OutputPath (Join-Path $OutputDir "HermesGo.exe")
Write-Utf8File -Path (Join-Path $builderRoot "README.md") -Content $builderReadme
Write-Utf8File -Path (Join-Path $docsDir "001-当前状态与标准边界.md") -Content $doc001
Write-Utf8File -Path (Join-Path $docsDir "002-便携构建步骤与后续工作.md") -Content $doc002

Write-Step "Portable HermesGo output created at $OutputDir"
