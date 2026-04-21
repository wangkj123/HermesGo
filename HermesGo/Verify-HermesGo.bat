@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify-HermesGo.ps1" %*
exit /b %ERRORLEVEL%
