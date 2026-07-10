#!/usr/bin/env bats
# tests/completion-contract.bats — 리뷰 2차 P1-8: run_loop 완료 판정 계약 회귀 테스트.
#
# rc=0(성공)으로 인정하려면:
#   (1) op 경로 clean
#   (2) 사이클 중 새로 생긴 WIP 없음 (pre_wip 델타 — 추적 수정·미추적 신규 모두,
#       메인 워크트리의 기존 사용자 WIP는 보호)
#   (3) DONE/(status: done) 또는 ARCHIVE/(status: blocked|skipped)로 이동
#   (4) HEAD 전진
# 이전에는 "op 경로 clean + 티켓 파일 부재"만 봐서, status가 open인 채 이동하거나
# 제품 경로에 미커밋 변경을 남긴 세션도 성공으로 집계됐다.

# _make_home <dir> — run_loop 하네스 생성. dir이 */.ralph/wt-*면 isolated 모드로 판정된다.
_make_home() {
  local home="$1"
  mkdir -p "$home/scripts" \
           "$home/skills" \
           "$home/docs/tickets/DONE" \
           "$home/docs/tickets/ARCHIVE" \
           "$home/src" \
           "$home/state"

  cp "$REPO_ROOT/scripts/run_loop.sh" "$home/scripts/run_loop.sh"
  chmod +x "$home/scripts/run_loop.sh"

  cat > "$home/.gitignore" <<'EOF'
state/lock
state/current_ticket
state/failures.log
state/reservations/
.ralph/
scripts/run_headless.sh
EOF
  # 참고: scripts/run_headless.sh는 각 테스트가 다시 쓰는 fake다. ignore하지 않으면
  # isolated worktree pre-flight의 `git clean -fd`가 untracked인 fake를 지워버린다.

  cat > "$home/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$home/scripts/run_checks.sh"

  echo "# implementer stub" > "$home/skills/implementer.md"
  echo "# Master Spec" > "$home/docs/master-spec.md"
  echo "# Runbook" > "$home/docs/runbook.md"
  echo "console.log('app')" > "$home/src/app.js"

  cat > "$home/docs/tickets/T100-contract.md" <<'EOF'
---
id: T100
title: Completion contract test
status: open
priority: P2
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-07-10
---

# T100
EOF

  git -C "$home" init -q
  git -C "$home" config user.email "test@example.com"
  git -C "$home" config user.name "Test"
  git -C "$home" add .
  git -C "$home" commit -q -m init
}

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_BASE="$(mktemp -d)"
  # in_isolated_worktree는 ROOT 경로 패턴(*/.ralph/wt-*)으로 판정 — 격리 모드 재현용.
  TEST_HOME="$TEST_BASE/.ralph/wt-test"
  _make_home "$TEST_HOME"
}

teardown() {
  rm -rf "$TEST_BASE"
}

# 재프롬프트 2회차에는 티켓 파일이 없으므로 no-op으로 끝나는 fake 헤드리스.
# 주의: awk에서 `exit`로 조기 종료하면 printf가 나머지 프롬프트를 쓰다 SIGPIPE(141)로
# 죽는다 (pipefail+set -e 조합, macOS에서 간헐 재현) — stdin을 끝까지 읽는다.
_fake_headless_prologue='#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
ticket=$(printf "%s\n" "$prompt" | awk -F": " "!found && /^파일 경로:/ {print \$2; found=1}")
[ -f "$ticket" ] || exit 0
id=$(basename "$ticket" .md | cut -d- -f1)
'

@test "C1: DONE move committed but status left open -> status-not-done rc=8" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: moved without status change"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 8 ]
  [[ "$output" == *"status-not-done"* ]]
}

@test "C2: DONE committed but tracked product file (src/) left dirty -> no-commit rc=7" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "// uncommitted product change" >> src/app.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")" 2>/dev/null || {
  mkdir -p docs/tickets/DONE
  git rm -q --cached "\$ticket" 2>/dev/null || true
  mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
  git add "docs/tickets/DONE/\$(basename "\$ticket")"
}
git commit -q -m "\${id}: done move only, src left dirty"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C3: proper completion (status done + DONE move + single commit + clean tree) -> rc=0" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "// implemented" >> src/app.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")" 2>/dev/null || mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git add -A
git commit -q -m "\${id}: proper completion"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T100-contract.md" ]
}

@test "C4: reviewer path ARCHIVE move + status blocked -> rc=0 (allowed by contract)" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: blocked"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git mv "\$ticket" "docs/tickets/ARCHIVE/\$(basename "\$ticket")" 2>/dev/null || mv "\$ticket" "docs/tickets/ARCHIVE/\$(basename "\$ticket")"
git add -A
git commit -q -m "\${id}: rejected to archive"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/ARCHIVE/T100-contract.md" ]
}

@test "C5: ticket vanished (neither DONE nor ARCHIVE) -> done-file-missing rc=8" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
git rm -q "\$ticket"
git commit -q -m "\${id}: ticket deleted instead of moved"
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 8 ]
  [[ "$output" == *"done-file-missing"* ]]
}

# ── 리뷰 3차 P1: WIP delta false-success 회귀 ─────────────────────────────────

@test "C6: main worktree - pre-existing user WIP survives, proper completion -> rc=0" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  # 사용자 자신의 추적 WIP (사이클 전부터 존재) — 보호 대상, 실패 사유 아님
  echo "// user WIP before cycle" >> "$main_home/src/app.js"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: proper completion, user WIP untouched" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 0 ]
  grep -q "user WIP before cycle" "$main_home/src/app.js"
}

@test "C7: main worktree - persona leaves NEW tracked modification -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "// persona leftover" >> src/app.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: DONE only, src left dirty" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C8: isolated worktree - persona leaves NEW untracked file -> no-commit rc=7" {
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "// untracked leftover" > src/new.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: DONE only, src/new.js left untracked" -- docs
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$TEST_HOME"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}
