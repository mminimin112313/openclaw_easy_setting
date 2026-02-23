@echo off
setlocal

cd /d "%~dp0"
set "BOOTSTRAP_BAT=%CD%\install-openclaw-windows.bat"
set "STATE_DIR=%CD%\control-plane\state"
set "HOME_DIR=%STATE_DIR%\openclaw-home"
set "BACKUP_DIR=%STATE_DIR%\backups"
set "HAS_SETUP="
set "HAS_SOUL_BACKUP="
set "EXIT_CODE=0"
set "PS_INSTALLER=%CD%\scripts\windows\install-openclaw-windows.ps1"
set "FORCE_WIZARD="
set "FORCE_QUICK="

if /I "%~1"=="--wizard" set "FORCE_WIZARD=1"
if /I "%~1"=="--quick" set "FORCE_QUICK=1"

where docker >nul 2>&1
if errorlevel 1 (
  echo [INFO] Docker Desktop not detected.
  echo [INFO] Launching prerequisite installer...
  if exist "%BOOTSTRAP_BAT%" (
    call "%BOOTSTRAP_BAT%"
    if errorlevel 1 (
      echo [ERROR] Prerequisite installer failed.
      set "EXIT_CODE=1"
      goto :done
    )
  ) else (
    echo [ERROR] Missing bootstrap script: "%BOOTSTRAP_BAT%"
    set "EXIT_CODE=1"
    goto :done
  )
)

if exist "%HOME_DIR%\openclaw.json" (
  findstr /I /C:"telegram" /C:"botToken" "%HOME_DIR%\openclaw.json" >nul 2>&1
  if not errorlevel 1 set "HAS_SETUP=1"
)

for /f "delims=" %%F in ('dir /b /a:-d "%BACKUP_DIR%\openclaw-state_*.openclawdata" 2^>nul') do (
  if not defined HAS_SOUL_BACKUP set "HAS_SOUL_BACKUP=1"
)

if defined HAS_SETUP if defined HAS_SOUL_BACKUP (
  if defined FORCE_WIZARD goto :run_wizard
  if defined FORCE_QUICK goto :run_quick
  echo [INFO] Existing setup and encrypted backup detected.
  set /p RUN_WIZARD=Run setup wizard now? y or N:
)

if defined HAS_SETUP if defined HAS_SOUL_BACKUP (
  setlocal EnableDelayedExpansion
  set "RUN_WIZARD=!RUN_WIZARD: =!"
  if /I "!RUN_WIZARD!"=="Y" (
    endlocal
    goto :run_wizard
  )
  if /I "!RUN_WIZARD!"=="YES" (
    endlocal
    goto :run_wizard
  )
  endlocal
  goto :run_quick
)

:run_quick
if defined HAS_SETUP if defined HAS_SOUL_BACKUP (
  echo [INFO] Existing setup and encrypted backup detected.
  echo [INFO] Starting services in safe mode with --skip-auth.
  call "%~dp0start-openclaw-control-plane.bat" --skip-auth
  if errorlevel 1 goto :fail_start
  echo [INFO] Opening admin page...
  start "" "http://localhost:2845/"
  echo [DONE] Existing environment started.
  goto :done
)

:run_wizard
echo [INFO] First-run or reconfiguration mode.
if not exist "%PS_INSTALLER%" (
  echo [ERROR] Wizard script not found: "%PS_INSTALLER%"
  set "EXIT_CODE=1"
  goto :done
)

echo [1/1] Running setup wizard...
call "%BOOTSTRAP_BAT%"
if errorlevel 1 (
  echo [ERROR] Setup wizard failed.
  set "EXIT_CODE=1"
  goto :done
)

echo [DONE] Setup wizard completed.
goto :done

:fail_start
echo [ERROR] Startup failed. Review messages above.
set "EXIT_CODE=1"
goto :done

:done
echo Press any key to close...
pause >nul
exit /b %EXIT_CODE%
