#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
HOST="${1:-jhewes@192.168.0.125}"
DESTINATION="${2:-${ROOT_DIR}/HostSnapshots/wolf-bc-250-$(date +%Y%m%d-%H%M%S)}"

mkdir -p "${DESTINATION}"

echo "Snapshotting ${HOST} into ${DESTINATION}"
echo "SSH will prompt for the Bazzite account password once."

ssh -T "${HOST}" 'bash -s' <<'REMOTE_SCRIPT' | tar -xzf - -C "${DESTINATION}"
set -euo pipefail

snapshot_dir="$(mktemp -d)"
trap 'rm -rf "${snapshot_dir}"' EXIT

mkdir -p "${snapshot_dir}/checkpoint"

{
    echo "Captured: $(date --iso-8601=seconds)"
    echo
    echo "=== host ==="
    hostnamectl || true
    echo
    echo "=== rpm-ostree ==="
    rpm-ostree status || true
    echo
    echo "=== Homebrew packages ==="
    if [ -x /home/linuxbrew/.linuxbrew/bin/brew ]; then
        /home/linuxbrew/.linuxbrew/bin/brew list --versions
    fi
    echo
    echo "=== Sunshine source ==="
    for repo in "$HOME/src/sunshine-pyrowave" "$HOME/src/pyrowave"; do
        if [ -d "${repo}/.git" ]; then
            echo "--- ${repo} ---"
            git -C "${repo}" status --short
            git -C "${repo}" rev-parse HEAD
            git -C "${repo}" diff --stat
        fi
    done
    echo
    echo "=== Installed prototype ==="
    sha256sum "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine" 2>/dev/null || true
    getcap "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine" 2>/dev/null || true
    echo
    echo "=== Service ==="
    systemctl --user cat sunshine-pyrowave.service || true
    systemctl --user status sunshine-pyrowave.service --no-pager || true
} > "${snapshot_dir}/checkpoint/host-manifest.txt"

paths=(
    "src/sunshine-pyrowave"
    "src/pyrowave"
    ".local/opt/sunshine-pyrowave"
    ".config/systemd/user/sunshine-pyrowave.service"
    ".config/systemd/user/sunshine-pyrowave.service.d"
)

archive_paths=()
for path in "${paths[@]}"; do
    if [ -e "$HOME/${path}" ]; then
        archive_paths+=("${path}")
    fi
done

cd "$HOME"
tar -czf - "${archive_paths[@]}" -C "${snapshot_dir}" checkpoint
REMOTE_SCRIPT

echo "Host snapshot complete: ${DESTINATION}"
echo "Manifest: ${DESTINATION}/checkpoint/host-manifest.txt"
