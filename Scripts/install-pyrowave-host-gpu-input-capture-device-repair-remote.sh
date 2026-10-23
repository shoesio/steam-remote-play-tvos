#!/usr/bin/env bash
set -euo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-gpu-input-capture-device-repair.patch}"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

SOURCE_ROOT="$HOME/src/sunshine-pyrowave"
INSTALL_ROOT="$HOME/.local/opt/sunshine-pyrowave"
cd "$SOURCE_ROOT"

if grep -q 'selecting Vulkan KMS/DMA-BUF capture device independently' src/video.cpp; then
    echo "The PyroWave capture-device repair is already present; forcing its object to rebuild."
else
    git apply --check "$PATCH_FILE"
    git apply "$PATCH_FILE"
fi

# The checkpoint build intentionally had Vulkan Video disabled because its
# working prototype used software conversion. GPU-native PyroWave needs
# Sunshine's Vulkan KMS/DMA-BUF converter and its capture-device factory even
# though the configured normal codec remains libx264.
cmake -S . -B build-pyrowave-vanilla -DSUNSHINE_ENABLE_VULKAN=ON
grep -q '^SUNSHINE_ENABLE_VULKAN:BOOL=ON' build-pyrowave-vanilla/CMakeCache.txt

# Force Ninja to invalidate video.cpp, then prove the Vulkan-only branch and
# marker reached the executable before stopping the working custom service.
touch src/video.cpp
cmake --build build-pyrowave-vanilla --target sunshine

if ! grep -aFq 'selecting Vulkan KMS/DMA-BUF capture device independently' \
    build-pyrowave-vanilla/sunshine; then
    echo "Built binary does not contain the PyroWave Vulkan capture marker; refusing to install." >&2
    exit 1
fi

if [ -x "$INSTALL_ROOT/bin/sunshine" ]; then
    cp -p "$INSTALL_ROOT/bin/sunshine" "$INSTALL_ROOT/bin/sunshine.pre-capture-device-repair"
fi

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 build-pyrowave-vanilla/sunshine "$INSTALL_ROOT/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$INSTALL_ROOT/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "PyroWave now selects Vulkan KMS/DMA-BUF capture independently of the configured H.264 encoder."
echo "Start a 1280x720@60 PyroWave stream and run Scripts/check-pyrowave-host-pacing.sh."
