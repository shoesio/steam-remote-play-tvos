#!/usr/bin/env bash
set -eo pipefail

export PATH="/home/linuxbrew/.linuxbrew/bin:/home/linuxbrew/.linuxbrew/sbin:$PATH"
export HOMEBREW_PREFIX="/home/linuxbrew/.linuxbrew"
export PKG_CONFIG_PATH="$HOMEBREW_PREFIX/lib/pkgconfig:$HOMEBREW_PREFIX/share/pkgconfig"
export LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="$HOMEBREW_PREFIX/lib:${LD_LIBRARY_PATH:-}"
export CMAKE_PREFIX_PATH="$HOMEBREW_PREFIX:${CMAKE_PREFIX_PATH:-}"

cd "$HOME/src/sunshine-pyrowave"

python3 - <<'PY'
from pathlib import Path

path = Path("src/video.cpp")
source = path.read_text()
marker = "CloudNow 60 fps capture bypass"

if marker not in source:
    method_start = source.find("    bool should_encode_frame() {")
    if method_start < 0:
        raise SystemExit("Could not find PyroWave frame-pacing method")
    lock = "      std::lock_guard pacing_lock {pacing_mutex};\n"
    lock_at = source.find(lock, method_start)
    if lock_at < 0:
        raise SystemExit("Expected the deployed PyroWave pacing lock")
    insertion = lock_at + len(lock)
    bypass = (
        "      // CloudNow 60 fps capture bypass: the capture loop is already capped at 60 Hz.\n"
        "      // Applying an exact second 60 Hz deadline rejects callbacks that arrive a\n"
        "      // fraction early and aliases the stream down to roughly 38 fps.\n"
        "      if (framerate >= 60) {\n"
        "        accepted_frame_count++;\n"
        "        if (accepted_frame_count % 120 == 0) {\n"
        "          BOOST_LOG(info) << \"CloudNow PyroWave host pacing accepted=\" << accepted_frame_count\n"
        "                          << \" gated=\" << throttled_frame_count\n"
        "                          << \" target=\" << framerate << \" fps\";\n"
        "        }\n"
        "        return true;\n"
        "      }\n"
    )
    source = source[:insertion] + bypass + source[insertion:]
    path.write_text(source)

if marker not in path.read_text():
    raise SystemExit("60 fps pacing correction was not installed")
PY

grep -n -A 18 -B 2 'CloudNow 60 fps capture bypass' src/video.cpp

cmake --build build-pyrowave-vanilla --target sunshine

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 build-pyrowave-vanilla/sunshine "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "60 fps pacing correction deployed."
