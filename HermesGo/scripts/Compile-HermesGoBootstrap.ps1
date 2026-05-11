# Compiles create_hermes_go/HermesGoBootstrap.cs -> HermesGo.exe (auto-update bootstrap).
# Icon is optional: if create_hermes_go/assets/icons/HermesGo.ico exists, it is embedded.
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$repoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$builderRoot = Join-Path $repoRoot "create_hermes_go"
$sourceCs = Join-Path $builderRoot "HermesGoBootstrap.cs"
$iconPath = Join-Path $builderRoot "assets\icons\HermesGo.ico"
$outExe = Join-Path (Split-Path -Parent $PSScriptRoot) "HermesGo.exe"

if (-not (Test-Path -LiteralPath $sourceCs)) {
    throw "Missing C# source: $sourceCs"
}

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
if (Test-Path -LiteralPath $iconPath) {
    $arguments += ("/win32icon:{0}" -f $iconPath)
}
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
