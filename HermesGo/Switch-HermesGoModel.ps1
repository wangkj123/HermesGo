param(
    [string]$Model = "",
    [string]$Provider = "",
    [string]$BaseUrl = ""
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

function Read-PortableDefaults {
    param([string]$Path)

    $defaults = [ordered]@{
        DEFAULT_OLLAMA_PROVIDER = "ollama"
        DEFAULT_OLLAMA_MODEL = "gemma:2b"
        DEFAULT_OLLAMA_BASE_URL = "http://127.0.0.1:11434/v1"
    }

    if (-not (Test-Path -LiteralPath $Path)) {
        return [pscustomobject]$defaults
    }

    foreach ($line in (Get-Content -LiteralPath $Path -Encoding utf8)) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith(";") -or $trimmed.StartsWith("#")) {
            continue
        }

        $parts = $trimmed.Split("=", 2)
        if ($parts.Count -ne 2) {
            continue
        }

        $key = $parts[0].Trim()
        if (-not $defaults.Contains($key)) {
            continue
        }

        $value = $parts[1].Trim()
        if ($value.StartsWith('"') -and $value.EndsWith('"') -and $value.Length -ge 2) {
            $value = $value.Substring(1, $value.Length - 2)
        }
        $defaults[$key] = $value
    }

    return [pscustomobject]$defaults
}

function Update-YamlValue {
    param(
        [string]$Text,
        [string]$Key,
        [string]$Value
    )

    $escaped = $Value.Replace("\", "\\").Replace('"', '\"')
    $pattern = "(?m)^(\s*$([regex]::Escape($Key)):\s*).*$"
    $replacement = "`$1`"$escaped`""
    return [regex]::Replace($Text, $pattern, $replacement)
}

$root = Resolve-PortablePath -Path (Join-Path $PSScriptRoot "..")
$homeDir = Join-Path $root "home"
$defaultsPath = Join-Path $homeDir "portable-defaults.txt"
$configPath = Join-Path $homeDir "config.yaml"

$current = Read-PortableDefaults -Path $defaultsPath

if ([string]::IsNullOrWhiteSpace($Model)) {
    $fallback = [string]$current.DEFAULT_OLLAMA_MODEL
    if ($Host.Name -eq "ConsoleHost" -and [Environment]::UserInteractive) {
        $entered = Read-Host ("输入要切换的本地模型 [{0}]" -f $fallback)
        if ([string]::IsNullOrWhiteSpace($entered)) {
            $Model = $fallback
        } else {
            $Model = $entered.Trim()
        }
    } else {
        Write-Host "请用 -Model 指定要切换的本地模型，例如: Switch-HermesGoModel.ps1 -Model qwen2.5:7b"
        exit 1
    }
}

if ([string]::IsNullOrWhiteSpace($Provider)) {
    $Provider = [string]$current.DEFAULT_OLLAMA_PROVIDER
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = [string]$current.DEFAULT_OLLAMA_BASE_URL
}

if ([string]::IsNullOrWhiteSpace($Provider)) {
    $Provider = "ollama"
}
if ([string]::IsNullOrWhiteSpace($BaseUrl)) {
    $BaseUrl = "http://127.0.0.1:11434/v1"
}

New-Item -ItemType Directory -Path $homeDir -Force | Out-Null

$portableDefaultsText = @"
; Portable fallback defaults for HermesGo
DEFAULT_OLLAMA_PROVIDER=$Provider
DEFAULT_OLLAMA_MODEL=$Model
DEFAULT_OLLAMA_BASE_URL=$BaseUrl
"@
Set-Content -LiteralPath $defaultsPath -Value $portableDefaultsText -Encoding utf8

$configText = if (Test-Path -LiteralPath $configPath) {
    Get-Content -LiteralPath $configPath -Raw -Encoding utf8
} else {
    @"
model:
  default: "gemma:2b"
  provider: "ollama"
  base_url: "http://127.0.0.1:11434/v1"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
"@
}

$configText = Update-YamlValue -Text $configText -Key "default" -Value $Model
$configText = Update-YamlValue -Text $configText -Key "provider" -Value $Provider
$configText = Update-YamlValue -Text $configText -Key "base_url" -Value $BaseUrl
Set-Content -LiteralPath $configPath -Value $configText -Encoding utf8

Write-Host ("已切换默认本地模型: {0}" -f $Model)
Write-Host ("已更新: {0}" -f $defaultsPath)
Write-Host ("已更新: {0}" -f $configPath)
