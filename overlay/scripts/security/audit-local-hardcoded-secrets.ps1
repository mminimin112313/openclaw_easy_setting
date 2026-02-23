param(
  [string]$RepoRoot = ""
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $RepoRoot) {
  $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot "..\..")).Path
}

Push-Location $RepoRoot
try {
  if (-not (Test-Path ".git")) {
    throw "Not a git repository: $RepoRoot"
  }

  $patterns = @(
    @{ Name = "OpenAI key"; Regex = "sk-[A-Za-z0-9]{20,}" },
    @{ Name = "Telegram bot token"; Regex = "\b\d{7,11}:[A-Za-z0-9_-]{30,}\b" },
    @{ Name = "GitHub PAT"; Regex = "\bghp_[A-Za-z0-9]{20,}\b" },
    @{ Name = "Slack token"; Regex = "\bxox[baprs]-[A-Za-z0-9-]{10,}\b" },
    @{ Name = "Private key block"; Regex = "-----BEGIN (RSA |OPENSSH |EC |DSA )?PRIVATE KEY-----" }
  )

  Write-Host "[INFO] Running hardcoded secret scan on tracked files..."
  $hits = @()

  $trackedFiles = & git ls-files
  $targetFiles = $trackedFiles | Where-Object {
    $_ -match "^(openclaw-oneclick\.bat|install-openclaw-windows\.bat|start-openclaw-control-plane\.bat|stop-openclaw-control-plane\.bat|restore-openclaw-soul\.bat|run-cro-chat-and-backup\.bat|docker-compose\.yml|Dockerfile)$" -or
    $_ -match "^control-plane/(?!state/).+" -or
    $_ -match "^scripts/windows/.+\.ps1$" -or
    $_ -match "^scripts/security/.+\.ps1$"
  }

  foreach ($file in $targetFiles) {
    if (-not (Test-Path $file)) { continue }
    $content = Get-Content $file -Raw
    foreach ($pattern in $patterns) {
      $matches = [regex]::Matches($content, $pattern.Regex)
      foreach ($m in $matches) {
        $value = $m.Value
        if ($value -match "change-me|test|example|dummy|sample") { continue }
        $hits += [PSCustomObject]@{
          Type = $pattern.Name
          Match = "${file}: $value"
        }
      }
    }
  }

  if ($hits.Count -gt 0) {
    Write-Host ""
    Write-Host "[ERROR] Hardcoded sensitive patterns detected:"
    $hits | ForEach-Object { Write-Host ("- [{0}] {1}" -f $_.Type, $_.Match) }
    exit 2
  }

  Write-Host "[OK] No hardcoded sensitive values found in tracked operational files."
  exit 0
}
finally {
  Pop-Location
}
