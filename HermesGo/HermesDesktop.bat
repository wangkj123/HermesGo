@echo off
setlocal EnableExtensions
cd /d "%~dp0"

set "ROOT=%CD%"
if exist "%ROOT%\app\runtime\python311\python.exe" (
    set "ROOT=%ROOT%\app"
)

set "DESKTOP_DIR=%ROOT%\runtime\hermes-desktop"
set "DESKTOP_EXE=%DESKTOP_DIR%\Hermes.exe"

if not exist "%DESKTOP_EXE%" (
    echo [ERROR] Hermes Desktop not found: %DESKTOP_EXE%
    echo Build it once: powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\build_hermes_desktop_portable.ps1"
    pause
    exit /b 1
)

set "HERMES_HOME=%ROOT%\home"
set "HERMES_DESKTOP_HERMES_ROOT=%ROOT%\runtime\hermes-agent"
set "HERMES_DESKTOP_PYTHON=%ROOT%\runtime\python311\python.exe"

echo Starting Hermes Desktop (portable) ...
echo   HERMES_HOME=%HERMES_HOME%
echo   Agent root=%HERMES_DESKTOP_HERMES_ROOT%
start "" "%DESKTOP_EXE%"
exit /b 0
