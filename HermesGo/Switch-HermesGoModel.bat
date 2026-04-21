@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-HermesGoModel.ps1" %*
exit /b %ERRORLEVEL%
