#!/usr/bin/env sh
set -eu

NANOBOT_HOME="${NANOBOT_HOME:-/root/.nanobot}"
mkdir -p "$NANOBOT_HOME"

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
  kill $NANOBOT_PID1 $NANOBOT_PID2 2>/dev/null || true
  wait $NANOBOT_PID1 $NANOBOT_PID2 2>/dev/null || true
  echo "[shutdown] final sync..."
  aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI" || true
  kill $SYNC_PID1 2>/dev/null || true
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

# 等待任意进程退出
wait -n $NANOBOT_PID1 $NANOBOT_PID2 2>/dev/null || true
