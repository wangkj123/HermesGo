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

function Set-LauncherSelection {
    param([string]$Key)
    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null
    Set-Content -LiteralPath (Join-Path $homeDir 'launcher-selected.txt') -Value $Key -Encoding utf8
}

function Record-LauncherState {
    param(
        [string]$Key,
        [string]$OutputName,
        [double]$Duration = 4.0
    )

    Stop-HermesGoProcesses
    Set-LauncherSelection -Key $Key
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

Record-LauncherState -Key 'beginner' -OutputName '01-启动器主界面.mp4'
Record-LauncherState -Key 'cloud' -OutputName '02-Cloud-GPT-5.4-mini.mp4'
Record-CodexLogin -OutputName '02-Cloud-GPT-5.4-mini-login.mp4'
Record-LauncherState -Key 'expert' -OutputName '03-Expert-Dashboard-Only.mp4'
Record-LauncherState -Key 'switch-model' -OutputName '04-本地模型切换.mp4'
Record-LauncherState -Key 'verify' -OutputName '05-自检和日志.mp4'
Record-LauncherState -Key 'codex-login' -OutputName '06-Codex-登录.mp4'
Record-LauncherState -Key 'open-home' -OutputName '07-打开-home-目录.mp4'
Record-LauncherState -Key 'open-logs' -OutputName '08-打开-logs-目录.mp4'
Record-LauncherState -Key 'open-custom-actions' -OutputName '09-自定义动作.mp4'

Stop-HermesGoProcesses
Write-Host "Recordings created in $recordingsDir"
