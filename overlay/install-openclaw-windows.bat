@echo off
setlocal

cd /d "%~dp0"
set "PS_SCRIPT=%CD%\scripts\windows\install-openclaw-windows.ps1"

if not exist "%PS_SCRIPT%" (
  echo [ERROR] Missing installer script: "%PS_SCRIPT%"
  exit /b 1
)

echo [INFO] Running OpenClaw Windows installer...
echo [INFO] Installer script path: "%PS_SCRIPT%"
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS_SCRIPT%"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo [ERROR] Installer failed with code %EXIT_CODE%.
  exit /b %EXIT_CODE%
)

echo [DONE] Installer finished successfully.
exit /b 0
