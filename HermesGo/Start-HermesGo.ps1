param(
    [switch]$NoOpenBrowser,
    [switch]$NoOpenChat,
    [switch]$NoOpenDesktop,
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

function Remove-WindowsReservedArtifacts {
    param([string]$Directory)

    if ([string]::IsNullOrWhiteSpace($Directory) -or -not (Test-Path -LiteralPath $Directory)) {
        return
    }

    $reserved = @('nul', 'con', 'prn', 'aux') + (1..9 | ForEach-Object { "com$_"; "lpt$_" })
    foreach ($name in $reserved) {
        $candidate = Join-Path $Directory $name
        if (-not (Test-Path -LiteralPath $candidate -PathType Leaf -ErrorAction SilentlyContinue)) {
            continue
        }

        try {
            $full = (Get-Item -LiteralPath $candidate -ErrorAction Stop).FullName
            Remove-Item -LiteralPath "\\?\$full" -Force -ErrorAction Stop
            Write-Host "[HermesGo] Removed Windows reserved artifact: $full"
        } catch {
            Write-Host "[HermesGo] WARNING: could not remove reserved artifact $candidate : $($_.Exception.Message)"
        }
    }
}

function Resolve-HermesAppRoot {
    param([string]$ScriptRoot)

    $scriptRoot = Resolve-PortablePath -Path $ScriptRoot
    $candidates = @(
        $scriptRoot,
        (Resolve-PortablePath -Path (Join-Path $scriptRoot "..")),
        (Resolve-PortablePath -Path (Join-Path $scriptRoot "..\.."))
    )

    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate "runtime\python311\python.exe")) {
            return $candidate
        }
    }

    $packageRoot = Resolve-PortablePath -Path (Join-Path $scriptRoot "..")
    $appRoot = Join-Path $packageRoot "app"
    if (Test-Path -LiteralPath (Join-Path $appRoot "runtime\python311\python.exe")) {
        return $appRoot
    }

    throw "Portable Python not found under $ScriptRoot (expected app\runtime\python311\python.exe)."
}

function Get-PortablePathList {
    param([string]$AppRoot)

    $pythonRoot = Join-Path $AppRoot "runtime\python311"
    $parts = New-Object System.Collections.Generic.List[string]
    foreach ($entry in @(
            (Join-Path $AppRoot "runtime\bin"),
            $pythonRoot,
            (Join-Path $pythonRoot "Scripts"),
            $AppRoot
        )) {
        if (-not [string]::IsNullOrWhiteSpace($entry) -and (Test-Path -LiteralPath $entry)) {
            if (-not $parts.Contains($entry)) {
                [void]$parts.Add($entry)
            }
        }
    }

  # Windows needs System32 only to host cmd/powershell; never prepend user/system Python.
    $system32 = Join-Path $env:WINDIR "System32"
    if ((Test-Path -LiteralPath $system32) -and -not $parts.Contains($system32)) {
        [void]$parts.Add($system32)
    }

    return [string]::Join(";", $parts.ToArray())
}

function Set-PortableProcessEnvironment {
    param([string]$AppRoot)

    Remove-Item Env:PYTHONHOME -ErrorAction SilentlyContinue
    Remove-Item Env:PYTHONPATH -ErrorAction SilentlyContinue
    Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue

    $env:PATH = Get-PortablePathList -AppRoot $AppRoot
    $env:HERMES_HOME = Join-Path $AppRoot "home"
    $env:OLLAMA_MODELS = Join-Path $AppRoot "data\ollama\models"
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"
}

function Ensure-PortableHomeConfig {
    param([string]$AppRoot)

    $configPath = Join-Path $AppRoot "home\config.yaml"
    if (Test-Path -LiteralPath $configPath) {
        return
    }

    $templates = @(
        (Join-Path $AppRoot "home\config.yaml.slim-default"),
        (Join-Path $AppRoot "packaging\config.yaml.slim-default"),
        (Join-Path $PSScriptRoot "..\packaging\config.yaml.slim-default"),
        (Join-Path $PSScriptRoot "..\..\packaging\config.yaml.slim-default")
    )

    foreach ($template in $templates) {
        $resolved = Resolve-PortablePath -Path $template
        if (Test-Path -LiteralPath $resolved) {
            Copy-Item -LiteralPath $resolved -Destination $configPath -Force
            Write-LauncherLine "Created default config from template: $resolved"
            return
        }
    }

    $defaultConfig = @"
model:
  provider: "deepseek"
  default: "deepseek-v4-flash"
  base_url: "https://api.deepseek.com/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
"@
    Set-Content -LiteralPath $configPath -Value $defaultConfig -Encoding utf8
    Write-LauncherLine "Created built-in slim default config: $configPath"
}

function Start-ProcessWithEnvironment {
    param(
        [string]$FilePath,
        [string]$WorkingDirectory = "",
        [hashtable]$Environment = @{},
        [string[]]$ArgumentList = @(),
        [string]$WindowStyle = "Normal"
    )

    $saved = @{}
    foreach ($key in $Environment.Keys) {
        $saved[$key] = [Environment]::GetEnvironmentVariable($key, "Process")
        Set-Item -Path ("Env:" + $key) -Value $Environment[$key]
    }

    try {
        $psi = @{
            FilePath     = $FilePath
            PassThru     = $true
            WindowStyle  = $WindowStyle
        }
        if (-not [string]::IsNullOrWhiteSpace($WorkingDirectory)) {
            $psi.WorkingDirectory = $WorkingDirectory
        }
        if ($ArgumentList -and $ArgumentList.Count -gt 0) {
            $psi.ArgumentList = $ArgumentList
        }
        return Start-Process @psi
    }
    finally {
        foreach ($key in $Environment.Keys) {
            if ($null -eq $saved[$key] -or $saved[$key].Length -eq 0) {
                Remove-Item -Path ("Env:" + $key) -ErrorAction SilentlyContinue
            } else {
                Set-Item -Path ("Env:" + $key) -Value $saved[$key]
            }
        }
    }
}

$root = Resolve-HermesAppRoot -ScriptRoot $PSScriptRoot

$packageRoot = Split-Path -Parent $root
Remove-WindowsReservedArtifacts -Directory $root
if ($packageRoot -and $packageRoot -ne $root) {
    Remove-WindowsReservedArtifacts -Directory $packageRoot
}

$pythonExe = Join-Path $root "runtime\python311\python.exe"
$runtimeDir = Join-Path $root "runtime\hermes-agent"
$runtimeBinDir = Join-Path $root "runtime\bin"
$homeDir = Join-Path $root "home"
$ollamaModelsDir = Join-Path $root "data\ollama\models"
$tmpLogDir = Join-Path $root "logs\tmp"
$debugLog = Join-Path $root "HermesGo-debug.txt"
$dashboardOutLog = Join-Path $tmpLogDir "HermesGo-dashboard.out.txt"
$dashboardErrLog = Join-Path $tmpLogDir "HermesGo-dashboard.err.txt"
$dashboardUrl = "http://127.0.0.1:9119/"
$dashboardBrowserUrl = "http://127.0.0.1:9119/env?quick=1"
$webuiUrl = "http://127.0.0.1:8787/"
$webuiDir = Join-Path $root "runtime\hermes-webui"
$desktopDir = Join-Path $root "runtime\hermes-desktop"
$desktopExe = Join-Path $desktopDir "Hermes.exe"
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

function Get-ConfigModelProvider {
    $configPath = Join-Path $homeDir "config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return ""
    }
    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $providerMatch = [regex]::Match($configText, '(?m)^\s*provider:\s*"?(?<v>[^"\r\n]+)"?\s*$')
    if (-not $providerMatch.Success) {
        return ""
    }
    return $providerMatch.Groups["v"].Value.Trim().ToLowerInvariant()
}

function Get-HermesEnvValue {
    param([string]$Key)

    if ([string]::IsNullOrWhiteSpace($Key)) {
        return ""
    }

    $value = [Environment]::GetEnvironmentVariable($Key, "Process")
    if (-not [string]::IsNullOrWhiteSpace($value)) {
        return $value.Trim()
    }

    $envPath = Join-Path $homeDir ".env"
    if (-not (Test-Path -LiteralPath $envPath)) {
        return ""
    }

    foreach ($line in (Get-Content -LiteralPath $envPath -Encoding utf8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith("#")) {
            continue
        }
        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }
        if ($parts[0].Trim() -ne $Key) {
            continue
        }
        return $parts[1].Trim()
    }

    return ""
}

function Set-ConfigModelRoute {
    param(
        [string]$Provider,
        [string]$Model,
        [string]$BaseUrl
    )

    $configPath = Join-Path $homeDir "config.yaml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        return $false
    }

    $configText = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
    $escapedProvider = $Provider.Replace("\", "\\").Replace('"', '\"')
    $escapedModel = $Model.Replace("\", "\\").Replace('"', '\"')
    $escapedBaseUrl = $BaseUrl.Replace("\", "\\").Replace('"', '\"')

    $updated = $configText
    $updated = [regex]::Replace($updated, '(?m)^(\s*provider:\s*).*$','${1}"' + $escapedProvider + '"')
    $updated = [regex]::Replace($updated, '(?m)^(\s*default:\s*).*$','${1}"' + $escapedModel + '"')
    $updated = [regex]::Replace($updated, '(?m)^(\s*base_url:\s*).*$','${1}"' + $escapedBaseUrl + '"')

    if ($updated -eq $configText) {
        return $false
    }

    Set-Content -LiteralPath $configPath -Value $updated -Encoding utf8
    return $true
}

function Apply-CloudPreferredRouteIfAvailable {
    # Only auto-upgrade when still on local ollama fallback.
    $provider = Get-ConfigModelProvider
    if ($provider -and $provider -ne "ollama") {
        Write-LauncherLine "Cloud auto-route skipped: current provider is $provider"
        return
    }

    $deepseekKey = Get-HermesEnvValue -Key "DEEPSEEK_API_KEY"
    if (-not [string]::IsNullOrWhiteSpace($deepseekKey)) {
        if (Set-ConfigModelRoute -Provider "deepseek" -Model "deepseek-v4-pro" -BaseUrl "https://api.deepseek.com/v1") {
            Write-LauncherLine "Cloud auto-route applied: deepseek/deepseek-v4-pro"
        } else {
            Write-LauncherLine "Cloud auto-route already set: deepseek/deepseek-v4-pro"
        }
        return
    }
}

function Ensure-LocalOllamaReady {
    $ollamaConfig = Get-LocalOllamaConfig
    if (-not $ollamaConfig) {
        return
    }

    $ollamaExe = Join-Path $root "runtime\ollama\ollama.exe"
    if (-not (Test-Path -LiteralPath $ollamaExe)) {
        Write-LauncherLine "Slim package: bundled Ollama not included; skipping local Ollama ($ollamaExe)."
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

function Test-WebUIReady {
    try {
        $healthUrl = "http://127.0.0.1:8787/health"
        $response = Invoke-DirectHttpRequest -Uri $healthUrl -TimeoutSec 3
        return $response.StatusCode -eq 200
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

function Start-WebUIProcess {
    if (Test-WebUIReady) {
        Write-LauncherLine "WebUI already reachable: $webuiUrl"
        return
    }

    $listener = Get-NetTCPConnection -LocalPort 8787 -State Listen -ErrorAction SilentlyContinue
    if ($listener) {
        $listener | Select-Object -ExpandProperty OwningProcess -Unique | ForEach-Object {
            if ($_ -and $_ -ne $PID) {
                Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue
            }
        }
    }

    $runPy = Join-Path $webuiDir "run.py"
    if (-not (Test-Path -LiteralPath $runPy)) {
        Write-LauncherLine "WebUI run.py not found: $runPy"
        return
    }

    $process = Start-Process -FilePath $pythonExe `
        -ArgumentList @($runPy) `
        -WorkingDirectory $webuiDir `
        -PassThru `
        -WindowStyle Hidden
    Write-LauncherLine "WebUI process started: PID $($process.Id)"

    $deadline = (Get-Date).AddSeconds(30)
    while ((Get-Date) -lt $deadline) {
        if (Test-ListeningPort -Port 8787) {
            Write-LauncherLine "WebUI probe succeeded."
            return
        }
        Start-Sleep -Seconds 1
    }

    Write-LauncherLine "WebUI probe timed out after 30s (PID $($process.Id) may still be starting)"
}

function Start-HermesDesktopProcess {
    if (-not (Test-Path -LiteralPath $desktopExe)) {
        Write-LauncherLine "Hermes Desktop skipped (not bundled): $desktopExe"
        return
    }

    $running = Get-Process -Name "Hermes" -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -and ($_.Path -eq $desktopExe) } |
        Select-Object -First 1
    if ($running) {
        Write-LauncherLine "Hermes Desktop already running: PID $($running.Id)"
        return
    }

    $desktopEnv = @{
        HERMES_HOME = $homeDir
        HERMES_DESKTOP_HERMES_ROOT = $runtimeDir
        HERMES_DESKTOP_PYTHON = $pythonExe
    }

    $process = Start-ProcessWithEnvironment `
        -FilePath $desktopExe `
        -WorkingDirectory $desktopDir `
        -Environment $desktopEnv `
        -WindowStyle "Normal"
    Write-LauncherLine "Hermes Desktop started: PID $($process.Id)"
}

function Start-ChatWindow {
    $existing = Get-Process -Name "cmd" -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowTitle -like "*HermesGo Chat*" } |
        Select-Object -First 1
    if ($existing) {
        Write-LauncherLine "Chat window already running: PID $($existing.Id)"
        return
    }

    $portablePath = Get-PortablePathList -AppRoot $root
    $command = 'set PYTHONHOME=' +
        '&&set PYTHONPATH=' +
        '&&set VIRTUAL_ENV=' +
        '&&set PATH=' + $portablePath +
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

function Open-DashboardBrowser {
    param([string]$Url)

    $attempts = @(
        @{
            Name = "Start-Process url"
            Action = {
                Start-Process -FilePath $Url
            }
        }
        @{
            Name = "cmd start"
            Action = {
                Start-Process -FilePath "cmd.exe" -ArgumentList "/c", "start", "", $Url -WindowStyle Hidden
            }
        }
        @{
            Name = "explorer"
            Action = {
                Start-Process -FilePath "explorer.exe" -ArgumentList $Url
            }
        }
    )

    foreach ($attempt in $attempts) {
        try {
            & $attempt.Action
            Write-LauncherLine "Browser launched: $Url via $($attempt.Name)"
            return
        } catch {
            Write-LauncherLine "Browser launch failed via $($attempt.Name): $($_.Exception.Message)"
        }
    }

    throw "Unable to launch browser for $Url"
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
    Write-LauncherLine "Dashboard browser URL: $dashboardBrowserUrl"
    Write-LauncherLine "Dashboard temp stdout: $dashboardOutLog"
    Write-LauncherLine "Dashboard temp stderr: $dashboardErrLog"

    foreach ($requiredPath in @($pythonExe, $runtimeDir, $homeDir)) {
        if (-not (Test-Path -LiteralPath $requiredPath)) {
            throw "Required path not found: $requiredPath"
        }
    }

    Set-PortableProcessEnvironment -AppRoot $root
    Apply-ProxyBypassEnvironment
    Ensure-PortableHomeConfig -AppRoot $root
    Write-LauncherLine ("Portable PATH: " + $env:PATH)
    Write-LauncherLine "Portable target: standard Hermes runtime with portable Python only (no system Python on PATH)."
    Apply-CloudPreferredRouteIfAvailable

    Ensure-LocalOllamaReady
    Start-DashboardProcess
    Start-WebUIProcess

    if (-not $headless) {
        if (-not $NoOpenDesktop) {
            Start-HermesDesktopProcess
        }
        if (-not $NoOpenBrowser) {
            Open-DashboardBrowser -Url $webuiUrl
            Start-Sleep -Seconds 1
            Open-DashboardBrowser -Url $dashboardBrowserUrl
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
