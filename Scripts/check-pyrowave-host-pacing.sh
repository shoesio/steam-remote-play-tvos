#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
REMOTE_CHECKER="/var/home/jhewes/check-pyrowave-host-pacing-remote.sh"
CHECKER_FILE="${ROOT_DIR}/Scripts/check-pyrowave-host-pacing-remote.sh"

if [ ! -f "${CHECKER_FILE}" ]; then
    echo "Missing remote PyroWave pacing checker: ${CHECKER_FILE}" >&2
    exit 1
fi

echo "Checking PyroWave host pacing on ${HOST}"
echo "SSH may request the Bazzite account password."

scp "${CHECKER_FILE}" "${HOST}:${REMOTE_CHECKER}"
ssh -tt "${HOST}" "bash '${REMOTE_CHECKER}'"
