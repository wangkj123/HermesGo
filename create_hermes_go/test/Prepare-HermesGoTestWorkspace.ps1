param(
    [string]$SourceDir = (Join-Path $PSScriptRoot "..\output\HermesGo"),
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "workspaces\HermesGo-sandbox"),
    [switch]$Clean
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Write-Step {
    param([string]$Message)
    Write-Host "[HermesGo test] $Message"
}

function Copy-Tree {
    param(
        [string]$From,
        [string]$To
    )

    New-Item -ItemType Directory -Path $To -Force | Out-Null
    & robocopy $From $To /MIR /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed ($LASTEXITCODE): $From -> $To"
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

$resolvedSource = (Resolve-Path -LiteralPath $SourceDir).Path
$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspaceDir)
$workspaceParent = Split-Path -Parent $resolvedWorkspace
New-Item -ItemType Directory -Path $workspaceParent -Force | Out-Null

if ($Clean -and (Test-Path -LiteralPath $resolvedWorkspace)) {
    Write-Step "cleaning existing workspace: $resolvedWorkspace"
    Remove-TreeRobust -Path $resolvedWorkspace
}

Write-Step "copying $resolvedSource -> $resolvedWorkspace"
Copy-Tree -From $resolvedSource -To $resolvedWorkspace

$marker = Join-Path $resolvedWorkspace "app\docs\TEST_WORKSPACE.txt"
$markerContent = @"
HermesGo test workspace

Source: $resolvedSource
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Use this directory for local iteration and verification.
"@
Set-Content -LiteralPath $marker -Value $markerContent -Encoding utf8

Write-Step "workspace ready: $resolvedWorkspace"
Write-Host $resolvedWorkspace
