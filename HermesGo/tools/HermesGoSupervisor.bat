@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "SCRIPT=%ROOT%HermesGoSupervisor.ps1"
set "SUPERVISOR_ARGS=-RelaunchOnFailure -MaxRestarts 2"
set "POPUP_ARG=-PopupOnFailure"

if not exist "%SCRIPT%" (
    echo HermesGoSupervisor.ps1 not found.
    if /I not "%HERMESGO_SUPERVISOR_NO_PAUSE%"=="1" pause
    exit /b 1
)

if /I "%HERMESGO_SUPERVISOR_NO_POPUP%"=="1" set "POPUP_ARG="

powershell -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT%" %SUPERVISOR_ARGS% %POPUP_ARG% %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo HermesGoSupervisor finished with exit code %EXIT_CODE%.
if /I not "%HERMESGO_SUPERVISOR_NO_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
