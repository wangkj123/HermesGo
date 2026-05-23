@echo off
setlocal EnableExtensions

set "HERMESGO_STRICT_PORTABLE=1"
set "HERMES_PORTABLE_STRICT=1"
set "HERMESGO_SKIP_GLOBAL_PATH=1"
set "HERMES_DISABLE_WSL=1"
set "HERMES_PREFER_WINDOWS=1"

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Switch-HermesGoModel.ps1" %*
exit /b %ERRORLEVEL%
