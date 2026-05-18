@echo off
setlocal EnableExtensions

set "SCRIPT=%~dp0app\scripts\Start-HermesGo.ps1"
if not exist "%SCRIPT%" set "SCRIPT=%~dp0Start-HermesGo.ps1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %*
exit /b %ERRORLEVEL%
