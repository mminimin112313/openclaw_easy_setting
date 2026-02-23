# OpenClaw Easy Setting (Windows)

This repository is a beginner-friendly package to install and run OpenClaw on Windows with minimal manual steps.

## Quick Start

1. Run `bootstrap-openclaw-easy.bat`.
2. Click **Yes** in the popup.
3. Wait for clone + overlay + installer.
4. Complete the setup wizard (Telegram token/chat id, backup passphrase, admin password).

## What It Does Automatically

- Clones or updates `https://github.com/openclaw/openclaw`
- Applies all files from `overlay/` into the OpenClaw repo
- Runs Windows installer scripts
- Performs basic security hardcode audit
- Starts control-plane and opens admin UI

## Included Overlay Skills

- `openai-whisper`
- `openai-whisper-api`
- `youtube-subs`
- `video-frames`

## Security Notes

- No personal token/password should be hardcoded in this repo.
- Backup passphrase is requested at runtime and should not be stored in plaintext.
- Admin UI on port `2845` should remain password-protected.

## Entry Files

- `bootstrap-openclaw-easy.bat` (recommended)
- `bootstrap-openclaw-easy.ps1`
