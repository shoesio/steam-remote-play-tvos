#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
PATCH_FILE="${ROOT_DIR}/sunshine-pyrowave-gamescope-linear-dmabuf-repair.patch"
INSTALLER_FILE="${ROOT_DIR}/Scripts/install-pyrowave-host-gamescope-linear-dmabuf-repair-remote.sh"
REMOTE_PATCH="/var/home/jhewes/sunshine-pyrowave-gamescope-linear-dmabuf-repair.patch"
REMOTE_INSTALLER="/var/home/jhewes/install-pyrowave-host-gamescope-linear-dmabuf-repair-remote.sh"

echo "Copying the isolated Gamescope linear DMA-BUF repair to ${HOST}"
scp "$PATCH_FILE" "${HOST}:${REMOTE_PATCH}"
scp "$INSTALLER_FILE" "${HOST}:${REMOTE_INSTALLER}"

echo "Rebuilding and installing only the separate sunshine-pyrowave service."
ssh -tt "$HOST" "bash '${REMOTE_INSTALLER}' '${REMOTE_PATCH}'"
