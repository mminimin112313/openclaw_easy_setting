#!/bin/sh
set -eu

SOURCE_DIR="${OPENCLAW_BACKUP_SOURCE:-/home/node/.openclaw}"
BACKUP_DIR="${OPENCLAW_BACKUP_DIR:-/state/backups}"
PASSPHRASE="${OPENCLAW_BACKUP_PASSPHRASE:-}"
MAX_KEEP="${OPENCLAW_BACKUP_MAX_KEEP:-48}"
STATUS_FILE="${OPENCLAW_BACKUP_STATUS_FILE:-/state/backup-status.json}"
STAMP="$(date +%Y%m%d_%H%M%S)"
OUT_FILE="${BACKUP_DIR}/openclaw-state_${STAMP}.openclawdata"
TMP_ARCHIVE="${BACKUP_DIR}/.openclaw-state_${STAMP}.tar.gz"

if [ -z "${PASSPHRASE}" ]; then
  echo "[backup] OPENCLAW_BACKUP_PASSPHRASE is required." >&2
  exit 2
fi

if [ ! -d "${SOURCE_DIR}" ]; then
  echo "[backup] source directory not found: ${SOURCE_DIR}" >&2
  exit 3
fi

mkdir -p "${BACKUP_DIR}"
mkdir -p "$(dirname "${STATUS_FILE}")"

tar -C "${SOURCE_DIR}" -czf "${TMP_ARCHIVE}" .
openssl enc -aes-256-cbc -salt -pbkdf2 -iter 200000 \
  -in "${TMP_ARCHIVE}" \
  -out "${OUT_FILE}" \
  -pass "pass:${PASSPHRASE}"
rm -f "${TMP_ARCHIVE}"

if [ "${MAX_KEEP}" -gt 0 ] 2>/dev/null; then
  ls -1t "${BACKUP_DIR}"/openclaw-state_*.openclawdata 2>/dev/null | awk "NR>${MAX_KEEP}" | xargs -r rm -f
fi

echo "[backup] encrypted backup written: ${OUT_FILE}"
printf '{"ok":true,"timestamp":"%s","file":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${OUT_FILE}" > "${STATUS_FILE}"
