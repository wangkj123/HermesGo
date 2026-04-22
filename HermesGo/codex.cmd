@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "PYTHON_EXE=%ROOT%runtime\python311\python.exe"
set "RUNTIME_BIN=%ROOT%runtime\bin"
set "HERMES_HOME=%ROOT%home"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PATH=%ROOT%;%RUNTIME_BIN%;%PATH%"
set "PYTHONHOME="
set "PYTHONPATH="

if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)

if /i "%~1"=="login" (
    "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~2 %~3 %~4 %~5 %~6 %~7 %~8 %~9
    exit /b %ERRORLEVEL%
)

if /i "%~1"=="auth" if /i "%~2"=="login" (
    "%PYTHON_EXE%" -m hermes_cli.main auth add openai-codex --device-auth %~3 %~4 %~5 %~6 %~7 %~8 %~9
    exit /b %ERRORLEVEL%
)

echo HermesGo codex compatibility launcher
echo.
echo This package includes a Codex-compatible launcher so you do not need to
echo install a separate codex CLI.
echo.
echo Use:
echo   codex login
echo.
echo Or open HermesGo and use the Web Dashboard Config page.
exit /b 0
