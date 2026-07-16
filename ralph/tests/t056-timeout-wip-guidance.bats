#!/usr/bin/env bats
# ralph/tests/t056-timeout-wip-guidance.bats — T056 acceptance criteria validation.
# Verifies run_headless.sh default timeout and orchestrator.sh WIP guidance text.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
RUN_HEADLESS="$REPO_ROOT/ralph/scripts/run_headless.sh"
ORCHESTRATOR="$REPO_ROOT/ralph/scripts/orchestrator.sh"

@test "run_headless.sh uses CLAUDE_TIMEOUT_SECONDS:-1200 syntax" {
  grep -qE 'CLAUDE_TIMEOUT_SECONDS:-1200' "$RUN_HEADLESS"
}

@test "run_headless.sh header comment mentions 1200" {
  grep -q '1200' "$RUN_HEADLESS"
}

@test "run_headless.sh includes ADR-0017 reference" {
  grep -q 'ADR-0017' "$RUN_HEADLESS"
}

@test "orchestrator round summary has runbook §3 reference in rc≠0 branch" {
  grep -q 'runbook §3' "$ORCHESTRATOR"
}

@test "orchestrator round summary has .ralph/wt- worktree path in no-commit WIP guidance" {
  grep -q '미커밋 WIP' "$ORCHESTRATOR"
}
