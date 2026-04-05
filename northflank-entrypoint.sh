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

echo "[boot] restoring state from ${S3_URI} ..."
aws_cli s3 sync "$S3_URI" "$NANOBOT_HOME" || true

(
  while true; do
    sleep "$INTERVAL"
    echo "[sync] uploading state to ${S3_URI} ..."
    aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI"
  done
) &

trap 'echo "[shutdown] final sync"; aws_cli s3 sync "$NANOBOT_HOME" "$S3_URI" || true' EXIT INT TERM

exec nanobot gateway --port "${PORT:-18790}"
