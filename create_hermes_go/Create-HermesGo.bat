@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Create-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
