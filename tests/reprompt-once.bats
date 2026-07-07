#!/usr/bin/env bats
# tests/reprompt-once.bats — T308 미커밋 WIP 1회 재프롬프트 회귀 테스트.
#
# 확인 사항:
#   1. rc=0 + 미커밋 WIP → 마무리 세션 1회 자동 디스패치, events.jsonl에 reprompt 기록
#   2. 마무리 세션이 커밋+DONE 이동을 완료하면 사이클은 정상 완료(rc=0)로 끝남
#   3. 마무리 세션도 미완이면 기존 실패 경로(no-commit) 그대로, 재프롬프트는 1회 상한
#      (run_headless.sh 총 호출 횟수 = 2: 원본 1 + 재프롬프트 1)
#   4. no-done-move 스테이지도 동일하게 재프롬프트 대상
#   5. rc 125(idle-exit) 경로엔 재프롬프트 없음 (run_headless.sh 호출 1회, 이벤트 없음)

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  WORKSPACE_ROOT="$(mktemp -d)"
  TEST_HOME="$WORKSPACE_ROOT/.ralph/wt-fixture"   # isolated worktree 역할 (RALPH_ROOT)
  STATE_ROOT="$(mktemp -d)"                       # 명시적 안정 상태 루트 (RALPH_STATE_ROOT)
  mkdir -p "$TEST_HOME"

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"

  mkdir -p "$TEST_HOME/docs/tickets/DONE" \
           "$TEST_HOME/scripts/lib" \
           "$TEST_HOME/skills" \
           "$TEST_HOME/state"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
.ralph/
state/lock
state/current_ticket
state/failures.log
state/reservations/
EOF

  cp "$REPO_ROOT/scripts/run_loop.sh"           "$TEST_HOME/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/scripts/run_loop.sh"
  cp "$REPO_ROOT/scripts/lib/session_events.sh" "$TEST_HOME/scripts/lib/session_events.sh"

  touch "$TEST_HOME/docs/master-spec.md"
  echo "# implementer stub" > "$TEST_HOME/skills/implementer.md"

  cat > "$TEST_HOME/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
test -f docs/master-spec.md
test -d docs/tickets
echo "checks passed (stub)"
EOF
  chmod +x "$TEST_HOME/scripts/run_checks.sh"

  cat > "$TEST_HOME/scripts/pick_next_ticket.sh" <<'EOF'
#!/usr/bin/env bash
ls docs/tickets/T*.md 2>/dev/null | head -1
EOF
  chmod +x "$TEST_HOME/scripts/pick_next_ticket.sh"

  cat > "$TEST_HOME/docs/tickets/T103-reprompt-test.md" <<'EOF'
---
id: T103
title: Reprompt test
status: open
priority: P0
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-07-07
---
Test body.
EOF

  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m "init"
}

teardown() {
  rm -rf "$WORKSPACE_ROOT" "$STATE_ROOT"
}

# 1회차: tracked 파일을 미커밋 상태로 남김. 2회차(재프롬프트): 커밋 없이 계속 미완.
_install_still_incomplete_headless() {
  local counter="$WORKSPACE_ROOT/invocation-count"
  rm -f "$counter"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
cd "\${2:-\$(pwd)}"
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1))
echo "\$n" > "$counter"
echo "uncommitted change \$n" >> docs/tickets/T103-reprompt-test.md
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install still-incomplete headless"
}

# 1회차: 티켓 파일을 미커밋 상태로 남김(no-commit). 2회차(재프롬프트): 커밋+DONE 이동 완료.
_install_reprompt_recovers_headless() {
  local counter="$WORKSPACE_ROOT/invocation-count"
  rm -f "$counter"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
cd "\${2:-\$(pwd)}"
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1))
echo "\$n" > "$counter"
if [ "\$n" = "1" ]; then
  echo "uncommitted change" >> docs/tickets/T103-reprompt-test.md
  exit 0
else
  sed -i.bak 's/^status: .*/status: done/' docs/tickets/T103-reprompt-test.md && rm -f docs/tickets/T103-reprompt-test.md.bak
  git add docs/tickets/T103-reprompt-test.md
  git mv docs/tickets/T103-reprompt-test.md docs/tickets/DONE/
  git commit -q -m "T103: finish via reprompt"
  exit 0
fi
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install reprompt-recovers headless"
}

# 1회차: 자체 commit은 하지만 DONE 이동을 하지 않음(no-done-move). 2회차: DONE 이동 완료.
_install_no_done_move_recovers_headless() {
  local counter="$WORKSPACE_ROOT/invocation-count"
  rm -f "$counter"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
cd "\${2:-\$(pwd)}"
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1))
echo "\$n" > "$counter"
if [ "\$n" = "1" ]; then
  echo "implementation marker" >> docs/master-spec.md
  git add docs/master-spec.md
  git commit -q -m "fake: implementation without done move"
  exit 0
else
  sed -i.bak 's/^status: .*/status: done/' docs/tickets/T103-reprompt-test.md && rm -f docs/tickets/T103-reprompt-test.md.bak
  git add docs/tickets/T103-reprompt-test.md
  git mv docs/tickets/T103-reprompt-test.md docs/tickets/DONE/
  git commit -q -m "T103: finish done-move via reprompt"
  exit 0
fi
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install no-done-move-recovers headless"
}

# idle-exit(rc=125) — 재프롬프트가 개입하면 안 되는 경로.
_install_idle_headless() {
  local counter="$WORKSPACE_ROOT/invocation-count"
  rm -f "$counter"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
n=0
[ -f "$counter" ] && n=\$(cat "$counter")
n=\$((n+1))
echo "\$n" > "$counter"
echo "fake idle-exit"
exit 125
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" add "$TEST_HOME/scripts/run_headless.sh"
  git -C "$TEST_HOME" commit -q -m "install idle headless"
}

_run_loop() {
  run env \
    RALPH_ROOT="$TEST_HOME" \
    RALPH_STATE_ROOT="$STATE_ROOT" \
    /bin/bash "$TEST_HOME/scripts/run_loop.sh" T103-reprompt-test
}

_events_archive() {
  echo "$STATE_ROOT/.ralph/logs/T103.events.jsonl"
}

@test "no-commit WIP triggers exactly one reprompt dispatch, recorded in events.jsonl" {
  _install_still_incomplete_headless

  _run_loop

  # 재프롬프트 후에도 미완 → 기존 no-commit 실패 경로(rc=7)
  [ "$status" -eq 7 ]

  # run_headless.sh는 원본 1회 + 재프롬프트 1회 = 총 2회만 호출됨(무한 루프 없음)
  [ "$(cat "$WORKSPACE_ROOT/invocation-count")" = "2" ]

  events_file="$(_events_archive)"
  [ -f "$events_file" ]
  grep -q '"action":"reprompt"' "$events_file"
}

@test "reprompt session completing commit+DONE move ends cycle as normal success" {
  _install_reprompt_recovers_headless

  _run_loop

  [ "$status" -eq 0 ]
  [ "$(cat "$WORKSPACE_ROOT/invocation-count")" = "2" ]

  # 티켓이 DONE으로 이동했어야 함
  [ ! -f "$TEST_HOME/docs/tickets/T103-reprompt-test.md" ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T103-reprompt-test.md" ]

  events_file="$(_events_archive)"
  [ -f "$events_file" ]
  grep -q '"action":"reprompt"' "$events_file"
}

@test "no-done-move WIP also gets one reprompt and can recover" {
  _install_no_done_move_recovers_headless

  _run_loop

  [ "$status" -eq 0 ]
  [ "$(cat "$WORKSPACE_ROOT/invocation-count")" = "2" ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T103-reprompt-test.md" ]

  events_file="$(_events_archive)"
  [ -f "$events_file" ]
  grep -q '"action":"reprompt"' "$events_file"
}

@test "reprompt failure path still produces no-commit diagnostics bundle" {
  _install_still_incomplete_headless

  _run_loop

  [ "$status" -eq 7 ]

  bundle_dir="$(find "$STATE_ROOT/state/headless-diagnostics/T103" -mindepth 1 -maxdepth 1 -type d 2>/dev/null | head -1)"
  [ -n "$bundle_dir" ]
  grep -q "stage=no-commit" "$bundle_dir/status.txt"
}

@test "idle-exit (rc 125) path never triggers a reprompt" {
  _install_idle_headless

  _run_loop

  [ "$status" -eq 15 ]

  # run_headless.sh는 idle-exit에서 한 번만 호출됨 — 재프롬프트 없음
  [ "$(cat "$WORKSPACE_ROOT/invocation-count")" = "1" ]

  events_file="$(_events_archive)"
  if [ -f "$events_file" ]; then
    run grep -q '"action":"reprompt"' "$events_file"
    [ "$status" -ne 0 ]
  fi
}
