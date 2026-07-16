#!/usr/bin/env bats
# ralph/tests/reviewer-scope-enumeration.bats — T032 acceptance criteria validation
# Static verification that ralph/skills/reviewer.md contains required format specifications.
# Does NOT call the reviewer persona; validates the spec document itself.

REVIEWER_SKILL="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)/ralph/skills/reviewer.md"

@test "T1: reviewer.md requires diff file list section header in output format" {
  grep -qF "검토 대상 diff 파일 목록" "$REVIEWER_SKILL"
}

@test "T2: reviewer.md requires scope-not-missing phrase in A section output" {
  grep -qF "범위 누락 없음" "$REVIEWER_SKILL"
}

@test "T3: reviewer.md states scope missing triggers REQUEST CHANGES verdict" {
  grep -qE "범위 누락.*REQUEST CHANGES|REQUEST CHANGES.*범위 누락" "$REVIEWER_SKILL"
}
