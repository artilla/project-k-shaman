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
#   CLAUDE_IDLE_SECONDS 기본 300 (T304: timeout/gtimeout 경로에도 동일 적용)
#       0이면 idle 감지 비활성화.
#       무출력 + 작업 트리 무변화 상태가 지속되면 rc=125로 종료.
#
# 사용:
#   ./ralph/scripts/run_headless.sh "프롬프트 문자열" [작업 디렉터리]
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
# T305: bash-watchdog 폴백 경로 전용 스트림 하트비트 필터. claude -p가 도구 호출 중
# 최종 출력만 버퍼링해도(§2, T017/T018 실측) NDJSON 이벤트마다 output_file 바이트가
# 흘러 idle 워치독의 활동 판정이 실제 진행과 일치하도록 한다. node 부재 시 폴백은
# build_claude_pipeline_command()에서 처리.
HEARTBEAT_FILTER="$RUN_HEADLESS_DIR/lib/heartbeat_capture.mjs"
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
  local timeout_cmd="$1"

  # T304: idle 감시가 필요 없으면(0) 외부 timeout/gtimeout에 그대로 위임한다 —
  # 무변경 경로.
  if [ "$CLAUDE_IDLE_SECONDS" = "0" ]; then
    run_claude_external_timeout_plain "$timeout_cmd"
    return
  fi

  run_claude_external_timeout_idle "$timeout_cmd"
}

run_claude_external_timeout_plain() {
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

# T304: timeout/gtimeout 경로용 idle 감시. 전체 상한은 외부 timeout 명령이 그대로
# 강제하므로(remaining-초 자체 계산 불필요), 여기서는 bash-watchdog와 동일한
# IDLE_MARKER 메커니즘(출력 바이트 진행 + worktree 지문 변화)만 얹어 무출력
# 상태를 감지하고 rc=125로 조기 회수한다. worktree_fingerprint/file_size/
# session_watchdog_paused/record_idle_exit_event는 아래에 정의되어 있으나, 이
# 스크립트는 실행 시점(파일 맨 아래 dispatch)에만 이 함수들을 호출하므로 정의
# 순서와 무관하게 안전하다.
run_claude_external_timeout_idle() {
  local timeout_cmd="$1" child rc output_file printer watcher
  local last_activity last_output_size last_tree_state now_tick current_output_size current_tree_state

  output_file=$(mktemp "${TMPDIR:-/tmp}/ralph-claude-output.XXXXXX")
  write_runtime_meta "$timeout_cmd" "unknown"

  set +e
  if [ "$TOKEN_TELEMETRY" = "1" ]; then
    (
      set -o pipefail
      "$timeout_cmd" "$CLAUDE_TIMEOUT_SECONDS" \
        "$CLAUDE_CMD" "$CLAUDE_HEADLESS" $CLAUDE_OUTPUT_ARGS --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
        < "$PROMPT_FILE" | usage_filter > "$output_file" 2>&1
    ) &
  else
    "$timeout_cmd" "$CLAUDE_TIMEOUT_SECONDS" \
      "$CLAUDE_CMD" "$CLAUDE_HEADLESS" --permission-mode "$CLAUDE_PERMISSION_MODE" --model "$CLAUDE_MODEL" \
      < "$PROMPT_FILE" > "$output_file" 2>&1 &
  fi
  child=$!
  set -e

  tail -n +1 -f "$output_file" &
  printer=$!

  (
    last_activity="$(date +%s)"
    last_output_size="$(file_size "$output_file")"
    last_tree_state="$(worktree_fingerprint)"

    while kill -0 "$child" 2>/dev/null; do
      sleep 1 &
      wait $! 2>/dev/null || true

      if ! kill -0 "$child" 2>/dev/null; then
        exit 0
      fi

      if session_watchdog_paused; then
        last_activity="$(date +%s)"
        last_output_size="$(file_size "$output_file")"
        last_tree_state="$(worktree_fingerprint)"
        continue
      fi

      now_tick="$(date +%s)"
      current_output_size="$(file_size "$output_file")"
      current_tree_state="$(worktree_fingerprint)"
      if [ "$current_output_size" != "$last_output_size" ] || [ "$current_tree_state" != "$last_tree_state" ]; then
        last_activity="$now_tick"
        last_output_size="$current_output_size"
        last_tree_state="$current_tree_state"
      elif [ "$((now_tick - last_activity))" -ge "$CLAUDE_IDLE_SECONDS" ]; then
        : > "$IDLE_MARKER"
        record_idle_exit_event "$((now_tick - last_activity))"
        kill -TERM "$child" 2>/dev/null || true
        if command -v pkill >/dev/null 2>&1; then
          pkill -TERM -P "$child" 2>/dev/null || true
        fi
        sleep 2
        kill -KILL "$child" 2>/dev/null || true
        if command -v pkill >/dev/null 2>&1; then
          pkill -KILL -P "$child" 2>/dev/null || true
        fi
        exit 0
      fi
    done
  ) &
  watcher=$!

  set +e
  wait "$child"
  rc=$?
  set -e

  sleep 0.1
  kill "$printer" 2>/dev/null || true
  wait "$printer" 2>/dev/null || true

  if [ -f "$IDLE_MARKER" ]; then
    # watcher는 idle 감지 후 이미 exit 0로 스스로 끝났다 — reap만 한다.
    wait "$watcher" 2>/dev/null || true
  else
    disown "$watcher" 2>/dev/null || true
    kill "$watcher" 2>/dev/null || true
    wait "$watcher" 2>/dev/null || true
  fi

  rm -f "$output_file" 2>/dev/null || true

  if [ -f "$IDLE_MARKER" ]; then
    echo "ERROR: run_headless idle after ${CLAUDE_IDLE_SECONDS}s without output or worktree changes." >&2
    return "$RUN_HEADLESS_IDLE_EXIT_CODE"
  fi

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

  if [ -f "./ralph/scripts/lib/session_events.sh" ]; then
    # shellcheck source=./lib/session_events.sh
    . "./ralph/scripts/lib/session_events.sh"
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

# T305: bash-watchdog 경로에서 실행할 전체 쉘 명령 문자열을 만든다.
# claude를 --output-format stream-json --verbose로 강제해 도구 호출·시스템 이벤트도
# NDJSON 한 줄씩 즉시 flush되게 하고, heartbeat_capture.mjs로 걸러 사람이 읽을 텍스트
# (assistant text)는 그대로, 그 외 이벤트는 `[hb] ...` 한 줄로 output_file에 남긴다 —
# idle 워치독이 보는 "output" 판정이 실제 진행과 일치한다(§2 claude -p 최종 출력
# 버퍼링 오탐 수정). node가 없으면 기존 버퍼링 방식으로 폴백(WARN, 무회귀).
# bash -c로 실행되는 단일 문자열이므로 %q로 각 값을 안전하게 쉘 인용한다.
build_claude_pipeline_command() {
  local outfile="${CLAUDE_OUTPUT_FILE:-/dev/stdout}" node_bin="" cmdline

  command -v node >/dev/null 2>&1 && node_bin="$(command -v node)"

  if [ -n "$node_bin" ]; then
    printf -v cmdline '%q %q --output-format stream-json --verbose --permission-mode %q --model %q < %q 2>&1 | %q %q > %q' \
      "$CLAUDE_CMD" "$CLAUDE_HEADLESS" "$CLAUDE_PERMISSION_MODE" "$CLAUDE_MODEL" "$PROMPT_FILE" \
      "$node_bin" "$HEARTBEAT_FILTER" "$outfile"
  else
    echo "WARN: node not found; run_headless idle heartbeat falls back to buffered output (T305)." >&2
    printf -v cmdline '%q %q --permission-mode %q --model %q < %q > %q 2>&1' \
      "$CLAUDE_CMD" "$CLAUDE_HEADLESS" "$CLAUDE_PERMISSION_MODE" "$CLAUDE_MODEL" "$PROMPT_FILE" "$outfile"
  fi

  printf '%s' "$cmdline"
}

start_claude_process_group() {
  local setsid_cmd="" cmdline shell_bin
  cmdline="$(build_claude_pipeline_command)"
  # $BASH: 현재 실행 중인 bash 자신의 절대경로(빌트인 변수) — PATH에 bash가 없는
  # 축소된 테스트/운영 환경에서도 파이프라인 내부 쉘을 안정적으로 찾는다.
  shell_bin="${BASH:-bash}"

  if command -v setsid >/dev/null 2>&1; then
    setsid_cmd="setsid"
  elif command -v gsetsid >/dev/null 2>&1; then
    setsid_cmd="gsetsid"
  fi

  if [ -n "$setsid_cmd" ]; then
    "$setsid_cmd" "$shell_bin" -c "$cmdline" &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  if command -v perl >/dev/null 2>&1; then
    perl -MPOSIX=setsid -e '
setsid() or die "setsid failed: $!";
exec $ARGV[0], "-c", $ARGV[1] or die "exec failed: $!";
' "$shell_bin" "$cmdline" &
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
proc = subprocess.Popen([sys.argv[1], "-c", sys.argv[2]])
sys.exit(proc.wait())
' "$shell_bin" "$cmdline" &
    CLAUDE_CHILD_PID=$!
    CLAUDE_GROUP_PID="$CLAUDE_CHILD_PID"
    return
  fi

  echo "WARN: setsid/gsetsid/perl/python3 not found; timeout can only kill direct child process." >&2
  "$shell_bin" -c "$cmdline" &
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
