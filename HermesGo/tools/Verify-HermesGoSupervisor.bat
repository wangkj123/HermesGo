@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Verify-HermesGoSupervisor.ps1" %*
exit /b %ERRORLEVEL%
