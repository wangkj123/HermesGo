@echo off
setlocal EnableExtensions

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start-AutoDevFlow.ps1" %*
set "EXIT_CODE=%ERRORLEVEL%"

echo.
echo AutoDevFlow finished with exit code %EXIT_CODE%.
if exist "%~dp0latest-summary.txt" start "" "%~dp0latest-summary.txt"
if exist "%~dp0latest-run.txt" (
    set /p AUTODEV_RUN_DIR=<"%~dp0latest-run.txt"
    if defined AUTODEV_RUN_DIR start "" explorer.exe "%AUTODEV_RUN_DIR%"
)
if /I "%AUTODEVFLOW_PAUSE%"=="1" pause
exit /b %EXIT_CODE%
