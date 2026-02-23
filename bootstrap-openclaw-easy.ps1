Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Info([string]$message, [string]$title = "OpenClaw Easy Setting") {
  [System.Windows.Forms.MessageBox]::Show(
    $message,
    $title,
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Information
  ) | Out-Null
}

function Fail([string]$message) {
  [System.Windows.Forms.MessageBox]::Show(
    $message,
    "Error",
    [System.Windows.Forms.MessageBoxButtons]::OK,
    [System.Windows.Forms.MessageBoxIcon]::Error
  ) | Out-Null
  throw $message
}

function Ask-YesNo([string]$message, [string]$title = "OpenClaw Easy Setting") {
  $res = [System.Windows.Forms.MessageBox]::Show(
    $message,
    $title,
    [System.Windows.Forms.MessageBoxButtons]::YesNo,
    [System.Windows.Forms.MessageBoxIcon]::Question
  )
  return $res -eq [System.Windows.Forms.DialogResult]::Yes
}

try {
  $root = Split-Path -Parent $PSCommandPath
  $defaultTarget = Join-Path $HOME "openclaw-easy\openclaw"

  $intro = @"
OpenClaw Easy Setting will start now.

Steps:
1) Clone or update OpenClaw source
2) Apply easy-setting overlay
3) Run installer and startup wizard

Continue?
"@
  if (-not (Ask-YesNo $intro)) {
    Info "Canceled by user."
    exit 0
  }

  Info "Install path: $defaultTarget`n`nThe folder will be created if missing."

  $targetParent = Split-Path -Parent $defaultTarget
  New-Item -ItemType Directory -Path $targetParent -Force | Out-Null

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git is not installed. Install Git first, then run this script again."
  }

  if (-not (Test-Path $defaultTarget)) {
    git clone https://github.com/openclaw/openclaw.git $defaultTarget
    if ($LASTEXITCODE -ne 0) { Fail "Failed to clone openclaw repository." }
  } else {
    git -C $defaultTarget pull --rebase
    if ($LASTEXITCODE -ne 0) { Fail "Failed to update existing openclaw directory." }
  }

  Info "Applying easy-setting overlay files..."
  $overlay = Join-Path $root "overlay"
  if (-not (Test-Path $overlay)) { Fail "Overlay folder not found: $overlay" }

  Copy-Item -Path (Join-Path $overlay "*") -Destination $defaultTarget -Recurse -Force

  $installer = Join-Path $defaultTarget "install-openclaw-windows.bat"
  if (-not (Test-Path $installer)) { Fail "Installer script not found: $installer" }

  Info "Starting installer now. This may take several minutes."
  & cmd /c "`"$installer`""
  if ($LASTEXITCODE -ne 0) {
    Fail "Installer failed (code=$LASTEXITCODE)."
  }

  Info "Setup completed.`nOpen the browser and continue in OpenClaw Control UI."
  exit 0
}
catch {
  Write-Error $_
  exit 1
}
