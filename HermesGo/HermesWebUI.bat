@echo off
setlocal
cd /d "%~dp0"

set "ROOT=%~dp0app"
if not exist "%ROOT%\runtime\python311\python.exe" set "ROOT=%~dp0"

set "PYTHON=%ROOT%\runtime\python311\python.exe"
set "WEBUI=%ROOT%\runtime\hermes-webui"

if not exist "%PYTHON%" (
    echo [ERROR] Python not found under package app\runtime\python311
    pause
    exit /b 1
)
if not exist "%WEBUI%\run.py" (
    echo [ERROR] WebUI not found: %WEBUI%\run.py
    pause
    exit /b 1
)
set "PATH=%ROOT%\runtime\bin;%ROOT%\runtime\python311;%ROOT%\runtime\python311\Scripts;%ROOT%;%SystemRoot%\System32"
set "HERMES_HOME=%ROOT%\home"
echo Starting Hermes WebUI on http://127.0.0.1:8787 ...
start "Hermes WebUI" /MIN "%PYTHON%" "%WEBUI%\run.py"
timeout /t 3 /nobreak >nul
start http://127.0.0.1:8787
exit /b 0