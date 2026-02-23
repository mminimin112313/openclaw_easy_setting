Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Windows.Forms | Out-Null

function Info([string]$message, [string]$title = "OpenClaw Easy Setting") {
  [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information) | Out-Null
}

function Fail([string]$message) {
  [System.Windows.Forms.MessageBox]::Show($message, "오류", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
  throw $message
}

function Ask-YesNo([string]$message, [string]$title = "OpenClaw Easy Setting") {
  $res = [System.Windows.Forms.MessageBox]::Show($message, $title, [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
  return $res -eq [System.Windows.Forms.DialogResult]::Yes
}

try {
  $root = Split-Path -Parent $PSCommandPath
  $defaultTarget = Join-Path $HOME "openclaw-easy\openclaw"

  $intro = @"
OpenClaw 초보자 설치를 시작합니다.

진행 내용:
1) OpenClaw 원본 코드 다운로드
2) easy-setting overlay 적용
3) 설치/실행 자동 진행

설치를 시작할까요?
"@
  if (-not (Ask-YesNo $intro)) {
    Info "설치를 취소했습니다."
    exit 0
  }

  Info "설치 경로: $defaultTarget`n`n(폴더가 없으면 자동 생성됩니다.)"

  $targetParent = Split-Path -Parent $defaultTarget
  New-Item -ItemType Directory -Path $targetParent -Force | Out-Null

  if (-not (Get-Command git -ErrorAction SilentlyContinue)) {
    Fail "git이 없습니다. 이 저장소 폴더에서 install-openclaw-windows를 먼저 실행하거나 Git을 설치하세요."
  }

  if (-not (Test-Path $defaultTarget)) {
    git clone https://github.com/openclaw/openclaw.git $defaultTarget
    if ($LASTEXITCODE -ne 0) { Fail "openclaw clone 실패" }
  } else {
    git -C $defaultTarget pull --rebase
    if ($LASTEXITCODE -ne 0) { Fail "기존 openclaw 업데이트 실패" }
  }

  Info "커스텀 설정 파일을 적용합니다."
  $overlay = Join-Path $root "overlay"
  if (-not (Test-Path $overlay)) { Fail "overlay 폴더가 없습니다: $overlay" }

  Copy-Item -Path (Join-Path $overlay "*") -Destination $defaultTarget -Recurse -Force

  $installer = Join-Path $defaultTarget "install-openclaw-windows.bat"
  if (-not (Test-Path $installer)) { Fail "설치 스크립트가 없습니다: $installer" }

  Info "이제 본 설치를 시작합니다. 시간이 걸릴 수 있습니다."
  & cmd /c "`"$installer`""
  if ($LASTEXITCODE -ne 0) {
    Fail "설치 스크립트 실행 실패 (code=$LASTEXITCODE)"
  }

  Info "설치/실행이 완료되었습니다.`n브라우저에서 OpenClaw 설정 화면을 확인하세요."
  exit 0
}
catch {
  Write-Error $_
  exit 1
}

