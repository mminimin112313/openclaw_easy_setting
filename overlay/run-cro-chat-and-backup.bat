@echo off
setlocal

cd /d "%~dp0"
set "COMPOSE_FILE=%CD%\control-plane\docker-compose.yml"
set "SESSION_ID=cro-demo"
set "SKIP_AUTH="
set "STATE_DIR=%CD%\control-plane\state"
set "RUNTIME_ENV_FILE=%STATE_DIR%\.env.runtime"
set "BACKUP_PASSPHRASE="
if /I "%~1"=="--skip-auth" set "SKIP_AUTH=1"

if not exist "%COMPOSE_FILE%" (
  echo [ERROR] docker-compose file not found: "%COMPOSE_FILE%"
  exit /b 1
)

where docker >nul 2>&1
if errorlevel 1 (
  echo [ERROR] Docker CLI not found.
  exit /b 1
)

if not exist "%STATE_DIR%" mkdir "%STATE_DIR%"
if not exist "%RUNTIME_ENV_FILE%" type nul > "%RUNTIME_ENV_FILE%"
echo [SECURITY] Backup passphrase is no longer saved on disk.
set /p BACKUP_PASSPHRASE=Enter backup passphrase:
if not defined BACKUP_PASSPHRASE (
  echo [ERROR] Backup passphrase cannot be empty.
  exit /b 1
)
set "OPENCLAW_BACKUP_PASSPHRASE=%BACKUP_PASSPHRASE%"

echo [1/6] Ensuring control-plane is running...
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-gateway openclaw-cli openclaw-backup
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" up -d --force-recreate openclaw-backup
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "i=0; until openclaw gateway health >/dev/null 2>&1; do i=$((i+1)); if [ $i -ge 40 ]; then echo gateway_not_ready; exit 1; fi; sleep 1; done"
if errorlevel 1 exit /b 1

echo [2/6] Checking model auth status...
if defined SKIP_AUTH (
  echo [INFO] Skipping auth step by option --skip-auth
) else (
  docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw models status --json | grep -q '\"missingProvidersInUse\": \[\]'"
  if errorlevel 1 (
    echo [INFO] Missing provider auth. Starting interactive OAuth login.
    docker compose -f "%COMPOSE_FILE%" run --rm -it openclaw-cli sh -lc "openclaw models auth login --provider openai-codex"
    if errorlevel 1 (
      echo [ERROR] OAuth login failed or canceled.
      exit /b 1
    )
  )
)

echo [3/6] Setting Cro identity and persona...
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "mkdir -p /home/node/.openclaw/workspace && printf '%s\n' 'Your name is Cro.' 'Always answer kindly and clearly.' 'When unclear, ask one short clarification question first.' 'Prefer actionable step-by-step guidance.' > /home/node/.openclaw/workspace/SOUL.md && openclaw config set agents.defaults.workspace /home/node/.openclaw/workspace >/dev/null && openclaw agents set-identity --agent main --name 'Cro' --theme 'Kind practical assistant' --emoji ':)' >/dev/null"
if errorlevel 1 exit /b 1

echo [4/6] Running 4 test chat turns (session: %SESSION_ID%)...
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw agent --session-id '%SESSION_ID%' --message 'Hi Cro. Your name is Cro from now on.' --thinking low --json"
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw agent --session-id '%SESSION_ID%' --message 'Preference: respond kindly and concise.' --thinking low --json"
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw agent --session-id '%SESSION_ID%' --message 'Test data 1: Favorite drink is americano.' --thinking low --json"
if errorlevel 1 exit /b 1
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "openclaw agent --session-id '%SESSION_ID%' --message 'Test data 2: Remind me tomorrow 9am for meeting.' --thinking low --json"
if errorlevel 1 exit /b 1

echo [5/6] Verifying session list...
docker compose -f "%COMPOSE_FILE%" exec -T openclaw-cli sh -lc "test -f /home/node/.openclaw/agents/main/sessions/%SESSION_ID%.jsonl && echo session_file_ok || (echo session_file_missing && exit 1)"
if errorlevel 1 exit /b 1

echo [6/6] Triggering encrypted backup now...
docker compose -f "%COMPOSE_FILE%" exec -T -e OPENCLAW_BACKUP_PASSPHRASE="%BACKUP_PASSPHRASE%" openclaw-cli sh -lc "sh /scripts/backup-openclaw-state.sh"
if errorlevel 1 (
  echo [ERROR] Backup failed. Verify the passphrase you entered.
  exit /b 1
)

echo [DONE] Chat test and backup completed.
echo - Session ID: %SESSION_ID%
echo - Backups: control-plane\state\backups
exit /b 0
