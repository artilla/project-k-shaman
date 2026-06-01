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

  # 기본 티켓: safe:true, id:T999
  cat > "$TEST_DIR/ticket.md" <<'EOF'
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}

# ── 2. safe:false → NOT ELIGIBLE (조건 1) ─────────────────────────────────────
@test "auto_merge: safe:false -> NOT ELIGIBLE exit 1 (condition 1)" {
  cat > "$TEST_DIR/unsafe_ticket.md" <<'EOF'
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
    "$SCRIPT_PATH" "$TEST_DIR/unsafe_ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
    "$SCRIPT_PATH" "$TEST_DIR/ticket.md" --changed-files "$TEST_DIR/changed.txt"
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
  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]
}

# ── 18. Fix 3: no frontmatter id, filename T999, T999 review PASS → ELIGIBLE ──
@test "auto_merge: no frontmatter id filename T999 with T999 review PASS -> ELIGIBLE (Fix 3 regression guard)" {
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
  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
}
