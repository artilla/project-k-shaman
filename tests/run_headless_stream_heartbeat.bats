#!/usr/bin/env bats
# tests/run_headless_stream_heartbeat.bats — T305 스트림 하트비트 회귀 테스트.
#
# claude -p는 도구 호출 중 최종 출력만 버퍼링한다(실측: T017/T018, 2026-07-06~07).
# bash-watchdog 경로(timeout/gtimeout 부재 시 폴백)가 claude를 --output-format
# stream-json --verbose로 실행하고 scripts/lib/heartbeat_capture.mjs를 거치도록
# 바꿔, 텍스트 없는 도구 호출/시스템 이벤트도 output_file 바이트를 흘려 idle
# 워치독의 "output 없음" 오탐을 막는다. node가 없으면 기존 버퍼링 동작으로
# 폴백한다(무회귀).

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  TEST_BIN="$TEST_HOME/bin"
  WORK="$TEST_HOME/work"
  mkdir -p "$TEST_BIN" "$WORK" "$WORK/scripts/lib" "$TEST_HOME/state/reservations/T890.d"

  SCRIPT="$REPO_ROOT/scripts/run_headless.sh"
  FAKE_CLAUDE="$TEST_HOME/fake-claude"
  META="$TEST_HOME/state/reservations/T890.d/meta"
  EVENTS="$TEST_HOME/state/reservations/T890.d/events.jsonl"
  printf 'pgid=unknown\ntimeout_backend=unknown\n' > "$META"
  : > "$EVENTS"
  cp "$REPO_ROOT/scripts/lib/session_events.sh" "$WORK/scripts/lib/session_events.sh"

  cat > "$FAKE_CLAUDE" <<'FAKE'
#!/bin/sh
case "${FAKE_CLAUDE_MODE:-heartbeat}" in
  heartbeat)
    trap 'exit 143' TERM INT
    i=0
    n="${FAKE_CLAUDE_EVENTS:-5}"
    while [ "$i" -lt "$n" ]; do
      printf '{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Bash"}]}}\n'
      sleep "${FAKE_CLAUDE_GAP:-1}"
      i=$((i + 1))
    done
    printf '{"type":"assistant","message":{"content":[{"type":"text","text":"done"}]}}\n'
    ;;
  silent)
    trap 'exit 143' TERM INT
    while :; do sleep 1; done
    ;;
  plain-text)
    echo "plain text answer, not json"
    ;;
  args-dump)
    printf '%s\n' "$@" > "${FAKE_CLAUDE_ARGS_FILE:?}"
    echo "args dumped"
    ;;
  *)
    echo "unknown mode ${FAKE_CLAUDE_MODE}" >&2
    exit 2
    ;;
esac
FAKE
  chmod +x "$FAKE_CLAUDE"

  _link_tool awk
  _link_tool basename
  _link_tool date
  _link_tool dirname
  _link_tool grep
  _link_tool mkdir
  _link_tool mktemp
  _link_tool mv
  _link_tool rm
  _link_tool sleep
  _link_tool tail
  _link_tool tr
  _link_tool wc
  _link_tool node
  if command -v git >/dev/null 2>&1; then
    _link_tool git
  fi
  if command -v pkill >/dev/null 2>&1; then
    _link_tool pkill
  fi
  if command -v perl >/dev/null 2>&1; then
    _link_tool perl
  fi
  if command -v python3 >/dev/null 2>&1; then
    _link_tool python3
  fi
}

teardown() {
  rm -rf "$TEST_HOME"
}

_link_tool() {
  local tool="$1" path
  path="$(command -v "$tool")"
  ln -s "$path" "$TEST_BIN/$tool"
}

_run() {
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_MODEL="fake-model" \
    CLAUDE_HEADLESS="-p" \
    CLAUDE_PERMISSION_MODE="bypassPermissions" \
    CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-20}" \
    CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-2}" \
    RALPH_SESSION_META_FILE="$META" \
    RALPH_STATE_ROOT="$TEST_HOME" \
    FAKE_CLAUDE_MODE="${FAKE_CLAUDE_MODE:-heartbeat}" \
    FAKE_CLAUDE_EVENTS="${FAKE_CLAUDE_EVENTS:-5}" \
    FAKE_CLAUDE_GAP="${FAKE_CLAUDE_GAP:-1}" \
    FAKE_CLAUDE_ARGS_FILE="${FAKE_CLAUDE_ARGS_FILE:-}" \
    /bin/bash "$SCRIPT" "heartbeat test" "$WORK"
}

@test "bash-watchdog path invokes claude with --output-format stream-json --verbose" {
  args_file="$TEST_HOME/argv.txt"
  FAKE_CLAUDE_MODE=args-dump FAKE_CLAUDE_ARGS_FILE="$args_file" _run

  [ "$status" -eq 0 ]
  [ -f "$args_file" ]
  grep -qx -- "--output-format" "$args_file"
  grep -qx -- "stream-json" "$args_file"
  grep -qx -- "--verbose" "$args_file"
}

@test "tool-call-only heartbeats reset the idle timer and the session finishes normally" {
  CLAUDE_IDLE_SECONDS=2 FAKE_CLAUDE_EVENTS=5 FAKE_CLAUDE_GAP=1 _run

  [ "$status" -eq 0 ]
  # NOTE: bash 3.2's `[[ ]]` does not trigger errexit as a bare statement —
  # `|| return 1` makes assertion failure abort the test (verified empirically).
  [[ "$output" == *"done"* ]] || return 1
  [[ "$output" == *"[hb] tool_use:Bash"* ]] || return 1
  if grep -q '"action":"idle-exit"' "$EVENTS"; then return 1; fi
}

@test "genuine silence still idle-exits even with heartbeat wiring active" {
  CLAUDE_IDLE_SECONDS=1 FAKE_CLAUDE_MODE=silent _run

  [ "$status" -eq 125 ]
  [[ "$output" == *"idle after 1s"* ]] || return 1
  grep -q '"action":"idle-exit"' "$EVENTS"
}

@test "non-JSON claude output still passes through unchanged (compat fallback)" {
  FAKE_CLAUDE_MODE=plain-text _run

  [ "$status" -eq 0 ]
  [[ "$output" == *"plain text answer, not json"* ]] || return 1
}

@test "heartbeat_capture.mjs: assistant text passes through, non-text events become [hb] lines, malformed JSON passes through" {
  run node "$REPO_ROOT/scripts/lib/heartbeat_capture.mjs" <<'EOF'
{"type":"system","subtype":"init"}
{"type":"assistant","message":{"content":[{"type":"tool_use","name":"Read","id":"1"}]}}
{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"1"}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"hello "}]}}
{"type":"assistant","message":{"content":[{"type":"text","text":"world"}]}}
not-json-at-all
{"type":"result","usage":{"input_tokens":1}}
EOF

  [ "$status" -eq 0 ]
  [[ "$output" == *"[hb] system:init"* ]] || return 1
  [[ "$output" == *"[hb] tool_use:Read"* ]] || return 1
  [[ "$output" == *"[hb] tool_result:1"* ]] || return 1
  [[ "$output" == *"hello world"* ]] || return 1
  [[ "$output" == *"not-json-at-all"* ]] || return 1
  [[ "$output" == *"[hb] result"* ]] || return 1
}
