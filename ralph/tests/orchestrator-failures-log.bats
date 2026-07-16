#!/usr/bin/env bats
# ralph/tests/orchestrator-failures-log.bats — orchestrator worker failures.log collect regression tests.
#
# Does not invoke real Claude CLI. Uses fake worker worktrees and
# RALPH_TEST_COLLECT_ONLY env-var mode to exercise collect_worker_failures only.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_HOME="$(mktemp -d)"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"

  mkdir -p "$TEST_HOME/ralph/scripts"
  mkdir -p "$TEST_HOME/state"
  mkdir -p "$TEST_HOME/docs/tickets/DONE"
  mkdir -p "$TEST_HOME/.ralph/logs"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
state/
.ralph/
EOF

  cp "$REPO_ROOT/ralph/scripts/orchestrator.sh" "$TEST_HOME/ralph/scripts/orchestrator.sh"
  chmod +x "$TEST_HOME/ralph/scripts/orchestrator.sh"

  touch "$TEST_HOME/docs/master-spec.md"
  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "init"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# Create a fake failures.log in the worker worktree
_make_worker_failures() {
  local id="$1"
  local content="$2"
  local wt_state="$TEST_HOME/.ralph/wt-${id}/state"
  mkdir -p "$wt_state"
  printf '%s\n' "$content" > "$wt_state/failures.log"
}

# Build a 5-field TSV line (args: ticket_id stage message)
_tsv5() {
  printf '%s\t%s\t%s\t%s\t%s' \
    "2026-05-15T00:00:00+00:00" "${1:-T001}" "${2:-claude-exec-failed}" "0" "${3:-test error}"
}

# Run orchestrator in RALPH_TEST_COLLECT_ONLY mode
_run_collect() {
  run env RALPH_TEST_COLLECT_ONLY="$1" \
    bash "$TEST_HOME/ralph/scripts/orchestrator.sh"
}

@test "5-field TSV failure in worker worktree is appended to main state/failures.log" {
  _make_worker_failures "T001" "$(_tsv5 T001 claude-exec-failed 'worker failed')"
  _run_collect "T001"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/state/failures.log" ]

  local line field_count
  line="$(cat "$TEST_HOME/state/failures.log")"
  field_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  [ "$field_count" -eq 5 ]
}

@test "appended line first field is an ISO8601 timestamp" {
  _make_worker_failures "T001" "$(_tsv5 T001 claude-exec-failed 'ts check')"
  _run_collect "T001"

  [ "$status" -eq 0 ]
  local ts
  ts="$(cut -f1 "$TEST_HOME/state/failures.log")"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "missing worker failures.log does not create main state/failures.log" {
  # worker worktree dir exists but no failures.log
  mkdir -p "$TEST_HOME/.ralph/wt-T002/state"
  _run_collect "T002"

  [ "$status" -eq 0 ]
  # main failures.log must not exist or be empty
  if [ -f "$TEST_HOME/state/failures.log" ]; then
    [ ! -s "$TEST_HOME/state/failures.log" ]
  fi
}

@test "empty worker failures.log does not modify main failures.log" {
  mkdir -p "$TEST_HOME/.ralph/wt-T003/state"
  touch "$TEST_HOME/.ralph/wt-T003/state/failures.log"   # empty file
  _run_collect "T003"

  [ "$status" -eq 0 ]
  if [ -f "$TEST_HOME/state/failures.log" ]; then
    [ ! -s "$TEST_HOME/state/failures.log" ]
  fi
}

@test "same worker ID is not appended twice in one collect-only call" {
  _make_worker_failures "T005" "$(_tsv5 T005 claude-exec-failed 'dedupe test')"
  _run_collect "T005,T005"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/state/failures.log" ]
  line_count="$(awk 'END{print NR}' "$TEST_HOME/state/failures.log")"
  [ "$line_count" -eq 1 ]
}

@test "after collect, report_failures.sh can parse the appended failure" {
  _make_worker_failures "T004" "$(_tsv5 T004 claude-exec-failed 'report test')"
  _run_collect "T004"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/state/failures.log" ]

  run bash "$REPO_ROOT/ralph/scripts/report_failures.sh" --log "$TEST_HOME/state/failures.log"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Total failures: 1"* ]]
}
