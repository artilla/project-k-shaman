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
  cp "$REPO_ROOT/scripts/ticket_edit.sh" "$TEST_HOME/scripts/ticket_edit.sh"
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

# ── 리뷰 10차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T36: concurrent run_loop -> exactly one acquires the atomic lock" {
  _make_ticket T036 true
  _commit_all "add T036"
  cat > "$TEST_HOME/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
sleep 2
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"

  ( cd "$TEST_HOME" && ./scripts/run_loop.sh T036 >/dev/null 2>&1 ) &
  local p1=$!
  ( cd "$TEST_HOME" && ./scripts/run_loop.sh T036 >/dev/null 2>&1 ) &
  local p2=$!
  local r1=0 r2=0
  wait "$p1" || r1=$?
  wait "$p2" || r2=$?
  # 정확히 하나가 lock 거부(rc=3)여야 한다 (둘 다 진입 금지)
  if [ "$r1" -eq 3 ]; then [ "$r2" -ne 3 ]; else [ "$r2" -eq 3 ]; fi
}

@test "T37: picker generic failure (rc=42) propagates, not treated as idle" {
  cat > "$TEST_HOME/scripts/pick_next_ticket.sh" <<'EOF'
#!/usr/bin/env bash
echo "picker internal error" >&2
exit 42
EOF
  chmod +x "$TEST_HOME/scripts/pick_next_ticket.sh"
  _commit_all "fake failing picker"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  [[ "$output" == *"idle로 처리하지 않습니다"* ]]
  [[ "$output" != *"처리할 open 티켓 없음"* ]]
}

@test "T38: DONE directory symlink -> picker refuses exit 2 (deps cannot be satisfied externally)" {
  rmdir "$TEST_HOME/docs/tickets/DONE" 2>/dev/null || rm -rf "$TEST_HOME/docs/tickets/DONE"
  mkdir -p "$TEST_HOME/external-done"
  printf -- '---\nid: T001\nstatus: done\nsafe: true\n---\n' > "$TEST_HOME/external-done/T001-dep.md"
  ln -s ../../external-done "$TEST_HOME/docs/tickets/DONE"
  cat > "$TEST_HOME/docs/tickets/T038-test.md" <<'EOF'
---
id: T038
title: dep test
status: open
priority: P2
safe: true
persona: implementer
depends_on: [T001]
---
# T038
EOF
  _commit_all "add T038 with symlinked DONE"

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 2 ]
  [[ "$output" != *"T038-test.md"* ]]

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T038 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 4 ]
}

@test "T39: docs/approvals symlink -> approve refused and validator returns unverifiable" {
  _make_ticket T039 false
  _commit_all "add T039"
  rmdir "$TEST_HOME/docs/approvals" 2>/dev/null || rm -rf "$TEST_HOME/docs/approvals"
  mkdir -p "$TEST_HOME/external-approvals"
  ln -s ../external-approvals "$TEST_HOME/docs/approvals"

  run bash -c 'cd "$1" && EDITOR= ./scripts/approve.sh T039' _ "$TEST_HOME"
  [ "$status" -eq 2 ]
  [ "$(ls "$TEST_HOME/external-approvals" | wc -l | tr -d ' ')" = "0" ]

  # 외부에 마커가 있어도 검증기는 unverifiable(exit 6) — safe:false 실행 승인 불성립
  printf -- 'approved_by: "T"\napproved_at: "2026-07-10T09:00:00+09:00"\nscope_confirmation: "Test scope is approved"\nrollback_plan: "git revert HEAD"\n' \
    > "$TEST_HOME/external-approvals/T039.md"
  run node "$TEST_HOME/mission-control/approval.mjs" "$TEST_HOME" T039
  [ "$status" -eq 6 ]

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T039' _ "$TEST_HOME"
  [ "$status" -eq 14 ]
}

@test "T40: hardlinked ticket -> writer refuses (links>1 guard)" {
  _make_ticket T040 true
  _commit_all "add T040"
  ln "$TEST_HOME/docs/tickets/T040-test.md" "$TEST_HOME/hardlink-copy.md"

  run bash -c 'cd "$1" && ./scripts/ticket_edit.sh set-priority T040 P1' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"hardlink"* ]]
  grep -q '^priority: P2$' "$TEST_HOME/docs/tickets/T040-test.md"
}

@test "T41: CR-contaminated safe line -> shell rejects and server invalidates the field alike" {
  printf -- '---\nid: T041\ntitle: t\nstatus: open\npriority: P2\nsafe: true\r\npersona: implementer\n---\n# T041\n' \
    > "$TEST_HOME/docs/tickets/T041-test.md"
  _commit_all "add T041 with CR safe line"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T041' _ "$TEST_HOME"
  [ "$status" -eq 14 ]

  command -v node >/dev/null 2>&1 || skip "node not available"
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[1], 'utf8');
const fnStart = src.indexOf('function parseFrontmatter');
const fnEnd = src.indexOf('// ── Read model');
const parseFrontmatter = new Function(src.slice(fnStart, fnEnd) + '; return parseFrontmatter;')();
const fm = parseFrontmatter(readFileSync(process.argv[2], 'utf8'));
if (fm && fm.safe === true) { console.error('server promoted CR line', fm); process.exit(1); }
console.log('cr-line-invalidated');
" "$REPO_ROOT/mission-control/server.mjs" "$TEST_HOME/docs/tickets/T041-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cr-line-invalidated"* ]]
}

# ── 리뷰 11차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T42: CR safe line plus normal safe line -> both shell and server treat as duplicate" {
  printf -- '---\nid: T042\ntitle: t\nstatus: open\npriority: P2\nsafe: true\r\nsafe: true\npersona: implementer\n---\n# T042\n' \
    > "$TEST_HOME/docs/tickets/T042-test.md"
  _commit_all "add T042 CR duplicate"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T042' _ "$TEST_HOME"
  [ "$status" -eq 14 ]

  command -v node >/dev/null 2>&1 || skip "node not available"
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[1], 'utf8');
const fnStart = src.indexOf('function parseFrontmatter');
const fnEnd = src.indexOf('// ── Read model');
const parseFrontmatter = new Function(src.slice(fnStart, fnEnd) + '; return parseFrontmatter;')();
const fm = parseFrontmatter(readFileSync(process.argv[2], 'utf8'));
if (!fm || !(fm._duplicateKeys || []).includes('safe')) { console.error('server missed CR duplicate', fm); process.exit(1); }
console.log('cr-duplicate-detected');
" "$REPO_ROOT/mission-control/server.mjs" "$TEST_HOME/docs/tickets/T042-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cr-duplicate-detected"* ]]
}

@test "T43: malformed dependency id (glob) does not satisfy deps" {
  _make_ticket T001 true done
  git -C "$TEST_HOME" mv docs/tickets/T001-test.md docs/tickets/DONE/T001-test.md 2>/dev/null || {
    mv "$TEST_HOME/docs/tickets/T001-test.md" "$TEST_HOME/docs/tickets/DONE/T001-test.md"
  }
  cat > "$TEST_HOME/docs/tickets/T043-test.md" <<'EOF'
---
id: T043
title: dep glob test
status: open
priority: P2
safe: true
persona: implementer
depends_on: [T*]
---
# T043
EOF
  _commit_all "add T043 with glob dep"

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T043-test.md"* ]]
}

@test "T44: dry-run in non-git dir cannot be switched to co-pilot via loop_mode" {
  # 주의: TEST_HOME 하위는 git 워크트리 내부라 non-git이 아니다 — repo 밖 임시 디렉터리 사용.
  local ng
  ng="$(mktemp -d)"
  mkdir -p "$ng/scripts" "$ng/docs/tickets/DONE" "$ng/skills" "$ng/state" "$ng/mission-control"
  cp "$TEST_HOME/scripts/run_loop.sh" "$ng/scripts/"
  cp "$TEST_HOME/scripts/run_checks.sh" "$ng/scripts/"
  cp "$TEST_HOME/mission-control/approval.mjs" "$ng/mission-control/"
  cat > "$ng/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "MUST-NOT-DISPATCH" >&2
exit 99
EOF
  cat > "$ng/scripts/pick_next_ticket.sh" <<'EOF'
#!/usr/bin/env bash
ls docs/tickets/T*.md 2>/dev/null | head -1
EOF
  chmod +x "$ng/scripts/"*.sh
  echo stub > "$ng/skills/implementer.md"
  echo x > "$ng/docs/master-spec.md"; echo x > "$ng/docs/runbook.md"
  cat > "$ng/docs/tickets/T044-test.md" <<'EOF'
---
id: T044
title: t
status: open
priority: P2
safe: true
persona: implementer
---
# T044
EOF
  echo "co-pilot" > "$ng/state/loop_mode"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T044 --dry-run' _ "$ng"
  rm -rf "$ng"
  [[ "$output" != *"MUST-NOT-DISPATCH"* ]]
  [[ "$output" == *"실행 전제조건 미충족"* ]]
}

# ── 리뷰 12차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T45: specific-ticket invocation still enforces depends_on (rc=11)" {
  cat > "$TEST_HOME/docs/tickets/T450-test.md" <<'EOF'
---
id: T450
title: t
status: open
priority: P2
safe: true
persona: implementer
depends_on: [T999]
---
# T450
EOF
  _commit_all "add T450 with unmet dep"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T450' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  [[ "$output" == *"depends_on 미충족"* ]]
}

@test "T46: fake DONE evidence (id mismatch) does not satisfy deps; real evidence does" {
  cat > "$TEST_HOME/docs/tickets/T460-test.md" <<'EOF'
---
id: T460
title: t
status: open
priority: P2
safe: true
persona: implementer
depends_on: [T001]
---
# T460
EOF
  # 파일명은 T001이지만 frontmatter id/status가 다른 가짜 증거 (tracked)
  printf -- '---\nid: T777\nstatus: open\nsafe: true\n---\n' > "$TEST_HOME/docs/tickets/DONE/T001-fake.md"
  _commit_all "add T460 + fake done evidence"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T460' _ "$TEST_HOME"
  [ "$status" -eq 11 ]

  # 진짜 증거로 교체하면 충족된다
  printf -- '---\nid: T001\nstatus: done\nsafe: true\n---\n' > "$TEST_HOME/docs/tickets/DONE/T001-fake.md"
  _commit_all "fix done evidence"
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T460 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
}

@test "T47: whitespace-broken dep id is not normalized into a valid id" {
  _make_ticket T001 true done
  git -C "$TEST_HOME" mv docs/tickets/T001-test.md docs/tickets/DONE/T001-test.md 2>/dev/null || \
    mv "$TEST_HOME/docs/tickets/T001-test.md" "$TEST_HOME/docs/tickets/DONE/T001-test.md"
  cat > "$TEST_HOME/docs/tickets/T470-test.md" <<'EOF'
---
id: T470
title: t
status: open
priority: P2
safe: true
persona: implementer
depends_on: [T 0 0 1]
---
# T470
EOF
  _commit_all "add T470 with whitespace dep"

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T470-test.md"* ]]
}

@test "T48: lock token replaced mid-cycle -> rc=16 and the foreign lock is preserved" {
  _make_ticket T480 true open
  # run_headless가 사이클 도중 state/lock을 탈취(토큰 교체)한다
  cat > "$TEST_HOME/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "stolen-token" > state/lock
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  _commit_all "add T480 + token-stealing fake"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T480' _ "$TEST_HOME"
  [ "$status" -eq 16 ]
  [[ "$output" == *"토큰이 교체"* ]]
  # 남의 lock을 지우지 않는다
  [ "$(cat "$TEST_HOME/state/lock")" = "stolen-token" ]
}

@test "T49: approve --reject publishes status+Rejection atomically; malformed frontmatter leaves file untouched" {
  _make_ticket T490 false awaiting-approval
  _commit_all "add T490"

  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "nope" T490' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  # 단일 publish 결과: status와 Rejection이 함께 반영
  grep -q '^status: skipped' "$TEST_HOME/docs/tickets/T490-test.md"
  grep -q '## Rejection' "$TEST_HOME/docs/tickets/T490-test.md"
  # stage/temp 잔여물 없음
  [ -z "$(ls "$TEST_HOME/docs/tickets/".stage.* 2>/dev/null)" ]

  # CRLF opener(malformed) 티켓은 아무것도 바뀌지 않은 채 실패한다
  printf -- '---\r\nid: T491\nstatus: open\nsafe: false\n---\n# T491\n' > "$TEST_HOME/docs/tickets/T491-test.md"
  _commit_all "add malformed T491"
  local before
  before="$(cksum "$TEST_HOME/docs/tickets/T491-test.md")"
  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "nope" T491' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [ "$before" = "$(cksum "$TEST_HOME/docs/tickets/T491-test.md")" ]
}

@test "T50: concurrent approval race -> existing marker is preserved, not overwritten" {
  _make_ticket T500 false awaiting-approval
  printf -- '---\nid: T500\ndecision: reject\n---\nprior decision\n' > "$TEST_HOME/docs/approvals/T500.md"
  _commit_all "add T500 + prior marker"

  local before
  before="$(cksum "$TEST_HOME/docs/approvals/T500.md")"
  run bash -c 'cd "$1" && ./scripts/approve.sh T500' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  # 먼저 도착한 결정이 보존된다 (덮어쓰기 없음)
  [ "$before" = "$(cksum "$TEST_HOME/docs/approvals/T500.md")" ]
  grep -q 'prior decision' "$TEST_HOME/docs/approvals/T500.md"
  [ -z "$(ls "$TEST_HOME/docs/approvals/".marker.* 2>/dev/null)" ]
}

@test "T51: CR-contaminated persona line -> shell rc=12 and server flags persona_malformed" {
  printf -- '---\nid: T510\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\r\n---\n# T510\n' \
    > "$TEST_HOME/docs/tickets/T510-test.md"
  _commit_all "add T510 CR persona"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T510' _ "$TEST_HOME"
  [ "$status" -eq 12 ]

  command -v node >/dev/null 2>&1 || skip "node not available"
  run node --input-type=module -e "
import { readFileSync } from 'node:fs';
const src = readFileSync(process.argv[1], 'utf8');
const fnStart = src.indexOf('function parseFrontmatter');
const fnEnd = src.indexOf('// ── Read model');
const parseFrontmatter = new Function(src.slice(fnStart, fnEnd) + '; return parseFrontmatter;')();
const fm = parseFrontmatter(readFileSync(process.argv[2], 'utf8'));
const crKeys = (fm && fm._crKeys) || [];
if (!crKeys.includes('persona')) { console.error('server missed CR persona', fm); process.exit(1); }
console.log('cr-persona-flagged');
" "$REPO_ROOT/mission-control/server.mjs" "$TEST_HOME/docs/tickets/T510-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cr-persona-flagged"* ]]
}

# ── 리뷰 13차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T52: malformed dep values are not promoted; inline comment is tolerated" {
  printf -- '---\nid: T001\ntitle: t\nstatus: done\nsafe: true\n---\n# T001\n' > "$TEST_HOME/docs/tickets/DONE/T001-dep.md"
  # 내부 브래킷 — [T[001]]이 T001로 승격되면 안 된다
  printf -- '---\nid: T520\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [T[001]]\n---\n# T520\n' > "$TEST_HOME/docs/tickets/T520-test.md"
  # 미폐 quote — "T001' 도 승격 금지
  printf -- '---\nid: T521\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: ["T001'"'"']\n---\n# T521\n' > "$TEST_HOME/docs/tickets/T521-test.md"
  # 정상 inline comment는 dependency 판정을 방해하지 않는다
  printf -- '---\nid: T522\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [T001] # after T001\n---\n# T522\n' > "$TEST_HOME/docs/tickets/T522-test.md"
  _commit_all "add T52x dep parser cases"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T520 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T521 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T522 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 0 ]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T520-test.md"* ]]
  [[ "$output" != *"T521-test.md"* ]]
  [[ "$output" == *"T522-test.md"* ]]
}

@test "T53: lock token stolen after pre-cycle tag -> no reservation/dispatch, rc=16" {
  _make_ticket T530 true open
  cat > "$TEST_HOME/scripts/run_headless.sh" <<'EOF'
#!/usr/bin/env bash
echo "MUST-NOT-DISPATCH" >&2
exit 99
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  _commit_all "add T530"

  # git tag 시점(예약 직전)에 lock을 탈취하는 git wrapper
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/bin"
  cat > "$TEST_HOME/bin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "tag" ]; then echo stolen > "$TEST_HOME/state/lock"; fi
exec "$realgit" "\$@"
EOF
  chmod +x "$TEST_HOME/bin/git"

  run bash -c 'cd "$1" && PATH="$1/bin:$PATH" ./scripts/run_loop.sh T530' _ "$TEST_HOME"
  [ "$status" -eq 16 ]
  [[ "$output" != *"MUST-NOT-DISPATCH"* ]]
  [[ "$output" == *"예약 직전"* ]]
  # 남의 lock 보존
  [ "$(cat "$TEST_HOME/state/lock")" = "stolen" ]
}

@test "T54: headless leaving detached background descendants -> reaped, result not trusted" {
  _make_ticket T540 true open
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
awk '/^---\$/{fm=!fm;print;next} fm && \$1=="status:"{print "status: done";next}{print}' \
  docs/tickets/T540-test.md > /tmp/t540.\$\$ && mv /tmp/t540.\$\$ docs/tickets/T540-test.md
git mv docs/tickets/T540-test.md docs/tickets/DONE/T540-test.md
git add -A; git commit -qm "T540: done"
( sleep 6; echo late > "$TEST_HOME/late.txt" ) >/dev/null 2>&1 &
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  _commit_all "add T540"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T540' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"잔존 자손"* ]]
  sleep 7
  # 지연 writer는 회수되어 worktree를 오염시키지 못한다
  [ ! -f "$TEST_HOME/late.txt" ]
}

@test "T55: decisions serialize with ticket status - skipped ticket cannot be approved or re-rejected" {
  _make_ticket T550 false open
  # 이미 reject된 상태를 흉내
  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "first" T550' _ "$TEST_HOME"
  [ "$status" -eq 0 ]

  run bash -c 'cd "$1" && ./scripts/approve.sh T550' _ "$TEST_HOME"
  [ "$status" -eq 3 ]
  [ ! -f "$TEST_HOME/docs/approvals/T550.md" ]

  run bash -c 'cd "$1" && ./scripts/approve.sh --reject "second" T550' _ "$TEST_HOME"
  [ "$status" -eq 3 ]
  # 첫 결정(Rejection 1회)만 남는다
  [ "$(grep -c '## Rejection' "$TEST_HOME/docs/tickets/T550-test.md")" -eq 1 ]
}

@test "T56: reject producer partial failure (awk dies mid-stream) leaves the ticket untouched" {
  _make_ticket T560 false awaiting-approval
  _commit_all "add T560"

  local realawk
  realawk="$(command -v awk)"
  mkdir -p "$TEST_HOME/fakebin"
  cat > "$TEST_HOME/fakebin/awk" <<EOF
#!/usr/bin/env bash
"$realawk" "\$@" | head -3
exit 1
EOF
  chmod +x "$TEST_HOME/fakebin/awk"

  local before
  before="$(cksum "$TEST_HOME/docs/tickets/T560-test.md")"
  run bash -c 'cd "$1" && PATH="$1/fakebin:$PATH" ./scripts/approve.sh --reject "no" T560' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [ "$before" = "$(cksum "$TEST_HOME/docs/tickets/T560-test.md")" ]
  [ -z "$(ls "$TEST_HOME/docs/tickets/".stage.* 2>/dev/null)" ]
}

@test "T58: true concurrent approval race - ln loser aborts, winner's decision untouched" {
  _make_ticket T580 false awaiting-approval
  _commit_all "add T580"

  # 생성 창(-f 검사 후 ~ ln 전) 한가운데서 호출되는 date를 가로채 경쟁자의 마커를
  # 먼저 심는다 — 결정적(deterministic) 동시 승인 경합 재현.
  local realdate
  realdate="$(command -v date)"
  mkdir -p "$TEST_HOME/racebin"
  cat > "$TEST_HOME/racebin/date" <<EOF
#!/usr/bin/env bash
m="$TEST_HOME/docs/approvals/T580.md"
if [ ! -e "\$m" ]; then
  printf 'approved_by: "rival"\napproved_at: "2026-01-01T00:00:00+00:00"\nscope_confirmation: "rival"\nrollback_plan: "rival"\n' > "\$m.rival.\$\$"
  ln "\$m.rival.\$\$" "\$m" 2>/dev/null || true
  rm -f "\$m.rival.\$\$"
fi
exec "$realdate" "\$@"
EOF
  chmod +x "$TEST_HOME/racebin/date"

  run bash -c 'cd "$1" && PATH="$1/racebin:$PATH" EDITOR=true ./scripts/approve.sh T580' _ "$TEST_HOME"
  [ "$status" -eq 3 ]
  [[ "$output" == *"동시 승인 경합"* ]]
  # 패자는 남의 마커를 편집/검증 대상으로 삼지 않는다
  [[ "$output" != *"approval marker ready"* ]]
  # 승자(경쟁자)의 결정이 그대로 보존된다
  grep -q 'approved_by: "rival"' "$TEST_HOME/docs/approvals/T580.md"
  [ "$(grep -c 'approved_by:' "$TEST_HOME/docs/approvals/T580.md")" -eq 1 ]
}

@test "T57: concurrent writers are serialized - no silent lost update" {
  _make_ticket T570 true open
  _commit_all "add T570"

  # bats는 test 본문을 errexit로 실행 — 실패 rc를 `|| rc=$?`로 잡아야 서브셸이
  # rc 기록 전에 중단되지 않는다.
  ( cd "$TEST_HOME" && rc=0 && ./scripts/ticket_edit.sh set-priority T570 P1 > "$TEST_HOME/w_a.log" 2>&1 || rc=$?; echo "$rc" > "$TEST_HOME/w_a.rc" ) &
  ( cd "$TEST_HOME" && rc=0 && ./scripts/ticket_edit.sh set-labels T570 "alpha,beta" > "$TEST_HOME/w_b.log" 2>&1 || rc=$?; echo "$rc" > "$TEST_HOME/w_b.rc" ) &
  wait

  local f="$TEST_HOME/docs/tickets/T570-test.md"
  # 리뷰 16차 P1: 기준(CAS) 캡처가 lock 안으로 들어가면서 동시 writer는 "직렬화되어
  # 둘 다 반영"된다 — 과거의 '한쪽이 내용 변경 감지로 거부' 허용 분기는 lost update를
  # 사용자에게 전가하던 결함의 관용이었다. 이제 두 편집 모두 성공해야 한다.
  [ "$(cat "$TEST_HOME/w_a.rc")" -eq 0 ]
  [ "$(cat "$TEST_HOME/w_b.rc")" -eq 0 ]
  grep -q '^priority: P1' "$f"
  grep -q '^labels: \["alpha", "beta"\]' "$f"
  # write lock 잔존 없음
  [ ! -d "$TEST_HOME/state/ticket_write.lock.d" ]
}

# ── 리뷰 14차 P1/P2 회귀 ──────────────────────────────────────────────────────

@test "T59: empty-element dependency lists ([,] / [T001,]) are malformed, not dependency-free" {
  printf -- '---\nid: T001\ntitle: t\nstatus: done\nsafe: true\n---\n# T001\n' > "$TEST_HOME/docs/tickets/DONE/T001-dep.md"
  printf -- '---\nid: T595\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [,]\n---\n# T595\n' > "$TEST_HOME/docs/tickets/T595-test.md"
  printf -- '---\nid: T596\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [T001,]\n---\n# T596\n' > "$TEST_HOME/docs/tickets/T596-test.md"
  _commit_all "add T59x empty-element dep cases"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T595 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T596 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T595-test.md"* ]]
  [[ "$output" != *"T596-test.md"* ]]
}

@test "T60: DONE evidence with duplicate id/status declarations is not accepted" {
  # 중복 id (첫 값만 읽혀 우회 가능) — 증거 불인정
  printf -- '---\nid: T601\nid: T999\ntitle: t\nstatus: done\nsafe: true\n---\n# T601\n' > "$TEST_HOME/docs/tickets/DONE/T601-dep.md"
  # 중복 status — 증거 불인정
  printf -- '---\nid: T602\ntitle: t\nstatus: done\nstatus: open\nsafe: true\n---\n# T602\n' > "$TEST_HOME/docs/tickets/DONE/T602-dep.md"
  printf -- '---\nid: T605\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [T601]\n---\n# T605\n' > "$TEST_HOME/docs/tickets/T605-test.md"
  printf -- '---\nid: T606\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: [T602]\n---\n# T606\n' > "$TEST_HOME/docs/tickets/T606-test.md"
  _commit_all "add T60x duplicate-field evidence cases"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T605 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T606 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]

  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T605-test.md"* ]]
  [[ "$output" != *"T606-test.md"* ]]
}

@test "T61: fake frontmatter block in ticket body does not change picker vs direct-run verdicts" {
  # 실제 frontmatter에는 depends_on이 없고, 본문의 가짜 --- 블록에 미충족 dep이 있다.
  cat > "$TEST_HOME/docs/tickets/T610-test.md" <<'TKT'
---
id: T610
title: fake block test
status: open
priority: P2
safe: true
persona: implementer
---

# T610

## 예시 (frontmatter가 아님)

---
depends_on: [T999]
---

본문 끝.
TKT
  _commit_all "add T610 fake-block ticket"

  # direct-run: 첫 블록만 읽으므로 dep 없음 → 실행 가능
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T610 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  # picker도 동일 판정 — 본문 가짜 블록의 [T999]를 dep으로 읽지 않는다
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" == *"T610-test.md"* ]]
}

@test "T62: approve and reject are mutually serialized - no skipped ticket with a valid approval marker" {
  _make_ticket T620 false awaiting-approval
  _commit_all "add T620"

  # approve의 임계구역(마커 heredoc의 date 호출) 한가운데서 reject를 발사 —
  # 결정적 상호 직렬화 재현. reject는 lock에서 대기한 뒤 마커를 보고 거부해야 한다.
  local realdate
  realdate="$(command -v date)"
  mkdir -p "$TEST_HOME/racebin2"
  cat > "$TEST_HOME/racebin2/date" <<WRAP
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/rej.launched" ]; then
  touch "$TEST_HOME/rej.launched"
  # 주의: bg 서브셸이 command substitution(\$(date ...))의 pipe fd를 물고 있으면
  # approve가 EOF를 기다리며 lock을 오래 쥔다 — fd를 완전히 분리한다.
  ( cd "$TEST_HOME" && ./scripts/approve.sh --reject "concurrent" T620 > "$TEST_HOME/rej.log" 2>&1; echo \$? > "$TEST_HOME/rej.rc" ) > /dev/null 2>&1 < /dev/null &
  sleep 1
fi
exec "$realdate" "\$@"
WRAP
  chmod +x "$TEST_HOME/racebin2/date"

  run bash -c 'cd "$1" && PATH="$1/racebin2:$PATH" EDITOR=true ./scripts/approve.sh T620' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/docs/approvals/T620.md" ]

  # 백그라운드 reject 완료 대기
  local i=0
  while [ ! -f "$TEST_HOME/rej.rc" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done
  [ -f "$TEST_HOME/rej.rc" ]
  [ "$(cat "$TEST_HOME/rej.rc")" -eq 3 ]
  grep -q '승인 마커' "$TEST_HOME/rej.log"

  # 불변식: skipped 상태와 유효 approval marker는 공존하지 않는다
  grep -q '^status: awaiting-approval' "$TEST_HOME/docs/tickets/T620-test.md"
  ! grep -q '## Rejection' "$TEST_HOME/docs/tickets/T620-test.md"
  # write lock 잔존 없음
  [ ! -d "$TEST_HOME/state/ticket_write.lock.d" ]
}

@test "T63: stale write-lock reclaim re-verifies the moved lock's owner - live lock is never deleted" {
  _make_ticket T630 true open
  _commit_all "add T630"

  # 관찰 시점의 dead pid, 그리고 reclaim mv 직전에 끼어드는 live owner를 시뮬레이션
  local deadpid livepid
  sh -c 'exit 0' & deadpid=$!
  wait "$deadpid" 2>/dev/null || true
  sleep 60 & livepid=$!

  mkdir -p "$TEST_HOME/state/ticket_write.lock.d"
  echo "$deadpid" > "$TEST_HOME/state/ticket_write.lock.d/pid"

  local realmv
  realmv="$(command -v mv)"
  mkdir -p "$TEST_HOME/racebin3"
  cat > "$TEST_HOME/racebin3/mv" <<WRAP
#!/usr/bin/env bash
case "\$2" in
  *ticket_write.lock.d.reclaim.*)
    # reclaim 직전, 새 live owner가 lock을 차지한 상황을 주입
    echo "$livepid" > "\$1/pid" 2>/dev/null
    ;;
esac
exec "$realmv" "\$@"
WRAP
  chmod +x "$TEST_HOME/racebin3/mv"

  run bash -c 'cd "$1" && PATH="$1/racebin3:$PATH" ./scripts/ticket_edit.sh set-priority T630 P1' _ "$TEST_HOME"
  # live owner를 만나 대기하다 명시적으로 실패한다 — 조용한 성공(rc=0) 금지
  [ "$status" -ne 0 ]
  [[ "$output" == *"경합 지속"* ]]
  # live lock은 삭제되지 않고 보존된다
  [ -d "$TEST_HOME/state/ticket_write.lock.d" ]
  [ "$(cat "$TEST_HOME/state/ticket_write.lock.d/pid")" = "$livepid" ]
  # 티켓은 무변조
  grep -q '^priority: P2' "$TEST_HOME/docs/tickets/T630-test.md"

  kill "$livepid" 2>/dev/null || true
}

# ── 리뷰 15차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T64: writer audit commits are attributed correctly under concurrency" {
  _make_ticket T640 true open
  _commit_all "add T640"

  # writer A의 commit을 지연시키는 git wrapper — 과거에는 A의 publish 후 lock이
  # 풀려 B의 publish가 끼어들고, A의 `git add`가 B의 변경까지 스테이징해 한
  # 커밋에 두 변경이 오귀속됐다 (B는 diff 없음 → 커밋 생략, 둘 다 rc=0).
  # 리뷰 16차: sleep 기반 경합은 비결정적이었다(누가 먼저 lock을 잡는지 부하
  # 의존, CAS 기준을 lock 밖에서 캡처하던 결함과 결합해 편집 유실) — B는 A의
  # publish를 "파일 내용으로 관찰"한 뒤에만 디스패치한다 (결정적: A가 lock을
  # 쥔 채 commit sleep 중임이 보장된 시점).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/slowgit"
  cat > "$TEST_HOME/slowgit/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "commit" ]; then sleep 1.5; fi
exec "$realgit" "\$@"
EOF
  chmod +x "$TEST_HOME/slowgit/git"

  ( cd "$TEST_HOME" && rc=0 && PATH="$TEST_HOME/slowgit:$PATH" ./scripts/ticket_edit.sh set-priority T640 P1 > "$TEST_HOME/wa.log" 2>&1 || rc=$?; echo "$rc" > "$TEST_HOME/wa.rc" ) &
  local j=0
  while ! grep -q '^priority: P1' "$TEST_HOME/docs/tickets/T640-test.md" 2>/dev/null && [ "$j" -lt 200 ]; do
    sleep 0.05; j=$((j+1))
  done
  grep -q '^priority: P1' "$TEST_HOME/docs/tickets/T640-test.md"   # A publish 확인 (미확인이면 즉시 실패)
  ( cd "$TEST_HOME" && rc=0 && ./scripts/ticket_edit.sh set-labels T640 "alpha" > "$TEST_HOME/wb.log" 2>&1 || rc=$?; echo "$rc" > "$TEST_HOME/wb.rc" ) &
  wait

  [ "$(cat "$TEST_HOME/wa.rc")" -eq 0 ]
  [ "$(cat "$TEST_HOME/wb.rc")" -eq 0 ]
  local fpath="docs/tickets/T640-test.md"
  # 두 변경이 각각 자기 커밋으로 기록된다 (한 커밋에 합쳐지지 않음)
  run git -C "$TEST_HOME" log -2 --format=%s
  [[ "$output" == *"priority"* ]]
  [[ "$output" == *"labels"* ]]
  # labels 커밋에는 priority 변경이 없어야 하고, 그 역도 성립
  local labels_c priority_c
  labels_c="$(git -C "$TEST_HOME" log --format=%H --grep='labels' -1)"
  priority_c="$(git -C "$TEST_HOME" log --format=%H --grep='priority' -1)"
  git -C "$TEST_HOME" show "$labels_c" -- "$fpath" | grep -q '^+labels:'
  ! git -C "$TEST_HOME" show "$labels_c" -- "$fpath" | grep -q '^+priority:'
  git -C "$TEST_HOME" show "$priority_c" -- "$fpath" | grep -q '^+priority:'
  ! git -C "$TEST_HOME" show "$priority_c" -- "$fpath" | grep -q '^+labels:'
  [ ! -d "$TEST_HOME/state/ticket_write.lock.d" ]
}

@test "T65: DONE file with duplicate status declarations is not accepted as completion" {
  _make_ticket T650 true open
  # headless mock: 티켓을 DONE으로 옮기되 status를 중복 선언(done+open)으로 기록
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
f=docs/tickets/T650-test.md
awk '/^---\$/{fm=!fm;print;next} fm && \$1=="status:"{print "status: done"; print "status: open";next}{print}' \
  "\$f" > /tmp/t650.\$\$ && mv /tmp/t650.\$\$ "\$f"
git mv "\$f" docs/tickets/DONE/T650-test.md
git add -A; git commit -qm "T650: done(dup status)"
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  _commit_all "add T650"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T650' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  # 완료로 집계되지 않았으므로 telemetry 커밋도 없다
  run git -C "$TEST_HOME" log --format=%s -5
  [[ "$output" != *"telemetry"* ]]
}

# ── 리뷰 16차 P1 회귀 ─────────────────────────────────────────────────────────

@test "T67: DONE evidence whose frontmatter id differs from the requested ticket is not completion" {
  _make_ticket T670 true open
  # headless mock: 파일명은 T670이지만 frontmatter id를 T999로 바꿔 DONE 이동 —
  # 과거에는 id "개수"만 검사해 값 불일치 파일이 완료로 집계됐다.
  cat > "$TEST_HOME/scripts/run_headless.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
f=docs/tickets/T670-test.md
[ -f "\$f" ] || exit 0   # 재프롬프트 세션은 무동작
awk '/^---\$/{fm=!fm;print;next} fm && \$1=="id:"{print "id: T999";next} fm && \$1=="status:"{print "status: done";next}{print}' \
  "\$f" > /tmp/t670.\$\$ && mv /tmp/t670.\$\$ "\$f"
git mv "\$f" docs/tickets/DONE/T670-test.md
git add -A; git commit -qm "T670: done(id mismatch)"
exit 0
EOF
  chmod +x "$TEST_HOME/scripts/run_headless.sh"
  _commit_all "add T670"

  run bash -c 'cd "$1" && ./scripts/run_loop.sh T670' _ "$TEST_HOME"
  [ "$status" -ne 0 ]
  [[ "$output" == *"id-mismatch"* ]]
  # 완료로 집계되지 않았으므로 telemetry 커밋도 없다
  run git -C "$TEST_HOME" log --format=%s -5
  [[ "$output" != *"telemetry"* ]]
}

@test "T68: writer audit commit does not absorb unrelated pre-staged index entries" {
  _make_ticket T680 true open
  _commit_all "add T680"

  # 사용자가 미리 staged해 둔 무관 파일 — 감사 커밋에 흡수되면 안 된다.
  echo "unrelated" > "$TEST_HOME/other.txt"
  git -C "$TEST_HOME" add other.txt

  run bash -c 'cd "$1" && ./scripts/ticket_edit.sh set-priority T680 P1' _ "$TEST_HOME"
  [ "$status" -eq 0 ]

  # 감사 커밋에는 티켓 파일만 들어간다
  run git -C "$TEST_HOME" show --name-only --format= HEAD
  [[ "$output" == *"T680-test.md"* ]]
  [[ "$output" != *"other.txt"* ]]
  # 무관 staged 항목은 그대로 index에 보존된다
  run git -C "$TEST_HOME" diff --cached --name-only
  [[ "$output" == *"other.txt"* ]]
}

@test "T66: duplicate depends_on declarations are malformed - no bypass via empty first declaration" {
  printf -- '---\nid: T661\ntitle: t\nstatus: open\npriority: P2\nsafe: true\npersona: implementer\ndepends_on: []\ndepends_on: [T999]\n---\n# T661\n' > "$TEST_HOME/docs/tickets/T661-test.md"
  _commit_all "add T661"

  # 첫 선언([])만 읽으면 의존성 없음으로 실행됐다 — 중복은 malformed(rc=11)
  run bash -c 'cd "$1" && ./scripts/run_loop.sh T661 --dry-run' _ "$TEST_HOME"
  [ "$status" -eq 11 ]
  run bash -c 'cd "$1" && ./scripts/pick_next_ticket.sh' _ "$TEST_HOME"
  [ "$status" -eq 0 ]
  [[ "$output" != *"T661-test.md"* ]]
}
