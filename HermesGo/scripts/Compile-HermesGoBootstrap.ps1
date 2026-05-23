# Compiles create_hermes_go/HermesGoBootstrap.cs -> HermesGo.exe (auto-update bootstrap).
# Icon is optional: if create_hermes_go/assets/icons/HermesGo.ico exists, it is embedded.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$builderRoot = Join-Path $repoRoot "create_hermes_go"
$sourceCs = Join-Path $builderRoot "HermesGoBootstrap.cs"
$iconScript = Join-Path $builderRoot "scripts\New-HermesGoIcon.ps1"
$iconPath = Join-Path $builderRoot "assets\icons\HermesGo.ico"
$outExe = Join-Path (Split-Path -Parent $PSScriptRoot) "HermesGo.exe"
$devAssetsDir = Join-Path (Split-Path -Parent $PSScriptRoot) "assets"

if (-not (Test-Path -LiteralPath $sourceCs)) {
    throw "Missing C# source: $sourceCs"
}

if (-not (Test-Path -LiteralPath $iconScript)) {
    throw "Missing icon generator: $iconScript"
}

$psExe = Join-Path $env:WINDIR "System32\WindowsPowerShell\v1.0\powershell.exe"
if (-not (Test-Path -LiteralPath $psExe)) {
    $psExe = "powershell.exe"
}

Write-Host "[Compile-HermesGoBootstrap] generating icon assets"
& $psExe -NoProfile -ExecutionPolicy Bypass -File $iconScript
if ($LASTEXITCODE -ne 0) {
    throw "New-HermesGoIcon.ps1 failed: $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $iconPath)) {
    throw "Icon not created: $iconPath"
}

New-Item -ItemType Directory -Path (Join-Path $devAssetsDir "icons") -Force | Out-Null
Copy-Item -LiteralPath $iconPath -Destination (Join-Path $devAssetsDir "icons\HermesGo.ico") -Force
Copy-Item -LiteralPath (Join-Path $builderRoot "assets\HermesGo-logo.png") -Destination (Join-Path $devAssetsDir "HermesGo-logo.png") -Force

$csc = $null
foreach ($candidate in @(
        (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe"),
        (Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319\csc.exe")
    )) {
    if (Test-Path -LiteralPath $candidate) {
        $csc = $candidate
        break
    }
}
if (-not $csc) {
    throw "csc.exe not found under Windows .NET Framework v4."
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
        throw "Missing reference: $referencePath"
    }
}

$arguments = @(
    "/nologo",
    "/target:winexe",
    "/langversion:5",
    "/optimize+",
    "/platform:anycpu",
    ("/out:{0}" -f $outExe)
)
$arguments += ("/win32icon:{0}" -f $iconPath)
foreach ($referencePath in $referencePaths) {
    $arguments += ("/reference:{0}" -f $referencePath)
}
$arguments += $sourceCs

Write-Host "[Compile-HermesGoBootstrap] csc -> $outExe"
& $csc @arguments
if ($LASTEXITCODE -ne 0) {
    throw "csc failed: $LASTEXITCODE"
}
if (-not (Test-Path -LiteralPath $outExe)) {
    throw "Output missing: $outExe"
}
Write-Host "[Compile-HermesGoBootstrap] OK"

if ($env:HERMESGO_SKIP_TEST_SYNC -match '^(?i)(1|true|yes)$') {
    Write-Host "[Compile-HermesGoBootstrap] test sync skipped (HERMESGO_SKIP_TEST_SYNC)"
} else {
    $syncPy = Join-Path (Split-Path -Parent $PSScriptRoot) "packaging_sync.py"
    if (Test-Path -LiteralPath $syncPy) {
        Write-Host "[Compile-HermesGoBootstrap] syncing test package from latest dist zip"
        $pyLauncher = $null
        foreach ($candidate in @(
                (Join-Path $devAssetsDir "..\runtime\python311\python.exe"),
                (Join-Path $env:LOCALAPPDATA "Programs\Python\Python311\python.exe"),
                "py.exe",
                "python.exe"
            )) {
            $resolved = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($candidate)
            if (Test-Path -LiteralPath $resolved) {
                $pyLauncher = $resolved
                break
            }
        }
        if (-not $pyLauncher) {
            throw "Python not found for packaging_sync.py"
        }
        $syncDest = $env:HERMESGO_TEST_PACKAGE_ROOT
        if (-not $syncDest) {
            foreach ($candidate in @(
                    (Join-Path $repoRoot "sync-dest.txt"),
                    (Join-Path $repoRoot "HermesGo\sync-dest.txt"),
                    (Join-Path $repoRoot "HermesGo\home\sync-dest.txt"),
                    (Join-Path $repoRoot "HermesGo\app\sync-dest.txt"),
                    (Join-Path $repoRoot "HermesGo\app\home\sync-dest.txt")
                )) {
                if (Test-Path -LiteralPath $candidate) {
                    $syncDest = (Get-Content -LiteralPath $candidate -Encoding utf8 -TotalCount 1).Trim()
                    if ($syncDest) { break }
                }
            }
        }
        $syncArgs = @($syncPy)
        if ($syncDest) {
            Write-Host "[Compile-HermesGoBootstrap] sync dest: $syncDest"
            $syncArgs += @("--dest", $syncDest)
        }
        & $pyLauncher @syncArgs
        if ($LASTEXITCODE -ne 0) {
            Write-Warning "Test package sync failed (exit $LASTEXITCODE). Run build_zip_slim.py after a full zip build."
        }
    }
}
