#!/usr/bin/env sh
set -eu

HOME_DIR="${HOME:-/root}"
NANOBOT_HOME="${NANOBOT_HOME:-${HOME_DIR}/.nanobot}"
mkdir -p "$NANOBOT_HOME"

echo "[boot] notion env check: NOTION_API_KEY=${NOTION_API_KEY:+set} NOTION_KEY=${NOTION_KEY:+set} NOTION_DATABASE_ID=${NOTION_DATABASE_ID:+set}" 1>&2
if [ "${NOTION_API_KEY:-}" != "" ]; then
  echo "[boot] notion env len: NOTION_API_KEY=${#NOTION_API_KEY}" 1>&2
fi
if [ "${NOTION_KEY:-}" != "" ]; then
  echo "[boot] notion env len: NOTION_KEY=${#NOTION_KEY}" 1>&2
fi
if [ "${NOTION_DATABASE_ID:-}" != "" ]; then
  echo "[boot] notion env len: NOTION_DATABASE_ID=${#NOTION_DATABASE_ID}" 1>&2
fi

if [ "${NOTION_API_KEY:-}" != "" ] || [ "${NOTION_KEY:-}" != "" ]; then
  mkdir -p "${HOME_DIR}/.config/notion"
  printf "%s" "${NOTION_API_KEY:-$NOTION_KEY}" > "${HOME_DIR}/.config/notion/api_key"
  chmod 600 "${HOME_DIR}/.config/notion/api_key" || true
fi

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

SYNC_EXCLUDES="--exclude workspace-keeplearn/keep-learn-note/* --exclude 'workspace*/.git/*' --exclude 'workspace*/**/.git/*' --exclude '.github-manager.json'"

# Agent control: comma-separated list (default: main,douyin)
# Note: Using START_AGENTS to avoid conflict with nanobot's pydantic-settings
START_AGENTS="${START_AGENTS:-main,douyin}"
echo "[boot] START_AGENTS=${START_AGENTS}"

# Helper: check if agent is enabled
agent_enabled() {
  case ",${START_AGENTS}," in
    *",$1,"*) return 0 ;;
    *) return 1 ;;
  esac
}

aws_cli() {
  aws --endpoint-url "$AWS_ENDPOINT_URL" "$@"
}

# 同步配置与运行时目录（同一个 NANOBOT_HOME 下包含 config.json + config-douyin.json）
echo "[boot] restoring state from ${S3_URI} ..."
aws_cli s3 sync "$S3_URI" "$NANOBOT_HOME" $SYNC_EXCLUDES || true

# 后台同步任务
(
  while true; do
    sleep "$INTERVAL"
    echo "[sync] uploading state to ${S3_URI} ..."
    aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI" $SYNC_EXCLUDES
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
  if [ "${NANOBOT_PID3:-}" != "" ]; then
    kill "$NANOBOT_PID3" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID1:-}" != "" ]; then
    wait "$NANOBOT_PID1" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID2:-}" != "" ]; then
    wait "$NANOBOT_PID2" 2>/dev/null || true
  fi
  if [ "${NANOBOT_PID3:-}" != "" ]; then
    wait "$NANOBOT_PID3" 2>/dev/null || true
  fi
  echo "[shutdown] final sync..."
  aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI" $SYNC_EXCLUDES || true
  if [ "${SYNC_PID1:-}" != "" ]; then
    kill "$SYNC_PID1" 2>/dev/null || true
  fi
  exit 0
}

trap 'shutdown' EXIT INT TERM

# 启动主机器人（端口 18790）
if agent_enabled main; then
  echo "[boot] starting main bot on port 18790..."
  nanobot gateway --config "${NANOBOT_HOME}/config.json" --port 18790 &
  NANOBOT_PID1=$!
fi

# 启动抖音日报机器人（端口 18791）
if agent_enabled douyin; then
  echo "[boot] starting douyin bot on port 18791..."
  nanobot gateway --config "${NANOBOT_HOME}/config-douyin.json" --port 18791 &
  NANOBOT_PID2=$!
fi

# 启动持续学习机器人（端口 18793）
KEEPL_RESTARTS=0
KEEPL_MAX_RESTARTS="${KEEPL_MAX_RESTARTS:-5}"
KEEPL_BACKOFF_SECONDS="${KEEPL_BACKOFF_SECONDS:-5}"

start_keeplearn() {
  echo "[boot] starting keeplearn bot on port 18793..."
  nanobot gateway --config "${NANOBOT_HOME}/config-keeplearn.json" --port 18793 &
  NANOBOT_PID3=$!
}

if agent_enabled keeplearn; then
  start_keeplearn
fi

# 兼容 /bin/sh：持续运行直到任一关键子进程退出
while true; do
  # main bot: critical, exit if dies
  if agent_enabled main && [ "${NANOBOT_PID1:-}" != "" ]; then
    if ! kill -0 "$NANOBOT_PID1" 2>/dev/null; then
      echo "[monitor] main bot exited"
      exit 0
    fi
  fi

  # douyin bot: critical, exit if dies
  if agent_enabled douyin && [ "${NANOBOT_PID2:-}" != "" ]; then
    if ! kill -0 "$NANOBOT_PID2" 2>/dev/null; then
      echo "[monitor] douyin bot exited"
      exit 0
    fi
  fi

  # keeplearn bot: auto-restart on failure
  if agent_enabled keeplearn && [ "${NANOBOT_PID3:-}" != "" ]; then
    if ! kill -0 "$NANOBOT_PID3" 2>/dev/null; then
      KEEPL_EXIT_CODE=0
      wait "$NANOBOT_PID3" 2>/dev/null || KEEPL_EXIT_CODE=$?
      echo "[monitor] keeplearn bot exited (code=${KEEPL_EXIT_CODE})"

      KEEPL_RESTARTS=$((KEEPL_RESTARTS + 1))
      if [ "$KEEPL_RESTARTS" -gt "$KEEPL_MAX_RESTARTS" ]; then
        echo "[monitor] keeplearn reached max restarts (${KEEPL_MAX_RESTARTS}); not restarting"
        NANOBOT_PID3=""
      else
        echo "[monitor] restarting keeplearn in ${KEEPL_BACKOFF_SECONDS}s (attempt ${KEEPL_RESTARTS}/${KEEPL_MAX_RESTARTS})"
        sleep "$KEEPL_BACKOFF_SECONDS"
        KEEPL_BACKOFF_SECONDS=$((KEEPL_BACKOFF_SECONDS * 2))
        start_keeplearn
      fi
    fi
  fi

  # If no agents enabled, exit
  if [ "${NANOBOT_PID1:-}" = "" ] && [ "${NANOBOT_PID2:-}" = "" ] && [ "${NANOBOT_PID3:-}" = "" ]; then
    echo "[monitor] no agents running, exiting"
    exit 0
  fi

  sleep 2
done
