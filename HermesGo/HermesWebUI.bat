@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "SCRIPT=%~dp0app\scripts\Start-HermesGo.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Start-HermesGo.ps1"

set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
if not exist "%PS%" set "PS=powershell.exe"

echo Starting Hermes WebUI (gateway + 8787) ...
"%PS%" -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" -WebUIOnly -NoOpenDesktop -NoOpenChat
exit /b %ERRORLEVEL%
