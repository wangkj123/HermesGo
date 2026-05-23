@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "HERMESGO_STRICT_PORTABLE=1"
set "HERMES_PORTABLE_STRICT=1"
set "HERMESGO_SKIP_GLOBAL_PATH=1"
set "HERMES_DISABLE_WSL=1"
set "HERMES_PREFER_WINDOWS=1"

set "SCRIPT=%~dp0app\scripts\Start-HermesGo.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Start-HermesGo.ps1"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

echo Starting Hermes Desktop (portable init + probe) ...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -DesktopOnly
exit /b %ERRORLEVEL%
