#!/usr/bin/env bash
# scripts/mission_control.sh — Mission Control 서버 시작/중지 래퍼
# ADR-0024: localhost 전용, 상태 비보유, 외부 의존성 0
#
# 사용법:
#   ./scripts/mission_control.sh start [--port <n>] [--private-path <iface>]
#   ./scripts/mission_control.sh stop
#   ./scripts/mission_control.sh status

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVER="$ROOT/mission-control/server.mjs"
PID_FILE="$ROOT/state/mission-control.pid"

cmd="${1:-status}"
shift || true

# state/ 디렉터리 보장 (기존 디렉터리와 충돌 없음)
mkdir -p "$ROOT/state"

# ── start ─────────────────────────────────────────────────
do_start() {
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[mission-control] already running (pid $pid)"
      exit 0
    fi
    rm -f "$PID_FILE"
  fi

  node "$SERVER" "$@" &
  echo $! > "$PID_FILE"
  echo "[mission-control] started (pid $(cat "$PID_FILE"))"
}

# ── stop ──────────────────────────────────────────────────
do_stop() {
  if [ ! -f "$PID_FILE" ]; then
    echo "[mission-control] not running"
    exit 0
  fi

  pid="$(cat "$PID_FILE")"
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid"
    # 최대 3초 대기
    for _ in 1 2 3 4 5 6; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.5
    done
  fi
  rm -f "$PID_FILE"
  echo "[mission-control] stopped"
}

# ── status ────────────────────────────────────────────────
do_status() {
  if [ -f "$PID_FILE" ]; then
    pid="$(cat "$PID_FILE")"
    if kill -0 "$pid" 2>/dev/null; then
      echo "[mission-control] running (pid $pid)"
    else
      echo "[mission-control] stale pid file (process not found)"
      rm -f "$PID_FILE"
    fi
  else
    echo "[mission-control] not running"
  fi
}

case "$cmd" in
  start)  do_start "$@" ;;
  stop)   do_stop ;;
  status) do_status ;;
  *)
    echo "Usage: $0 {start|stop|status} [--port <n>] [--private-path <iface>]" >&2
    exit 1
    ;;
esac
