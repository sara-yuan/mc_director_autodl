#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
PORT="$(cat "$DIR/comfy_port.txt" 2>/dev/null)"
if [ -z "$PORT" ]; then PORT="8188"; fi
PAT="main.py --listen 127.0.0.1 --port $PORT"
if [ -f "$DIR/comfy.pid" ]; then
  PID="$(cat "$DIR/comfy.pid" 2>/dev/null)"
  case "$PID" in
    ''|*[!0-9]*) ;;
    *) kill "$PID" 2>/dev/null ;;
  esac
fi
pkill -f "$PAT" 2>/dev/null
i=0
while [ $i -lt 20 ]; do
  pgrep -f "$PAT" >/dev/null 2>&1 || break
  sleep 0.5
  i=$((i+1))
done
pkill -9 -f "$PAT" 2>/dev/null
rm -f "$DIR/comfy.pid"
echo "COMFY_STOPPED"

