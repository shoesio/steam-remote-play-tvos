#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
REMOTE_INSTALLER="/var/home/jhewes/install-pyrowave-host-60fps-bypass-remote.sh"
INSTALLER_FILE="${ROOT_DIR}/Scripts/install-pyrowave-host-60fps-bypass-remote.sh"

echo "Copying the PyroWave 60 fps pacing correction to ${HOST}"
scp "${INSTALLER_FILE}" "${HOST}:${REMOTE_INSTALLER}"

echo "Rebuilding Sunshine and restarting the prototype service."
echo "SSH and sudo may each request the Bazzite account password."
ssh -tt "${HOST}" "bash '${REMOTE_INSTALLER}'"
