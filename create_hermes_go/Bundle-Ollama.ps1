param(
    [string]$Version = "0.1.36",
    [string]$SourceUrl = "",
    [switch]$ForceDownload
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$builderRoot = $PSScriptRoot
$repoRoot = Split-Path -Parent $builderRoot
$sourceRoot = Join-Path $repoRoot "HermesGo"
$sourceRuntime = Join-Path $sourceRoot "runtime\ollama"
$installersDir = Join-Path $sourceRoot "installers"
$cacheDir = Join-Path $builderRoot "cache"
$downloadZip = Join-Path $cacheDir ("ollama-windows-amd64-v{0}.zip" -f $Version)
$downloadTemp = "$downloadZip.part"
$sourceUrl = if ($SourceUrl) {
    $SourceUrl
} else {
    ""
}

function Write-Line {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Write-Host "[bundle-ollama] [$timestamp] $Message"
}

function Resolve-InstalledOllama {
    foreach ($candidate in @(
        "$env:LOCALAPPDATA\Programs\Ollama\ollama.exe",
        "$env:ProgramFiles\Ollama\ollama.exe"
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) {
            return $candidate
        }
    }

    $cmd = Get-Command ollama -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Path) {
        return $cmd.Path
    }

    return $null
}

function Copy-InstalledRuntime {
    param([string]$ExePath)

    $runtimeRoot = Split-Path -Parent $ExePath
    if (-not (Test-Path -LiteralPath $runtimeRoot)) {
        return $false
    }

    if (Test-Path -LiteralPath $sourceRuntime) {
        Remove-Item -LiteralPath $sourceRuntime -Recurse -Force
    }
    New-Item -ItemType Directory -Path $sourceRuntime -Force | Out-Null
    Copy-Item -Path (Join-Path $runtimeRoot "*") -Destination $sourceRuntime -Recurse -Force
    return $true
}

function Test-ValidZip {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return $false
    }

    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
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

function Get-DownloadCandidates {
    param([string]$PinnedVersion)

    if ($sourceUrl) {
        return @(
            [pscustomobject]@{
                Tier = "custom"
                Label = "custom-source"
                Url = $sourceUrl
            }
        )
    }

    return @(
        [pscustomobject]@{
            Tier = "domestic"
            Label = "cn-mirror-versioned"
            Url = "https://ollama.ac.cn/download/v$PinnedVersion/ollama-windows-amd64.zip"
            DisableProxy = $true
        }
        [pscustomobject]@{
            Tier = "foreign-direct"
            Label = "github-release-versioned"
            Url = "https://github.com/ollama/ollama/releases/download/v$PinnedVersion/ollama-windows-amd64.zip"
            DisableProxy = $false
        }
        [pscustomobject]@{
            Tier = "foreign-proxy"
            Label = "ghproxy-link-versioned"
            Url = "https://ghproxy.link/https://github.com/ollama/ollama/releases/download/v$PinnedVersion/ollama-windows-amd64.zip"
            DisableProxy = $false
        }
    )
}

function Invoke-DownloadAttempt {
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
        "--continue-at", "-",
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

function Expand-DownloadedZip {
    param(
        [string]$ZipPath,
        [string]$Destination
    )

    if (Test-Path -LiteralPath $Destination) {
        Remove-Item -LiteralPath $Destination -Recurse -Force
    }
    New-Item -ItemType Directory -Path $Destination -Force | Out-Null
    Expand-Archive -LiteralPath $ZipPath -DestinationPath $Destination -Force
}

function Save-DownloadRecord {
    param(
        [string]$Tier,
        [string]$Label,
        [string]$Url,
        [string]$Result,
        [string]$Next
    )

    $progressLog = Join-Path $repoRoot "logs\agent-progress.md"
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $lines = @(
        "",
        "### $timestamp",
        "- Action: Attempt Ollama runtime download.",
        "- Tool: curl.exe --ssl-no-revoke.",
        "- Result: tier=$Tier; source=$Label; url=$Url; outcome=$Result.",
        "- Next: $Next"
    )
    Add-Content -LiteralPath $progressLog -Value ($lines -join [Environment]::NewLine) -Encoding utf8
}

if (-not $ForceDownload) {
    $installed = Resolve-InstalledOllama
    if ($installed) {
        Write-Line "Copying installed Ollama runtime from $installed"
        if (Copy-InstalledRuntime -ExePath $installed) {
            Write-Line "Bundled Ollama runtime copied to $sourceRuntime"
            exit 0
        }
    }
}

New-Item -ItemType Directory -Path $cacheDir -Force | Out-Null
if (Test-Path -LiteralPath $downloadZip) {
    $cachedSize = (Get-Item -LiteralPath $downloadZip).Length
    if (-not (Test-ValidZip -Path $downloadZip)) {
        Write-Line ("Cached Ollama zip is invalid ({0} bytes); redownloading." -f $cachedSize)
        Remove-Item -LiteralPath $downloadZip -Force
    } else {
        Write-Line "Reusing cached Ollama zip: $downloadZip"
    }
}

if (-not (Test-Path -LiteralPath $downloadZip)) {
    $downloaded = $false
    $candidates = Get-DownloadCandidates -PinnedVersion $Version
    foreach ($candidate in $candidates) {
        Write-Line "Trying [$($candidate.Tier)] $($candidate.Label): $($candidate.Url)"
        try {
            Invoke-DownloadAttempt -Url $candidate.Url -Destination $downloadTemp -DisableProxy $candidate.DisableProxy
            if (-not (Test-ValidZip -Path $downloadTemp)) {
                throw "Downloaded file is not a valid zip archive."
            }
            Move-Item -LiteralPath $downloadTemp -Destination $downloadZip -Force
            Save-DownloadRecord -Tier $candidate.Tier -Label $candidate.Label -Url $candidate.Url -Result "success" -Next "Expand zip into runtime and continue package build."
            Write-Line "Cached Ollama zip written to $downloadZip"
            $downloaded = $true
            break
        } catch {
            $message = $_.Exception.Message
            Save-DownloadRecord -Tier $candidate.Tier -Label $candidate.Label -Url $candidate.Url -Result ("failed: " + $message) -Next "Switch to the next source tier."
            Write-Line "Download failed from $($candidate.Label): $message"
            Remove-Item -LiteralPath $downloadTemp -Force -ErrorAction SilentlyContinue
        }
    }

    if (-not $downloaded) {
        throw "All Ollama download sources failed for version $Version"
    }
}

Write-Line "Expanding Ollama zip into $sourceRuntime"
Expand-DownloadedZip -ZipPath $downloadZip -Destination $sourceRuntime

$ollamaExe = Get-ChildItem -LiteralPath $sourceRuntime -Recurse -Filter "ollama.exe" -ErrorAction SilentlyContinue | Select-Object -First 1
if (-not $ollamaExe) {
    throw "ollama.exe was not found after expanding $downloadZip"
}

New-Item -ItemType Directory -Path $installersDir -Force | Out-Null
Copy-Item -LiteralPath $downloadZip -Destination (Join-Path $installersDir "ollama-windows-amd64.zip") -Force
@(
    "Source URL: $sourceUrl"
    "Version: $Version"
    "Resolved exe: $($ollamaExe.FullName)"
) | Set-Content -LiteralPath (Join-Path $sourceRuntime "SOURCE.txt") -Encoding utf8

Write-Line "Bundled Ollama runtime ready at $sourceRuntime"
