#!/usr/bin/env bats
# tests/lint-external-docs.bats — lint_external_docs.sh 회귀 테스트 (T049)
#
# 격리: 각 테스트는 mktemp -d 임시 디렉터리에서 독립 실행.

SCRIPT_PATH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/lint_external_docs.sh"

setup() {
  TEST_DIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_DIR"
}

# ── 1. clean 외부 doc → exit 0 ────────────────────────────────────────────────
@test "lint_external_docs: clean doc with no violations → exit 0" {
  cat > "$TEST_DIR/clean.md" <<'EOF'
# Guide
Run: git merge --no-ff "$BASE_BRANCH"
BASE_BRANCH="${BASE_BRANCH:-$(./scripts/lib/base_branch.sh)}"
Nothing suspicious here.
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 2. git merge main 하드코딩 → exit 1 + Rule A 진단 ───────────────────────
@test "lint_external_docs: 'git merge main' hardcoded → exit 1 with Rule-A diagnostic" {
  cat > "$TEST_DIR/violation.md" <<'EOF'
# Guide
```bash
git merge main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

@test "lint_external_docs: 'git merge --no-ff main' hardcoded → exit 1 with Rule-A diagnostic" {
  cat > "$TEST_DIR/violation-noff.md" <<'EOF'
# Guide
```bash
git merge --no-ff main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

# ── 3. origin/main 하드코딩 → exit 1 + Rule A 진단 ─────────────────────────
@test "lint_external_docs: 'origin/main' hardcoded → exit 1 with Rule-A diagnostic" {
  cat > "$TEST_DIR/violation2.md" <<'EOF'
# Guide
```bash
git diff origin/main..HEAD
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

# ── 4. BASE_BRANCH=$(...) 직접 대입 → exit 1 + Rule B 진단 ─────────────────
@test "lint_external_docs: 'BASE_BRANCH=\$(...)' direct assignment → exit 1 with Rule-B diagnostic" {
  cat > "$TEST_DIR/violation3.md" <<'EOF'
# Guide
```bash
BASE_BRANCH=$(./scripts/lib/base_branch.sh)
echo "$BASE_BRANCH"
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-B"* ]]
}

# ── 5. ${BASE_BRANCH:-$(...)} 보존 패턴 → exit 0 (면제) ────────────────────
@test "lint_external_docs: '\${BASE_BRANCH:-\$(...)}' override-preserving pattern → exit 0" {
  cat > "$TEST_DIR/ok.md" <<'EOF'
# Guide
BASE_BRANCH="${BASE_BRANCH:-$(./scripts/lib/base_branch.sh)}"
echo "$BASE_BRANCH"
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 6. LINT_EXTERNAL_TARGET override → 다른 디렉터리 지정 동작 ─────────────
@test "lint_external_docs: LINT_EXTERNAL_TARGET override scans only the specified directory" {
  # violation dir: has a violation
  mkdir -p "$TEST_DIR/violation_dir"
  cat > "$TEST_DIR/violation_dir/bad.md" <<'EOF'
```bash
git merge main
```
EOF
  # clean dir: no violations
  mkdir -p "$TEST_DIR/clean_dir"
  cat > "$TEST_DIR/clean_dir/good.md" <<'EOF'
Nothing wrong here.
EOF
  # Point to clean_dir only → exit 0
  LINT_EXTERNAL_TARGET="$TEST_DIR/clean_dir" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 7. git checkout main 하드코딩 → exit 1 + Rule A 진단 ───────────────────
@test "lint_external_docs: 'git checkout main' hardcoded → exit 1 with Rule-A diagnostic" {
  cat > "$TEST_DIR/checkout.md" <<'EOF'
```bash
git checkout main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

# ── 8. git rebase main 하드코딩 → exit 1 + Rule A 진단 ────────────────────
@test "lint_external_docs: 'git rebase main' hardcoded → exit 1 with Rule-A diagnostic" {
  cat > "$TEST_DIR/rebase.md" <<'EOF'
```bash
git rebase main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

# ── 9. BASE_BRANCH 사용 라인은 Rule A 면제 ────────────────────────────────
@test "lint_external_docs: line using BASE_BRANCH variable is exempt from Rule-A" {
  cat > "$TEST_DIR/exempt.md" <<'EOF'
```bash
git merge "$BASE_BRANCH"
git rebase "$BASE_BRANCH"
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

@test "lint_external_docs: 'git merge main' inside sh fence → exit 1 Rule-A (T067)" {
  cat > "$TEST_DIR/sh_fenced_violation.md" <<'EOF'
```sh
git merge main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

@test "lint_external_docs: 'BASE_BRANCH=\$(...)' inside shell fence → exit 1 Rule-B (T067)" {
  cat > "$TEST_DIR/shell_fenced_ruleB.md" <<'EOF'
```shell
BASE_BRANCH=$(git symbolic-ref --short HEAD)
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-B"* ]]
}

@test "lint_external_docs: hardcoded main is not exempted by a BASE_BRANCH comment" {
  cat > "$TEST_DIR/comment.md" <<'EOF'
```bash
git merge main # replace with BASE_BRANCH later
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

@test "lint_external_docs: origin/mainland is not treated as origin/main" {
  cat > "$TEST_DIR/origin-mainland.md" <<'EOF'
This example mentions origin/mainland, not the main branch.
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 10. dogfooding: 현재 quickstart docs → exit 0 ──────────────────────────
@test "lint_external_docs: current docs/onboarding (quickstart) passes with exit 0" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINT_EXTERNAL_TARGET="$REPO_ROOT/docs/onboarding" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── T067 fence-aware 신규 테스트 ──────────────────────────────────────────────

# ── 11. ```bash fence 안 git merge main → Rule A 위반 ────────────────────────
@test "lint_external_docs: 'git merge main' inside bash fence → exit 1 Rule-A (T067)" {
  cat > "$TEST_DIR/fenced_violation.md" <<'EOF'
```bash
git merge main
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-A"* ]]
}

# ── 12. fence 밖 산문 main.. → 위반 아님 ────────────────────────────────────
@test "lint_external_docs: 'git diff main..ralph' in prose outside fence → exit 0 (T067)" {
  cat > "$TEST_DIR/prose_main.md" <<'EOF'
See `git diff main..ralph/T001` to compare branches.
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 13. 표/리스트 main.. → 위반 아님 ────────────────────────────────────────
@test "lint_external_docs: 'main..' text in table row → exit 0 (T067)" {
  cat > "$TEST_DIR/table_main.md" <<'EOF'
| Step | Command |
|------|---------|
| (a) | ADR-0006 원문은 `main..` 표기 |
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 14. fence 안 BASE_BRANCH=$(...) → Rule B 위반 ───────────────────────────
@test "lint_external_docs: 'BASE_BRANCH=\$(...)' inside bash fence → exit 1 Rule-B (T067)" {
  cat > "$TEST_DIR/fenced_ruleB.md" <<'EOF'
```bash
BASE_BRANCH=$(git symbolic-ref --short HEAD)
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Rule-B"* ]]
}

# ── 15. fence 안 ${BASE_BRANCH:-$(...)} → 면제 ──────────────────────────────
@test "lint_external_docs: '\${BASE_BRANCH:-\$(...)}' inside bash fence → exit 0 exempt (T067)" {
  cat > "$TEST_DIR/fenced_exempt.md" <<'EOF'
```bash
BASE_BRANCH="${BASE_BRANCH:-$(git symbolic-ref --short HEAD)}"
```
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 16. 닫는 fence 이후 산문 git checkout main → 위반 아님 ──────────────────
@test "lint_external_docs: 'git checkout main' in prose after closing fence → exit 0 (T067)" {
  cat > "$TEST_DIR/after_fence.md" <<'EOF'
```bash
echo hello
```
git checkout main
EOF
  LINT_EXTERNAL_TARGET="$TEST_DIR" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 17. LINT_EXTERNAL_TARGET=docs/onboarding → exit 0 ───────────────────────
@test "lint_external_docs: LINT_EXTERNAL_TARGET=docs/onboarding → exit 0 (T067)" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINT_EXTERNAL_TARGET="$REPO_ROOT/docs/onboarding" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 18. LINT_EXTERNAL_TARGET=docs/decisions → exit 0 ────────────────────────
@test "lint_external_docs: LINT_EXTERNAL_TARGET=docs/decisions → exit 0 (T067)" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINT_EXTERNAL_TARGET="$REPO_ROOT/docs/decisions" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}

# ── 19. 기본 타깃(docs/onboarding docs/decisions) → exit 0 ──────────────────
@test "lint_external_docs: both default targets (onboarding+decisions) → exit 0 (T067)" {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  LINT_EXTERNAL_TARGET="$REPO_ROOT/docs/onboarding $REPO_ROOT/docs/decisions" run "$SCRIPT_PATH"
  [ "$status" -eq 0 ]
}
