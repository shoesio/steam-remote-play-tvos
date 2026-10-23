#!/usr/bin/env bash
set -euo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-gpu-input.patch}"

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

SOURCE_ROOT="$HOME/src/sunshine-pyrowave"
INSTALL_ROOT="$HOME/.local/opt/sunshine-pyrowave"
cd "$SOURCE_ROOT"

if ! grep -q 'pyrowave_encoder_encode_cpu_synchronous' src/video.cpp; then
    echo "The expected working CPU PyroWave checkpoint is not present; refusing to patch." >&2
    exit 1
fi

git apply --check "$PATCH_FILE"
git apply "$PATCH_FILE"
cmake -S . -B build-pyrowave-vanilla -DSUNSHINE_ENABLE_VULKAN=ON
grep -q '^SUNSHINE_ENABLE_VULKAN:BOOL=ON' build-pyrowave-vanilla/CMakeCache.txt
cmake --build build-pyrowave-vanilla --target sunshine

if ! grep -aFq 'selecting Vulkan KMS/DMA-BUF capture device independently' \
    build-pyrowave-vanilla/sunshine; then
    echo "Built binary does not contain the PyroWave Vulkan capture marker; refusing to install." >&2
    exit 1
fi

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
echo "GPU-input build installed. Start with a 1280x720@60 PyroWave stream and inspect CloudNow PyroWave timing logs."
echo "CPU rollback remains available by adding SUNSHINE_PYROWAVE_FORCE_CPU=1 to the custom service environment."
