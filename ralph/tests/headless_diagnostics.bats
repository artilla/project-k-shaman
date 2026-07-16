#!/usr/bin/env bats
# ralph/tests/headless_diagnostics.bats — T102 진단 번들 보존 회귀 테스트.
#
# 확인 사항:
#   1. idle-exit(rc=125) 발생 시 RALPH_STATE_ROOT에 summary.md 포함 번들 생성
#   2. no-commit(rc=7) 발생 시 status.txt와 diff.stat 포함 번들 생성
#   3. isolated worktree 삭제 후에도 STATE_ROOT의 번들이 유지됨
#   4. summary.md에 command/model/timeout backend/stage 정보가 있음

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  WORKSPACE_ROOT="$(mktemp -d)"
  TEST_HOME="$WORKSPACE_ROOT/.ralph/wt-fixture"   # isolated worktree 역할 (RALPH_ROOT)
  STATE_ROOT="$(mktemp -d)"                       # 명시적 안정 상태 루트 (RALPH_STATE_ROOT)
  mkdir -p "$TEST_HOME"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"

  mkdir -p "$TEST_HOME/docs/tickets/DONE" \
           "$TEST_HOME/ralph/scripts/lib" \
           "$TEST_HOME/ralph/skills" \
           "$TEST_HOME/state"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
.ralph/
state/lock
state/current_ticket
state/failures.log
state/reservations/
EOF

  cp "$REPO_ROOT/ralph/scripts/run_loop.sh"           "$TEST_HOME/ralph/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/ralph/scripts/run_loop.sh"
  cp "$REPO_ROOT/ralph/scripts/lib/session_events.sh" "$TEST_HOME/ralph/scripts/lib/session_events.sh"

  touch "$TEST_HOME/docs/master-spec.md"
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

  cat > "$TEST_HOME/docs/tickets/T102-diag-test.md" <<'EOF'
---
id: T102
title: Diagnostics test
status: open
priority: P0
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-06-13
---
Test body.
EOF

  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "init"
}

teardown() {
  rm -rf "$WORKSPACE_ROOT" "$STATE_ROOT"
}

# fake headless: idle-exit (rc=125) — run_headless.sh가 grid-exit로 종료하는 상황 모사
_install_idle_headless() {
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake idle-exit"
exit 125
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install idle headless"
}

# fake headless: 파일 변경 후 commit 없이 종료 (rc=0) → run_loop이 no-commit(rc=7) 반환
_install_no_commit_headless() {
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
cd "${2:-$(pwd)}"
# tracked file 수정, commit 없이 종료 — _op_dirty_lines 검사를 트리거한다
echo "uncommitted change" >> docs/tickets/T102-diag-test.md
exit 0
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install no-commit headless"
}

# fake headless: untracked 산출물 + tracked 변경 후 commit 없이 종료
_install_untracked_no_commit_headless() {
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
cd "${2:-$(pwd)}"
mkdir -p generated
printf 'hello\n' > generated/wip.txt
echo "tracked change" >> docs/tickets/T102-diag-test.md
exit 0
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install untracked no-commit headless"
}

# fake headless: TERM 종료(rc=143) — 수동 중단/외부 TERM 분류 모사
_install_term_headless() {
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "fake term"
exit 143
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install term headless"
}

# fake headless: 자체 commit은 만들지만 티켓을 DONE으로 옮기지 않음 → no-done-move(rc=8)
_install_no_done_move_headless() {
  cat > "$TEST_HOME/ralph/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
cd "${2:-$(pwd)}"
echo "committed implementation marker" >> docs/master-spec.md
git add docs/master-spec.md
git commit -q -m "fake: implementation without done move"
exit 0
EOF
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install no-done-move headless"
}

_run_loop() {
  run env \
    RALPH_ROOT="$TEST_HOME" \
    RALPH_STATE_ROOT="$STATE_ROOT" \
    /bin/bash "$TEST_HOME/ralph/scripts/run_loop.sh" T102-diag-test
}

# T304: run_headless.sh 실제 코드(스텁 아님)를 timeout/gtimeout 경로로 태워
# idle-exit(rc=125)이 여전히 진단 번들을 만드는지 확인한다. gtimeout은 인자를
# 그대로 통과시키는 투과 스텁 — 실제 하드 타임아웃 강제는 검증 대상이 아니고,
# run_headless.sh 자체의 idle 감시가 검증 대상이다.
_install_real_headless_with_gtimeout_fixture() {
  cp "$REPO_ROOT/ralph/scripts/run_headless.sh" "$TEST_HOME/ralph/scripts/run_headless.sh"
  chmod +x "$TEST_HOME/ralph/scripts/run_headless.sh"
  cp "$REPO_ROOT/ralph/scripts/lib/session_events.sh" "$TEST_HOME/ralph/scripts/lib/session_events.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/ralph/scripts/run_headless.sh" "$TEST_HOME/ralph/scripts/lib/session_events.sh"
  git -C "$TEST_HOME" commit -q -m "install real run_headless.sh + gtimeout fixture"

  FIXTURE_BIN="$WORKSPACE_ROOT/fixture-bin"
  mkdir -p "$FIXTURE_BIN"

  cat > "$FIXTURE_BIN/gtimeout" <<'EOF'
#!/bin/sh
shift
exec "$@"
EOF
  chmod +x "$FIXTURE_BIN/gtimeout"

  cat > "$FIXTURE_BIN/fake-claude" <<'EOF'
#!/bin/sh
trap 'exit 143' TERM INT
while :; do sleep 1; done
EOF
  chmod +x "$FIXTURE_BIN/fake-claude"
}

@test "T304: timeout-command path idle-exit still creates diagnostic bundle" {
  _install_real_headless_with_gtimeout_fixture

  run env \
    RALPH_ROOT="$TEST_HOME" \
    RALPH_STATE_ROOT="$STATE_ROOT" \
    PATH="$FIXTURE_BIN:$PATH" \
    CLAUDE_CMD="$FIXTURE_BIN/fake-claude" \
    CLAUDE_IDLE_SECONDS=1 \
    /bin/bash "$TEST_HOME/ralph/scripts/run_loop.sh" T102-diag-test

  [ "$status" -eq 15 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/summary.md" ]
  grep -q "stage=idle-exit" "$bundle_dir/status.txt"
}

@test "idle-exit creates diagnostic bundle with summary.md in STATE_ROOT" {
  _install_idle_headless

  _run_loop

  # run_loop은 idle-exit 시 rc=15 반환
  [ "$status" -eq 15 ]

  # 번들이 STATE_ROOT(worktree가 아닌 곳)에 생성되어야 함
  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/summary.md" ]
  grep -q "stage=idle-exit" "$bundle_dir/status.txt"
}

@test "no-commit rc=7 creates diagnostic bundle with status.txt and diff.stat" {
  _install_no_commit_headless

  _run_loop

  # no-commit → rc=7
  [ "$status" -eq 7 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/status.txt" ]
  [ -f "$bundle_dir/diff.stat" ]
  grep -q "stage=no-commit" "$bundle_dir/status.txt"
}

@test "no-done-move rc=8 creates diagnostic bundle" {
  _install_no_done_move_headless

  _run_loop

  [ "$status" -eq 8 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/status.txt" ]
  grep -q "stage=no-done-move" "$bundle_dir/status.txt"
}

@test "diagnostic bundle survives isolated worktree deletion" {
  _install_idle_headless

  _run_loop

  # STATE_ROOT에 번들 확인
  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/summary.md" ]

  # worktree(TEST_HOME) 삭제
  rm -rf "$TEST_HOME"

  # STATE_ROOT의 번들은 여전히 존재해야 함
  [ -f "$bundle_dir/summary.md" ]
  [ -d "$STATE_ROOT/state/headless-diagnostics/T102" ]
}

@test "diagnostic bundle defaults to isolated worktree parent when RALPH_STATE_ROOT is unset" {
  _install_idle_headless

  run env \
    RALPH_ROOT="$TEST_HOME" \
    /bin/bash "$TEST_HOME/ralph/scripts/run_loop.sh" T102-diag-test

  [ "$status" -eq 15 ]

  bundle_dir="$(find "$WORKSPACE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/summary.md" ]

  rm -rf "$TEST_HOME"
  [ -f "$bundle_dir/summary.md" ]
}

@test "diagnostic bundle summary.md contains command model timeout-backend stage and headless-log-path" {
  _install_idle_headless

  run env \
    RALPH_ROOT="$TEST_HOME" \
    RALPH_STATE_ROOT="$STATE_ROOT" \
    CLAUDE_MODEL="test-sentinel-model" \
    /bin/bash "$TEST_HOME/ralph/scripts/run_loop.sh" T102-diag-test

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]

  grep -q "test-sentinel-model"  "$bundle_dir/summary.md"
  grep -q "headless_log"         "$bundle_dir/summary.md"
  grep -q "timeout_backend"      "$bundle_dir/summary.md"
  grep -q "idle-exit"            "$bundle_dir/summary.md"
}

@test "rc 143 diagnostic bundle records manual-term termination class" {
  _install_term_headless

  _run_loop

  [ "$status" -eq 5 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  grep -q "stage=claude-exec-failed" "$bundle_dir/status.txt"
  grep -q "headless_rc=143" "$bundle_dir/status.txt"
  grep -q "termination_class=manual-term" "$bundle_dir/status.txt"
  grep -q "termination_class.*manual-term" "$bundle_dir/summary.md"
}

@test "diagnostic bundle records porcelain status and untracked file sizes" {
  _install_untracked_no_commit_headless

  _run_loop

  [ "$status" -eq 7 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/git-status.porcelain" ]
  [ -f "$bundle_dir/untracked-files.tsv" ]
  grep -q "?? generated/wip.txt" "$bundle_dir/git-status.porcelain"
  grep -Eq '^[0-9]+[[:space:]]+generated/wip.txt$' "$bundle_dir/untracked-files.tsv"
  grep -q "generated/wip.txt" "$bundle_dir/diff.stat"
}

@test "diagnostic bundle records changed file mtimes and last worktree change" {
  _install_untracked_no_commit_headless

  _run_loop

  [ "$status" -eq 7 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T102" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  [ -f "$bundle_dir/changed-files-mtime.tsv" ]
  [ -f "$bundle_dir/worktree-change.txt" ]
  grep -q "docs/tickets/T102-diag-test.md" "$bundle_dir/changed-files-mtime.tsv"
  grep -q "generated/wip.txt" "$bundle_dir/changed-files-mtime.tsv"
  if grep -q "^none$" "$bundle_dir/worktree-change.txt"; then return 1; fi
  grep -q "last_worktree_change_at=" "$bundle_dir/status.txt"
}
