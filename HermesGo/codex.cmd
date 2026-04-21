@echo off
setlocal EnableExtensions

set "ROOT=%~dp0"
set "PYTHON_EXE=%ROOT%runtime\python311\python.exe"

if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)

if /i "%~1"=="login" (
    shift
    "%PYTHON_EXE%" -m hermes_cli.main login --provider openai-codex %*
    exit /b %ERRORLEVEL%
)

if /i "%~1"=="auth" if /i "%~2"=="login" (
    shift
    shift
    "%PYTHON_EXE%" -m hermes_cli.main login --provider openai-codex %*
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
