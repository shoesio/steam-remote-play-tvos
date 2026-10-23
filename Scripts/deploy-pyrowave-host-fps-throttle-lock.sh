#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
REMOTE_INSTALLER="/var/home/jhewes/install-pyrowave-host-pacing-lock-remote.sh"
INSTALLER_FILE="${ROOT_DIR}/Scripts/install-pyrowave-host-pacing-lock-remote.sh"

if [ ! -f "${INSTALLER_FILE}" ]; then
    echo "Missing PyroWave pacing-lock installer" >&2
    exit 1
fi

echo "Copying the resilient PyroWave pacing-lock installer to ${HOST}"
scp "${INSTALLER_FILE}" "${HOST}:${REMOTE_INSTALLER}"

echo "Updating the host source, rebuilding Sunshine, and restarting the prototype service."
echo "SSH and sudo may each request the Bazzite account password."
ssh -tt "${HOST}" "bash '${REMOTE_INSTALLER}'"
