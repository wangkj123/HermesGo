@echo off
setlocal
cd /d "%~dp0"

:: Try development layout first (runtime/python311/...)
set "PYTHON=%CD%\runtime\python311\python.exe"
set "WEBUI=%CD%\runtime\hermes-webui"

:: If not found, try deployment layout (app/runtime/python311/...)
if not exist "%PYTHON%" (
    set "PYTHON=%CD%\app\runtime\python311\python.exe"
    set "WEBUI=%CD%\app\runtime\hermes-webui"
)

if not exist "%PYTHON%" (
    echo [ERROR] Python not found
    echo   Tried: %CD%\runtime\python311\python.exe
    echo   Tried: %CD%\app\runtime\python311\python.exe
    pause
    exit /b 1
)
if not exist "%WEBUI%\run.py" (
    echo [ERROR] WebUI launcher not found: %WEBUI%\run.py
    pause
    exit /b 1
)
echo Starting Hermes WebUI on http://127.0.0.1:8787 ...
start "Hermes WebUI" /MIN "%PYTHON%" "%WEBUI%\run.py"
timeout /t 3 /nobreak >"%SystemRoot%\System32\NUL"
start http://127.0.0.1:8787
exit /b 0
