@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Bundle-Ollama.ps1" %*
exit /b %ERRORLEVEL%
