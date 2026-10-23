#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
PATCH_FILE="${2:-${ROOT_DIR}/sunshine-pyrowave-transport.patch}"
REMOTE_PATCH="/var/home/jhewes/sunshine-pyrowave-transport.patch"
REMOTE_INSTALLER="/var/home/jhewes/install-pyrowave-host-transport-remote.sh"
INSTALLER_FILE="${ROOT_DIR}/Scripts/install-pyrowave-host-transport-remote.sh"

if [ ! -f "${PATCH_FILE}" ] || [ ! -f "${INSTALLER_FILE}" ]; then
    echo "Missing PyroWave transport deployment files" >&2
    exit 1
fi

echo "Copying PyroWave transport patch to ${HOST}"
scp "${PATCH_FILE}" "${HOST}:${REMOTE_PATCH}"
scp "${INSTALLER_FILE}" "${HOST}:${REMOTE_INSTALLER}"

echo "Applying patch, rebuilding Sunshine, and restarting the prototype service."
echo "SSH and sudo may each request the Bazzite account password."
ssh -tt "${HOST}" "bash '${REMOTE_INSTALLER}' '${REMOTE_PATCH}'"
