#!/usr/bin/env bats
# tests/auto-merge-execute.bats — auto_merge.sh --execute 회귀 테스트 (T060)
#
# 격리: 각 테스트는 mktemp -d + git init 실제 git 저장소에서 독립 실행.
# 외부 도구(lint_external_docs.sh, run_checks.sh, check_scope_omission.sh)는
# 환경 변수 오버라이드로 mock.
# 티켓 파일은 TEST_HOME (git repo 외부)에 두어 working-tree clean 조건 유지.

SCRIPT_PATH="$(cd "$BATS_TEST_DIRNAME/.." && pwd)/scripts/auto_merge.sh"

# Helper: 격리된 git 저장소 생성
# make_repo <dir> [num_commits] [file_area: docs|scripts]
make_repo() {
  local d="$1"
  local num="${2:-1}"
  local area="${3:-docs}"

  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false

  touch "$d/README.md"
  git -C "$d" add README.md
  git -C "$d" commit -q -m "initial"

  git -C "$d" checkout -q -b "ralph/T999"

  local i=1
  while [ "$i" -le "$num" ]; do
    if [ "$area" = "docs" ]; then
      mkdir -p "$d/docs"
      echo "content $i" > "$d/docs/file-$i.md"
      git -C "$d" add "docs/file-$i.md"
    else
      mkdir -p "$d/scripts"
      printf '#!/bin/sh\necho hi\n' > "$d/scripts/tool-$i.sh"
      git -C "$d" add "scripts/tool-$i.sh"
    fi
    git -C "$d" commit -q -m "add content $i"
    i=$((i + 1))
  done

  git -C "$d" checkout -q main
}

# Helper: 티켓 파일 생성 (repo 외부 경로에)
make_ticket() {
  local path="$1"
  local safe="${2:-true}"
  cat > "$path" <<TICKET
---
id: T999
title: Test ticket
safe: $safe
---
## AC
- [ ] test
TICKET
}

setup() {
  TEST_HOME="$(mktemp -d)"

  # 기본 mock: 외부 도구 모두 exit 0
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/mock_lint.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/mock_checks.sh"
  printf '#!/bin/sh\nexit 0\n' > "$TEST_HOME/mock_scope.sh"
  chmod +x "$TEST_HOME/mock_lint.sh" \
           "$TEST_HOME/mock_checks.sh" \
           "$TEST_HOME/mock_scope.sh"

  MOCK_LINT="$TEST_HOME/mock_lint.sh"
  MOCK_CHECKS="$TEST_HOME/mock_checks.sh"
  MOCK_SCOPE="$TEST_HOME/mock_scope.sh"

  # 기본 티켓 (safe:true, repo 외부)
  make_ticket "$TEST_HOME/T999-test.md"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# ── 1. ELIGIBLE + 단일 commit + clean base → merge 실행, merge commit 생성 ──────
@test "execute: ELIGIBLE single-commit clean base -> merge commit created exit 0" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]
  [[ "$output" == *"auto-merge executed"* ]]

  # base가 앞으로 이동 (merge commit 추가)
  local new_sha
  new_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$new_sha" != "$base_sha" ]

  # merge commit (부모 2개) - no-ff 보장
  local parent_count
  parent_count="$(git -C "$d" log --format='%P' -1 | wc -w | tr -d ' ')"
  [ "$parent_count" -eq 2 ]
}

# ── 2. NOT ELIGIBLE(safe:false) + --execute → merge 안 됨, exit 1, base 불변 ──
@test "execute: safe:false NOT ELIGIBLE -> no merge exit 1 base unchanged" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-unsafe.md" false  # safe: false

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-unsafe.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]

  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
}

# ── 3. NOT ELIGIBLE(코드 변경) + --execute → merge 안 됨, base 불변 ──────────
@test "execute: code change NOT ELIGIBLE -> no merge exit 1 base unchanged" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 scripts  # scripts/ 변경 → 조건 2 FAIL

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"VERDICT: NOT ELIGIBLE"* ]]

  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
}

# ── 4. ELIGIBLE + 다중 commit → (c) single-commit 갭 차단, merge 안 됨 ─────────
@test "execute: ELIGIBLE but multi-commit -> single-commit gate blocks merge exit 1" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 2 docs  # 커밋 2개

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"single-commit 위반"* ]]

  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
}

# ── 5. dirty working tree + --execute → 전제조건 FAIL, base 불변 ──────────────
@test "execute: dirty working tree -> precondition fail exit 1 base unchanged" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  # working tree를 dirty하게 만듦 (tracked 파일 수정)
  echo "dirty" >> "$d/README.md"

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"requires clean working tree"* ]]

  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
}

# ── 6. --execute + --changed-files 동시 → exit 2 (상호 배타) ─────────────────
@test "execute: --execute + --changed-files mutually exclusive -> exit 2" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  printf 'docs/guide.md\n' > "$TEST_HOME/changed.txt"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main \
    --changed-files '$TEST_HOME/changed.txt'"

  [ "$status" -eq 2 ]
}

# ── 7. eval-only 기본 (--execute 없음) → VERDICT만, git mutation 0 ─────────────
@test "execute: eval-only default no --execute -> VERDICT only git mutation 0" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  local base_sha branch_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"
  branch_sha="$(git -C "$d" rev-parse ralph/T999)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --base main"

  [ "$status" -eq 0 ]
  [[ "$output" == *"VERDICT: ELIGIBLE"* ]]

  # base·branch 모두 불변
  local after_base after_branch
  after_base="$(git -C "$d" rev-parse HEAD)"
  after_branch="$(git -C "$d" rev-parse ralph/T999)"
  [ "$after_base" = "$base_sha" ]
  [ "$after_branch" = "$branch_sha" ]

  # 출력에 merge/rollback 언급 없음
  [[ "$output" != *"auto-merge executed"* ]]
}

# ── 8. post-merge run_checks FAIL → auto-rollback, base가 merge 전으로 복구 ───
@test "execute: post-merge run_checks fail -> auto-rollback base restored exit 1" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  # run_checks: 1회차(조건 4 eval) 성공, 2회차(post-merge) 실패
  local counter_file="$TEST_HOME/check_count"
  local mock_fail2="$TEST_HOME/mock_checks_fail2.sh"
  cat > "$mock_fail2" <<MOCK
#!/bin/sh
if [ -f "$counter_file" ]; then
  exit 1
else
  touch "$counter_file"
  exit 0
fi
MOCK
  chmod +x "$mock_fail2"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$mock_fail2' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"post-merge run_checks 실패"* ]]
  [[ "$output" == *"rollback"* ]]

  # base가 merge 전으로 복구됨 (ORIG_HEAD 복원)
  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
}

# ── 9. audit log에 EXECUTED / ROLLED_BACK 라인 기록 검증 ───────────────────────
@test "execute: audit log records EXECUTED on success and ROLLED_BACK on rollback" {
  # 9a. 성공 → EXECUTED
  local d1="$TEST_HOME/repo1"
  mkdir -p "$d1"
  make_repo "$d1" 1 docs

  run bash -c "cd '$d1' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state1' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 0 ]
  [ -f "$TEST_HOME/state1/auto_merge.log" ]
  grep -q "EXECUTED" "$TEST_HOME/state1/auto_merge.log"
  grep -q "T999" "$TEST_HOME/state1/auto_merge.log"

  # 9b. rollback → ROLLED_BACK
  local d2="$TEST_HOME/repo2"
  mkdir -p "$d2"
  make_repo "$d2" 1 docs

  local counter2="$TEST_HOME/cnt2"
  local mock2="$TEST_HOME/mock2.sh"
  cat > "$mock2" <<MOCK
#!/bin/sh
if [ -f "$counter2" ]; then
  exit 1
else
  touch "$counter2"
  exit 0
fi
MOCK
  chmod +x "$mock2"

  run bash -c "cd '$d2' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$mock2' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state2' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [ -f "$TEST_HOME/state2/auto_merge.log" ]
  grep -q "ROLLED_BACK" "$TEST_HOME/state2/auto_merge.log"
}

# ── 10. merge conflict → abort/reset rollback, base 복구 ────────────────────────
@test "execute: git merge conflict -> rollback base restored exit 1" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"

  git -C "$d" init -q -b main
  git -C "$d" config user.email "test@test.com"
  git -C "$d" config user.name "Test"
  git -C "$d" config commit.gpgsign false

  mkdir -p "$d/docs"
  echo "base" > "$d/docs/conflict.md"
  git -C "$d" add docs/conflict.md
  git -C "$d" commit -q -m "initial"

  git -C "$d" checkout -q -b ralph/T999
  echo "branch" > "$d/docs/conflict.md"
  git -C "$d" add docs/conflict.md
  git -C "$d" commit -q -m "branch change"

  git -C "$d" checkout -q main
  echo "main" > "$d/docs/conflict.md"
  git -C "$d" add docs/conflict.md
  git -C "$d" commit -q -m "main change"

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state-conflict' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"git merge failed"* ]]
  [[ "$output" == *"rollback"* ]]

  local after_sha
  after_sha="$(git -C "$d" rev-parse HEAD)"
  [ "$after_sha" = "$base_sha" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
  [ -f "$TEST_HOME/state-conflict/auto_merge.log" ]
  grep -q "ROLLED_BACK" "$TEST_HOME/state-conflict/auto_merge.log"
}

# ── 리뷰 6차 P1: 티켓-브랜치 연결 + TOCTOU OID 고정 ────────────────────────────

@test "execute: branch not linked to ticket id -> refused, no merge" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  # 브랜치는 ralph/T999로 생성되어 있음 — T666으로 개명해 티켓과 끊는다
  git -C "$d" branch -m ralph/T999 ralph/T666

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T666 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"not linked to ticket T999"* ]]
  [ "$(git -C "$d" rev-parse HEAD)" = "$base_sha" ]
}

@test "execute: ref moved after checks (TOCTOU) -> pinned OID merged, not the moved ref" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs   # ralph/T999 = docs 커밋 1개

  # 검사(조건 4) 도중 브랜치 ref를 src/bad.js 커밋으로 이동시키는 훅:
  # RUN_CHECKS_CMD는 조건 4에서 병합 전에 실행된다 — 여기서 ref를 옮겨도
  # 병합은 시작 시 고정한 OID여야 한다.
  cat > "$TEST_HOME/mock_checks_move.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/moved.flag" ]; then
  touch "$TEST_HOME/moved.flag"
  cd '$d'
  git checkout -q ralph/T999
  mkdir -p src
  echo "malicious" > src/bad.js
  git add src/bad.js
  git commit -q -m "sneak src change"
  git checkout -q main
fi
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_move.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_move.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  # 병합이 실행되든(고정 OID) 거부되든, 이동된 src/bad.js가 base에 들어가면 안 된다
  [ ! -f "$d/src/bad.js" ] || ! git -C "$d" ls-tree -r main --name-only | grep -qx "src/bad.js"
  run git -C "$d" ls-tree -r main --name-only
  [[ "$output" != *"src/bad.js"* ]]
}
