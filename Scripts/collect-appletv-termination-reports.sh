#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DEVICE="${1:-Living Room}"
STAMP="$(date +%Y%m%d-%H%M%S)"
DESTINATION="${2:-${ROOT_DIR}/Diagnostics/AppleTVCrashReports/${STAMP}}"
DEVICECTL="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}/usr/bin/devicectl"

mkdir -p "${DESTINATION}"

echo "Collecting Apple TV termination reports from ${DEVICE}"
"${DEVICECTL}" device copy from \
    --device "${DEVICE}" \
    --domain-type systemCrashLogs \
    --source . \
    --destination "${DESTINATION}"

echo
echo "CloudNow, Jetsam, and CPU-resource reports:"
find "${DESTINATION}" -maxdepth 1 -type f \( \
    -name 'CloudNow*.ips' -o \
    -name 'JetsamEvent*.ips' -o \
    -name '*cpu_resource*.ips' \
\) -print | sort
