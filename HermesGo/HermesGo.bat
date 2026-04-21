@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
