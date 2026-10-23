#!/usr/bin/env bash
set -euo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-gpu-input-log-shadow-repair.patch}"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

SOURCE_ROOT="$HOME/src/sunshine-pyrowave"
INSTALL_ROOT="$HOME/.local/opt/sunshine-pyrowave"
cd "$SOURCE_ROOT"

if grep -q 'pyrowave_device_create_info device_info' src/video.cpp; then
    echo "The log-shadow repair is already present; continuing with the build."
else
    git apply --check "$PATCH_FILE"
    git apply "$PATCH_FILE"
fi

cmake --build build-pyrowave-vanilla --target sunshine

if [ -x "$INSTALL_ROOT/bin/sunshine" ]; then
    cp -p "$INSTALL_ROOT/bin/sunshine" "$INSTALL_ROOT/bin/sunshine.pre-gpu-input"
fi

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 build-pyrowave-vanilla/sunshine "$INSTALL_ROOT/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$INSTALL_ROOT/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "GPU-input log-shadow repair built and installed. Begin with 1280x720@60."
