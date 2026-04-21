param(
    [string]$WorkspaceDir = (Join-Path $PSScriptRoot "workspaces\HermesGo-sandbox")
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$resolvedWorkspace = [System.IO.Path]::GetFullPath($WorkspaceDir)
if (-not (Test-Path -LiteralPath $resolvedWorkspace)) {
    throw "workspace not found: $resolvedWorkspace"
}

$env:PATH = [string]::Join(';', @($resolvedWorkspace, (Join-Path $resolvedWorkspace "runtime\bin"), $env:PATH))

$requiredPaths = @(
    "HermesGo.bat",
    "HermesGo.exe",
    "README.md",
    "Start-HermesGo.ps1",
    "Switch-HermesGoModel.bat",
    "Switch-HermesGoModel.ps1",
    "Verify-HermesGo.bat",
    "Verify-HermesGo.ps1",
    "codex.cmd",
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

$codexResolved = Get-Command codex -ErrorAction SilentlyContinue
if (-not $codexResolved) {
    throw "workspace codex compatibility launcher not found in PATH"
}

$codexOutput = & cmd /c "call `"$resolvedWorkspace\codex.cmd`"" 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "workspace codex compatibility launcher failed with exit code $LASTEXITCODE"
}
if (($codexOutput -join "`n") -notmatch "HermesGo codex compatibility launcher") {
    throw "workspace codex compatibility launcher did not print the expected banner"
}

$marker = Join-Path $resolvedWorkspace "TEST_WORKSPACE.txt"
if (-not (Test-Path -LiteralPath $marker)) {
    throw "workspace marker missing: TEST_WORKSPACE.txt"
}

Write-Host "[HermesGo test] workspace verified: $resolvedWorkspace"
