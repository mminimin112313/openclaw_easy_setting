#!/bin/sh
set -eu

if [ "$#" -lt 2 ]; then
  echo "usage: $0 <backup-file.openclawdata> <target-dir>" >&2
  exit 1
fi

BACKUP_FILE="$1"
TARGET_DIR="$2"
PASSPHRASE="${OPENCLAW_BACKUP_PASSPHRASE:-}"
TMP_ARCHIVE="$(mktemp "${TMPDIR:-/tmp}/openclaw-restore-XXXXXX.tar.gz")"
TMP_EXTRACT_DIR="$(mktemp -d "${TMPDIR:-/tmp}/openclaw-restore-dir-XXXXXX")"

if [ -z "${PASSPHRASE}" ]; then
  echo "[restore] OPENCLAW_BACKUP_PASSPHRASE is required." >&2
  exit 2
fi

if [ ! -f "${BACKUP_FILE}" ]; then
  echo "[restore] backup file not found: ${BACKUP_FILE}" >&2
  exit 3
fi

mkdir -p "${TARGET_DIR}"

if ! openssl enc -d -aes-256-cbc -pbkdf2 -iter 200000 \
  -in "${BACKUP_FILE}" \
  -out "${TMP_ARCHIVE}" \
  -pass "pass:${PASSPHRASE}"; then
  echo "[restore] decrypt failed (invalid passphrase or corrupted backup)." >&2
  rm -f "${TMP_ARCHIVE}"
  rm -rf "${TMP_EXTRACT_DIR}"
  exit 4
fi

# Extract to local temp first to avoid chmod/utime failures on bind-mounted
# target directories (common on Docker Desktop for Windows).
tar -C "${TMP_EXTRACT_DIR}" -xzf "${TMP_ARCHIVE}"
cp -R "${TMP_EXTRACT_DIR}"/. "${TARGET_DIR}"/
rm -f "${TMP_ARCHIVE}"
rm -rf "${TMP_EXTRACT_DIR}"

echo "[restore] state restored into: ${TARGET_DIR}"
