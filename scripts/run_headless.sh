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
#   CLAUDE_IDLE_SECONDS 기본 300
#       bash-group watchdog 경로에서만 적용. 0이면 idle 감지 비활성화.
#       무출력 + 작업 트리 무변화 상태가 지속되면 rc=125로 종료.
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
CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-300}"
RUN_HEADLESS_IDLE_EXIT_CODE=125

# ADR-0050: 토큰 텔레메트리(기본 OFF). RALPH_TOKEN_TELEMETRY=1이면 claude를
# --output-format stream-json으로 실행하고 usage(input/output/cache 토큰)를
# state/token_usage.log에 세션별 append한다. OFF면 기존 동작과 완전히 동일하다
# (텍스트 출력·timeout watchdog·exit code 무변경). stream-json은 NDJSON이라
# usage_capture 필터가 사람이 읽을 텍스트를 stdout으로 흘리며 usage만 추출한다.
# 필터는 항상 exit 0 → pipefail로 claude의 exit code(124 timeout 등)가 전파된다.
# bash-watchdog 폴백 경로(timeout/gtimeout 미존재)는 무변경 — telemetry 미적용.
TOKEN_TELEMETRY="${RALPH_TOKEN_TELEMETRY:-0}"
RUN_HEADLESS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLAUDE_OUTPUT_ARGS=""
[ "$TOKEN_TELEMETRY" = "1" ] && CLAUDE_OUTPUT_ARGS="--output-format stream-json --verbose"
TOKEN_LOG="${RALPH_STATE_ROOT:-$CWD}/state/token_usage.log"
TELEMETRY_TICKET=""
if [ -n "${RALPH_SESSION_META_FILE:-}" ]; then
  _td="$(basename "$(dirname "$RALPH_SESSION_META_FILE")")"; TELEMETRY_TICKET="${_td%.d}"
fi
usage_filter() { node "$RUN_HEADLESS_DIR/lib/usage_capture.mjs" "$TOKEN_LOG" "$TELEMETRY_TICKET" "$CLAUDE_MODEL"; }
[ "$TOKEN_TELEMETRY" = "1" ] && mkdir -p "$(dirname "$TOKEN_LOG")" 2>/dev/null || true

case "$CLAUDE_TIMEOUT_SECONDS" in
  ''|*[!0-9]*)
    echo "ERROR: CLAUDE_TIMEOUT_SECONDS must be a non-negative integer (got '$CLAUDE_TIMEOUT_SECONDS')." >&2
    exit 2
    ;;
esac
case "$CLAUDE_IDLE_SECONDS" in
  ''|*[!0-9]*)
    echo "ERROR: CLAUDE_IDLE_SECONDS must be a non-negative integer (got '$CLAUDE_IDLE_SECONDS')." >&2
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
IDLE_MARKER=$(mktemp "${TMPDIR:-/tmp}/ralph-idle.XXXXXX")
DONE_MARKER=$(mktemp "${TMPDIR:-/tmp}/ralph-done.XXXXXX")
rm -f "$TIMEOUT_MARKER"
rm -f "$IDLE_MARKER"
rm -f "$DONE_MARKER"

cleanup() {
  rm -f "$PROMPT_FILE" "$TIMEOUT_MARKER" "$IDLE_MARKER" "$DONE_MARKER" 2>/dev/null || true
}
trap cleanup EXIT

printf '%s' "$PROMPT" > "$PROMPT_FILE"

write_runtime_meta() {
  local backend="$1" pgid="$2" meta="${RALPH_SESSION_META_FILE:-}" tmp

  [ -n "$meta" ] || return 0
  [ -f "$meta" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-meta.XXXXXX")
  awk -v backend="$backend" -v pgid="$pgid" '
    BEGIN { saw_pgid = 0; saw_backend = 0 }
    /^pgid=/ {
      print "pgid=" pgid
      saw_pgid = 1
      next
    }
    /^timeout_backend=/ {
      print "timeout_backend=" backend
      saw_backend = 1
      next
    }
    { print }
    END {
      if (!saw_pgid) print "pgid=" pgid
      if (!saw_backend) print "timeout_backend=" backend
    }
  ' "$meta" > "$tmp" && mv "$tmp" "$meta"
}

run_claude_no_timeout() {
  write_runtime_meta "none" "unknown"
  if [ "$TOKEN_TELEMETRY" = "1" ]; then
    local rc
    set -o pipefail
    "$CLAUDE_CMD" "$CLAUDE_HEADLESS" $CLAUDE_OUTPUT_ARGS --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" < "$PROMPT_FILE" | usage_filter
    rc=$?
    set +o pipefail
    return "$rc"
  fi
  "$CLAUDE_CMD" "$CLAUDE_HEADLESS" --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" < "$PROMPT_FILE"
}

run_claude_external_timeout() {
  local timeout_cmd="$1" rc
  write_runtime_meta "$timeout_cmd" "unknown"
  set +e
  if [ "$TOKEN_TELEMETRY" = "1" ]; then
    set -o pipefail
    "$timeout_cmd" "$CLAUDE_TIMEOUT_SECONDS" \
      "$CLAUDE_CMD" "$CLAUDE_HEADLESS" $CLAUDE_OUTPUT_ARGS --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE" | usage_filter
    rc=$?
    set +o pipefail
  else
    "$timeout_cmd" "$CLAUDE_TIMEOUT_SECONDS" \
      "$CLAUDE_CMD" "$CLAUDE_HEADLESS" --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE"
    rc=$?
  fi
  set -e
  if [ "$rc" = "124" ] || [ "$rc" = "137" ]; then
    echo "ERROR: run_headless timeout after ${CLAUDE_TIMEOUT_SECONDS}s." >&2
  fi
  return "$rc"
}

session_events_file() {
  local meta="${RALPH_SESSION_META_FILE:-}"

  [ -n "$meta" ] || return 1
  printf '%s\n' "$(dirname "$meta")/events.jsonl"
}

session_watchdog_paused() {
  local events

  events="$(session_events_file)" || return 1
  [ -f "$events" ] || return 1

  awk '
    /"action":"pause"/ { paused = 1 }
    /"action":"resume"/ { paused = 0 }
    END { exit paused ? 0 : 1 }
  ' "$events"
}

worktree_fingerprint() {
  if command -v git >/dev/null 2>&1 && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    {
      git rev-parse HEAD 2>/dev/null || true
      git status --porcelain 2>/dev/null || true
    }
    return 0
  fi

  printf '%s\n' "nogit"
}

file_size() {
  wc -c < "$1" | tr -d '[:space:]'
}

session_id_from_meta() {
  local meta="${RALPH_SESSION_META_FILE:-}" dir base
  [ -n "$meta" ] || return 1
  dir="$(dirname "$meta")"
  base="$(basename "$dir")"
  case "$base" in
    T[0-9][0-9][0-9]*.d) printf '%s\n' "${base%.d}" ;;
    *) return 1 ;;
  esac
}

record_idle_exit_event() {
  local idle_for="$1" id root
  id="$(session_id_from_meta)" || return 0
  root="${RALPH_STATE_ROOT:-${RALPH_ROOT:-$(pwd)}}"

  if [ -f "./scripts/lib/session_events.sh" ]; then
    # shellcheck source=./lib/session_events.sh
    . "./scripts/lib/session_events.sh"
    RALPH_STATE_ROOT="$root" session_event "$id" system "idle-exit" "idle_for=${idle_for}s" 2>/dev/null || true
  fi
}

run_claude_bash_watchdog() {
  local child watcher printer rc group_pid output_file

  output_file=$(mktemp "${TMPDIR:-/tmp}/ralph-claude-output.XXXXXX")
  CLAUDE_OUTPUT_FILE="$output_file"
  start_claude_process_group
  child="$CLAUDE_CHILD_PID"
  group_pid="${CLAUDE_GROUP_PID:-}"
  write_runtime_meta "bash-group" "${group_pid:-unknown}"

  tail -n +1 -f "$output_file" &
  printer=$!

  (
    remaining="$CLAUDE_TIMEOUT_SECONDS"
    last_tick="$(date +%s)"
    last_activity="$last_tick"
    last_output_size="$(file_size "$output_file")"
    last_tree_state="$(worktree_fingerprint)"

    while [ "$remaining" -gt 0 ]; do
      sleep 1 &
      _watcher_sleep=$!
      wait "$_watcher_sleep" 2>/dev/null || true

      if [ -f "$DONE_MARKER" ]; then
        exit 0
      fi

      now_tick="$(date +%s)"
      elapsed=$((now_tick - last_tick))
      last_tick="$now_tick"

      if session_watchdog_paused; then
        last_activity="$now_tick"
        last_output_size="$(file_size "$output_file")"
        last_tree_state="$(worktree_fingerprint)"
        continue
      fi

      current_output_size="$(file_size "$output_file")"
      current_tree_state="$(worktree_fingerprint)"
      if [ "$current_output_size" != "$last_output_size" ] || [ "$current_tree_state" != "$last_tree_state" ]; then
        last_activity="$now_tick"
        last_output_size="$current_output_size"
        last_tree_state="$current_tree_state"
      elif [ "$CLAUDE_IDLE_SECONDS" -gt 0 ] && [ "$((now_tick - last_activity))" -ge "$CLAUDE_IDLE_SECONDS" ]; then
        : > "$IDLE_MARKER"
        record_idle_exit_event "$((now_tick - last_activity))"
        terminate_claude_process_tree "$child" "$group_pid" TERM
        sleep 2
        terminate_claude_process_tree "$child" "$group_pid" KILL
        exit 0
      fi

      if [ "$elapsed" -gt 0 ]; then
        remaining=$((remaining - elapsed))
      fi
    done

    if [ ! -f "$DONE_MARKER" ] && process_scope_alive "$child" "$group_pid"; then
      : > "$TIMEOUT_MARKER"
      terminate_claude_process_tree "$child" "$group_pid" TERM
      sleep 2
      terminate_claude_process_tree "$child" "$group_pid" KILL
    fi
  ) &
  watcher=$!

  set +e
  while kill -0 "$child" 2>/dev/null; do
    if [ -f "$TIMEOUT_MARKER" ] || [ -f "$IDLE_MARKER" ]; then
      terminate_claude_process_tree "$child" "$group_pid" TERM
      sleep 0.2
      terminate_claude_process_tree "$child" "$group_pid" KILL
      break
    fi
    sleep 0.1
  done
  wait "$child"
  rc=$?
  set -e

  if [ -n "$group_pid" ]; then
    while process_group_alive "$group_pid" && [ ! -f "$TIMEOUT_MARKER" ] && [ ! -f "$IDLE_MARKER" ]; do
      sleep 1
    done
  fi
  : > "$DONE_MARKER"

  sleep 0.1
  kill "$printer" 2>/dev/null || true
  wait "$printer" 2>/dev/null || true

  if [ -f "$TIMEOUT_MARKER" ] || [ -f "$IDLE_MARKER" ]; then
    set +e
    wait "$watcher" 2>/dev/null
    set -e
  else
    disown "$watcher" 2>/dev/null || true
    if command -v pkill >/dev/null 2>&1; then
      pkill -TERM -P "$watcher" 2>/dev/null || true
    fi
    kill "$watcher" 2>/dev/null || true
  fi

  rm -f "$output_file" 2>/dev/null || true

  if [ -f "$TIMEOUT_MARKER" ]; then
    echo "ERROR: run_headless timeout after ${CLAUDE_TIMEOUT_SECONDS}s." >&2
    return 124
  fi
  if [ -f "$IDLE_MARKER" ]; then
    echo "ERROR: run_headless idle after ${CLAUDE_IDLE_SECONDS}s without output or worktree changes." >&2
    return "$RUN_HEADLESS_IDLE_EXIT_CODE"
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
      < "$PROMPT_FILE" > "${CLAUDE_OUTPUT_FILE:-/dev/stdout}" 2>&1 &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=setsid -e '
setsid() or die "setsid failed: $!";
exec @ARGV or die "exec failed: $!";
' "$CLAUDE_CMD" "$CLAUDE_HEADLESS" \
      --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE" > "${CLAUDE_OUTPUT_FILE:-/dev/stdout}" 2>&1 &
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
      < "$PROMPT_FILE" > "${CLAUDE_OUTPUT_FILE:-/dev/stdout}" 2>&1 &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  echo "WARN: setsid/gsetsid/perl/python3 not found; timeout can only kill direct child process." >&2
  "$CLAUDE_CMD" "$CLAUDE_HEADLESS" \
    --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
    < "$PROMPT_FILE" > "${CLAUDE_OUTPUT_FILE:-/dev/stdout}" 2>&1 &
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
    kill "-$signal" "$child" 2>/dev/null || true
    if command -v pkill >/dev/null 2>&1; then
      pkill "-$signal" -g "$group_pid" 2>/dev/null || true
    fi
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
