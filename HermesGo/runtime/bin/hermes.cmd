@echo off
setlocal EnableExtensions
for %%I in ("%~dp0..\..") do set "HERMESGO_APP=%%~fI"
set "PYTHON_EXE=%HERMESGO_APP%\runtime\python311\python.exe"
set "HERMES_HOME=%HERMESGO_APP%\home"
set "HERMES_PORTABLE_APP_ROOT=%HERMESGO_APP%"
set "HERMESGO_STRICT_PORTABLE=1"
set "HERMES_PORTABLE_STRICT=1"
set "HERMESGO_SKIP_GLOBAL_PATH=1"
set "HERMES_DISABLE_WSL=1"
set "HERMES_PREFER_WINDOWS=1"
set "PYTHONUTF8=1"
set "PYTHONIOENCODING=utf-8"
set "PYTHONHOME="
set "PYTHONPATH="
if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)
"%PYTHON_EXE%" -m hermes_cli.main %*
exit /b %ERRORLEVEL%
