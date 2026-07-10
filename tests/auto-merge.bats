#!/usr/bin/env bats
# tests/auto-merge.bats — auto_merge.sh 회귀 테스트 (T051)
#
# 격리: 각 테스트는 mktemp -d 임시 디렉터리에서 독립 실행.
# 외부 도구(lint_external_docs.sh, run_checks.sh, check_scope_omission.sh)는
# 환경 변수 오버라이드(LINT_EXTERNAL_DOCS_CMD, RUN_CHECKS_CMD, CHECK_SCOPE_OMISSION_CMD)로 목킹.

SCRIPT_PATH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/auto_merge.sh"

setup() {
  TEST_DIR="$(mktemp -d)"

  # 기본 mock: 외부 도구 모두 exit 0
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/mock_lint.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/mock_checks.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_DIR/mock_scope.sh"
  chmod +x "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh"

  # 리뷰 7차 P1: 티켓 경로는 canonical tickets 디렉터리 검사 대상 — 테스트는 오버라이드.
  export TICKETS_DIR="$TEST_DIR"

  # 기본 티켓: safe:true, id:T999 (파일명은 T<id>-*.md 계약)
  cat > "$TEST_DIR/T999-test.md" <<'EOF'
---
id: T999
title: Test ticket
safe: true
---
## Acceptance Criteria
- [ ] something
EOF
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── 1. 5조건 모두 충족 → ELIGIBLE (exit 0) ────────────────────────────────────
@test "auto_merge: all 5 conditions pass (safe:true, docs/ only, lint 0, checks 0, no decisions) -> ELIGIBLE exit 0" {
  printf 'docs/guide.md\ndocs/readme.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 2. safe:false → NOT ELIGIBLE (조건 1) ─────────────────────────────────────
@test "auto_merge: safe:false -> NOT ELIGIBLE exit 1 (condition 1)" {
  cat > "$TEST_DIR/T999-unsafe.md" <<'EOF'
---
id: T999
safe: false
---
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-unsafe.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 3. src/foo.js 포함 → NOT ELIGIBLE (조건 2, 코드 금지) ─────────────────────
@test "auto_merge: changed-files contains src/foo.js -> NOT ELIGIBLE exit 1 (condition 2)" {
  printf 'docs/guide.md\nsrc/foo.js\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 4. docs-x/ prefix는 docs/로 오인하지 않음 ───────────────────────────────
@test "auto_merge: docs-x/ is not treated as docs/ -> NOT ELIGIBLE exit 1 (condition 2)" {
  printf 'docs-x/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 5. .github/workflows/ci.yml 포함 → NOT ELIGIBLE (조건 2) ─────────────────
@test "auto_merge: changed-files contains .github/workflows/ci.yml -> NOT ELIGIBLE exit 1 (condition 2)" {
  printf 'docs/guide.md\n.github/workflows/ci.yml\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 6. docs/decisions/ 접촉 + review 파일 없음 → NOT ELIGIBLE (조건 5) ─────────
@test "auto_merge: changed-files touches docs/decisions/ without review file -> NOT ELIGIBLE exit 1 (condition 5)" {
  printf 'docs/decisions/0015-test.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    REVIEWS_DIR="$TEST_DIR/reviews" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 7. docs/decisions/ 접촉 + review PASS 존재 → ELIGIBLE ─────────────────────
@test "auto_merge: changed-files touches docs/decisions/ with review PASS -> ELIGIBLE exit 0 (condition 5)" {
  printf 'docs/decisions/0015-test.md\n' > "$TEST_DIR/changed.txt"
  mkdir -p "$TEST_DIR/reviews"
  printf '[T999] REVIEW: PASS\n' > "$TEST_DIR/reviews/T999-review.md"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    REVIEWS_DIR="$TEST_DIR/reviews" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 8. REQUEST CHANGES 안의 설명성 PASS는 verdict로 오인하지 않음 ────────────
@test "auto_merge: REQUEST CHANGES review mentioning PASS is not accepted as PASS verdict" {
  printf 'docs/decisions/0015-test.md\n' > "$TEST_DIR/changed.txt"
  mkdir -p "$TEST_DIR/reviews"
  printf '[T999] REVIEW: REQUEST CHANGES\nSuggestion: add PASS criteria later\n' > "$TEST_DIR/reviews/T999-review.md"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    REVIEWS_DIR="$TEST_DIR/reviews" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 9. tests/ 한정 변경 → ELIGIBLE ────────────────────────────────────────────
@test "auto_merge: tests/-only changes -> ELIGIBLE exit 0" {
  printf 'tests/foo.bats\ntests/bar.bats\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 10. advisory(check_scope_omission) exit 1이 VERDICT에 영향 없음 ───────────
@test "auto_merge: advisory check_scope_omission exit 1 does not affect VERDICT" {
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  printf '#!/bin/sh\necho "scope advisory output" >&2\nexit 1\n' > "$TEST_DIR/mock_scope_fail.sh"
  chmod +x "$TEST_DIR/mock_scope_fail.sh"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope_fail.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
  [[ "$output" == *"ADVISORY:"* ]]
}

# ── T053 Fix 1: frontmatter-only safe parsing ─────────────────────────────────

# ── 11. Fix 1: frontmatter safe:false + body safe:true → NOT ELIGIBLE ─────────
@test "auto_merge: frontmatter safe:false body safe:true -> NOT ELIGIBLE (Fix 1 body bypass)" {
  cat > "$TEST_DIR/T999-body-safe.md" <<'EOF'
---
id: T999
safe: false
---
# Body
safe: true
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-body-safe.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 12. Fix 1: safe:truefoo (trailing noise) → NOT ELIGIBLE ──────────────────
@test "auto_merge: safe:truefoo trailing noise -> NOT ELIGIBLE (Fix 1 value boundary)" {
  cat > "$TEST_DIR/T999-safe-noise.md" <<'EOF'
---
id: T999
safe: truefoo
---
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-safe-noise.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 13. Fix 1: unclosed frontmatter → NOT ELIGIBLE ───────────────────────────
@test "auto_merge: unclosed frontmatter -> NOT ELIGIBLE (Fix 1 fail-closed)" {
  cat > "$TEST_DIR/T999-unclosed-frontmatter.md" <<'EOF'
---
id: T999
safe: true
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-unclosed-frontmatter.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── T053 Fix 2: traversal / absolute-path rejection ───────────────────────────

# ── 14. Fix 2: docs/../src/x.js traversal → NOT ELIGIBLE ────────────────────
@test "auto_merge: changed-files docs/../src/x.js traversal -> NOT ELIGIBLE (Fix 2)" {
  printf 'docs/../src/x.js\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 15. Fix 2: tests/../../x traversal → NOT ELIGIBLE ───────────────────────
@test "auto_merge: changed-files tests/../../x traversal -> NOT ELIGIBLE (Fix 2)" {
  printf 'tests/../../x\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 16. Fix 2: absolute path /etc/passwd → NOT ELIGIBLE ─────────────────────
@test "auto_merge: changed-files absolute path /etc/passwd -> NOT ELIGIBLE (Fix 2)" {
  printf '/etc/passwd\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── T053 Fix 3: filename-anchored ticket ID ───────────────────────────────────

# ── 17. Fix 3: filename T999 + frontmatter id:T045 + T045 review PASS → NOT ELIGIBLE ─
@test "auto_merge: filename T999 frontmatter id:T045 with T045 review PASS -> NOT ELIGIBLE (Fix 3 id mismatch)" {
  cat > "$TEST_DIR/T999-spoof.md" <<'EOF'
---
id: T045
safe: true
---
EOF
  printf 'docs/decisions/0099-x.md\n' > "$TEST_DIR/changed.txt"
  mkdir -p "$TEST_DIR/reviews"
  printf '[T045] REVIEW: PASS\n' > "$TEST_DIR/reviews/T045-review.md"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    REVIEWS_DIR="$TEST_DIR/reviews" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-spoof.md" --changed-files "$TEST_DIR/changed.txt"
  # 리뷰 7차 P1: id 계약 위반은 평가 전에 즉시 거부(exit 2)
  [ "$status" -eq 2 ]
  [[ "$output" == *"id contract"* ]]
}

# ── 18. Fix 3: no frontmatter id, filename T999, T999 review PASS → ELIGIBLE ──
@test "auto_merge: missing frontmatter id -> refused exit 2 (id contract)" {
  cat > "$TEST_DIR/T999-noid.md" <<'EOF'
---
safe: true
---
EOF
  printf 'docs/decisions/0099-x.md\n' > "$TEST_DIR/changed.txt"
  mkdir -p "$TEST_DIR/reviews"
  printf '[T999] REVIEW: PASS\n' > "$TEST_DIR/reviews/T999-review.md"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    REVIEWS_DIR="$TEST_DIR/reviews" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-noid.md" --changed-files "$TEST_DIR/changed.txt"
  # 리뷰 7차 P1: id 누락 하위 호환 제거 — 정확히 1회 선언 필수
  [ "$status" -eq 2 ]
  [[ "$output" == *"id contract"* ]]
}

# ── 리뷰 2차 P1-11: rename 소스 경로 검사 (--name-status) ─────────────────────
# --name-only는 rename 감지 시 목적지만 출력해, src/ → docs/ rename이 조건 2를
# 우회했다. 소스·목적지 양쪽 모두 검사되는지 실제 git repo로 검증한다.

_make_rename_repo() {
  # $1 = 대상 디렉터리. main에 src/app.js와 docs/keep.md를 두고,
  # ralph/T999 브랜치에서 rename을 수행한다 (동일 내용 → git rename 감지 확실).
  local d="$1"
  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false

  mkdir -p "$d/src" "$d/docs"
  printf 'line1\nline2\nline3\nline4\nline5\n' > "$d/src/app.js"
  echo "keep" > "$d/docs/keep.md"
  git -C "$d" add .
  git -C "$d" commit -q -m "initial"
  git -C "$d" checkout -q -b "ralph/T999"
}

@test "auto_merge: rename src/app.js -> docs/app.md exposes source path -> NOT ELIGIBLE (condition 2)" {
  local repo="$TEST_DIR/repo-rename"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  git -C "$repo" mv src/app.js docs/app.md
  git -C "$repo" commit -q -m "sneaky rename"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base main
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/app.js"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

@test "auto_merge: rename docs/ -> docs/ stays ELIGIBLE (both paths inside whitelist)" {
  local repo="$TEST_DIR/repo-rename-ok"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  git -C "$repo" mv docs/keep.md docs/kept.md
  git -C "$repo" commit -q -m "docs-internal rename"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base main
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 리뷰 3차 P1: diff 실패 fail-closed ────────────────────────────────────────

@test "auto_merge: git diff failure (nonexistent base) -> NOT ELIGIBLE (condition 2 fail-closed)" {
  local repo="$TEST_DIR/repo-badbase"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  echo "extra" > "$repo/docs/extra.md"
  git -C "$repo" add docs/extra.md
  git -C "$repo" commit -q -m "docs change"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base no-such-branch
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"condition 2: git diff failed"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 리뷰 4차 P1: unchanged-source copy 탐지 (--find-copies-harder) ────────────

@test "auto_merge: copy src/app.js -> docs/app.md (source unchanged) -> NOT ELIGIBLE (condition 2)" {
  local repo="$TEST_DIR/repo-copy"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  cp "$repo/src/app.js" "$repo/docs/app.md"   # 소스는 그대로 — -C만으로는 A(추가)로 보였다
  git -C "$repo" add docs/app.md
  git -C "$repo" commit -q -m "sneaky copy"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base main
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/app.js"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

@test "auto_merge: copy docs/keep.md -> docs/copy.md stays ELIGIBLE (both paths inside whitelist)" {
  local repo="$TEST_DIR/repo-copy-ok"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  cp "$repo/docs/keep.md" "$repo/docs/copy.md"
  git -C "$repo" add docs/copy.md
  git -C "$repo" commit -q -m "docs-internal copy"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base main
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 리뷰 5차 P1/P2: 중복 safe·renameLimit fail-open ───────────────────────────

@test "auto_merge: duplicate safe (false then true) -> NOT ELIGIBLE (condition 1)" {
  cat > "$TEST_DIR/T999-dup1.md" <<'EOF'
---
id: T999
title: dup
safe: false
safe: true
---
## AC
- [ ] x
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-dup1.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate safe"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

@test "auto_merge: duplicate safe (true then false) -> NOT ELIGIBLE (condition 1)" {
  cat > "$TEST_DIR/T999-dup2.md" <<'EOF'
---
id: T999
title: dup
safe: true
safe: false
---
## AC
- [ ] x
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-dup2.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 1 ]
  [[ "$output" == *"duplicate safe"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

@test "auto_merge: low diff.renameLimit does not silence copy detection (-l0)" {
  local repo="$TEST_DIR/repo-renamelimit"
  mkdir -p "$repo"
  _make_rename_repo "$repo"
  git -C "$repo" config diff.renameLimit 1
  cp "$repo/src/app.js" "$repo/docs/app.md"
  git -C "$repo" add docs/app.md
  git -C "$repo" commit -q -m "sneaky copy under tiny renameLimit"

  run bash -c '
    cd "$1" && env \
      LINT_EXTERNAL_DOCS_CMD="$2" RUN_CHECKS_CMD="$3" CHECK_SCOPE_OMISSION_CMD="$4" \
      "$5" "$6" --base main
  ' _ "$repo" "$TEST_DIR/mock_lint.sh" "$TEST_DIR/mock_checks.sh" "$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-test.md"
  [ "$status" -eq 1 ]
  [[ "$output" == *"src/app.js"* ]]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 리뷰 7차 P1: 티켓 경로·id 계약 강화 ───────────────────────────────────────

@test "auto_merge: ticket outside canonical tickets dir -> refused exit 2" {
  mkdir -p "$TEST_DIR/elsewhere"
  cp "$TEST_DIR/T999-test.md" "$TEST_DIR/elsewhere/T999-test.md"
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/elsewhere/T999-test.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"outside canonical"* ]]
}

@test "auto_merge: filename T999evil.md -> refused exit 2 (full basename contract)" {
  cp "$TEST_DIR/T999-test.md" "$TEST_DIR/T999evil.md"
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999evil.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not match"* ]]
}

@test "auto_merge: duplicate id declarations -> refused exit 2" {
  cat > "$TEST_DIR/T999-dupid.md" <<'EOF'
---
id: T999
id: T045
safe: true
---
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-dupid.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"id contract"* ]]
}

@test "auto_merge: whitespace-forged id (T 9 9 9) -> refused exit 2" {
  cat > "$TEST_DIR/T999-wsid.md" <<'EOF'
---
id: T 9 9 9
safe: true
---
EOF
  printf 'docs/guide.md\n' > "$TEST_DIR/changed.txt"
  run env \
    LINT_EXTERNAL_DOCS_CMD="$TEST_DIR/mock_lint.sh" \
    RUN_CHECKS_CMD="$TEST_DIR/mock_checks.sh" \
    CHECK_SCOPE_OMISSION_CMD="$TEST_DIR/mock_scope.sh" \
    "$SCRIPT_PATH" "$TEST_DIR/T999-wsid.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 2 ]
  [[ "$output" == *"id contract"* ]]
}
