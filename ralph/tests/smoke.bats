#!/usr/bin/env bats
# smoke.bats — 추출된 하네스 기본 위생(starter). 자유롭게 교체·확장하세요.
ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

@test "run_checks.sh is executable" {
  [ -x "$ROOT/ralph/scripts/run_checks.sh" ]
}

@test "master-spec exists" {
  [ -f "$ROOT/docs/master-spec.md" ]
}

@test "ticket TEMPLATE exists" {
  [ -f "$ROOT/docs/tickets/TEMPLATE.md" ]
}
