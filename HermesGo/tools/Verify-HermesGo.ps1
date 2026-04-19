param(
    [switch]$KeepTemp
)

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

$toolsDir = Resolve-PortablePath -Path $PSScriptRoot
$appRoot = Split-Path -Parent $toolsDir
$tmpLogDir = Join-Path $appRoot "logs\tmp"
$launcherLog = Join-Path $appRoot "HermesGo-debug.txt"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$configPath = Join-Path $appRoot "home\config.yaml"
$ollamaModelsDir = Join-Path $appRoot "data\ollama\models"
$launcher = Join-Path $appRoot "tools\Start-HermesGo.ps1"
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

function Write-Step {
    param([string]$Message)
    Write-Host $Message
}

function Assert-Contains {
    param(
        [string]$Path,
        [string]$Needle,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "Missing expected file: $Path"
    }

    $content = Get-Content -LiteralPath $Path -Raw -Encoding utf8
    if ($content -notmatch [regex]::Escape($Needle)) {
        throw "Assertion failed for $Label. Needle not found: $Needle"
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

function Reset-Logs {
    New-Item -ItemType Directory -Path $tmpLogDir -Force | Out-Null
    Remove-Item -LiteralPath $launcherLog, $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
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

function Get-ConfiguredModelName {
    if (-not (Test-Path -LiteralPath $configPath)) {
        return ""
    }

    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $modelMatch = [regex]::Match($configText, '(?m)^\s*default:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    if (-not $modelMatch.Success) {
        return ""
    }

    return $modelMatch.Groups["v"].Value.Trim()
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

$originalHeadless = $env:HERMESGO_HEADLESS
$originalOllamaModels = $env:OLLAMA_MODELS

try {
    $env:HERMESGO_HEADLESS = "1"
    Apply-ProxyBypassEnvironment
    $env:OLLAMA_MODELS = $ollamaModelsDir
    Write-Step "Verify step 1: headless launcher path."
    Reset-Logs
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

    powershell -NoProfile -ExecutionPolicy Bypass -File $launcher -NoOpenBrowser -NoOpenChat
    if ($LASTEXITCODE -ne 0) {
        throw "Launcher failed with exit code $LASTEXITCODE"
    }

    Assert-Contains $launcherLog "HermesGo launcher started." "launcher-start"
    Assert-Contains $launcherLog "HermesGo finished with exit code 0." "launcher-exit"
    Assert-Contains $launcherLog "Ollama model store: $ollamaModelsDir" "ollama-model-store"
    Assert-Contains $dashboardOutLog "Using bundled web UI frontend." "bundled-web-ui"

    $response = Invoke-DirectHttpRequest -Uri $dashboardUrl -TimeoutSec 5
    if ($response.StatusCode -ne 200 -or $response.Content -notmatch "<title>Hermes Agent</title>") {
        throw "Dashboard HTTP probe did not return the Hermes UI."
    }

    $ollamaProbe = Invoke-OllamaCompatProbe -ModelName $configuredModel
    if (-not $ollamaProbe.choices -or $ollamaProbe.choices.Count -lt 1) {
        throw "Bundled Ollama OpenAI-compatible probe returned no choices."
    }

    Write-Step "HermesGo verification passed."
}
finally {
    if ($null -eq $originalHeadless) {
        Remove-Item Env:HERMESGO_HEADLESS -ErrorAction SilentlyContinue
    }
    else {
        $env:HERMESGO_HEADLESS = $originalHeadless
    }

    if ($null -eq $originalOllamaModels) {
        Remove-Item Env:OLLAMA_MODELS -ErrorAction SilentlyContinue
    }
    else {
        $env:OLLAMA_MODELS = $originalOllamaModels
    }

    if (-not $KeepTemp) {
        Remove-Item -LiteralPath $launcherLog, $dashboardOutLog, $dashboardErrLog -Force -ErrorAction SilentlyContinue
    }
}
