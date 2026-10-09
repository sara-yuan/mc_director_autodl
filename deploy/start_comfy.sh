#!/usr/bin/env bash
DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$(cat "$DIR/python_path.txt")"
PORT="${1:-8188}"
MODE="${2:-}"
if [ -z "$MODE" ] && [ -f "$DIR/comfy_mode.txt" ]; then
  MODE="$(cat "$DIR/comfy_mode.txt")"
fi
if [ -z "$MODE" ]; then MODE="lowvram"; fi
case "$MODE" in
  novram|cpu) FLAG="--novram"; EXTRA="--disable-mmap --disable-pinned-memory" ;;
  *) FLAG="--enable-dynamic-vram --reserve-vram 11"; EXTRA="--disable-mmap --fast-disk --disable-pinned-memory" ;;
esac
echo "$MODE" > "$DIR/comfy_mode.txt"
echo "$PORT" > "$DIR/comfy_port.txt"
cd "$DIR/ComfyUI"
PAT="main.py --listen 127.0.0.1 --port $PORT"

# 1) stop previous instance: pid file first, then process-name fallback
if [ -f "$DIR/comfy.pid" ]; then
  OLD="$(cat "$DIR/comfy.pid" 2>/dev/null)"
  case "$OLD" in
    ''|*[!0-9]*) ;;
    *) kill "$OLD" 2>/dev/null ;;
  esac
fi
pkill -f "$PAT" 2>/dev/null
i=0
while [ $i -lt 40 ]; do
  pgrep -f "$PAT" >/dev/null 2>&1 || break
  sleep 0.5
  i=$((i+1))
done
pkill -9 -f "$PAT" 2>/dev/null
rm -f "$DIR/comfy.pid"
sleep 1

# 2) keep the previous session log instead of truncating it
if [ -f "$DIR/comfy.log" ] && [ "$(wc -c < "$DIR/comfy.log" 2>/dev/null || echo 0)" -gt 5242880 ]; then
  mv -f "$DIR/comfy.log" "$DIR/comfy.log.1"
fi

# 3) start
nohup bash -c '
  PYTHONUNBUFFERED=1 "$1" -u main.py --listen 127.0.0.1 --port "$2" $3 $4 2>&1 |
  while IFS= read -r line; do printf "[%s] %s\n" "$(date +%H:%M:%S)" "$line"; done >> "$5"
' _ "$PY" "$PORT" "$FLAG" "$EXTRA" "$DIR/comfy.log" &
WRAP=$!

# 4) record the real main.py pid (the wrapper pid is not the server)
PID=""
i=0
while [ $i -lt 60 ]; do
  PID="$(pgrep -f "$PAT" | head -1)"
  if [ -n "$PID" ]; then break; fi
  sleep 0.5
  i=$((i+1))
done
if [ -n "$PID" ]; then echo "$PID" > "$DIR/comfy.pid"; else echo "$WRAP" > "$DIR/comfy.pid"; fi

# 5) wait until the API really answers, not just until a process exists
OK=""
START_TS=$SECONDS
while : ; do
  CODE="$(curl -s -m 3 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/system_stats" 2>/dev/null)"
  if [ "$CODE" = "200" ]; then OK=1; break; fi
  pgrep -f "$PAT" >/dev/null 2>&1 || break
  if [ $((SECONDS - START_TS)) -ge 150 ]; then break; fi
  sleep 1
done
if [ -n "$OK" ]; then
  echo "COMFY_STARTED pid=$PID port=$PORT mode=$MODE"
  exit 0
fi
echo "COMFY_START_FAILED"
tail -n 80 "$DIR/comfy.log" 2>/dev/null || true
exit 1
