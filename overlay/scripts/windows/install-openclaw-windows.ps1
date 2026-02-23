param(
  [switch]$SkipBuild,
  [switch]$SkipLauncher,
  [switch]$NoGui
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$script:GuiAvailable = $false

function Initialize-Gui {
  if ($NoGui) {
    $script:GuiAvailable = $false
    return
  }
  try {
    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing | Out-Null
    $script:GuiAvailable = $true
  } catch {
    $script:GuiAvailable = $false
  }
}

function Show-Info([string]$message, [string]$title = "OpenClaw 설치 안내") {
  Write-Host "[INFO] $message"
  if ($script:GuiAvailable) {
    [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
  }
}

function Show-ErrorMessage([string]$message, [string]$title = "OpenClaw 설치 오류") {
  Write-Host "[ERROR] $message"
  if ($script:GuiAvailable) {
    [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  }
}

function Ask-YesNo([string]$message, [string]$title = "OpenClaw 설치 확인") {
  if ($NoGui) {
    Write-Host "[INFO] NoGui mode: auto-approve."
    return $true
  }
  if ($script:GuiAvailable) {
    $res = [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
    return $res -eq [System.Windows.Forms.DialogResult]::Yes
  }
  $ans = Read-Host "$message (y/n)"
  return $ans -match "^[Yy]"
}

function Write-Step([string]$message) {
  Write-Host ""
  Write-Host "[STEP] $message"
  if ($script:GuiAvailable) {
    Write-Host "[GUI] $message"
  }
}

function Test-Command([string]$name) {
  return $null -ne (Get-Command $name -ErrorAction SilentlyContinue)
}

function Ensure-Winget {
  if (Test-Command "winget") { return }
  throw "winget이 없습니다. Microsoft Store에서 'App Installer' 설치 후 다시 실행하세요."
}

function Install-WithWinget([string]$id, [string]$displayName) {
  Write-Host "[INFO] Installing $displayName ($id) via winget..."
  winget install -e --id $id --accept-package-agreements --accept-source-agreements --silent
}

function Ensure-Git {
  if (Test-Command "git") {
    Write-Host "[OK] Git already installed."
    return
  }
  Install-WithWinget -id "Git.Git" -displayName "Git"
  if (-not (Test-Command "git")) {
    throw "Git 설치가 완료되지 않았습니다. 새 터미널을 열고 다시 실행하세요."
  }
}

function Ensure-DockerDesktop {
  if (Test-Command "docker") {
    Write-Host "[OK] Docker CLI already installed."
    return
  }
  Install-WithWinget -id "Docker.DockerDesktop" -displayName "Docker Desktop"
  if (-not (Test-Command "docker")) {
    throw "Docker 설치가 완료되지 않았습니다. 새 터미널을 열고 다시 실행하세요."
  }
}

function Start-DockerDesktop {
  Write-Host "[INFO] Starting Docker Desktop..."
  $dockerDesktopExe = "$Env:ProgramFiles\Docker\Docker\Docker Desktop.exe"
  if (Test-Path $dockerDesktopExe) {
    Start-Process -FilePath $dockerDesktopExe | Out-Null
  } else {
    Start-Process -FilePath "docker" -ArgumentList "version" -WindowStyle Hidden -ErrorAction SilentlyContinue | Out-Null
  }
}

function Wait-DockerDaemon([int]$timeoutSeconds = 240) {
  Write-Host "[INFO] Waiting for Docker daemon (up to $timeoutSeconds sec)..."
  $deadline = (Get-Date).AddSeconds($timeoutSeconds)
  while ((Get-Date) -lt $deadline) {
    try {
      docker info *> $null
      Write-Host "[OK] Docker daemon is ready."
      return
    } catch {
      Start-Sleep -Seconds 3
    }
  }
  throw "Docker 데몬이 준비되지 않았습니다. Docker Desktop을 직접 실행한 뒤 다시 시도하세요."
}

function Resolve-RepoRoot {
  $scriptDir = Split-Path -Parent $PSCommandPath
  return (Resolve-Path (Join-Path $scriptDir "..\..")).Path
}

function Run-PrivacyAudit([string]$repoRoot) {
  Write-Step "Privacy hardcoding audit"
  $auditScript = Join-Path $repoRoot "scripts\security\audit-local-hardcoded-secrets.ps1"
  if (-not (Test-Path $auditScript)) {
    throw "Missing privacy audit script: $auditScript"
  }
  & powershell -NoProfile -ExecutionPolicy Bypass -File $auditScript -RepoRoot $repoRoot
  if ($LASTEXITCODE -ne 0) {
    throw "개인정보/토큰 하드코딩 점검에서 실패했습니다. 결과를 확인하고 수정 후 다시 실행하세요."
  }
}

function Build-Image([string]$repoRoot) {
  Write-Step "Build OpenClaw Docker image"
  Push-Location $repoRoot
  try {
    docker build -t openclaw:local .
  } finally {
    Pop-Location
  }
}

function Run-OneClick([string]$repoRoot) {
  Write-Step "Run OpenClaw one-click launcher"
  $launcher = Join-Path $repoRoot "openclaw-oneclick.bat"
  if (-not (Test-Path $launcher)) {
    throw "Missing launcher: $launcher"
  }
  & cmd /c "`"$launcher`""
  if ($LASTEXITCODE -ne 0) {
    throw "openclaw-oneclick.bat failed with code $LASTEXITCODE."
  }
}

try {
  Initialize-Gui
  $startMessage = @"
이 설치기는 초보자용 자동 설치를 수행합니다.

진행 내용:
1) Git / Docker Desktop 확인 및 자동 설치
2) Docker 실행 확인
3) 개인정보/토큰 하드코딩 점검
4) OpenClaw 이미지 빌드
5) 원클릭 실행기로 설정 페이지 열기

계속할까요?
"@
  if (-not (Ask-YesNo -message $startMessage -title "OpenClaw 초보자 설치")) {
    Show-Info -message "설치를 취소했습니다."
    exit 0
  }

  Write-Step "Check prerequisites"
  Ensure-Winget
  Ensure-Git
  Ensure-DockerDesktop
  Show-Info -message "필수 프로그램 확인이 끝났습니다."

  Write-Step "Start Docker daemon"
  Start-DockerDesktop
  Wait-DockerDaemon
  Show-Info -message "Docker 준비가 완료되었습니다."

  $repoRoot = Resolve-RepoRoot
  Write-Host "[INFO] Repo root: $repoRoot"

  Run-PrivacyAudit -repoRoot $repoRoot
  Show-Info -message "개인정보/토큰 하드코딩 점검을 통과했습니다."

  if (-not $SkipBuild) {
    Show-Info -message "이미지 빌드를 시작합니다. 몇 분 걸릴 수 있습니다."
    Build-Image -repoRoot $repoRoot
    Show-Info -message "이미지 빌드가 완료되었습니다."
  } else {
    Write-Host "[INFO] Skip build requested."
  }
  if (-not $SkipLauncher) {
    Show-Info -message "이제 OpenClaw를 실행하고 설정 화면을 엽니다."
    Run-OneClick -repoRoot $repoRoot
  } else {
    Write-Host "[INFO] Skip launcher requested."
  }

  Show-Info -message "설치가 완료되었습니다. 브라우저에서 열린 OpenClaw 화면 안내대로 진행하세요." -title "OpenClaw 설치 완료"
  exit 0
}
catch {
  $msg = if ($_.Exception -and $_.Exception.Message) { $_.Exception.Message } else { "$_" }
  Show-ErrorMessage -message "$msg`n`n설치 로그를 확인한 뒤 다시 실행하세요."
  exit 1
}
