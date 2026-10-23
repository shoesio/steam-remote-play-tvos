#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"

exec bash "${ROOT_DIR}/Scripts/deploy-pyrowave-host-transport.sh" \
    "${HOST}" \
    "${ROOT_DIR}/sunshine-pyrowave-async-transport.patch"
