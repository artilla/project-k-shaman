#!/usr/bin/env bats
# ralph/tests/headless_idle_watchdog.bats — T088 idle watchdog regression tests.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  TEST_BIN="$TEST_HOME/bin"
  WORK="$TEST_HOME/work"
  mkdir -p "$TEST_BIN" "$WORK" "$WORK/ralph/scripts/lib" "$TEST_HOME/state/reservations/T880.d"

  git -C "$WORK" init -q
  git -C "$WORK" config user.email "test@example.com"
  git -C "$WORK" config user.name "Test"
  touch "$WORK/tracked.txt"
  git -C "$WORK" add tracked.txt
  git -C "$WORK" commit -q -m init

  SCRIPT="$REPO_ROOT/ralph/scripts/run_headless.sh"
  FAKE_CLAUDE="$TEST_HOME/fake-claude"
  META="$TEST_HOME/state/reservations/T880.d/meta"
  EVENTS="$TEST_HOME/state/reservations/T880.d/events.jsonl"
  printf 'pgid=unknown\ntimeout_backend=unknown\n' > "$META"
  : > "$EVENTS"
  cp "$REPO_ROOT/ralph/scripts/lib/session_events.sh" "$WORK/ralph/scripts/lib/session_events.sh"

  cat > "$FAKE_CLAUDE" <<'FAKE'
#!/bin/sh
case "${FAKE_CLAUDE_MODE:-idle}" in
  idle)
    trap 'exit 143' TERM INT
    while :; do sleep 1; done
    ;;
  write-then-idle)
    trap 'exit 143' TERM INT
    printf 'artifact\n' > artifact.txt
    while :; do sleep 1; done
    ;;
  paused)
    trap 'exit 143' TERM INT
    while :; do sleep 1; done
    ;;
  disabled)
    sleep 1
    echo "idle disabled finished"
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

# T304: 실제 timeout/gtimeout처럼 첫 인자(초)를 버리고 나머지를 그대로 exec하는
# 투과(pass-through) 스텁. 외부 timeout 명령의 실제 하드-타임아웃 강제는 검증
# 대상이 아니다(run_headless.sh 자체 idle 감시가 검증 대상) — 존재 여부만
# command -v로 감지되면 되므로 투과로 충분하다.
_install_timeout_forwarder() {
  local name="$1"
  cat > "$TEST_BIN/$name" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
  chmod +x "$TEST_BIN/$name"
}

_run_idle_watchdog() {
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_MODEL="fake-model" \
    CLAUDE_HEADLESS="-p" \
    CLAUDE_PERMISSION_MODE="bypassPermissions" \
    CLAUDE_TIMEOUT_SECONDS="${CLAUDE_TIMEOUT_SECONDS:-5}" \
    CLAUDE_IDLE_SECONDS="${CLAUDE_IDLE_SECONDS:-1}" \
    RALPH_SESSION_META_FILE="$META" \
    RALPH_STATE_ROOT="$TEST_HOME" \
    FAKE_CLAUDE_MODE="${FAKE_CLAUDE_MODE:-idle}" \
    /bin/bash "$SCRIPT" "idle test" "$WORK"
}

@test "idle watchdog exits with dedicated code and records idle-exit event" {
  _run_idle_watchdog

  [ "$status" -eq 125 ]
  [[ "$output" == *"idle after 1s"* ]]
  grep -q '"action":"idle-exit"' "$EVENTS"
}

@test "CLAUDE_IDLE_SECONDS=0 disables idle detection" {
  CLAUDE_IDLE_SECONDS=0 FAKE_CLAUDE_MODE=disabled _run_idle_watchdog

  [ "$status" -eq 0 ]
  [[ "$output" == *"idle disabled finished"* ]]
  if grep -q '"action":"idle-exit"' "$EVENTS"; then return 1; fi
}

@test "idle exit preserves worktree artifacts written before termination" {
  FAKE_CLAUDE_MODE=write-then-idle _run_idle_watchdog

  [ "$status" -eq 125 ]
  [ -f "$WORK/artifact.txt" ]
  grep -q "artifact" "$WORK/artifact.txt"
}

@test "T304: timeout backend — idle watchdog exits with dedicated code and records idle-exit event" {
  _install_timeout_forwarder timeout
  _run_idle_watchdog

  [ "$status" -eq 125 ]
  [[ "$output" == *"idle after 1s"* ]]
  grep -q '"action":"idle-exit"' "$EVENTS"
}

@test "T304: gtimeout backend — idle watchdog exits with dedicated code and records idle-exit event" {
  _install_timeout_forwarder gtimeout
  _run_idle_watchdog

  [ "$status" -eq 125 ]
  [[ "$output" == *"idle after 1s"* ]]
  grep -q '"action":"idle-exit"' "$EVENTS"
}

@test "T304: gtimeout backend — CLAUDE_IDLE_SECONDS=0 disables idle detection" {
  _install_timeout_forwarder gtimeout
  CLAUDE_IDLE_SECONDS=0 FAKE_CLAUDE_MODE=disabled _run_idle_watchdog

  [ "$status" -eq 0 ]
  [[ "$output" == *"idle disabled finished"* ]]
  if grep -q '"action":"idle-exit"' "$EVENTS"; then return 1; fi
}

@test "T304: gtimeout backend — idle exit preserves worktree artifacts written before termination" {
  _install_timeout_forwarder gtimeout
  FAKE_CLAUDE_MODE=write-then-idle _run_idle_watchdog

  [ "$status" -eq 125 ]
  [ -f "$WORK/artifact.txt" ]
  grep -q "artifact" "$WORK/artifact.txt"
}

@test "paused sessions do not advance idle clock" {
  printf '{"ts":"2026-06-11T21:00:00+09:00","actor":"human","action":"pause","detail":"test"}\n' > "$EVENTS"

  output_file="$TEST_HOME/paused.out"
  env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_MODEL="fake-model" \
    CLAUDE_HEADLESS="-p" \
    CLAUDE_PERMISSION_MODE="bypassPermissions" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    CLAUDE_IDLE_SECONDS=1 \
    RALPH_SESSION_META_FILE="$META" \
    RALPH_STATE_ROOT="$TEST_HOME" \
    FAKE_CLAUDE_MODE=paused \
    /bin/bash "$SCRIPT" "idle test" "$WORK" > "$output_file" 2>&1 &
  runner=$!

  sleep 2
  kill -0 "$runner"
  if grep -q '"action":"idle-exit"' "$EVENTS"; then return 1; fi

  printf '{"ts":"2026-06-11T21:00:03+09:00","actor":"human","action":"resume","detail":"test"}\n' >> "$EVENTS"

  set +e
  wait "$runner"
  rc=$?
  set -e

  [ "$rc" -eq 125 ]
  grep -q '"action":"idle-exit"' "$EVENTS"
  grep -q "idle after 1s" "$output_file"
}
