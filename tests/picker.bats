#!/usr/bin/env bats
# tests/picker.bats — pick_next_ticket.sh 의 TEMPLATE 제외를 보장하는 회귀 테스트.
#
# 각 테스트는 임시 디렉터리에 격리된 레플리카 구조를 생성하고
# 원본 repo를 오염시키지 않는다.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"

  mkdir -p "$TEST_HOME/scripts"
  mkdir -p "$TEST_HOME/docs/tickets/DONE"

  cp "$REPO_ROOT/scripts/pick_next_ticket.sh" "$TEST_HOME/scripts/pick_next_ticket.sh"
  chmod +x "$TEST_HOME/scripts/pick_next_ticket.sh"

  PICKER="$TEST_HOME/scripts/pick_next_ticket.sh"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# ── helpers ─────────────────────────────────────────────────────────────────

_make_ticket() {
  local path="$1" status="$2" priority="${3:-P2}"
  local id
  id="$(basename "$path" .md | cut -d- -f1)"
  cat > "$path" <<EOF
---
id: $id
title: Test ticket $id
status: $status
priority: $priority
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-05-12
---
Test body.
EOF
}

_make_template() {
  cat > "$TEST_HOME/docs/tickets/TEMPLATE.md" <<'EOF'
---
id: TXXX
title: (한 줄 제목)
status: open            # open | done | skipped | blocked
priority: P2            # P0 | P1 | P2 | P3
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: YYYY-MM-DD
spec_ref: docs/master-spec.md#section-id
---
EOF
}

# ── test cases ───────────────────────────────────────────────────────────────

@test "only TEMPLATE.md: picker returns empty output" {
  _make_template

  run "$PICKER"

  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "T001(open) + TEMPLATE.md: picker selects T001" {
  _make_template
  _make_ticket "$TEST_HOME/docs/tickets/T001-open-test.md" "open"

  run "$PICKER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"T001"* ]]
}

@test "T001(done) + T002(open): picker selects T002" {
  _make_ticket "$TEST_HOME/docs/tickets/T001-done-test.md" "done"
  _make_ticket "$TEST_HOME/docs/tickets/T002-open-test.md" "open"

  run "$PICKER"

  [ "$status" -eq 0 ]
  [[ "$output" == *"T002"* ]]
}
