#!/usr/bin/env bats
# tests/new-ticket.bats — new_ticket writer의 경로·안전 기본 계약.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  mkdir -p "$TEST_HOME/scripts" "$TEST_HOME/docs/tickets/DONE"
  cp "$REPO_ROOT/scripts/new_ticket.sh" "$TEST_HOME/scripts/new_ticket.sh"
  chmod +x "$TEST_HOME/scripts/new_ticket.sh"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "new-ticket@test"
  git -C "$TEST_HOME" config user.name "new-ticket-test"
  NEW_TICKET="$TEST_HOME/scripts/new_ticket.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "new_ticket creates a portable hyphenated ASCII slug on macOS and GNU sed" {
  run bash -c "cd '$TEST_HOME' && '$NEW_TICKET' create --title 'Closed beta deployment architecture and staging rehearsal' </dev/null"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/T001-closed-beta-deployment-architecture-and.md" ]
  run find "$TEST_HOME/docs/tickets" -maxdepth 1 -type f -name 'T001*'
  [ "$status" -eq 0 ]
  [[ "$output" != *" "* ]]
  grep -q '^safe: false$' "$TEST_HOME/docs/tickets/T001-closed-beta-deployment-architecture-and.md"
  [ "$(git -C "$TEST_HOME" log --format=%s -1)" = "new_ticket(T001): Closed beta deployment architecture and staging rehearsal" ]
}
