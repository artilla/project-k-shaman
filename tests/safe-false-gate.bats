#!/usr/bin/env bats
# tests/safe-false-gate.bats — safe:false approval gate regression tests.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"

  mkdir -p "$TEST_HOME/scripts" \
           "$TEST_HOME/skills" \
           "$TEST_HOME/docs/tickets/DONE" \
           "$TEST_HOME/docs/tickets/ARCHIVE" \
           "$TEST_HOME/docs/approvals" \
           "$TEST_HOME/state"

  cp "$REPO_ROOT/scripts/pick_next_ticket.sh" "$TEST_HOME/scripts/pick_next_ticket.sh"
  cp "$REPO_ROOT/scripts/run_loop.sh" "$TEST_HOME/scripts/run_loop.sh"
  cp "$REPO_ROOT/scripts/orchestrator.sh" "$TEST_HOME/scripts/orchestrator.sh"
  cp "$REPO_ROOT/.gitignore" "$TEST_HOME/.gitignore"
  chmod +x "$TEST_HOME/scripts/"*.sh

  cat > "$TEST_HOME/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_checks.sh"

  cat > "$TEST_HOME/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
ticket=$(printf '%s\n' "$prompt" | awk -F': ' '/^파일 경로:/ {print $2; exit}')
[ -n "$ticket" ] || { echo "missing ticket path" >&2; exit 2; }
id=$(basename "$ticket" .md | cut -d- -f1)
mkdir -p docs/tickets/DONE
tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-ticket.XXXXXX")
awk '
  /^---$/ { fm = !fm; print; next }
  fm && $1 == "status:" { print "status: done"; next }
  { print }
' "$ticket" > "$tmp"
mv "$tmp" "$ticket"
git mv "$ticket" "docs/tickets/DONE/$(basename "$ticket")"
git add -A
git commit -m "${id}: fake safe false gate run" >/dev/null
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  cat > "$TEST_HOME/skills/implementer.md" <<'EOF'
# Implementer
EOF

  cat > "$TEST_HOME/docs/master-spec.md" <<'EOF'
# Master Spec
EOF

  cat > "$TEST_HOME/docs/runbook.md" <<'EOF'
# Runbook
EOF

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test User"
  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m init
}

teardown() {
  rm -rf "$TEST_HOME"
}

_make_ticket() {
  local id="$1" safe="$2" status="${3:-open}" priority="${4:-P2}"
  cat > "$TEST_HOME/docs/tickets/${id}-test.md" <<EOF
---
id: $id
title: Test ticket $id
status: $status
priority: $priority
safe: $safe
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-05-18
spec_ref: docs/decisions/0007-safe-false-ticket-ux.md
---

# $id
EOF
}

_make_approval() {
  local id="$1" mode="${2:-valid}"
  if [ "$mode" = "valid" ]; then
    cat > "$TEST_HOME/docs/approvals/${id}.md" <<'EOF'
approved_by: "Test User"
approved_at: "2026-05-18T10:00:00+09:00"
scope_confirmation: "Test scope is approved"
rollback_plan: "git revert HEAD"
EOF
  else
    cat > "$TEST_HOME/docs/approvals/${id}.md" <<'EOF'
approved_by: ""
approved_at: "not-a-date"
rollback_plan: ""
EOF
  fi
}

_commit_all() {
  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "$1"
}

@test "T1: safe:false is skipped in safe-only mode and marked awaiting-approval once" {
  _make_ticket T001 false
  _commit_all "add T001"

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh --safe-only' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP] T001"* ]]
  [[ "$output" != *"docs/tickets/T001-test.md"* ]]
  grep -q '^status: awaiting-approval$' "$TEST_HOME/docs/tickets/T001-test.md"
  [ "$(git -C "$TEST_HOME" log --format=%s -1)" = "ralph: mark T001 awaiting-approval" ]

  head_before=$(git -C "$TEST_HOME" rev-parse HEAD)
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh --safe-only' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  [ "$head_before" = "$(git -C "$TEST_HOME" rev-parse HEAD)" ]
}

@test "T2: explicit safe:false run without approval marker exits rc=14" {
  _make_ticket T002 false
  _commit_all "add T002"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T002' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"docs/approvals/T002.md"* ]]
}

@test "T3: explicit safe:false run with valid approval marker completes" {
  _make_ticket T003 false
  _make_approval T003 valid
  _commit_all "add T003"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T003' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T003-test.md" ]
  [ "$(git -C "$TEST_HOME" log --format=%s -1)" = "T003: fake safe false gate run" ]
}

@test "T4: malformed approval marker exits rc=14 and names invalid fields" {
  _make_ticket T004 false
  _make_approval T004 invalid
  _commit_all "add T004"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T004' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"approved_by"* ]]
  [[ "$output" == *"approved_at(ISO8601)"* ]]
  [[ "$output" == *"scope_confirmation"* ]]
  [[ "$output" == *"rollback_plan"* ]]
}

@test "T5: safe:true ticket does not require approval marker" {
  _make_ticket T005 true
  _commit_all "add T005"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T005' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T005-test.md" ]
}

@test "T6: orchestrator summary marks safe:false branch as human approval required" {
  _make_ticket T006 true

  cat > "$TEST_HOME/scripts/run_loop.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
id="$1"
ticket=$(ls "docs/tickets/${id}-"*.md | head -1)
mkdir -p docs/tickets/DONE
tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-ticket.XXXXXX")
awk '
  /^---$/ { fm = !fm; print; next }
  fm && $1 == "status:" { print "status: done"; next }
  fm && $1 == "safe:" { print "safe: false"; next }
  { print }
' "$ticket" > "$tmp"
mv "$tmp" "$ticket"
git mv "$ticket" "docs/tickets/DONE/$(basename "$ticket")"
git add -A
git commit -m "${id}: fake orchestrator safe false result" >/dev/null
EOF
  chmod +x "$TEST_HOME/scripts/run_loop.sh"
  _commit_all "add T006 and fake worker"

  run bash -c 'cd "$1" && ./scripts/orchestrator.sh --max 1' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"HUMAN APPROVAL REQUIRED FOR MERGE"* ]]
  [[ "$output" == *"safe:false"* ]]
}
