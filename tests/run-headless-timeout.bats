#!/usr/bin/env bats
# tests/run-headless-timeout.bats — run_headless.sh timeout wrapper regression tests.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  TEST_BIN="$TEST_HOME/bin"
  mkdir -p "$TEST_BIN" "$TEST_HOME/work"

  SCRIPT="$REPO_ROOT/scripts/run_headless.sh"
  FAKE_CLAUDE="$TEST_HOME/fake-claude"

  cat > "$FAKE_CLAUDE" <<'EOF'
#!/bin/sh
case "${FAKE_CLAUDE_MODE:-ok}" in
  ok)
    echo "fake claude ok"
    exit 0
    ;;
  echo-input)
    while IFS= read -r line || [ -n "$line" ]; do
      echo "prompt:$line"
    done
    exit 0
    ;;
  sleep)
    trap 'exit 143' TERM INT
    sleep "${FAKE_CLAUDE_SLEEP:-5}" &
    wait $!
    echo "fake claude slept"
    exit 0
    ;;
  spawn-grandchild)
    trap 'exit 143' TERM INT
    (
      (
        trap '' TERM INT
        while :; do
          sleep 1
        done
      ) &
      echo "$!" > "${FAKE_CLAUDE_GRANDCHILD_PID_FILE:?}"
      wait $!
    ) &
    wait $!
    ;;
  fail)
    echo "fake claude failed" >&2
    exit 42
    ;;
  *)
    echo "unknown FAKE_CLAUDE_MODE=${FAKE_CLAUDE_MODE}" >&2
    exit 2
    ;;
esac
EOF
  chmod +x "$FAKE_CLAUDE"

  _link_tool mktemp
  _link_tool rm
  _link_tool sleep
  _link_tool date
  if command -v pkill >/dev/null 2>&1; then
    _link_tool pkill
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

_write_timeout_wrapper() {
  local name="$1"
  local marker="$2"
  cat > "$TEST_BIN/$name" <<EOF
#!/bin/sh
echo "$name:\$1" >> "$marker"
shift
exec "\$@"
EOF
  chmod +x "$TEST_BIN/$name"
}

_run_headless() {
  run env \
    PATH="$PATH" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_MODEL="fake-model" \
    CLAUDE_HEADLESS="-p" \
    CLAUDE_PERMISSION_MODE="bypassPermissions" \
    "$SCRIPT" "$1" "$TEST_HOME/work"
}

@test "normal command succeeds and preserves stdout under timeout wrapper" {
  _run_headless "hello"

  [ "$status" -eq 0 ]
  [[ "$output" == *"fake claude ok"* ]]
}

@test "prompt is still passed on stdin" {
  run env \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    FAKE_CLAUDE_MODE="echo-input" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    "$SCRIPT" "hello prompt" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  [[ "$output" == *"prompt:hello prompt"* ]]
}

@test "CLAUDE_TIMEOUT_SECONDS=0 disables timeout" {
  run env \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    FAKE_CLAUDE_MODE="sleep" \
    FAKE_CLAUDE_SLEEP=1 \
    CLAUDE_TIMEOUT_SECONDS=0 \
    "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  [[ "$output" == *"fake claude slept"* ]]
}

@test "prefers timeout command when available" {
  marker="$TEST_HOME/timeout-marker"
  _write_timeout_wrapper timeout "$marker"

  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  grep -q "timeout:5" "$marker"
}

@test "uses gtimeout when timeout is absent" {
  marker="$TEST_HOME/gtimeout-marker"
  _write_timeout_wrapper gtimeout "$marker"

  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  grep -q "gtimeout:5" "$marker"
}

@test "bash watchdog fallback does not delay successful command" {
  start="$(date +%s)"
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"
  end="$(date +%s)"

  [ "$status" -eq 0 ]
  [[ "$output" == *"fake claude ok"* ]]
  [ "$((end - start))" -lt 3 ]
}

@test "bash watchdog fallback does not emit Terminated noise when command exits early" {
  # Force bash watchdog path (no timeout/gtimeout in TEST_BIN).
  # When the watcher sleep is killed without disown, bash may print
  # "Terminated: 15  sleep N" to stderr on exit.  Verify it is silent.
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS=5 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  [[ "$output" != *"Terminated"* ]]
}

@test "bash watchdog fallback times out long-running command" {
  start="$(date +%s)"
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    FAKE_CLAUDE_MODE="sleep" \
    FAKE_CLAUDE_SLEEP=5 \
    CLAUDE_TIMEOUT_SECONDS=1 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"
  end="$(date +%s)"

  [ "$status" -ne 0 ]
  [ "$status" -eq 124 ]
  [[ "$output" == *"timeout after 1s"* ]]
  [ "$((end - start))" -lt 5 ]
}

@test "bash watchdog fallback kills spawned grandchild process tree" {
  if ! command -v python3 >/dev/null 2>&1; then
    skip "python3 is required for process-group fallback on this platform"
  fi

  grandchild_pid_file="$TEST_HOME/grandchild.pid"
  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    FAKE_CLAUDE_MODE="spawn-grandchild" \
    FAKE_CLAUDE_GRANDCHILD_PID_FILE="$grandchild_pid_file" \
    CLAUDE_TIMEOUT_SECONDS=1 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 124 ]
  [[ "$output" == *"timeout after 1s"* ]]
  [ -s "$grandchild_pid_file" ]

  grandchild_pid="$(cat "$grandchild_pid_file")"
  sleep 1
  if kill -0 "$grandchild_pid" 2>/dev/null; then
    kill -KILL "$grandchild_pid" 2>/dev/null || true
    return 1
  fi
}

@test "invalid timeout value exits with usage error" {
  run env \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS="abc" \
    "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 2 ]
  [[ "$output" == *"CLAUDE_TIMEOUT_SECONDS"* ]]
}

@test "default CLAUDE_TIMEOUT_SECONDS is 1200 when env var is unset" {
  marker="$TEST_HOME/default-marker"
  _write_timeout_wrapper timeout "$marker"

  run env -u CLAUDE_TIMEOUT_SECONDS \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  grep -q "timeout:1200" "$marker"
}

@test "CLAUDE_TIMEOUT_SECONDS=300 env override is respected" {
  marker="$TEST_HOME/override-marker"
  _write_timeout_wrapper timeout "$marker"

  run env \
    PATH="$TEST_BIN" \
    CLAUDE_CMD="$FAKE_CLAUDE" \
    CLAUDE_TIMEOUT_SECONDS=300 \
    /bin/bash "$SCRIPT" "x" "$TEST_HOME/work"

  [ "$status" -eq 0 ]
  grep -q "timeout:300" "$marker"
}
