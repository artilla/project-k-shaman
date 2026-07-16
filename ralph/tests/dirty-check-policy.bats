#!/usr/bin/env bats
# ralph/tests/dirty-check-policy.bats — run_loop.sh operational-path dirty policy regression tests.
#
# Verifies:
#   1. Non-operational untracked files only -> pre-flight does NOT block with rc=4.
#   2. Operational dirty files present -> pre-flight blocks with rc=4.
#   3. Non-operational untracked files remain after fake headless DONE commit ->
#      final no-commit check passes (rc != 7).

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
  mkdir -p "$TEST_HOME/tests"
  mkdir -p "$TEST_HOME/docs"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
state/lock
state/current_ticket
state/failures.log
state/reservations/
EOF

  cp "$REPO_ROOT/ralph/scripts/run_loop.sh" "$TEST_HOME/ralph/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/ralph/scripts/run_loop.sh"

  touch "$TEST_HOME/docs/master-spec.md"

  # ralph/skills/implementer.md must exist for persona routing
  echo "# implementer stub" > "$TEST_HOME/ralph/skills/implementer.md"

  cat > "$TEST_HOME/ralph/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -f docs/master-spec.md
test -d docs/tickets
echo "checks passed (stub)"
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_checks.sh"

  cat > "$TEST_HOME/ralph/scripts/pick_next_ticket.sh" <<'EOF'
#!/usr/bin/env bash
ls docs/tickets/T*.md 2>/dev/null | head -1
EOF
  chmod +x "$TEST_HOME/ralph/scripts/pick_next_ticket.sh"

  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "init"
}

teardown() {
  rm -rf "$TEST_HOME"
}

_make_ticket() {
  local ticket_id="$1"
  cat > "$TEST_HOME/docs/tickets/${ticket_id}-test.md" <<EOF
---
id: ${ticket_id}
title: Test ticket ${ticket_id}
status: open
priority: P2
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-05-15
---
Test body.
EOF
  git -C "$TEST_HOME" add "$TEST_HOME/docs/tickets/${ticket_id}-test.md"
  git -C "$TEST_HOME" commit -q -m "add ${ticket_id}"
}

_install_fake_headless() {
  local ticket_id="$1"
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\${2:-\$(pwd)}"
ticket_file="docs/tickets/${ticket_id}-test.md"
[ -f "\$ticket_file" ] || { echo "ticket not found: \$ticket_file" >&2; exit 1; }
sed -i.bak 's/^status: .*/status: done/' "\$ticket_file"
rm -f "\${ticket_file}.bak"
git add "\$ticket_file"
git mv "\$ticket_file" "docs/tickets/DONE/${ticket_id}-test.md"
git commit -q -m "${ticket_id}: fake headless done"
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  # commit so ralph/scripts/run_headless.sh is tracked (ralph/scripts/ is operational path)
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "add fake run_headless.sh"
}

_run_loop() {
  local ticket_id="$1"
  run env RALPH_ROOT="$TEST_HOME" bash "$TEST_HOME/ralph/scripts/run_loop.sh" "$ticket_id"
}

# ── Test 1: non-operational untracked file only -> NOT blocked ────────────────

@test "preflight: non-op untracked file only does not trigger rc=4 block" {
  _make_ticket "T091"
  _install_fake_headless "T091"

  # Non-operational untracked file (docs/ but not in whitelist)
  touch "$TEST_HOME/docs/manyfast-service-analysis.md"

  _run_loop "T091"

  # Must NOT be blocked by dirty check (rc=4)
  [ "$status" -ne 4 ]
  # Cycle should complete successfully
  [ "$status" -eq 0 ]
  # DONE move must have happened
  [ -f "$TEST_HOME/docs/tickets/DONE/T091-test.md" ]
}

# ── Test 2a: operational dirty file (ralph/scripts/) -> blocked rc=4 ───────────────

@test "preflight: operational untracked file in ralph/scripts/ triggers rc=4" {
  _make_ticket "T092"

  # Operational untracked file in ralph/scripts/
  touch "$TEST_HOME/ralph/scripts/dirty-helper.sh"

  _run_loop "T092"

  [ "$status" -eq 4 ]
}

# ── Test 2b: operational dirty file (docs/tickets/) -> blocked rc=4 ──────────

@test "preflight: operational untracked file in docs/tickets/ triggers rc=4" {
  _make_ticket "T093"

  # Operational untracked file in docs/tickets/
  touch "$TEST_HOME/docs/tickets/T999-dirty.md"

  _run_loop "T093"

  [ "$status" -eq 4 ]
}

# ── Test 2c: operational modified tracked file -> blocked rc=4 ───────────────

@test "preflight: operational modified tracked file in ralph/scripts/ triggers rc=4" {
  _make_ticket "T095"

  # Operational tracked file modified after commit
  echo "# dirty" >> "$TEST_HOME/ralph/scripts/run_checks.sh"

  _run_loop "T095"

  [ "$status" -eq 4 ]
}

# ── Test 3: non-op untracked remains after DONE commit -> no-commit passes ───

@test "no-commit check passes when only non-op untracked files remain" {
  _make_ticket "T094"
  _install_fake_headless "T094"

  # Non-operational untracked file present throughout cycle
  touch "$TEST_HOME/docs/manyfast-service-analysis.md"

  _run_loop "T094"

  # Must NOT fail with no-commit error (rc=7)
  [ "$status" -ne 7 ]
  # Cycle completes successfully
  [ "$status" -eq 0 ]
  # DONE move happened
  [ -f "$TEST_HOME/docs/tickets/DONE/T094-test.md" ]
  # Non-op file still present (not committed)
  [ -f "$TEST_HOME/docs/manyfast-service-analysis.md" ]
}
