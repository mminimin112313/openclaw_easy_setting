@echo off
setlocal

cd /d "%~dp0"
set "COMPOSE_FILE=%CD%\control-plane\docker-compose.yml"
set "FORCE_DOWN="
set "BACKUP_ONLY="
if /I "%~1"=="--force-down" set "FORCE_DOWN=1"
if /I "%~1"=="--backup-only" set "BACKUP_ONLY=1"

if not exist "%COMPOSE_FILE%" (
  echo [ERROR] docker-compose file not found: "%COMPOSE_FILE%"
  exit /b 1
)

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker CLI not found.
  exit /b 1
)

echo [SECURITY] Backup passphrase is required for final backup and is not stored.
set /p OPENCLAW_BACKUP_PASSPHRASE=Enter backup passphrase:
if not defined OPENCLAW_BACKUP_PASSPHRASE (
  echo [ERROR] Backup passphrase cannot be empty.
  if not defined FORCE_DOWN exit /b 1
  echo [WARN] Continuing due to --force-down.
)

echo [1/3] Ensuring backup service is running...
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-backup openclaw-gateway openclaw-cli >nul
if errorlevel 1 (
  echo [ERROR] Failed to prepare containers for backup.
  if not defined FORCE_DOWN exit /b 1
  echo [WARN] Continuing due to --force-down.
)

echo [2/3] Running final encrypted backup before shutdown...
docker compose -f "%COMPOSE_FILE%" exec -T -e OPENCLAW_BACKUP_PASSPHRASE="%OPENCLAW_BACKUP_PASSPHRASE%" openclaw-backup sh -lc "sh /scripts/backup-openclaw-state.sh"
if errorlevel 1 (
  echo [ERROR] Final backup failed.
  echo [HINT] Verify the passphrase you entered for this run.
  if not defined FORCE_DOWN exit /b 1
  echo [WARN] Continuing due to --force-down.
)

if defined BACKUP_ONLY (
  echo [DONE] Backup completed. Option: --backup-only
  exit /b 0
)

echo [3/3] Stopping and removing control-plane containers...
docker compose -f "%COMPOSE_FILE%" down
if errorlevel 1 (
  echo [ERROR] docker compose down failed.
  exit /b 1
)

echo [DONE] Control-plane stopped after final backup.
exit /b 0
