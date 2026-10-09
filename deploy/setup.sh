#!/usr/bin/env bash
set -uo pipefail
APP_DIR="$1"
COMFY_DIR="$APP_DIR/ComfyUI"
MARKER="$APP_DIR/.setup_done"
FAILED="$APP_DIR/.setup_failed"
LOCK="$APP_DIR/.setup.lock"

# 幂等：已成功安装过则直接跳过，避免重复安装耗时。
if [ -f "$MARKER" ] && [ -x "$APP_DIR/start_comfy.sh" ]; then
  echo "SETUP_ALREADY_DONE"
  exit 0
fi
rm -f "$FAILED"
# setup.sh 无论如何退出都要释放锁，避免下次部署被残留锁卡住。
trap 'rm -rf "$LOCK"' EXIT

fail() {
  echo "$1" > "$FAILED"
  echo "$1"
  exit 1
}

if [ -f "$APP_DIR/python_path.txt" ]; then
  PY="$(cat "$APP_DIR/python_path.txt")"
else
  PY=""
  if [ -x "$APP_DIR/python-runtime/bin/python" ]; then PY="$APP_DIR/python-runtime/bin/python"; fi
  if [ -z "$PY" ]; then
    for c in python3 python; do
      if command -v "$c" >/dev/null 2>&1; then PY="$(command -v "$c")"; break; fi
    done
  fi
  if [ -z "$PY" ]; then
    for c in /root/miniconda3/bin/python /opt/conda/bin/python /root/anaconda3/bin/python; do
      if [ -x "$c" ]; then PY="$c"; break; fi
    done
  fi
  if [ -z "$PY" ]; then fail "PYTHON_NOT_FOUND"; fi
  echo "$PY" > "$APP_DIR/python_path.txt"
fi
echo "PYTHON=$PY"
# torch / torchaudio / torchvision：云镜像若不自带 torch（如纯净版/仙公云），按 CUDA 13.x 安装 cu130 版本；
# AutoDL 等镜像已预装 torch 则直接跳过，避免覆盖镜像自带的版本。
echo "INSTALLING_TORCH_CU130"
if "$PY" -c "import torch" >/dev/null 2>&1; then
  echo "TORCH_ALREADY_INSTALLED"
else
  if ! "$PY" -m pip install -q --no-warn-script-location \
      -i https://pypi.tuna.tsinghua.edu.cn/simple \
      --extra-index-url https://download.pytorch.org/whl/cu130 \
      torch==2.11.0+cu130 torchaudio==2.11.0+cu130 torchvision==0.26.0+cu130; then
    fail "SETUP_FAILED_PIP_TORCH_CU130"
  fi
fi
# ComfyUI 基础依赖：失败必须中止并标记，不能再静默跳过导致 ComfyUI 启动缺包。
echo "INSTALLING_REQUIREMENTS"
if [ -d "$COMFY_DIR" ] && [ -f "$COMFY_DIR/requirements.txt" ]; then
  if ! "$PY" -m pip install -q -r "$COMFY_DIR/requirements.txt" --no-warn-script-location -i https://pypi.tuna.tsinghua.edu.cn/simple; then
    echo "RETRY_PYPI_REQUIREMENTS"
    if ! "$PY" -m pip install -q -r "$COMFY_DIR/requirements.txt" --no-warn-script-location; then
      fail "SETUP_FAILED_PIP_REQUIREMENTS"
    fi
  fi
fi
# 自定义节点依赖：视频链路（VHS 需要 cv2/imageio）与 IndexTTS 2.5 配音（librosa/omegaconf/tiktoken/WeTextProcessing 等）
echo "INSTALLING_CUSTOM_DEPS"
CUSTOM_PKGS="opencv-python-headless imageio imageio-ffmpeg scipy librosa soundfile omegaconf munch modelscope ffmpy docstring-parser tiktoken openai-whisper fugashi unidic-lite g2p-en cn2an WeTextProcessing faster-whisper transformers==4.52.1 descript-audiotools"
if ! "$PY" -m pip install -q --no-warn-script-location -i https://pypi.tuna.tsinghua.edu.cn/simple $CUSTOM_PKGS; then
  echo "RETRY_PYPI"
  if ! "$PY" -m pip install -q --no-warn-script-location $CUSTOM_PKGS; then
    fail "SETUP_FAILED_PIP_CUSTOM"
  fi
fi
# SageAttention：H3 采样加速内核，缺失时 ComfyUI 会回退 pytorch attention，单步约 17 分钟。
# 安装失败仅告警不致命（ComfyUI 仍可回退运行），因此不用 fail。
echo "INSTALLING_SAGE_ATTENTION"
if ! "$PY" -m pip install -q --no-warn-script-location -i https://pypi.tuna.tsinghua.edu.cn/simple sageattention==1.0.6; then
  echo "SAGE_RETRY_ALIYUN"
  "$PY" -m pip install -q --no-warn-script-location -i http://mirrors.aliyun.com/pypi/simple --trusted-host mirrors.aliyun.com sageattention==1.0.6 || echo "SAGE_ATTENTION_INSTALL_FAILED"
fi
cat > "$APP_DIR/start_comfy.sh" <<'SH'
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

# SageAttention：H3 采样必须启用，否则回退 pytorch attention 后单步约 17 分钟。
# 仅在包已安装且存在 C 编译器（triton 内核运行时需要）时才开启，避免刷屏与无效重试。
SAGE=""
if "$PY" -c "import sageattention" >/dev/null 2>&1 && (command -v gcc >/dev/null 2>&1 || command -v cc >/dev/null 2>&1 || command -v clang >/dev/null 2>&1); then
  SAGE="--use-sage-attention"
fi

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
  PYTHONUNBUFFERED=1 "$1" -u main.py --listen 127.0.0.1 --port "$2" $3 $4 $6 2>&1 |
  while IFS= read -r line; do printf "[%s] %s\n" "$(date +%H:%M:%S)" "$line"; done >> "$5"
' _ "$PY" "$PORT" "$FLAG" "$EXTRA" "$DIR/comfy.log" "$SAGE" &
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
SH
cat > "$APP_DIR/stop_comfy.sh" <<'SH'
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

SH
chmod +x "$APP_DIR/start_comfy.sh" "$APP_DIR/stop_comfy.sh"
rm -f "$FAILED"
touch "$MARKER"
echo "SETUP_DONE"
