#!/usr/bin/env bash
set -eo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-transport.patch}"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

cd "$HOME/src/sunshine-pyrowave"
git apply --check "$PATCH_FILE"
git apply "$PATCH_FILE"

cmake --build build-pyrowave-vanilla --target sunshine

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 build-pyrowave-vanilla/sunshine "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "Start a PyroWave stream now. The first host frames should report internal_packets."
