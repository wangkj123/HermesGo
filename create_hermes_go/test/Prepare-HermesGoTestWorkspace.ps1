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

$resolvedSource = (Resolve-Path -LiteralPath $SourceDir).Path
$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspaceDir)
$workspaceParent = Split-Path -Parent $resolvedWorkspace
New-Item -ItemType Directory -Path $workspaceParent -Force | Out-Null

if ($Clean -and (Test-Path -LiteralPath $resolvedWorkspace)) {
    Write-Step "cleaning existing workspace: $resolvedWorkspace"
    Remove-Item -LiteralPath $resolvedWorkspace -Recurse -Force
}

Write-Step "copying $resolvedSource -> $resolvedWorkspace"
Copy-Tree -From $resolvedSource -To $resolvedWorkspace

$marker = Join-Path $resolvedWorkspace "TEST_WORKSPACE.txt"
$markerContent = @"
HermesGo test workspace

Source: $resolvedSource
Created: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")

Use this directory for local iteration and verification.
"@
Set-Content -LiteralPath $marker -Value $markerContent -Encoding utf8

Write-Step "workspace ready: $resolvedWorkspace"
Write-Host $resolvedWorkspace
