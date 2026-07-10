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

# ── 리뷰 4차 P1: fingerprint 양방향·내용 비교 + telemetry index 보존 회귀 ──────

@test "C9: pre-existing tracked WIP file modified further by persona -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  echo "// user WIP before cycle" >> "$main_home/src/app.js"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "// persona touched the SAME dirty file" >> src/app.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, same porcelain line but content changed" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C10: new file inside pre-existing untracked dir -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  mkdir -p "$main_home/scratch"
  echo "user note" > "$main_home/scratch/a.txt"   # porcelain은 '?? scratch/' 한 줄

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "persona leftover" > scratch/b.txt
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, new file hidden in untracked dir" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C11: pre-existing untracked user file deleted by persona -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  echo "precious" > "$main_home/usernote.txt"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
rm -f usernote.txt
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, user untracked file deleted" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C12: telemetry commits do not absorb pre-staged user WIP (index preserved)" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  # 사용자가 미리 staged해 둔 무관한 변경
  echo "// user staged change" >> "$main_home/src/app.js"
  git -C "$main_home" add src/app.js

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")" 2>/dev/null || mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: proper completion" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 0 ]

  # telemetry(completed_at) 커밋이 존재하고 DONE 파일만 포함해야 한다
  local tsha
  tsha=$(git -C "$main_home" log --format='%H %s' | awk '/telemetry\(T100\)/ {print $1; exit}')
  [ -n "$tsha" ]
  run git -C "$main_home" show --name-only --format= "$tsha"
  [[ "$output" == *"docs/tickets/DONE/T100-contract.md"* ]]
  [[ "$output" != *"src/app.js"* ]]

  # 사용자 staged WIP는 여전히 index에 남아 있어야 한다
  git -C "$main_home" diff --cached --name-only | grep -qx "src/app.js"
  grep -q "user staged change" "$main_home/src/app.js"
}

# ── 리뷰 5차 P1: NUL-safe 경로 해시 + index blob fingerprint 회귀 ─────────────

@test "C13: non-ASCII path pre-existing dirty file modified further -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  # 비ASCII 경로 추적 파일 (--name-only 텍스트 출력에서 C-quote되는 경로)
  echo "v1" > "$main_home/src/한글 파일.txt"
  git -C "$main_home" add "src/한글 파일.txt"
  git -C "$main_home" commit -q -m "add non-ascii tracked file"
  echo "user wip" >> "$main_home/src/한글 파일.txt"   # 사이클 전 dirty

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "persona touched non-ascii dirty file" >> "src/한글 파일.txt"
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, non-ascii dirty file touched" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C14: index blob swapped (worktree unchanged, MM preserved) -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  # 사용자: index-v1 staged + worktree 추가 수정 → porcelain MM
  echo "user-index-v1" >> "$main_home/src/app.js"
  git -C "$main_home" add src/app.js
  echo "user-worktree" >> "$main_home/src/app.js"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
# worktree는 그대로 두고 index blob만 교체 — porcelain 행(MM src/app.js) 불변
sha=\$(printf 'persona-index-v2\n' | git hash-object -w --stdin)
git update-index --cacheinfo "100644,\$sha,src/app.js"
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, index blob swapped" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

# ── 리뷰 6차 P1: symlink 재타깃 fingerprint 회귀 ──────────────────────────────

@test "C15: untracked symlink retargeted to same-content file -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  # 같은 내용의 두 파일 + 링크 (미추적) — hash-object는 대상 내용을 따라가므로
  # readlink를 기록하지 않으면 b→c 재타깃이 보이지 않았다
  echo "same content" > "$main_home/src/target-b.txt"
  echo "same content" > "$main_home/src/target-c.txt"
  git -C "$main_home" add src/target-b.txt src/target-c.txt
  git -C "$main_home" commit -q -m "add targets"
  ln -s target-b.txt "$main_home/src/link"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
ln -sfn target-c.txt src/link
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, symlink retargeted" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

@test "C16: assume-unchanged file modified by persona -> no-commit rc=7" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  git -C "$main_home" update-index --assume-unchanged src/app.js

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
echo "hidden change behind assume-unchanged" >> src/app.js
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done, hidden change" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 7 ]
  [[ "$output" == *"no-commit"* ]]
}

# ── 리뷰 7차 P1: fingerprint 수집 실패 fail-closed ────────────────────────────

@test "C17: unreadable dirty file -> fingerprint collection fails closed rc=13" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"
  echo "secret" > "$main_home/src/locked.txt"
  chmod 000 "$main_home/src/locked.txt"

  cat > "$main_home/scripts/run_headless.sh" <<EOF
${_fake_headless_prologue}
tmp=\$(mktemp)
awk '/^---\$/ { fm = !fm; print; next } fm && \$1 == "status:" { print "status: done"; next } { print }' "\$ticket" > "\$tmp"
mv "\$tmp" "\$ticket"
git add "\$ticket"
git mv "\$ticket" "docs/tickets/DONE/\$(basename "\$ticket")"
git commit -q -m "\${id}: done" -- docs
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T100' _ "$main_home"
  chmod 644 "$main_home/src/locked.txt" 2>/dev/null || true
  [ "$status" -eq 13 ]
  [[ "$output" == *"fingerprint 수집 실패"* ]]
  # 디스패치 자체가 중단됐어야 한다 — DONE 이동 없음
  [ ! -f "$main_home/docs/tickets/DONE/T100-contract.md" ]
}

@test "C18: git status command failure -> fingerprint fails closed rc=13 (not dispatched)" {
  local main_home="$TEST_BASE/main-home"
  _make_home "$main_home"

  # git shim: status만 rc=42로 실패시키고 나머지는 실제 git으로 위임
  local real_git
  real_git="$(command -v git)"
  mkdir -p "$main_home/bin"
  cat > "$main_home/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "status" ]; then exit 42; fi
exec "$real_git" "\$@"
EOF
  chmod +x "$main_home/bin/git"

  cat > "$main_home/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "should not be dispatched" >&2
exit 99
EOF
  chmod +x "$main_home/scripts/run_headless.sh"

  run bash -c 'cd "$1" && PATH="$1/bin:$PATH" ./scripts/run_loop.sh T100' _ "$main_home"
  [ "$status" -eq 13 ]
  [[ "$output" == *"fingerprint 수집 실패"* ]]
  [[ "$output" != *"should not be dispatched"* ]]
}
