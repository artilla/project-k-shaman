#!/usr/bin/env bash
# run_headless.sh — 단일 헤드리스 Claude 세션 1회 실행.
# 메인 오케스트레이터(orchestrator.sh)나 run_loop.sh에서 호출된다.
#
# 환경 변수:
#   CLAUDE_CMD          기본 "claude"
#   CLAUDE_MODEL        기본 "sonnet" (claude-sonnet-4-6 등 지정 가능)
#   CLAUDE_HEADLESS     기본 "-p" (one-shot 비대화 모드)
#   CLAUDE_PERMISSION_MODE 기본 "bypassPermissions"
#       (헤드리스 루프가 Edit/Bash/git commit까지 완료하도록 권한 프롬프트를 만들지 않음)
#   CLAUDE_TIMEOUT_SECONDS 기본 1200 (ADR-0017 방향 A: 보수적 2배)
#       0이면 timeout 비활성화.
#       timeout → gtimeout → process-group bash watchdog 순서로 실행 제한.
#
# 사용:
#   ./scripts/run_headless.sh "프롬프트 문자열" [작업 디렉터리]
#
# stdout: Claude의 응답
# exit:   Claude 명령의 exit code

set -euo pipefail

PROMPT="${1:?usage: run_headless.sh <prompt> [cwd]}"
CWD="${2:-$(pwd)}"

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
CLAUDE_HEADLESS="${CLAUDE_HEADLESS:--p}"
CLAUDE_PERMISSION_MODE="${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-1200}"

case "$CLAUDE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "ERROR: CLAUDE_TIMEOUT_SECONDS must be a non-negative integer (got '$CLAUDE_TIMEOUT_SECONDS')." >&2
    exit 2
    ;;
esac

if ! command -v "$CLAUDE_CMD" >/dev/null 2>&1; then
  echo "ERROR: '$CLAUDE_CMD' not found on PATH." >&2
  echo "       Install Claude Code: https://docs.claude.com" >&2
  exit 127
fi

cd "$CWD"

PROMPT_FILE=$(mktemp "${TMPDIR:-/tmp}/ralph-prompt.XXXXXX")
TIMEOUT_MARKER=$(mktemp "${TMPDIR:-/tmp}/ralph-timeout.XXXXXX")
DONE_MARKER=$(mktemp "${TMPDIR:-/tmp}/ralph-done.XXXXXX")
rm -f "$TIMEOUT_MARKER"
rm -f "$DONE_MARKER"

cleanup() {
  rm -f "$PROMPT_FILE" "$TIMEOUT_MARKER" "$DONE_MARKER" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s' "$PROMPT" > "$PROMPT_FILE"

run_claude_no_timeout() {
  "$CLAUDE_CMD" "$CLAUDE_HEADLESS" --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" < "$PROMPT_FILE"
}

run_claude_external_timeout() {
  local timeout_cmd="$1" rc
  set +e
  "$timeout_cmd" "$CLAUDE_TIMEOUT_SECONDS" \
    "$CLAUDE_CMD" "$CLAUDE_HEADLESS" --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
    < "$PROMPT_FILE"
  rc=$?
  set -e
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "ERROR: run_headless timeout after ${CLAUDE_TIMEOUT_SECONDS}s." >&2
  fi
  return "$rc"
}

run_claude_bash_watchdog() {
  local child watcher rc group_pid

  start_claude_process_group
  child="$CLAUDE_CHILD_PID"
  group_pid="${CLAUDE_GROUP_PID:-}"

  (
    sleep "$CLAUDE_TIMEOUT_SECONDS"
    if [ ! -f "$DONE_MARKER" ] && process_scope_alive "$child" "$group_pid"; then
      : > "$TIMEOUT_MARKER"
      terminate_claude_process_tree "$child" "$group_pid" TERM
      sleep 2
      terminate_claude_process_tree "$child" "$group_pid" KILL
    fi
  ) &
  watcher=$!

  set +e
  wait "$child"
  rc=$?
  set -e

  if [ -n "$group_pid" ]; then
    while process_group_alive "$group_pid" && [ ! -f "$TIMEOUT_MARKER" ]; do
      sleep 1
    done
  fi
  : > "$DONE_MARKER"

  if [ -f "$TIMEOUT_MARKER" ]; then
    set +e
    wait "$watcher" 2>/dev/null
    set -e
  else
    if command -v pkill >/dev/null 2>&1; then
      pkill -TERM -P "$watcher" 2>/dev/null || true
    fi
    kill "$watcher" 2>/dev/null || true
  fi

  if [ -f "$TIMEOUT_MARKER" ]; then
    echo "ERROR: run_headless timeout after ${CLAUDE_TIMEOUT_SECONDS}s." >&2
    return 124
  fi

  return "$rc"
}

start_claude_process_group() {
  local setsid_cmd=""

  if command -v setsid >/dev/null 2>&1; then
    setsid_cmd="setsid"
  elif command -v gsetsid >/dev/null 2>&1; then
    setsid_cmd="gsetsid"
  fi

  if [ -n "$setsid_cmd" ]; then
    "$setsid_cmd" "$CLAUDE_CMD" "$CLAUDE_HEADLESS" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE" &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import os
import subprocess
import sys

os.setsid()
proc = subprocess.Popen(sys.argv[1:], stdin=sys.stdin)
sys.exit(proc.wait())
' "$CLAUDE_CMD" "$CLAUDE_HEADLESS" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE" &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  echo "WARN: setsid/gsetsid/python3 not found; timeout can only kill direct child process." >&2
  "$CLAUDE_CMD" "$CLAUDE_HEADLESS" \
    --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
    < "$PROMPT_FILE" &
  CLAUDE_CHILD_PID=$!
  CLAUDE_GROUP_PID=""
}

process_scope_alive() {
  local child="$1"
  local group_pid="$2"

  if [ -n "$group_pid" ]; then
    process_group_alive "$group_pid"
    return
  fi

  kill -0 "$child" 2>/dev/null
}

process_group_alive() {
  local group_pid="$1"
  kill -0 -- "-$group_pid" 2>/dev/null
}

terminate_claude_process_tree() {
  local child="$1"
  local group_pid="$2"
  local signal="$3"

  if [ -n "$group_pid" ]; then
    kill "-$signal" -- "-$group_pid" 2>/dev/null || true
    return
  fi

  if command -v pkill >/dev/null 2>&1; then
    pkill "-$signal" -P "$child" 2>/dev/null || true
  fi
  kill "-$signal" "$child" 2>/dev/null || true
}

# 100% Fresh context: 매번 새 프로세스. 외부에서 컨텍스트가 새는 경로 없음.
# stdin으로 프롬프트 전달 → 인용 이슈 회피.
if [ "$CLAUDE_TIMEOUT_SECONDS" = "0" ]; then
  run_claude_no_timeout
elif command -v timeout >/dev/null 2>&1; then
  run_claude_external_timeout timeout
elif command -v gtimeout >/dev/null 2>&1; then
  run_claude_external_timeout gtimeout
else
  run_claude_bash_watchdog
fi
