@echo off
setlocal EnableExtensions
for %%I in ("%~dp0..\..") do set "HERMESGO_APP=%%~fI"
set "PYTHON_EXE=%HERMESGO_APP%\runtime\python311\python.exe"
if not exist "%PYTHON_EXE%" (
    echo HermesGo runtime not found: %PYTHON_EXE%
    exit /b 1
)
"%PYTHON_EXE%" -m ddgs %*
exit /b %ERRORLEVEL%
