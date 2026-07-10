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
           "$TEST_HOME/mission-control" \
           "$TEST_HOME/state"

  cp "$REPO_ROOT/scripts/pick_next_ticket.sh" "$TEST_HOME/scripts/pick_next_ticket.sh"
  cp "$REPO_ROOT/scripts/run_loop.sh" "$TEST_HOME/scripts/run_loop.sh"
  cp "$REPO_ROOT/scripts/orchestrator.sh" "$TEST_HOME/scripts/orchestrator.sh"
  cp "$REPO_ROOT/scripts/approve.sh" "$TEST_HOME/scripts/approve.sh"
  # 리뷰 2차 P1-7: run_loop의 safe:false 승인 판정은 mission-control/approval.mjs 단일 소스.
  cp "$REPO_ROOT/mission-control/approval.mjs" "$TEST_HOME/mission-control/approval.mjs"
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
# 주의: awk에서 `exit`로 조기 종료하면 printf가 나머지 프롬프트를 쓰다 SIGPIPE(141)로
# 죽는다 (pipefail+set -e 조합, macOS에서 간헐 재현) — stdin을 끝까지 읽는다.
ticket=$(printf '%s\n' "$prompt" | awk -F': ' '!found && /^파일 경로:/ {print $2; found=1}')
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
  # 리뷰 3차: scope 섹션은 _make_approval(valid)의 scope_confirmation과 일치해야 한다
  # (섹션 부재는 이제 unverifiable로 실행 거부 — T13이 그 경로를 검증).
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

## 변경 범위

- Test scope is approved
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
  # ADR-0046: run_loop appends a separate telemetry(T003) commit after the persona
  # done commit, so the persona commit need not be HEAD — assert it is present.
  git -C "$TEST_HOME" log --format=%s -3 | grep -qx "T003: fake safe false gate run"
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

# ── 리뷰 2차 P1-6/P1-7 회귀 ──────────────────────────────────────────────────

@test "T7: malformed safe field (safe: yes) -> run_loop rejects fail-closed rc=14" {
  _make_ticket T007 yes
  _commit_all "add T007"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T007' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"safe 필드가 비정상"* ]]
  # 승인 마커가 있어도 malformed safe는 실행 불가여야 한다 (fail-closed)
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T007-test.md" ]
}

@test "T8: missing/malformed safe field -> picker excludes fail-closed (no awaiting mark)" {
  # 리뷰 6차: quoted scalar("true")는 이제 서버와 동일하게 유효값 — 오타 케이스로 대체.
  _make_ticket T008 'TRUE'
  _commit_all "add T008"

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP] T008"* ]]
  [[ "$output" == *"비정상"* ]]
  [[ "$output" != *"docs/tickets/T008-test.md"* ]]
  # safe:false와 달리 awaiting-approval로 바꾸지 않는다 — 승인으로 우회 불가
  grep -q '^status: open$' "$TEST_HOME/docs/tickets/T008-test.md"
}

@test "T9: stale approval (ticket scope changed after approval) -> rc=14 with stale message" {
  cat > "$TEST_HOME/docs/tickets/T009-test.md" <<'EOF'
---
id: T009
title: Stale approval test
status: open
priority: P2
safe: false
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: []
created: 2026-07-10
---

# T009

## 변경 범위

- 승인 이후 넓어진 새 범위
EOF
  cat > "$TEST_HOME/docs/approvals/T009.md" <<'EOF'
approved_by: "Test User"
approved_at: "2026-07-10T10:00:00+09:00"
scope_confirmation: "원래 승인했던 좁은 범위"
rollback_plan: "git revert HEAD"
EOF
  _commit_all "add T009 with stale approval"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T009' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"stale"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T009-test.md" ]
}

@test "T10: validator unavailable -> safe:false refused fail-closed rc=14" {
  _make_ticket T010 false
  _make_approval T010 valid
  _commit_all "add T010"
  rm -f "$TEST_HOME/mission-control/approval.mjs"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T010' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"fail-closed"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T010-test.md" ]
}

# ── 리뷰 3차 P1 회귀 ──────────────────────────────────────────────────────────

@test "T11: safe only in a body --- block (frontmatter lacks safe) -> rejected fail-closed" {
  cat > "$TEST_HOME/docs/tickets/T011-test.md" <<'EOF'
---
id: T011
title: Body-injection test
status: open
priority: P2
persona: implementer
---

# T011

본문 예시 블록 (frontmatter 아님):

---
safe: true
---
EOF
  _commit_all "add T011"

  # picker: 후보 제외 + awaiting 마크 없음
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP] T011"* ]]
  [[ "$output" != *"docs/tickets/T011-test.md"* ]]
  grep -q '^status: open$' "$TEST_HOME/docs/tickets/T011-test.md"

  # run_loop: 실행 거부
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T011' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T011-test.md" ]
}

@test "T12: duplicate safe declarations in frontmatter -> rejected fail-closed rc=14" {
  cat > "$TEST_HOME/docs/tickets/T012-test.md" <<'EOF'
---
id: T012
title: Duplicate safe test
status: open
priority: P2
safe: false
safe: true
persona: implementer
---

# T012
EOF
  _commit_all "add T012"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T012' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"2"*"1"* ]]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[SKIP] T012"* ]]
}

@test "T13: valid marker but ticket has no scope section -> unverifiable rc=14" {
  cat > "$TEST_HOME/docs/tickets/T013-test.md" <<'EOF'
---
id: T013
title: Unverifiable scope test
status: open
priority: P2
safe: false
persona: implementer
---

# T013
EOF
  _make_approval T013 valid
  _commit_all "add T013"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T013' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"unverifiable"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T013-test.md" ]
}

@test "T14: TODO-draft scope_confirmation marker -> unverifiable rc=14" {
  _make_ticket T014 false
  cat > "$TEST_HOME/docs/approvals/T014.md" <<'EOF'
approved_by: "Test User"
approved_at: "2026-07-10T10:00:00+09:00"
scope_confirmation: "TODO: confirm exact approved scope for T014"
rollback_plan: "git revert HEAD"
EOF
  _commit_all "add T014"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T014' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"unverifiable"* ]]
}

# ── 리뷰 4차 P1/P2 회귀 ──────────────────────────────────────────────────────

@test "T15: unclosed frontmatter (no closing ---) -> rejected fail-closed" {
  cat > "$TEST_HOME/docs/tickets/T015-test.md" <<'EOF'
---
id: T015
title: Unclosed frontmatter test
status: open
priority: P2
safe: true
persona: implementer
EOF
  _commit_all "add T015"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T015' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T015-test.md" ]

  # picker: status도 무효(빈 값)라 후보에서 제외
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"docs/tickets/T015-test.md"* ]]
}

@test "T16: indented safe under a nested key -> rejected fail-closed rc=14" {
  cat > "$TEST_HOME/docs/tickets/T016-test.md" <<'EOF'
---
id: T016
title: Nested safe test
status: open
priority: P2
metadata:
  safe: true
persona: implementer
---

# T016
EOF
  _commit_all "add T016"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T016' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T016-test.md" ]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"docs/tickets/T016-test.md"* ]]
}

@test "T17: approve.sh with long scope section does not die on SIGPIPE and yields valid marker" {
  cat > "$TEST_HOME/docs/tickets/T017-test.md" <<'EOF'
---
id: T017
title: Long scope test
status: awaiting-approval
priority: P2
safe: false
persona: implementer
---

# T017

## 변경 범위

EOF
  # 긴 섹션 — 과거 `awk | head -3` 조합은 head 조기 종료로 awk가 SIGPIPE(141)로 죽었다
  for i in $(seq 1 400); do
    echo "- scope line number $i with enough padding text to fill the pipe buffer quickly" >> "$TEST_HOME/docs/tickets/T017-test.md"
  done
  _commit_all "add T017"

  run bash -c 'cd "$1" && EDITOR= RALPH_APPROVED_BY=Tester ./scripts/approve.sh T017' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/approvals/T017.md" ]
  grep -q '^scope_confirmation: "scope line number 1' "$TEST_HOME/docs/approvals/T017.md"
  # 생성 직후 검증기 판정이 ok여야 run_loop도 통과한다
  [[ "$output" == *"validator: ok"* ]]
}

# ── 리뷰 5차 P1 회귀 ──────────────────────────────────────────────────────────

@test "T18: duplicate status declarations -> run_loop rejects rc=14 (both orders)" {
  cat > "$TEST_HOME/docs/tickets/T018-test.md" <<'EOF'
---
id: T018
title: Dup status open-done
status: open
status: done
priority: P2
safe: true
persona: implementer
---
# T018
EOF
  cat > "$TEST_HOME/docs/tickets/T019-test.md" <<'EOF'
---
id: T019
title: Dup status done-open
status: done
status: open
priority: P2
safe: true
persona: implementer
---
# T019
EOF
  _commit_all "add T018 T019"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T018' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"status"* ]]
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T019' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  # picker도 양쪽 모두 후보 제외
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"docs/tickets/T018-test.md"* ]]
  [[ "$output" != *"docs/tickets/T019-test.md"* ]]
}

@test "T20: CRLF ticket -> run_loop rejects and approve --reject fails without touching file" {
  printf -- '---\r\nid: T020\r\ntitle: CRLF ticket\r\nstatus: open\r\npriority: P2\r\nsafe: true\r\npersona: implementer\r\n---\r\n\r\n# T020\r\n' \
    > "$TEST_HOME/docs/tickets/T020-test.md"
  _commit_all "add T020"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T020' _ "$TEST_HOME"
  [ "$status" -eq 14 ]

  local before_hash
  before_hash=$(git -C "$TEST_HOME" hash-object docs/tickets/T020-test.md)
  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "bad ticket" T020' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  # 원본 무변조 (과거: rc=0 '성공' 보고 + status 미변경)
  [ "$(git -C "$TEST_HOME" hash-object docs/tickets/T020-test.md)" = "$before_hash" ]
}

@test "T21: ---trailing closer -> approve --reject fails without mutating body status" {
  cat > "$TEST_HOME/docs/tickets/T021-test.md" <<'EOF'
---
id: T021
title: Trailing closer
status: open
priority: P2
safe: true
persona: implementer
---trailing

# T021

status: body-note-must-survive
EOF
  _commit_all "add T021"

  local before_hash
  before_hash=$(git -C "$TEST_HOME" hash-object docs/tickets/T021-test.md)
  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "bad closer" T021' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [ "$(git -C "$TEST_HOME" hash-object docs/tickets/T021-test.md)" = "$before_hash" ]
  grep -q "status: body-note-must-survive" "$TEST_HOME/docs/tickets/T021-test.md"
}

@test "T22: valid ticket --reject succeeds (status skipped, rejection note appended)" {
  _make_ticket T022 false awaiting-approval
  _commit_all "add T022"

  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "not needed" T022' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  grep -q '^status: skipped$' "$TEST_HOME/docs/tickets/T022-test.md"
  grep -q 'reason: "not needed"' "$TEST_HOME/docs/tickets/T022-test.md"
}

# ── 리뷰 6차 P1/P2 회귀 ──────────────────────────────────────────────────────

@test "T23: frontmatter id mismatch with filename -> rejected rc=14 and picker excludes" {
  cat > "$TEST_HOME/docs/tickets/T023-test.md" <<'EOF'
---
id: T999
title: Mismatched id
status: open
priority: P2
safe: true
persona: implementer
---
# T023
EOF
  _commit_all "add T023"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T023' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [[ "$output" == *"T999"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T023-test.md" ]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"docs/tickets/T023-test.md"* ]]
}

@test "T24: missing frontmatter id -> rejected rc=14" {
  cat > "$TEST_HOME/docs/tickets/T024-test.md" <<'EOF'
---
title: No id
status: open
priority: P2
safe: true
persona: implementer
---
# T024
EOF
  _commit_all "add T024"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T024' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T024-test.md" ]
}

@test "T25: persona path traversal (../docs/master-spec) -> rejected rc=12" {
  cat > "$TEST_HOME/docs/tickets/T025-test.md" <<'EOF'
---
id: T025
title: Persona traversal
status: open
priority: P2
safe: true
persona: ../docs/master-spec
---
# T025
EOF
  _commit_all "add T025"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T025' _ "$TEST_HOME"
  [ "$status" -eq 12 ]
  [[ "$output" == *"persona"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T025-test.md" ]
}

@test "T26: quoted scalars (status/persona/safe) accepted consistently with server" {
  cat > "$TEST_HOME/docs/tickets/T026-test.md" <<'EOF'
---
id: T026
title: Quoted scalars
status: "open"
priority: P2
safe: "true"
persona: "implementer"
---
# T026
EOF
  _commit_all "add T026"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T026' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/tickets/DONE/T026-test.md" ]
}

# ── 리뷰 7차 P1 회귀 ──────────────────────────────────────────────────────────

@test "T27: specific ticket lookup is exact (prefix T999 must not select T9990)" {
  _make_ticket T9990 true
  _commit_all "add T9990"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T999 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  [[ "$output" == *"정확히 대응하는 티켓이 없습니다"* ]]

  # 복수 매치도 거부
  _make_ticket T999 true
  cp "$TEST_HOME/docs/tickets/T999-test.md" "$TEST_HOME/docs/tickets/T999-second.md"
  sed -i.bak 's/^id: T999$/id: T999/' "$TEST_HOME/docs/tickets/T999-second.md" && rm -f "$TEST_HOME/docs/tickets/T999-second.md.bak"
  _commit_all "add ambiguous T999"
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T999 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  [[ "$output" == *"모호"* ]]
}

@test "T28: persona resolved through symlinked skill file -> refused rc=12" {
  ln -s ../docs/master-spec.md "$TEST_HOME/skills/linked.md"
  cat > "$TEST_HOME/docs/tickets/T028-test.md" <<'EOF'
---
id: T028
title: Symlinked persona
status: open
priority: P2
safe: true
persona: linked
---
# T028
EOF
  _commit_all "add T028 and symlinked skill"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T028 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 12 ]
  [[ "$output" == *"symlink"* ]]
  [ ! -f "$TEST_HOME/docs/tickets/DONE/T028-test.md" ]
}

@test "T29: server parser agrees with shell on quoted scalars and strict delimiters" {
  command -v node >/dev/null 2>&1 || skip "node not available"
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[1], 'utf8');
const fnStart = src.indexOf('function parseFrontmatter');
const fnEnd = src.indexOf('// ── Read model');
const parseFrontmatter = new Function(src.slice(fnStart, fnEnd) + '; return parseFrontmatter;')();
const quoted = parseFrontmatter('---\nid: T1\nstatus: \"open\"\nsafe: \"true\"\npersona: \"implementer\"\n---\nbody');
if (!quoted || quoted.safe !== true || quoted.status !== 'open' || quoted.persona !== 'implementer') { console.error('quoted mismatch', quoted); process.exit(1); }
const single = parseFrontmatter('---\nid: T1\nstatus: open\nsafe: \'true\'\n---\nbody');
if (!single || single.safe !== true) { console.error('single-quote mismatch', single); process.exit(1); }
const crlf = parseFrontmatter('---\r\nid: T1\r\nstatus: open\r\n---\r\nbody');
const trailing = parseFrontmatter('---\nid: T1\nstatus: open\n---trailing\nbody');
if (crlf !== null || trailing !== null) { console.error('delimiter mismatch', crlf, trailing); process.exit(1); }
console.log('server-shell-parser-consistent');
" "$REPO_ROOT/mission-control/server.mjs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"server-shell-parser-consistent"* ]]
}

# ── 리뷰 8차 P1 회귀 ──────────────────────────────────────────────────────────

@test "T30: symlinked ticket file -> run_loop rc=11 and picker excludes" {
  echo "external target" > "$TEST_HOME/outside-T030.md"
  ln -s ../../outside-T030.md "$TEST_HOME/docs/tickets/T030-link.md"
  _commit_all "add symlinked ticket"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T030 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  [[ "$output" == *"symlink"* ]]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"docs/tickets/T030-link.md"* ]]
}

@test "T31: docs/tickets directory replaced by symlink -> fail-closed everywhere" {
  _make_ticket T031 true
  _commit_all "add T031"
  mv "$TEST_HOME/docs/tickets" "$TEST_HOME/docs/real-tickets"
  ln -s real-tickets "$TEST_HOME/docs/tickets"

  # 리뷰 9차 P2: 구성 오류는 idle로 위장하지 않는다 — run_loop rc=4, picker exit 2
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T031 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 4 ]
  [[ "$output" == *"symlink"* ]]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" != *"T031"* ]]
}

@test "T32: skills directory replaced by symlink -> persona routing refused rc=12" {
  _make_ticket T032 true
  _commit_all "add T032"
  mv "$TEST_HOME/skills" "$TEST_HOME/real-skills"
  ln -s real-skills "$TEST_HOME/skills"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T032 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 12 ]
  [[ "$output" == *"skills"* ]]
}

# ── 리뷰 9차 P1/P2 회귀 ──────────────────────────────────────────────────────

@test "T33: approve --reject on symlinked ticket -> refused, target untouched" {
  cat > "$TEST_HOME/outside-T033.md" <<'EOF'
---
id: T033
title: external target
status: open
priority: P2
safe: false
persona: implementer
---
# external
EOF
  ln -s ../../outside-T033.md "$TEST_HOME/docs/tickets/T033-link.md"
  _commit_all "add symlinked ticket T033"

  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "no" T033' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  # 외부 대상 파일은 무변조
  grep -q '^status: open$' "$TEST_HOME/outside-T033.md"
  [ ! -f "$TEST_HOME/docs/approvals/T033.md" ]
}

@test "T34: dry-run with foreign state/lock preserves it (ownership-scoped cleanup)" {
  _make_ticket T034 true
  _commit_all "add T034"
  echo "foreign-owner" > "$TEST_HOME/state/lock"
  echo "docs/tickets/other.md" > "$TEST_HOME/state/current_ticket"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T034 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  # foreign 실행 상태가 살아 있어야 한다 (과거: EXIT trap이 무조건 삭제)
  [ -f "$TEST_HOME/state/lock" ]
  [ "$(cat "$TEST_HOME/state/lock")" = "foreign-owner" ]
  [ -f "$TEST_HOME/state/current_ticket" ]
}

@test "T35: server parser does not double-unquote nested quotes" {
  command -v node >/dev/null 2>&1 || skip "node not available"
  # safe: "'true'" — 외곽 큰따옴표 한 겹만 벗겨야 하며 boolean true로 승격되면 안 된다
  printf -- '---\nid: T906\nstatus: open\nsafe: "%s"\n---\nbody' "'true'" > "$TEST_HOME/nested.md"
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[1], 'utf8');
const fnStart = src.indexOf('function parseFrontmatter');
const fnEnd = src.indexOf('// ── Read model');
const parseFrontmatter = new Function(src.slice(fnStart, fnEnd) + '; return parseFrontmatter;')();
const nested = parseFrontmatter(readFileSync(process.argv[2], 'utf8'));
if (!nested || nested.safe === true || nested.safe === false) { console.error('nested unquote mismatch', nested); process.exit(1); }
console.log('nested-quote-preserved');
" "$REPO_ROOT/mission-control/server.mjs" "$TEST_HOME/nested.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nested-quote-preserved"* ]]
}
