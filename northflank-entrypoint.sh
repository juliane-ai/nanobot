#!/usr/bin/env sh
set -eu

NANOBOT_HOME="${NANOBOT_HOME:-/root/.nanobot}"
mkdir -p "$NANOBOT_HOME"

PYTHON_BIN="${PYTHON_BIN:-python3}"
if ! command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  PYTHON_BIN="python"
fi

if command -v "$PYTHON_BIN" >/dev/null 2>&1; then
  if ! "$PYTHON_BIN" -c 'import lark_oapi' >/dev/null 2>&1; then
    if [ "${AUTO_INSTALL_PY_DEPS:-0}" = "1" ]; then
      "$PYTHON_BIN" -m pip install --no-cache-dir lark-oapi || true
    fi
  fi
fi

: "${S3_BUCKET:?S3_BUCKET is required}"
: "${S3_PREFIX:?S3_PREFIX is required}"
: "${AWS_ENDPOINT_URL:?AWS_ENDPOINT_URL is required}"

S3_URI="s3://${S3_BUCKET}/${S3_PREFIX}"
INTERVAL="${SYNC_INTERVAL_SECONDS:-120}"

aws_cli() {
  aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"
}

# 同步配置与运行时目录（同一个 NANOBOT_HOME 下包含 config.json + config-douyin.json）
echo "[boot] restoring state from ${S3_URI} ..."
aws_cli s3 sync "$S3_URI" "$NANOBOT_HOME" || true

# 后台同步任务
(
  while true; do
    sleep "$INTERVAL"
    echo "[sync] uploading state to ${S3_URI} ..."
    aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI"
  done
) &
SYNC_PID1=$!

# 信号处理：停止所有进程并同步
shutdown() {
  echo "[shutdown] stopping all instances..."
  if [ "${NANOBOT_PID1:-}" != "" ]; then
    kill "$NANOBOT_PID1" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID2:-}" != "" ]; then
    kill "$NANOBOT_PID2" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID1:-}" != "" ]; then
    wait "$NANOBOT_PID1" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID2:-}" != "" ]; then
    wait "$NANOBOT_PID2" 2>/dev/null || true
  fi
  echo "[shutdown] final sync..."
  aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI" || true
  if [ "${SYNC_PID1:-}" != "" ]; then
    kill "$SYNC_PID1" 2>/dev/null || true
  fi
  exit 0
}

trap 'shutdown' EXIT INT TERM

# 启动主机器人（端口 18790）
echo "[boot] starting main bot on port 18790..."
nanobot gateway --config "${NANOBOT_HOME}/config.json" --port 18790 &
NANOBOT_PID1=$!

# 启动抖音日报机器人（端口 18791）
echo "[boot] starting douyin bot on port 18791..."
nanobot gateway --config "${NANOBOT_HOME}/config-douyin.json" --port 18791 &
NANOBOT_PID2=$!

# 兼容 /bin/sh：持续运行直到任一子进程退出
while true; do
  if ! kill -0 "$NANOBOT_PID1" 2>/dev/null; then
    echo "[monitor] main bot exited"
    exit 0
  fi
  if ! kill -0 "$NANOBOT_PID2" 2>/dev/null; then
    echo "[monitor] douyin bot exited"
    exit 0
  fi
  sleep 2
done
