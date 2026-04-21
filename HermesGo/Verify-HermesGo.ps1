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

    cmd /c "call `"$root\HermesGo.bat`" -NoOpenBrowser -NoOpenChat"
    if ($LASTEXITCODE -ne 0) { throw "HermesGo.bat failed with exit code $LASTEXITCODE" }
    Assert-Contains $launcherLog "HermesGo finished with exit code 0."
    Assert-Contains $launcherLog "Ollama model store: $ollamaModelsDir"
    Assert-Contains $launcherLog "Dashboard browser URL: http://127.0.0.1:9119/config"
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
