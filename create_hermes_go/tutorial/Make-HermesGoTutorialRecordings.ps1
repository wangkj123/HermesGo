param(
    [string]$PackageRoot = (Join-Path $PSScriptRoot '..\output\HermesGo'),
    [string]$TutorialRoot = $PSScriptRoot
)

$ErrorActionPreference = 'Stop'

$pythonRecorder = Join-Path $TutorialRoot 'Record-HermesGoTutorial.py'
$recordingsDir = Join-Path $TutorialRoot 'recordings'
$launcherExe = Join-Path $PackageRoot 'HermesGo.exe'
$homeDir = Join-Path $PackageRoot 'home'
$codexCmd = Join-Path $PackageRoot 'codex.cmd'

function Stop-HermesGoProcesses {
    Get-Process HermesGo -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
}

function Set-LauncherConfig {
    param(
        [string]$Provider,
        [string]$Model,
        [string]$BaseUrl
    )

    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
    @"
model:
  provider: "$Provider"
  default: "$Model"
  base_url: "$BaseUrl"

terminal:
  backend: "local"
  cwd: "."
  timeout: 180
  lifetime_seconds: 300
"@ | Set-Content -LiteralPath (Join-Path $homeDir 'config.yaml') -Encoding utf8
}

function Record-LauncherState {
    param(
        [string]$Provider,
        [string]$Model,
        [string]$BaseUrl,
        [string]$OutputName,
        [double]$Duration = 4.0
    )

    Stop-HermesGoProcesses
    Set-LauncherConfig -Provider $Provider -Model $Model -BaseUrl $BaseUrl
    $process = Start-Process -FilePath $launcherExe -WorkingDirectory $PackageRoot -PassThru
    try {
        Start-Sleep -Seconds 2
        & py -3 $pythonRecorder --window-title 'HermesGo 启动器' --duration $Duration --fps 8 --output (Join-Path $recordingsDir $OutputName)
    }
    finally {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

function Record-CodexLogin {
    param(
        [string]$OutputName,
        [double]$Duration = 8.0
    )

    Stop-HermesGoProcesses
    $process = Start-Process -FilePath $codexCmd -ArgumentList 'login' -WorkingDirectory $PackageRoot -PassThru
    try {
        Start-Sleep -Seconds 2
        & py -3 $pythonRecorder --screen --duration $Duration --fps 8 --output (Join-Path $recordingsDir $OutputName)
    }
    finally {
        try { Stop-Process -Id $process.Id -Force -ErrorAction SilentlyContinue } catch {}
    }
}

New-Item -ItemType Directory -Force -Path $recordingsDir | Out-Null

Record-LauncherState -Provider 'ollama' -Model 'gemma:2b' -BaseUrl 'http://127.0.0.1:11434/v1' -OutputName '01-Local-Start.mp4'
Record-LauncherState -Provider 'openai-codex' -Model 'gpt-5.4-mini' -BaseUrl 'https://chatgpt.com/backend-api/codex' -OutputName '02-Cloud-GPT-5.4-mini.mp4'
Record-CodexLogin -OutputName '02-Cloud-GPT-5.4-mini-login.mp4'

Stop-HermesGoProcesses
Write-Host "Recordings created in $recordingsDir"
