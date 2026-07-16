#!/usr/bin/env bats
# ralph/tests/failures-log.bats — state/failures.log TSV 포맷 회귀 테스트.
#
# 각 테스트는 임시 git repo에서 run_loop.sh의 실패 경로를 유도하고
# 원본 repo의 state/ 를 오염시키지 않는다.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_HOME="$(mktemp -d)"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"

  mkdir -p "$TEST_HOME/docs/tickets/DONE"
  mkdir -p "$TEST_HOME/docs/decisions"
  mkdir -p "$TEST_HOME/ralph/scripts"
  mkdir -p "$TEST_HOME/ralph/skills"
  mkdir -p "$TEST_HOME/state"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
state/lock
state/current_ticket
state/failures.log
state/reservations/
EOF

  cp "$REPO_ROOT/ralph/scripts/run_loop.sh" "$TEST_HOME/ralph/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/ralph/scripts/run_loop.sh"

  touch "$TEST_HOME/docs/master-spec.md"

  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "init"
}

teardown() {
  rm -rf "$TEST_HOME"
}

_make_ticket_with_persona() {
  local ticket_id="$1" persona="$2"
  cat > "$TEST_HOME/docs/tickets/${ticket_id}-test.md" <<EOF
---
id: ${ticket_id}
title: Test ticket ${ticket_id}
status: open
priority: P2
safe: true
persona: ${persona}
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-05-12
---
Test body.
EOF
  git -C "$TEST_HOME" add "$TEST_HOME/docs/tickets/${ticket_id}-test.md"
  git -C "$TEST_HOME" commit -q -m "add ${ticket_id}"
}

_run_loop_with_ticket() {
  local ticket_id="$1"
  run env RALPH_ROOT="$TEST_HOME" bash "$TEST_HOME/ralph/scripts/run_loop.sh" "$ticket_id"
}

@test "unknown-persona failure writes 5-field TSV to failures.log" {
  _make_ticket_with_persona "T099" "nonexistent-persona"
  _run_loop_with_ticket "T099"

  [ -f "$TEST_HOME/state/failures.log" ]
  line="$(head -1 "$TEST_HOME/state/failures.log")"
  field_count="$(printf '%s' "$line" | awk -F'\t' '{print NF}')"
  [ "$field_count" -eq 5 ]
}

@test "failures.log first field is an ISO8601 timestamp" {
  _make_ticket_with_persona "T098" "nonexistent-persona"
  _run_loop_with_ticket "T098"

  [ -f "$TEST_HOME/state/failures.log" ]
  ts="$(head -1 "$TEST_HOME/state/failures.log" | cut -f1)"
  [[ "$ts" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2} ]]
}

@test "failures.log second field is ticket ID and third is stage name" {
  _make_ticket_with_persona "T097" "nonexistent-persona"
  _run_loop_with_ticket "T097"

  [ -f "$TEST_HOME/state/failures.log" ]
  line="$(head -1 "$TEST_HOME/state/failures.log")"
  ticket_id="$(printf '%s' "$line" | cut -f2)"
  stage="$(printf '%s' "$line" | cut -f3)"
  [ "$ticket_id" = "T097" ]
  [ "$stage" = "unknown-persona" ]
}

@test "failures.log fifth field (message) contains error summary" {
  _make_ticket_with_persona "T096" "nonexistent-persona"
  _run_loop_with_ticket "T096"

  [ -f "$TEST_HOME/state/failures.log" ]
  message="$(head -1 "$TEST_HOME/state/failures.log" | cut -f5)"
  [ -n "$message" ]
}
