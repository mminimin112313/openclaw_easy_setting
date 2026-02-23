@echo off
setlocal

cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bootstrap-openclaw-easy.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
if not "%EXIT_CODE%"=="0" (
  echo [ERROR] bootstrap failed with code %EXIT_CODE%
  pause
  exit /b %EXIT_CODE%
)

echo [DONE] bootstrap completed.
exit /b 0

