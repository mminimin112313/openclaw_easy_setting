param(
  [switch]$SkipBuild,
  [switch]$SkipLauncher,
  [switch]$NoGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:GuiAvailable = $false

function Initialize-Gui {
  if ($NoGui) { return }
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    $script:GuiAvailable = $true
  } catch {
    $script:GuiAvailable = $false
  }
}

function Show-Info([string]$message, [string]$title = "OpenClaw Setup Wizard") {
  Write-Host "[INFO] $message"
  if ($script:GuiAvailable) {
    [System.Windows.Forms.MessageBox]::Show(
      $message, $title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Information
    ) | Out-Null
  }
}

function Show-Error([string]$message, [string]$title = "OpenClaw Setup Error") {
  Write-Host "[ERROR] $message"
  if ($script:GuiAvailable) {
    [System.Windows.Forms.MessageBox]::Show(
      $message, $title,
      [System.Windows.Forms.MessageBoxButtons]::OK,
      [System.Windows.Forms.MessageBoxIcon]::Error
    ) | Out-Null
  }
}

function Ask-YesNo([string]$message, [string]$title = "OpenClaw Setup Wizard") {
  if ($NoGui) {
    Write-Host "[INFO] NoGui mode: auto-approve."
    return $true
  }
  if ($script:GuiAvailable) {
    $res = [System.Windows.Forms.MessageBox]::Show(
      $message, $title,
      [System.Windows.Forms.MessageBoxButtons]::YesNo,
      [System.Windows.Forms.MessageBoxIcon]::Question
    )
    return $res -eq [System.Windows.Forms.DialogResult]::Yes
  }
  $ans = Read-Host "$message (y/n)"
  return $ans -match "^[Yy]"
}

function Get-FaqHint([string]$message) {
  $m = ($message | Out-String)
  if ($m -match "winget") {
    return "FAQ: Install App Installer from Microsoft Store, then retry."
  }
  if ($m -match "Docker daemon not ready|docker info|daemon") {
    return "FAQ: Start Docker Desktop, wait 1-2 minutes, then retry."
  }
  if ($m -match "openclaw-oneclick\.bat failed|start-openclaw-control-plane\.bat failed|gateway_not_ready") {
    return "FAQ: Verify Docker Desktop is running and no stale containers are blocking startup."
  }
  if ($m -match "Authentication failed|oauth|auth") {
    return "FAQ: Complete OAuth in local browser and retry."
  }
  if ($m -match "unauthorized|telegram") {
    return "FAQ: Recheck Telegram bot token and chat id. Reissue token from BotFather if revoked."
  }
  if ($m -match "port.*2845|address already in use") {
    return "FAQ: Free port 2845 and retry."
  }
  if ($m -match "backup") {
    return "FAQ: Backup passphrase cannot be empty. Restore only works with the same passphrase."
  }
  return "FAQ: Check logs and rerun the wizard."
}

function Test-Command([string]$name) {
  return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
  if (Test-Command "winget") { return }
  throw "winget not found."
}

function Install-WithWinget([string]$id, [string]$displayName) {
  Write-Host "[INFO] Installing $displayName via winget..."
  winget install -e --id $id --accept-package-agreements --accept-source-agreements --silent
}

function Ensure-Git {
  if (Test-Command "git") { return }
  Install-WithWinget -id "Git.Git" -displayName "Git"
  if (-not (Test-Command "git")) { throw "Git install appears incomplete." }
}

function Ensure-DockerDesktop {
  if (Test-Command "docker") { return }
  Install-WithWinget -id "Docker.DockerDesktop" -displayName "Docker Desktop"
  if (-not (Test-Command "docker")) { throw "Docker install appears incomplete." }
}

function Start-DockerDesktop {
  $exe = "$Env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $exe) {
    Write-Host "[INFO] Starting Docker Desktop..."
    Start-Process -FilePath $exe | Out-Null
  }
  $svc = Get-Service -Name "com.docker.service" -ErrorAction SilentlyContinue
  if ($svc -and $svc.Status -ne "Running") {
    try {
      Start-Service -Name "com.docker.service" -ErrorAction Stop
      Write-Host "[INFO] com.docker.service started."
    } catch {
      Write-Host "[WARN] Could not start com.docker.service automatically."
    }
  }
}

function Wait-DockerDaemon([int]$timeoutSeconds = 240) {
  Write-Host "[INFO] Waiting for Docker daemon (up to $timeoutSeconds sec)..."
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  $tick = 0
  while ((Get-Date) -lt $deadline) {
    try {
      docker info *> $null
      Write-Host "[OK] Docker daemon is ready."
      return
    } catch {
      $tick += 1
      if (($tick % 5) -eq 0) {
        $elapsed = [int]($timeoutSeconds - ($deadline - (Get-Date)).TotalSeconds)
        if ($elapsed -lt 0) { $elapsed = 0 }
        Write-Host "[INFO] Docker daemon not ready yet... $elapsed sec elapsed."
      }
      Start-Sleep -Seconds 3
    }
  }
  throw "Docker daemon not ready after timeout. Open Docker Desktop and wait until 'Engine running' is shown, then retry."
}

function Resolve-RepoRoot {
  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Resolve-Path (Join-Path $scriptDir "..\..")).Path
}

function Run-PrivacyAudit([string]$repoRoot) {
  $auditScript = Join-Path $repoRoot "scripts\security\audit-local-hardcoded-secrets.ps1"
  if (-not (Test-Path $auditScript)) { throw "Missing privacy audit script." }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $auditScript -RepoRoot $repoRoot
  if ($LASTEXITCODE -ne 0) { throw "Privacy audit failed." }
}

function Build-Image([string]$repoRoot) {
  Push-Location $repoRoot
  try {
    docker build -t openclaw:local .
  } finally {
    Pop-Location
  }
}

function Show-SetupWizard {
  if (-not $script:GuiAvailable) {
    $botToken = Read-Host "Telegram Bot Token"
    $chatId = Read-Host "Telegram Chat/User ID"
    $backupPass = Read-Host "Backup passphrase (required for restore)"
    $adminPass = Read-Host "Admin password (locks port 2845)"
    return @{
      TelegramBotToken = $botToken.Trim()
      TelegramChatId = $chatId.Trim()
      BackupPassphrase = $backupPass
      AdminPassword = $adminPass
      BackupIntervalSec = 3600
    }
  }

  $form = New-Object System.Windows.Forms.Form
  $form.Text = "OpenClaw Setup Wizard (Beginner Mode)"
  $form.Width = 640
  $form.Height = 470
  $form.StartPosition = "CenterScreen"

  $lbGuide = New-Object System.Windows.Forms.Label
  $lbGuide.Text = "Fill required fields only. Backup passphrase is required for restore and is not stored in plain text."
  $lbGuide.Left = 20; $lbGuide.Top = 15; $lbGuide.Width = 590; $lbGuide.Height = 30
  $form.Controls.Add($lbGuide)

  $labels = @(
    @{ T = "Telegram Bot Token"; Y = 55 },
    @{ T = "Telegram Chat/User ID"; Y = 115 },
    @{ T = "Backup passphrase (required for restore)"; Y = 175 },
    @{ T = "Admin password (locks port 2845)"; Y = 235 },
    @{ T = "Auto backup interval in seconds (min 60)"; Y = 295 }
  )

  foreach ($l in $labels) {
    $lb = New-Object System.Windows.Forms.Label
    $lb.Text = $l.T
    $lb.Left = 20
    $lb.Top = $l.Y
    $lb.Width = 590
    $form.Controls.Add($lb)
  }

  $tbToken = New-Object System.Windows.Forms.TextBox
  $tbToken.Left = 20; $tbToken.Top = 78; $tbToken.Width = 590
  $form.Controls.Add($tbToken)

  $tbChat = New-Object System.Windows.Forms.TextBox
  $tbChat.Left = 20; $tbChat.Top = 138; $tbChat.Width = 590
  $form.Controls.Add($tbChat)

  $tbBackup = New-Object System.Windows.Forms.TextBox
  $tbBackup.Left = 20; $tbBackup.Top = 198; $tbBackup.Width = 590; $tbBackup.UseSystemPasswordChar = $true
  $form.Controls.Add($tbBackup)

  $tbAdmin = New-Object System.Windows.Forms.TextBox
  $tbAdmin.Left = 20; $tbAdmin.Top = 258; $tbAdmin.Width = 590; $tbAdmin.UseSystemPasswordChar = $true
  $form.Controls.Add($tbAdmin)

  $tbInterval = New-Object System.Windows.Forms.TextBox
  $tbInterval.Left = 20; $tbInterval.Top = 318; $tbInterval.Width = 140; $tbInterval.Text = "3600"
  $form.Controls.Add($tbInterval)

  $btnOk = New-Object System.Windows.Forms.Button
  $btnOk.Text = "Apply"
  $btnOk.Left = 430
  $btnOk.Top = 370
  $btnOk.Width = 85
  $btnOk.DialogResult = [System.Windows.Forms.DialogResult]::OK
  $form.Controls.Add($btnOk)

  $btnCancel = New-Object System.Windows.Forms.Button
  $btnCancel.Text = "Cancel"
  $btnCancel.Left = 525
  $btnCancel.Top = 370
  $btnCancel.Width = 85
  $btnCancel.DialogResult = [System.Windows.Forms.DialogResult]::Cancel
  $form.Controls.Add($btnCancel)

  $form.AcceptButton = $btnOk
  $form.CancelButton = $btnCancel

  $result = $form.ShowDialog()
  if ($result -ne [System.Windows.Forms.DialogResult]::OK) { return $null }

  $interval = 3600
  [void][int]::TryParse($tbInterval.Text, [ref]$interval)
  if ($interval -lt 60) { $interval = 3600 }

  return @{
    TelegramBotToken = $tbToken.Text.Trim()
    TelegramChatId = $tbChat.Text.Trim()
    BackupPassphrase = $tbBackup.Text
    AdminPassword = $tbAdmin.Text
    BackupIntervalSec = $interval
  }
}

function Wait-AdminApi([int]$timeoutSeconds = 120) {
  $base = "http://localhost:2845"
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      $null = Invoke-RestMethod -Method Get -Uri "$base/api/auth/status" -TimeoutSec 5
      return
    } catch {
      Start-Sleep -Seconds 2
    }
  }
  throw "Admin API not reachable on localhost:2845."
}

function Start-ControlPlane([string]$repoRoot, [string]$backupPassphrase) {
  $startBat = Join-Path $repoRoot "start-openclaw-control-plane.bat"
  if (-not (Test-Path $startBat)) { throw "Missing start-openclaw-control-plane.bat" }
  $env:OPENCLAW_BACKUP_PASSPHRASE = $backupPassphrase
  try {
    & cmd /c "`"$startBat`" --skip-auth"
    if ($LASTEXITCODE -ne 0) { throw "start-openclaw-control-plane.bat failed: $LASTEXITCODE" }
  } finally {
    Remove-Item Env:OPENCLAW_BACKUP_PASSPHRASE -ErrorAction SilentlyContinue
  }
}

function Apply-BasicSetupViaApi([hashtable]$setup) {
  $base = "http://localhost:2845"
  $session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

  $status = Invoke-RestMethod -Method Get -Uri "$base/api/auth/status" -WebSession $session
  if ($status.passwordConfigured) {
    Invoke-RestMethod -Method Post -Uri "$base/api/auth/login" -WebSession $session -ContentType "application/json" -Body (@{
      password = $setup.AdminPassword
    } | ConvertTo-Json -Compress) | Out-Null
  } else {
    Invoke-RestMethod -Method Post -Uri "$base/api/auth/bootstrap" -WebSession $session -ContentType "application/json" -Body (@{
      password = $setup.AdminPassword
    } | ConvertTo-Json -Compress) | Out-Null
  }

  $apply = Invoke-RestMethod -Method Post -Uri "$base/api/setup/basic" -WebSession $session -ContentType "application/json" -Body (@{
    telegramBotToken = $setup.TelegramBotToken
    telegramChatId = $setup.TelegramChatId
    backupPassphrase = $setup.BackupPassphrase
    backupIntervalSec = $setup.BackupIntervalSec
    adminPassword = $setup.AdminPassword
  } | ConvertTo-Json -Compress)

  if (-not $apply.ok) { throw "Setup API apply failed." }
}

function Restart-AfterSetup([string]$repoRoot, [string]$backupPassphrase) {
  Push-Location $repoRoot
  try {
    $env:OPENCLAW_BACKUP_PASSPHRASE = $backupPassphrase
    docker compose -f control-plane/docker-compose.yml up -d --force-recreate openclaw-gateway openclaw-cli openclaw-backup openclaw-admin router
    if ($LASTEXITCODE -ne 0) { throw "Failed to recreate services after setup." }
    docker compose -f control-plane/docker-compose.yml exec -T openclaw-cli sh -lc "openclaw gateway health"
    if ($LASTEXITCODE -ne 0) { throw "Gateway health check failed after setup." }
  } finally {
    Remove-Item Env:OPENCLAW_BACKUP_PASSPHRASE -ErrorAction SilentlyContinue
    Pop-Location
  }
}

function Trigger-BackupNow([string]$repoRoot, [string]$backupPassphrase) {
  Push-Location $repoRoot
  try {
    docker compose -f control-plane/docker-compose.yml exec -T -e OPENCLAW_BACKUP_PASSPHRASE="$backupPassphrase" openclaw-backup sh -lc "sh /scripts/backup-openclaw-state.sh"
    if ($LASTEXITCODE -ne 0) { throw "Backup verification failed." }
  } finally {
    Pop-Location
  }
}

try {
  Initialize-Gui
  Write-Host "[INFO] Wizard build: 2026-02-23-utf8-safe-ascii"

  $intro = @"
OpenClaw wizard will run:
1) Check/install Git and Docker Desktop
2) Wait until Docker daemon is ready
3) Run privacy hardcode audit
4) Build image
5) Open setup wizard (Telegram + backup + admin password)
6) Apply setup, restart services, run immediate encrypted backup
"@
  if (-not (Ask-YesNo -message $intro -title "OpenClaw Setup Wizard")) {
    Show-Info -message "Installation canceled."
    exit 0
  }

  Show-Info -message "Checking prerequisites..."
  Ensure-Winget
  Ensure-Git
  Ensure-DockerDesktop
  Start-DockerDesktop
  Wait-DockerDaemon
  Show-Info -message "Git and Docker are ready."

  $repoRoot = Resolve-RepoRoot
  Run-PrivacyAudit -repoRoot $repoRoot
  Show-Info -message "Privacy hardcode audit passed."

  if (-not $SkipBuild) {
    Show-Info -message "Building docker image. This can take several minutes."
    Build-Image -repoRoot $repoRoot
  }

  if ($SkipLauncher) {
    Write-Host "[INFO] Skip launcher requested."
    exit 0
  }

  $setup = Show-SetupWizard
  if ($null -eq $setup) {
    Show-Info -message "Wizard canceled."
    exit 0
  }
  if ([string]::IsNullOrWhiteSpace($setup.TelegramBotToken) -or
      [string]::IsNullOrWhiteSpace($setup.TelegramChatId) -or
      [string]::IsNullOrWhiteSpace($setup.BackupPassphrase) -or
      [string]::IsNullOrWhiteSpace($setup.AdminPassword)) {
    throw "Wizard input is incomplete. All fields are required."
  }

  Show-Info -message "Starting services and waiting for admin API..."
  Start-ControlPlane -repoRoot $repoRoot -backupPassphrase $setup.BackupPassphrase
  Wait-AdminApi

  Show-Info -message "Applying setup to control-plane..."
  Apply-BasicSetupViaApi -setup $setup
  Restart-AfterSetup -repoRoot $repoRoot -backupPassphrase $setup.BackupPassphrase

  Show-Info -message "Running immediate encrypted backup check..."
  Trigger-BackupNow -repoRoot $repoRoot -backupPassphrase $setup.BackupPassphrase

  Start-Process "http://localhost:2845/"
  Show-Info -message ("Setup completed." +
    "`n- Admin UI: http://localhost:2845/" +
    "`n- Backup folder: control-plane\state\backups" +
    "`n- Restore command: restore-openclaw-soul.bat")
  exit 0
}
catch {
  $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  $faq = Get-FaqHint -message $msg
  Show-Error -message "$msg`n`n$faq"
  exit 1
}

