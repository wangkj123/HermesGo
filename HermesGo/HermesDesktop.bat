@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%~dp0app"
if not exist "%ROOT%\runtime\python311\python.exe" set "ROOT=%~dp0"

set "DESKTOP_EXE=%ROOT%\runtime\hermes-desktop\Hermes.exe"

if not exist "%DESKTOP_EXE%" (
    echo [ERROR] Hermes Desktop not found: %DESKTOP_EXE%
    pause
    exit /b 1
)

set "HERMES_HOME=%ROOT%\home"
set "HERMES_DESKTOP_HERMES_ROOT=%ROOT%\runtime\hermes-agent"
set "HERMES_DESKTOP_PYTHON=%ROOT%\runtime\python311\python.exe"

echo Starting Hermes Desktop (portable) ...
start "" "%DESKTOP_EXE%"
exit /b 0