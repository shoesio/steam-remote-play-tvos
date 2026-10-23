#!/usr/bin/env bash
set -euo pipefail

PATCH_FILE="${1:?Expected path to sunshine-pyrowave-adaptive-bitrate.patch}"

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

if ! grep -q 'CloudNow PyroWave GPU input initialized' src/video.cpp; then
    echo "The required GPU-native PyroWave checkpoint is not present; refusing to patch." >&2
    exit 1
fi

if grep -q 'CloudNow PyroWave adaptive feedback configured=' src/stream.cpp; then
    echo "The PyroWave adaptive-bitrate update is already present; forcing relevant objects to rebuild."

    # Repair the first deployed revision, which referenced the enclosing stream
    # config instead of its video monitor config and therefore did not compile.
    if grep -q 'std::max(session->config\.bitrate, 1)' src/stream.cpp; then
        sed -i 's/std::max(session->config\.bitrate, 1)/std::max(session->config.monitor.bitrate, 1)/' src/stream.cpp
        echo "Repaired the PyroWave initial bitrate field path."
    fi
    if grep -q 'session->config\.videoFormat != 3' src/stream.cpp; then
        sed -i 's/session->config\.videoFormat != 3/session->config.monitor.videoFormat != 3/' src/stream.cpp
        echo "Repaired the PyroWave video format field path."
    fi
else
    git apply --check "$PATCH_FILE"
    git apply "$PATCH_FILE"
fi

cmake -S . -B "$BUILD_ROOT" -DSUNSHINE_ENABLE_VULKAN=ON
grep -q '^SUNSHINE_ENABLE_VULKAN:BOOL=ON' "$BUILD_ROOT/CMakeCache.txt"
touch src/globals.h src/video.h src/video.cpp src/stream.cpp
# Keep deployment builds serial so any compiler diagnostic remains adjacent to
# Ninja's failure summary in the user's terminal transcript.
cmake --build "$BUILD_ROOT" --target sunshine -- -j1

if ! grep -aFq 'CloudNow PyroWave adaptive feedback configured=' "$BUILD_ROOT/sunshine"; then
    echo "Built binary does not contain the adaptive-bitrate marker; refusing to install." >&2
    exit 1
fi

if [ -x "$INSTALL_ROOT/bin/sunshine" ]; then
    cp -p "$INSTALL_ROOT/bin/sunshine" "$INSTALL_ROOT/bin/sunshine.pre-adaptive-bitrate"
fi

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 "$BUILD_ROOT/sunshine" "$INSTALL_ROOT/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$INSTALL_ROOT/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "Adaptive bitrate installed only for the separate PyroWave service."
echo "CloudNow Auto can now adjust the format-3 encoder budget without restarting the stream."
