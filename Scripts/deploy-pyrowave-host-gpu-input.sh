#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
PATCH_FILE="${ROOT_DIR}/sunshine-pyrowave-gpu-input.patch"
INSTALLER_FILE="${ROOT_DIR}/Scripts/install-pyrowave-host-gpu-input-remote.sh"
REMOTE_PATCH="/var/home/jhewes/sunshine-pyrowave-gpu-input.patch"
REMOTE_INSTALLER="/var/home/jhewes/install-pyrowave-host-gpu-input-remote.sh"

if [ ! -f "$PATCH_FILE" ] || [ ! -f "$INSTALLER_FILE" ]; then
    echo "Missing GPU-input deployment files" >&2
    exit 1
fi

echo "Copying the incremental GPU-input patch to ${HOST}"
scp "$PATCH_FILE" "${HOST}:${REMOTE_PATCH}"
scp "$INSTALLER_FILE" "${HOST}:${REMOTE_INSTALLER}"

echo "Building and installing only the separate sunshine-pyrowave service."
ssh -tt "$HOST" "bash '${REMOTE_INSTALLER}' '${REMOTE_PATCH}'"
