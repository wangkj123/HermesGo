@echo off
setlocal EnableExtensions
REM HermesGo green: start Microsoft Visual Studio Code with Hermes (portable hermes.cmd).
REM Does not open Cursor — VS Code only.
set "HERMESGO_STRICT_PORTABLE=1"
set "HERMES_DISABLE_WSL=1"
set "HERMES_PREFER_WINDOWS=1"

set "PS_EXE=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=%~dp0app\scripts\Install-HermesVSCode.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0scripts\Install-HermesVSCode.ps1"

if not exist "%SCRIPT%" (
    echo [HermesGo] Missing Install-HermesVSCode.ps1
    exit /b 1
)

"%PS_EXE%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -ApplyToWorkspace -InstallExtension -LaunchEditor %*
exit /b %ERRORLEVEL%
