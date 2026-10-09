#!/usr/bin/env bash
set -uo pipefail
APP_DIR="$(cd "$(dirname "$0")" && pwd)"
PY="$(cat "$APP_DIR/python_path.txt" 2>/dev/null || echo /root/miniconda3/bin/python)"
PORT="${1:-8188}"
FAIL=0
echo "== python =="; "$PY" -V 2>&1
echo "== gpu =="
"$PY" - <<'PY'
import torch
print("cuda_available", torch.cuda.is_available())
print("device_count", torch.cuda.device_count())
if torch.cuda.is_available():
    print("gpu", torch.cuda.get_device_name(0))
    print("vram_gb", round(torch.cuda.get_device_properties(0).total_memory/1024**3,1))
PY
if [ -f /usr/bin/nvidia-smi ] && [ ! -s /usr/bin/nvidia-smi ]; then
  echo "WARN: nvidia-smi 为空占位，AutoDL 处于无卡模式，请重新有卡启动"
  FAIL=1
fi
echo "== deps =="
"$PY" -c "import sqlalchemy, aiohttp, alembic; print('deps ok')" 2>&1 || FAIL=1
echo "== models =="
du -sh "$APP_DIR/ComfyUI/models" 2>/dev/null || { echo "NO_MODELS"; FAIL=1; }
echo "== port $PORT =="
if curl -sf "http://127.0.0.1:$PORT/system_stats" >/dev/null 2>&1; then
  echo "COMFY_LISTENING"
else
  echo "COMFY_NOT_LISTENING"
  FAIL=1
fi
echo "PREFLIGHT_EXIT=$FAIL"
exit $FAIL
