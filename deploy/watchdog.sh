#!/usr/bin/env bash
set -uo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="${1:-8188}"
INTERVAL="${2:-15}"
while true; do
  if ! curl -sf "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
    echo "[$(date '+%F %T')] comfy down, restarting" >> "$DIR/watchdog.log"
    "$DIR/start_comfy.sh" "$PORT" >> "$DIR/watchdog.log" 2>&1 || true
  fi
  sleep "$INTERVAL"
done
