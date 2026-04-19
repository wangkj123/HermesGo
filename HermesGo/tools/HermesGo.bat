@echo off
setlocal EnableExtensions

set "ROOT=%~dp0.."
set "START_SCRIPT=%~dp0Start-HermesGo.ps1"
set "GUI_EXE=%ROOT%\HermesGo.exe"

if "%~1"=="" (
    if /I "%HERMESGO_HEADLESS%"=="1" (
        powershell -NoProfile -ExecutionPolicy Bypass -File "%START_SCRIPT%" -NoOpenBrowser -NoOpenChat
        exit /b %ERRORLEVEL%
    )
    if exist "%GUI_EXE%" (
        start "" "%GUI_EXE%"
        exit /b 0
    )
)

if /I "%HERMESGO_HEADLESS%"=="1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%START_SCRIPT%" %*
    exit /b %ERRORLEVEL%
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%START_SCRIPT%" %*
exit /b %ERRORLEVEL%
