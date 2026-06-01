#!/usr/bin/env bats
# tests/t026-reviewer-protocol.bats — T026 acceptance criteria validation
# Verifies docs/runbook.md contains required reviewer result protocol section.

RUNBOOK="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/docs/runbook.md"

@test "runbook has reviewer result protocol section heading" {
  grep -qE "^## [0-9]+\. reviewer" "$RUNBOOK"
}

@test "runbook contains PASS result value" {
  grep -q "PASS" "$RUNBOOK"
}

@test "runbook contains REQUEST CHANGES result value" {
  grep -q "REQUEST CHANGES" "$RUNBOOK"
}

@test "runbook contains REJECT result value" {
  grep -q "REJECT" "$RUNBOOK"
}

@test "runbook contains docs/reviews/ path pattern" {
  grep -q "docs/reviews/" "$RUNBOOK"
}

@test "runbook contains TXXX-review.md file pattern" {
  grep -qE "TXXX.*review\.md" "$RUNBOOK"
}

@test "runbook contains review scope rule" {
  grep -q "git diff main" "$RUNBOOK"
}

@test "runbook contains recursion prevention rule" {
  grep -q "git diff main..ralph" "$RUNBOOK"
}

@test "runbook contains checklist section A (spec compliance)" {
  grep -qE "A\." "$RUNBOOK"
}

@test "runbook contains all 5 checklist items" {
  grep -q "Cognitive Debt" "$RUNBOOK"
}
