param(
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "workspaces\HermesGo-sandbox")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspaceDir)
if (-not (Test-Path -LiteralPath $resolvedWorkspace)) {
    throw "workspace not found: $resolvedWorkspace"
}

$requiredPaths = @(
    "HermesGo.bat",
    "HermesGo.exe",
    "README.md",
    "Start-HermesGo.ps1",
    "Switch-HermesGoModel.bat",
    "Switch-HermesGoModel.ps1",
    "Verify-HermesGo.bat",
    "Verify-HermesGo.ps1",
    "home",
    "data\ollama",
    "runtime\hermes-agent"
)

$missing = @()
foreach ($relativePath in $requiredPaths) {
    $candidate = Join-Path $resolvedWorkspace $relativePath
    if (-not (Test-Path -LiteralPath $candidate)) {
        $missing += $relativePath
    }
}

if ($missing.Count -gt 0) {
    throw ("workspace is missing required paths: " + ($missing -join ", "))
}

$marker = Join-Path $resolvedWorkspace "TEST_WORKSPACE.txt"
if (-not (Test-Path -LiteralPath $marker)) {
    throw "workspace marker missing: TEST_WORKSPACE.txt"
}

Write-Host "[HermesGo test] workspace verified: $resolvedWorkspace"
