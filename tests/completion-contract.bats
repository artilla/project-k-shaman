#!/usr/bin/env bats
# tests/completion-contract.bats — 리뷰 2차 P1-8: run_loop 완료 판정 계약 회귀 테스트.
#
# rc=0(성공)으로 인정하려면:
#   (1) op 경로 clean  (2) isolated worktree에서는 추적 파일 전체 clean
#   (3) DONE/(status: done) 또는 ARCHIVE/(status: blocked|skipped)로 이동
#   (4) HEAD 전진
# 이전에는 "op 경로 clean + 티켓 파일 부재"만 봐서, status가 open인 채 이동하거나
# 제품 경로에 미커밋 변경을 남긴 세션도 성공으로 집계됐다.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_BASE="$(mktemp -d)"
  # in_isolated_worktree는 ROOT 경로 패턴(*/.ralph/wt-*)으로 판정 — 격리 모드 재현용.
  TEST_HOME="$TEST_BASE/.ralph/wt-test"

  mkdir -p "$TEST_HOME/scripts" \
           "$TEST_HOME/skills" \
           "$TEST_HOME/docs/tickets/DONE" \
           "$TEST_HOME/docs/tickets/ARCHIVE" \
           "$TEST_HOME/src" \
           "$TEST_HOME/state"

  cp "$REPO_ROOT/scripts/run_loop.sh" "$TEST_HOME/scripts/run_loop.sh"
  chmod +x "$TEST_HOME/scripts/run_loop.sh"

  cat > "$TEST_HOME/.gitignore" <<'EOF'
state/lock
state/current_ticket
state/failures.log
state/reservations/
.ralph/
scripts/run_headless.sh
EOF
  # 참고: scripts/run_headless.sh는 각 테스트가 다시 쓰는 fake다. ignore하지 않으면
  # isolated worktree pre-flight의 `git clean -fd`가 untracked인 fake를 지워버린다.

  cat > "$TEST_HOME/scripts/run_checks.sh" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_checks.sh"

  echo "# implementer stub" > "$TEST_HOME/skills/implementer.md"
  echo "# Master Spec" > "$TEST_HOME/docs/master-spec.md"
  echo "# Runbook" > "$TEST_HOME/docs/runbook.md"
  echo "console.log('app')" > "$TEST_HOME/src/app.js"

  cat > "$TEST_HOME/docs/tickets/T100-contract.md" <<'EOF'
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

  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"
  git -C "$TEST_HOME" add .
  git -C "$TEST_HOME" commit -q -m init
}

teardown() {
  rm -rf "$TEST_BASE"
}

# 재프롬프트 2회차에는 티켓 파일이 없으므로 no-op으로 끝나는 fake 헤드리스.
_fake_headless_prologue='#!/usr/bin/env bash
set -euo pipefail
prompt="$1"
ticket=$(printf "%s\n" "$prompt" | awk -F": " "/^파일 경로:/ {print \$2; exit}")
[ -f "$ticket" ] || exit 0
id=$(basename "$ticket" .md | cut -d- -f1)
'

@test "C1: status가 open인 채 DONE 이동+커밋 -> status-not-done, rc=8" {
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

@test "C2: DONE 커밋은 했지만 제품 경로(src/) 추적 파일이 dirty -> no-commit, rc=7" {
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

@test "C3: 정상 완료 (status done + DONE 이동 + 단일 커밋 + 트리 clean) -> rc=0" {
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

@test "C4: reviewer 경로 — ARCHIVE 이동 + status blocked -> rc=0 (계약 허용)" {
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

@test "C5: 티켓이 DONE/ARCHIVE 어디에도 없이 사라짐 -> done-file-missing, rc=8" {
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
