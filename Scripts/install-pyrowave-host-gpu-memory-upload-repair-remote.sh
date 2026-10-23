#!/usr/bin/env bash
set -euo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-gpu-input-memory-upload-repair.patch}"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

SOURCE_ROOT="$HOME/src/sunshine-pyrowave"
INSTALL_ROOT="$HOME/.local/opt/sunshine-pyrowave"
BUILD_ROOT="$SOURCE_ROOT/build-pyrowave-vanilla"
cd "$SOURCE_ROOT"

if ! grep -q 'CloudNow PyroWave adaptive feedback configured=' src/stream.cpp; then
    echo "The adaptive PyroWave checkpoint is not present; refusing to patch." >&2
    exit 1
fi

if grep -q 'CloudNow PyroWave using PipeWire memory capture' src/video.cpp; then
    echo "The PyroWave Vulkan memory-upload repair is already present; rebuilding it."
else
    git apply --check "$PATCH_FILE"
    git apply "$PATCH_FILE"
fi

cmake -S . -B "$BUILD_ROOT" -DSUNSHINE_ENABLE_VULKAN=ON
grep -q '^SUNSHINE_ENABLE_VULKAN:BOOL=ON' "$BUILD_ROOT/CMakeCache.txt"
touch src/video.cpp
cmake --build "$BUILD_ROOT" --target sunshine -- -j1

if ! grep -aFq 'CloudNow PyroWave using PipeWire memory capture' "$BUILD_ROOT/sunshine"; then
    echo "Built binary lacks the Vulkan memory-upload marker; refusing to install." >&2
    exit 1
fi

if [ -x "$INSTALL_ROOT/bin/sunshine" ]; then
    cp -p "$INSTALL_ROOT/bin/sunshine" "$INSTALL_ROOT/bin/sunshine.pre-gpu-memory-upload"
fi

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 "$BUILD_ROOT/sunshine" "$INSTALL_ROOT/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$INSTALL_ROOT/bin/sunshine"
systemctl --user daemon-reload
systemctl --user reset-failed sunshine-pyrowave.service
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "Installed the Gamescope memory-to-Vulkan upload repair only for sunshine-pyrowave."
