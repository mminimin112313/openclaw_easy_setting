@echo off
setlocal

cd /d "%~dp0"
set "COMPOSE_FILE=%CD%\control-plane\docker-compose.yml"
set "OPENCLAW_STATE_HOST=%CD%\control-plane\state"
set "OPENCLAW_BACKUP_HOST=%OPENCLAW_STATE_HOST%\backups"
set "RUNTIME_ENV_FILE=%OPENCLAW_STATE_HOST%\.env.runtime"
set "OPENCLAW_HOME_HOST=%OPENCLAW_STATE_HOST%\openclaw-home"
set "FORCE_RESTORE="
set "BACKUP_PASSPHRASE="
if /I "%~1"=="--force" set "FORCE_RESTORE=1"

if not exist "%COMPOSE_FILE%" (
  echo [ERROR] docker-compose file not found: "%COMPOSE_FILE%"
  exit /b 1
)

if not exist "%OPENCLAW_BACKUP_HOST%" (
  echo [ERROR] backup directory not found: "%OPENCLAW_BACKUP_HOST%"
  exit /b 1
)

set "HAS_BACKUP_FILE="
for /f "delims=" %%F in ('dir /b /a:-d "%OPENCLAW_BACKUP_HOST%\openclaw-state_*.openclawdata" 2^>nul') do (
  if not defined HAS_BACKUP_FILE set "HAS_BACKUP_FILE=1"
)

if not defined HAS_BACKUP_FILE (
  echo [ERROR] no backup file found in "%OPENCLAW_BACKUP_HOST%"
  exit /b 1
)

echo [SECURITY] Backup passphrase is required and is not loaded from disk.
set /p BACKUP_PASSPHRASE=Enter backup passphrase:
if not defined BACKUP_PASSPHRASE (
  echo [ERROR] Backup passphrase cannot be empty.
  exit /b 1
)
set "OPENCLAW_BACKUP_PASSPHRASE=%BACKUP_PASSPHRASE%"

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker CLI not found.
  exit /b 1
)

if not defined FORCE_RESTORE (
  echo [WARN] Restore will replace current OpenClaw state.
  echo [WARN] If you continue, current runtime files may be overwritten.
  set /p CONFIRM_RESTORE=Type YES to continue restore:
  if /I not "%CONFIRM_RESTORE%"=="YES" (
    echo [INFO] Restore canceled by user.
    exit /b 0
  )
)

echo [0/4] Final backup before service stop...
docker compose -f "%COMPOSE_FILE%" up -d openclaw-backup openclaw-gateway openclaw-cli >nul
docker compose -f "%COMPOSE_FILE%" exec -T -e OPENCLAW_BACKUP_PASSPHRASE="%BACKUP_PASSPHRASE%" openclaw-backup sh -lc "sh /scripts/backup-openclaw-state.sh"
if errorlevel 1 (
  echo [WARN] Final backup failed before restore stop phase.
  echo [WARN] Continuing restore. (Use --force only if you accept risk.)
)

echo [1/4] Stopping services before restore...
docker compose -f "%COMPOSE_FILE%" stop openclaw-gateway openclaw-admin openclaw-backup >nul

echo [2/4] Starting CLI helper container...
docker compose -f "%COMPOSE_FILE%" up -d openclaw-cli
if errorlevel 1 (
  echo [ERROR] Failed to start openclaw-cli helper.
  exit /b 1
)

echo [3/4] Restoring backup (newest to oldest)...
set "RESTORED_BACKUP="
for /f "delims=" %%F in ('dir /b /a:-d /o-d "%OPENCLAW_BACKUP_HOST%\openclaw-state_*.openclawdata" 2^>nul') do (
  echo - Trying %%F
  docker compose -f "%COMPOSE_FILE%" run --rm -e OPENCLAW_BACKUP_PASSPHRASE="%BACKUP_PASSPHRASE%" openclaw-cli sh -lc "rm -rf /home/node/.openclaw/* && sh /scripts/restore-openclaw-state.sh /state/backups/%%F /home/node/.openclaw"
  if not errorlevel 1 (
    set "RESTORED_BACKUP=%%F"
    goto :restore_done
  )
)

:restore_done
if not defined RESTORED_BACKUP (
  echo [ERROR] Restore failed for all backup files.
  exit /b 1
)

echo [4/4] Restarting services...
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-gateway openclaw-cli openclaw-admin openclaw-backup
if errorlevel 1 (
  echo [ERROR] Services failed to restart after restore.
  exit /b 1
)

docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "i=0; until openclaw gateway health >/dev/null 2>&1; do i=$((i+1)); if [ $i -ge 40 ]; then echo gateway_not_ready; exit 1; fi; sleep 1; done"
if errorlevel 1 (
  echo [ERROR] Gateway health check failed after restore.
  exit /b 1
)

echo [DONE] Soul restore completed from %RESTORED_BACKUP%.
echo - openclaw-home path: "%OPENCLAW_HOME_HOST%"
exit /b 0
