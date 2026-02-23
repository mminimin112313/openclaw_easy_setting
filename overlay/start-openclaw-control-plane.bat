@echo off
setlocal

cd /d "%~dp0"
set "COMPOSE_FILE=%CD%\control-plane\docker-compose.yml"
set "SKIP_AUTH="
if /I "%~1"=="--skip-auth" set "SKIP_AUTH=1"
set "OPENCLAW_STATE_HOST=%CD%\control-plane\state"
set "OPENCLAW_HOME_HOST=%OPENCLAW_STATE_HOST%\openclaw-home"
set "OPENCLAW_RUNTIME_HOST=%OPENCLAW_STATE_HOST%\runtime"
set "OPENCLAW_LOGS_HOST=%OPENCLAW_STATE_HOST%\logs"
set "RUNTIME_ENV_FILE=%OPENCLAW_STATE_HOST%\.env.runtime"
set "OPENCLAW_BACKUP_PASSPHRASE="

if not exist "%COMPOSE_FILE%" (
  echo [ERROR] docker-compose file not found: "%COMPOSE_FILE%"
  exit /b 1
)

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker CLI not found. Install Docker Desktop first.
  exit /b 1
)

docker info >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker daemon is not running. Start Docker Desktop and retry.
  exit /b 1
)

if not exist "%OPENCLAW_STATE_HOST%" mkdir "%OPENCLAW_STATE_HOST%"
if not exist "%OPENCLAW_HOME_HOST%" mkdir "%OPENCLAW_HOME_HOST%"
if not exist "%OPENCLAW_RUNTIME_HOST%" mkdir "%OPENCLAW_RUNTIME_HOST%"
if not exist "%OPENCLAW_LOGS_HOST%" mkdir "%OPENCLAW_LOGS_HOST%"
if not exist "%RUNTIME_ENV_FILE%" type nul > "%RUNTIME_ENV_FILE%"

if not exist "%OPENCLAW_HOME_HOST%" (
  echo [ERROR] Failed to create persistent state path: "%OPENCLAW_HOME_HOST%"
  exit /b 1
)

echo.
echo [SECURITY] Backup passphrase is no longer saved on disk.
set /p OPENCLAW_BACKUP_PASSPHRASE=Enter backup passphrase for this run:
if not defined OPENCLAW_BACKUP_PASSPHRASE (
  echo [ERROR] Backup passphrase cannot be empty.
  exit /b 1
)

findstr /I /C:"privileged:" /C:"docker.sock" /C:"/:/host" "%COMPOSE_FILE%" >nul
if not errorlevel 1 (
  echo [ERROR] High-risk docker option detected in compose file.
  echo - Remove privileged mode, docker socket mount, or host-root mount before start.
  exit /b 1
)

echo.
echo [1/4] Codex OAuth authentication
echo - OAuth is executed in a temporary auth container and saved to shared volume.
echo - Browser window may open. Complete login flow in the prompt.
docker compose -f "%COMPOSE_FILE%" up -d openclaw-gateway
if errorlevel 1 (
  echo [ERROR] Failed to start gateway bootstrap container for auth.
  exit /b 1
)

if defined SKIP_AUTH (
  echo - Skipping auth step: --skip-auth
) else (
  echo - Using built-in OpenClaw OAuth login
  echo - If no browser pops up, copy the shown URL into your local browser and paste redirect URL back.
  docker compose -f "%COMPOSE_FILE%" run --rm openclaw-cli sh -lc "openclaw models auth login --provider openai-codex"
  if errorlevel 1 (
    echo [ERROR] Authentication failed or canceled.
    exit /b 1
  )
)

if defined SKIP_AUTH (
  echo - Auth status check skipped due to --skip-auth
) else (
  docker compose -f "%COMPOSE_FILE%" run --rm openclaw-cli sh -lc "openclaw models status --json | grep -q '\"missingProvidersInUse\": \[\]'"
  if errorlevel 1 (
    echo [ERROR] Auth profile is still missing for current agent.
    echo - Run this manually and finish OAuth:
    echo   docker compose -f "%COMPOSE_FILE%" run --rm -it openclaw-cli sh -lc "openclaw models auth login --provider openai-codex"
    exit /b 1
  )
)

echo.
echo [2/4] Start or recreate control-plane services
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-gateway openclaw-cli openclaw-admin openclaw-backup router
if errorlevel 1 (
  echo [ERROR] Failed to start control-plane services.
  exit /b 1
)

echo.
echo [3/4] Apply runtime defaults (restart + model routing)
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw config set commands.restart true && openclaw config set gateway.channelHealthCheckMinutes 1 && openclaw config set agents.defaults.model.primary openai-codex/gpt-5.2 && openclaw config set agents.defaults.model.fallbacks[0] openai-codex/gpt-5.3-codex"
if errorlevel 1 (
  echo [ERROR] Failed to apply OpenClaw runtime defaults.
  exit /b 1
)

docker compose -f "%COMPOSE_FILE%" restart openclaw-gateway
if errorlevel 1 (
  echo [ERROR] Failed to restart openclaw-gateway after applying defaults.
  exit /b 1
)
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-cli
if errorlevel 1 (
  echo [ERROR] Failed to recreate openclaw-cli after gateway restart.
  exit /b 1
)

echo.
echo [4/5] Service checks
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "i=0; until openclaw gateway health >/dev/null 2>&1; do i=$((i+1)); if [ $i -ge 30 ]; then echo gateway_not_ready; exit 1; fi; sleep 1; done"
if errorlevel 1 (
  echo [ERROR] Gateway did not become ready in time.
  exit /b 1
)

echo.
echo [5/5] Backup passphrase check (one encrypted backup run)
docker compose -f "%COMPOSE_FILE%" exec -T -e OPENCLAW_BACKUP_PASSPHRASE="%OPENCLAW_BACKUP_PASSPHRASE%" openclaw-backup sh -lc "sh /scripts/backup-openclaw-state.sh"
if errorlevel 1 (
  echo [ERROR] Initial backup verification failed.
  echo [HINT] Re-run and ensure backup passphrase is correct.
  exit /b 1
)

docker compose -f "%COMPOSE_FILE%" ps
echo.
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw gateway status --json || true"
echo.
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw browser status --json || true"

echo.
echo [DONE] OpenClaw control-plane is up.
echo - Admin UI: http://localhost:2845/
echo - OpenClaw UI: http://localhost:2845/openclaw/
exit /b 0
