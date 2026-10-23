#!/usr/bin/env bash
set -eo pipefail

SOURCE="$HOME/src/sunshine-pyrowave/src/video.cpp"
BINARY="$HOME/.local/opt/sunshine-pyrowave/bin/sunshine"

printf '\n=== Service ===\n'
systemctl --user status sunshine-pyrowave.service --no-pager -l || true

printf '\n=== Source pacing marker ===\n'
grep -n -E 'host frame pacing target|should_encode_frame|next_encode_time|pacing_mutex|accepted_frame_count|throttled_frame_count' "$SOURCE" || true

printf '\n=== Installed binary pacing marker ===\n'
strings "$BINARY" \
  | grep -E 'CloudNow PyroWave host frame pacing target|CloudNow PyroWave host pacing accepted=|selecting Vulkan KMS/DMA-BUF capture device independently' \
  || true

printf '\n=== Recent PyroWave GPU, pacing, and stream logs ===\n'
journalctl --user -u sunshine-pyrowave.service -n 800 --no-pager \
  | grep -iE 'CloudNow PyroWave|PyroWave GPU|PyroWave device|PyroWave input|PyroWave.*encode|Vulkan input|Vulkan frame|ANNOUNCE bitStreamFormat|New streaming|host packet|internal_packets|encoder|error|failed' \
  || true
