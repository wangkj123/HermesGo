param(
    [string]$HermesRoot = "",
    [string]$HomeDir = "",
    [switch]$SkipCodexNetwork
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

function Write-LogLine {
    param(
        [string]$Path,
        [string]$Message
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    Add-Content -LiteralPath $Path -Value ("[{0}] {1}" -f $timestamp, $Message) -Encoding utf8
}

function Test-PathOrThrow {
    param(
        [string]$Path,
        [string]$Label
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Label not found: $Path"
    }
}

if ([string]::IsNullOrWhiteSpace($HermesRoot)) {
    $HermesRoot = Resolve-PortablePath -Path (Join-Path $PSScriptRoot "..")
} else {
    $HermesRoot = Resolve-PortablePath -Path $HermesRoot
}
$HermesRoot = [System.IO.Path]::GetFullPath($HermesRoot)

$homeDir = if ([string]::IsNullOrWhiteSpace($HomeDir)) {
    Join-Path $HermesRoot "home"
} else {
    [System.IO.Path]::GetFullPath((Resolve-PortablePath -Path $HomeDir))
}
$runtimeDir = Join-Path $HermesRoot "runtime\hermes-agent"
$pythonExe = Join-Path $HermesRoot "runtime\python311\python.exe"
$ollamaExe = Join-Path $HermesRoot "runtime\ollama\ollama.exe"
$ollamaModelsDir = Join-Path $HermesRoot "data\ollama\models"
$manifestPath = Join-Path $ollamaModelsDir "manifests\registry.ollama.ai\library\gemma\2b"
$logDir = Join-Path $HermesRoot "logs"
$logPath = Join-Path $logDir "model-modes-test.log"
$configPath = Join-Path $homeDir "config.yaml"

New-Item -ItemType Directory -Path $logDir -Force | Out-Null
Set-Content -LiteralPath $logPath -Value "" -Encoding utf8

Test-PathOrThrow -Path $pythonExe -Label "Bundled Python"
Test-PathOrThrow -Path $runtimeDir -Label "Hermes runtime"
Test-PathOrThrow -Path $ollamaExe -Label "Bundled Ollama"
Test-PathOrThrow -Path $configPath -Label "Config"

$configBackup = Get-Content -LiteralPath $configPath -Raw -Encoding utf8
$ollamaProcess = $null

try {
    Write-LogLine -Path $logPath -Message "Testing Hermes root: $HermesRoot"
    if (-not (Test-Path -LiteralPath $manifestPath)) {
        throw "Bundled Ollama model manifest missing: $manifestPath"
    }
    Write-LogLine -Path $logPath -Message "Bundled gemma:2b manifest found."

    $env:HERMES_HOME = $homeDir
    $env:OLLAMA_MODELS = $ollamaModelsDir
    $env:PYTHONUTF8 = "1"
    $env:PYTHONIOENCODING = "utf-8"

    $configOllama = @'
model:
  default: "gemma:2b"
  provider: "ollama"
  base_url: "http://127.0.0.1:11434/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
'@
    Set-Content -LiteralPath $configPath -Value $configOllama -Encoding utf8
    Write-LogLine -Path $logPath -Message "Config switched to ollama/gemma:2b."

    $ollamaProcess = Start-Process -FilePath $ollamaExe `
        -ArgumentList "serve" `
        -WorkingDirectory (Split-Path -Parent $ollamaExe) `
        -WindowStyle Hidden `
        -PassThru
    Write-LogLine -Path $logPath -Message ("Bundled Ollama launched: PID {0}" -f $ollamaProcess.Id)

    $tagsReady = $false
    $tagsJson = ""
    $deadline = (Get-Date).AddSeconds(20)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 500
        try {
            $resp = Invoke-RestMethod -Uri "http://127.0.0.1:11434/api/tags" -Method Get -TimeoutSec 5
            $tagsJson = $resp | ConvertTo-Json -Depth 8 -Compress
            if ($tagsJson -match '"name":"gemma:2b"' -or $tagsJson -match '"model":"gemma:2b"') {
                $tagsReady = $true
                break
            }
        }
        catch {
        }
    }
    if (-not $tagsReady) {
        throw "Bundled Ollama started but gemma:2b was not returned by /api/tags."
    }
    Write-LogLine -Path $logPath -Message "Bundled Ollama API returned gemma:2b."

    $configCodex = @'
model:
  default: "gpt-5.4-mini"
  provider: "openai-codex"
  base_url: ""

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
'@
    Set-Content -LiteralPath $configPath -Value $configCodex -Encoding utf8
    Write-LogLine -Path $logPath -Message "Config switched to openai-codex/gpt-5.4-mini."

    $runtimeDirPy = $runtimeDir.Replace("\", "\\")
    $resolveScript = @'
import json
import sys
sys.path.insert(0, r"__RUNTIME_DIR__")
from hermes_cli.auth import resolve_codex_runtime_credentials

creds = resolve_codex_runtime_credentials(refresh_if_expiring=False)
print(json.dumps({
    "provider": creds.get("provider"),
    "base_url": creds.get("base_url"),
    "has_api_key": bool(creds.get("api_key")),
    "source": creds.get("source"),
}, ensure_ascii=False))
'@.Replace("__RUNTIME_DIR__", $runtimeDirPy)

    $resolveOutput = $resolveScript | & $pythonExe -
    if ($LASTEXITCODE -ne 0) {
        throw "Failed to resolve Codex runtime credentials."
    }
    Write-LogLine -Path $logPath -Message ("Codex resolve output: {0}" -f (($resolveOutput -join "")).Trim())

    if (-not $SkipCodexNetwork) {
        $networkScript = @'
import json
import sys
import httpx
sys.path.insert(0, r"__RUNTIME_DIR__")
from hermes_cli.auth import resolve_codex_runtime_credentials

creds = resolve_codex_runtime_credentials(refresh_if_expiring=False)
url = creds["base_url"].rstrip("/") + "/models?client_version=1.0.0"
headers = {"Authorization": "Bearer " + creds["api_key"], "Accept": "application/json"}

try:
    with httpx.Client(timeout=20.0, trust_env=True) as client:
        response = client.get(url, headers=headers)
    print(json.dumps({
        "status_code": response.status_code,
        "ok": response.status_code == 200,
        "body_preview": response.text[:240],
    }, ensure_ascii=False))
    if response.status_code != 200:
        raise SystemExit(1)
except Exception as exc:
    print(json.dumps({
        "status_code": None,
        "ok": False,
        "error": str(exc),
    }, ensure_ascii=False))
    raise SystemExit(1)
'@.Replace("__RUNTIME_DIR__", $runtimeDirPy)

        $networkPassed = $false
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            $networkOutput = $networkScript | & $pythonExe -
            $networkText = (($networkOutput -join "")).Trim()
            if ([string]::IsNullOrWhiteSpace($networkText)) {
                $networkText = "(no stdout)"
            }
            Write-LogLine -Path $logPath -Message ("Codex network attempt {0}: {1}" -f $attempt, $networkText)
            if ($LASTEXITCODE -eq 0) {
                $networkPassed = $true
                break
            }
            Start-Sleep -Seconds $attempt
        }
        if (-not $networkPassed) {
            throw "Codex network validation command failed after 3 attempts."
        }
    }

    Write-LogLine -Path $logPath -Message "result=pass"
    Write-Host "HermesGo model mode test passed."
    Write-Host "Log: $logPath"
    exit 0
}
catch {
    Write-LogLine -Path $logPath -Message ("result=fail error={0}" -f $_.Exception.Message)
    Write-Error $_
    exit 1
}
finally {
    Set-Content -LiteralPath $configPath -Value $configBackup -Encoding utf8
    if ($ollamaProcess -and -not $ollamaProcess.HasExited) {
        Stop-Process -Id $ollamaProcess.Id -Force -ErrorAction SilentlyContinue
    }
}
