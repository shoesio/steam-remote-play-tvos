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

if "CloudNow PyroWave host pacing accepted=" not in source:
    include_marker = "#include <list>\n"
    if "#include <mutex>\n" not in source:
        if include_marker not in source:
            raise SystemExit("Could not find standard-include insertion point")
        source = source.replace(include_marker, include_marker + "#include <mutex>\n", 1)

    method_start = source.find("    bool should_encode_frame() {")
    if method_start < 0:
        raise SystemExit("Could not find PyroWave frame-pacing method")
    brace_start = source.find("{", method_start)
    depth = 0
    method_end = -1
    for index in range(brace_start, len(source)):
        if source[index] == "{":
            depth += 1
        elif source[index] == "}":
            depth -= 1
            if depth == 0:
                method_end = index + 1
                break
    if method_end < 0:
        raise SystemExit("Could not find end of PyroWave frame-pacing method")

    method = source[method_start:method_end]
    if "std::lock_guard pacing_lock {pacing_mutex};" not in method:
        method = method.replace(
            "    bool should_encode_frame() {\n",
            "    bool should_encode_frame() {\n      std::lock_guard pacing_lock {pacing_mutex};\n",
            1,
        )
    if "throttled_frame_count++;" not in method:
        method = method.replace(
            "      if (now < next_encode_time) {\n        return false;\n      }",
            "      if (now < next_encode_time) {\n        throttled_frame_count++;\n        return false;\n      }",
            1,
        )
    method = method.replace(
        "      return true;\n",
        "      accepted_frame_count++;\n"
        "      if (accepted_frame_count % 120 == 0) {\n"
        "        BOOST_LOG(info) << \"CloudNow PyroWave host pacing accepted=\" << accepted_frame_count\n"
        "                        << \" gated=\" << throttled_frame_count\n"
        "                        << \" target=\" << framerate << \" fps\";\n"
        "      }\n"
        "      return true;\n",
        1,
    )
    if "accepted_frame_count" not in method or "throttled_frame_count" not in method:
        raise SystemExit("Could not update PyroWave frame-pacing method")
    source = source[:method_start] + method + source[method_end:]

if (
    "std::mutex pacing_mutex;" not in source
    or "size_t accepted_frame_count = 0;" not in source
    or "size_t throttled_frame_count = 0;" not in source
):
    member_marker = "    std::chrono::steady_clock::time_point next_encode_time {};\n"
    if member_marker not in source:
        raise SystemExit("Could not find PyroWave pacing state insertion point")
    state = ""
    if "std::mutex pacing_mutex;" not in source:
        state += "    std::mutex pacing_mutex;\n"
    if "size_t accepted_frame_count = 0;" not in source:
        state += "    size_t accepted_frame_count = 0;\n"
    if "size_t throttled_frame_count = 0;" not in source:
        state += "    size_t throttled_frame_count = 0;\n"
    source = source.replace(
        member_marker,
        member_marker + state,
        1,
    )

path.write_text(source)
PY

grep -n -C 3 -E 'pacing_mutex|accepted_frame_count|throttled_frame_count|lock_guard' src/video.cpp

cmake --build build-pyrowave-vanilla --target sunshine

systemctl --user stop sunshine-pyrowave.service || true
install -m 0755 build-pyrowave-vanilla/sunshine "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
sudo setcap cap_sys_admin,cap_sys_nice+p "$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"
systemctl --user daemon-reload
systemctl --user start sunshine-pyrowave.service
systemctl --user status sunshine-pyrowave.service --no-pager -l

echo
echo "Pacing lock deployed. Start a PyroWave stream, then run the local pacing check."
