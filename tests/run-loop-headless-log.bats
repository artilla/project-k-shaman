#!/usr/bin/env bats
# tests/run-loop-headless-log.bats — Step 2 run_loop headless log capture.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_HOME="$(mktemp -d)"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"

  mkdir -p "$TEST_HOME/docs/tickets/DONE" \
           "$TEST_HOME/scripts" \
           "$TEST_HOME/skills" \
           "$TEST_HOME/state" \
           "$TEST_HOME/docs"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
.ralph/
state/lock
state/current_ticket
state/failures.log
state/reservations/
EOF

  cp "$REPO_ROOT/scripts/run_loop.sh" "$TEST_HOME/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/scripts/run_loop.sh"

  touch "$TEST_HOME/docs/master-spec.md"
  echo "# implementer stub" > "$TEST_HOME/skills/implementer.md"

  cat > "$TEST_HOME/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -f docs/master-spec.md
test -d docs/tickets
EOF
  chmod +x "$TEST_HOME/scripts/run_checks.sh"

  cat > "$TEST_HOME/scripts/pick_next_ticket.sh" <<'EOF'
#!/usr/bin/env bash
ls docs/tickets/T*.md 2>/dev/null | head -1
EOF
  chmod +x "$TEST_HOME/scripts/pick_next_ticket.sh"

  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m init
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
created: 2026-06-01
---
Test body.
EOF
  git -C "$TEST_HOME" add "$TEST_HOME/docs/tickets/${ticket_id}-test.md"
  git -C "$TEST_HOME" commit -q -m "add ${ticket_id}"
}

_install_success_headless() {
  local ticket_id="$1"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
cd "\${2:-\$(pwd)}"
echo "fake stdout for ${ticket_id}"
echo "fake stderr for ${ticket_id}" >&2
ticket_file="docs/tickets/${ticket_id}-test.md"
sed -i.bak 's/^status: .*/status: done/' "\$ticket_file"
rm -f "\${ticket_file}.bak"
git add "\$ticket_file"
git mv "\$ticket_file" "docs/tickets/DONE/${ticket_id}-test.md"
git commit -q -m "${ticket_id}: fake headless done"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "add success headless"
}

_install_failure_headless() {
  local ticket_id="$1"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
echo "fake stdout before failure ${ticket_id}"
echo "fake stderr before failure ${ticket_id}" >&2
exit 42
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "add failure headless"
}

_run_loop() {
  local ticket_id="$1"
  run env RALPH_ROOT="$TEST_HOME" bash "$TEST_HOME/scripts/run_loop.sh" "$ticket_id"
}

@test "run_loop captures successful headless stdout and stderr to .ralph/logs" {
  _make_ticket "T201"
  _install_success_headless "T201"

  _run_loop "T201"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/.ralph/logs/T201.log" ]
  grep -q "ticket=T201" "$TEST_HOME/.ralph/logs/T201.log"
  grep -q "fake stdout for T201" "$TEST_HOME/.ralph/logs/T201.log"
  grep -q "fake stderr for T201" "$TEST_HOME/.ralph/logs/T201.log"
  [ -f "$TEST_HOME/docs/tickets/DONE/T201-test.md" ]
}

@test "run_loop keeps headless failure rc path while writing log" {
  _make_ticket "T202"
  _install_failure_headless "T202"

  _run_loop "T202"

  [ "$status" -eq 5 ]
  [ -f "$TEST_HOME/.ralph/logs/T202.log" ]
  grep -q "fake stdout before failure T202" "$TEST_HOME/.ralph/logs/T202.log"
  grep -q "fake stderr before failure T202" "$TEST_HOME/.ralph/logs/T202.log"
  grep -q "claude-exec-failed" "$TEST_HOME/state/failures.log"
}
