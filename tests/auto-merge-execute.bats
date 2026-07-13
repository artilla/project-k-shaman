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

  # 리뷰 7차 P1: canonical tickets 디렉터리 검사 오버라이드
  export TICKETS_DIR="$TEST_HOME"

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

  # 리뷰 7차 P2: "거부돼도 통과"하던 검증 강화 — 고정 OID가 "실제로" 병합돼야 한다
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-merge executed"* ]]
  local parent_count
  parent_count="$(git -C "$d" log --format='%P' -1 | wc -w | tr -d ' ')"
  [ "$parent_count" -eq 2 ]
  run git -C "$d" ls-tree -r main --name-only
  [[ "$output" != *"src/bad.js"* ]]
}

# ── 리뷰 7차 P1: ref 정확성 + base 측 TOCTOU ──────────────────────────────────

@test "execute: tag named like ticket branch -> refused (refs/heads only)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  # 브랜치를 지우고 같은 이름의 tag만 남긴다
  local tip
  tip="$(git -C "$d" rev-parse ralph/T999)"
  git -C "$d" branch -D ralph/T999 >/dev/null
  git -C "$d" tag "ralph/T999" "$tip"

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"
  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not a local branch"* ]]
  [ "$(git -C "$d" rev-parse HEAD)" = "$base_sha" ]
}

@test "execute: arbitrary namespace (attacker/T999) -> refused" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  git -C "$d" branch -m ralph/T999 attacker/T999

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch attacker/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"not linked to ticket T999"* ]]
}

@test "execute: base HEAD moved during checks -> merge refused (base TOCTOU)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  # 검사(조건 4) 중 main에 새 커밋을 추가하는 훅 — 병합 직전 재검증이 거부해야 한다
  cat > "$TEST_HOME/mock_checks_movebase.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/movedbase.flag" ]; then
  touch "$TEST_HOME/movedbase.flag"
  cd '$d'
  mkdir -p src
  echo "malicious" > src/bad.js
  git add src/bad.js
  git commit -q -m "sneak base change"
fi
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_movebase.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_movebase.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"TOCTOU"* ]]
  # 병합 커밋(2-parent)이 생기지 않았어야 한다
  local parent_count
  parent_count="$(git -C "$d" log --format='%P' -1 | wc -w | tr -d ' ')"
  [ "$parent_count" -le 1 ]
}

# ── 리뷰 8차 P1: 원자성 (고정 복구·lock) ──────────────────────────────────────

@test "execute: post-check failure rolls back to pinned BASE_OID even if ORIG_HEAD is polluted" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"

  # 1회차(조건 4)는 통과, 2회차(post-merge)에서 내부 reset으로 ORIG_HEAD를
  # 병합 커밋으로 오염시키고 실패한다 — 과거 'git reset --hard ORIG_HEAD' 복구는
  # base로 돌아가지 못했다.
  cat > "$TEST_HOME/mock_checks_pollute.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/pollute.flag" ]; then
  touch "$TEST_HOME/pollute.flag"
  exit 0
fi
cd '$d'
git reset --hard HEAD >/dev/null 2>&1   # ORIG_HEAD := 현재(병합) 커밋
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_pollute.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_pollute.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"

  [ "$status" -eq 1 ]
  [[ "$output" == *"post-merge run_checks 실패"* ]]
  # ORIG_HEAD가 오염됐어도 고정 BASE_OID로 정확히 복구돼야 한다
  [ "$(git -C "$d" rev-parse HEAD)" = "$base_sha" ]
}

@test "execute: concurrent lock present -> refused, no merge" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  mkdir -p "$TEST_HOME/state/auto_merge.lock.d"

  local base_sha
  base_sha="$(git -C "$d" rev-parse HEAD)"
  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"another auto-merge is in progress"* ]]
  [ "$(git -C "$d" rev-parse HEAD)" = "$base_sha" ]
}

# ── 리뷰 9차 P1: 최종 상태 검증·소유권 복구·stale lock ────────────────────────

@test "execute: post-check resets HEAD to base then exit 0 -> RECOVERY_REQUIRED not EXECUTED" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  cat > "$TEST_HOME/mock_checks_sneakreset.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/sr.flag" ]; then touch "$TEST_HOME/sr.flag"; exit 0; fi
cd '$d'
git reset --hard main~0 >/dev/null 2>&1  # no-op처럼 보이지만 아래에서 base로 되돌린다
git reset --hard \$(git rev-parse HEAD^1) >/dev/null 2>&1
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_sneakreset.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_sneakreset.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECOVERY_REQUIRED"* ]]
  [[ "$output" != *"auto-merge executed"* ]]
  grep -q "RECOVERY_REQUIRED" "$TEST_HOME/state/auto_merge.log"
}

@test "execute: post-check leaves untracked artifact then exit 0 -> RECOVERY_REQUIRED" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  cat > "$TEST_HOME/mock_checks_artifact.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/ar.flag" ]; then touch "$TEST_HOME/ar.flag"; exit 0; fi
echo leftover > '$d/build-artifact.tmp'
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_artifact.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_artifact.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECOVERY_REQUIRED"* ]]
}

@test "execute: stale lock (dead pid) is reclaimed and merge proceeds" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  mkdir -p "$TEST_HOME/state/auto_merge.lock.d"
  # 확실히 죽은 PID (spawn 후 즉시 종료된 프로세스)
  bash -c 'exit 0' &
  local dead_pid=$!
  wait "$dead_pid" 2>/dev/null || true
  echo "$dead_pid" > "$TEST_HOME/state/auto_merge.lock.d/pid"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale auto-merge lock"* ]]
  [[ "$output" == *"auto-merge executed"* ]]
}

# ── 리뷰 11차 P1 회귀 ─────────────────────────────────────────────────────────

@test "execute: modifying a file whose path contains the lock string is still detected (exact-path exclusion)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  # lock 문자열이 포함된 일반 tracked 파일 — substring 제외였다면 dirty가 숨는다
  mkdir -p "$d/docs"
  echo "note" > "$d/docs/auto_merge.lock.d-notes.md"
  git -C "$d" add docs/auto_merge.lock.d-notes.md
  git -C "$d" commit -q -m "add note file"

  # post-check가 그 파일을 수정하고 exit 0 → 최종 검증이 dirty를 봐야 한다
  cat > "$TEST_HOME/mock_checks_dirtyname.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/dn.flag" ]; then touch "$TEST_HOME/dn.flag"; exit 0; fi
echo modified >> '$d/docs/auto_merge.lock.d-notes.md'
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_dirtyname.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_dirtyname.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECOVERY_REQUIRED"* ]]
}

@test "execute: in-repo custom STATE_DIR audit log does not break final clean verdict" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$d/state2' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-merge executed"* ]]
  grep -q "EXECUTED" "$d/state2/auto_merge.log"
}

# ── 리뷰 12차 P1 회귀 ─────────────────────────────────────────────────────────

@test "execute: post-check failure with clean worktree rolls back fully (not REF_ONLY)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_fail2nd.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/f2.flag" ]; then touch "$TEST_HOME/f2.flag"; exit 0; fi
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_fail2nd.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_fail2nd.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  # 정상 경로(사전 clean worktree)는 REF_ONLY로 격하되지 않는다
  grep -q $'\tROLLED_BACK$' "$TEST_HOME/state/auto_merge.log"
  ! grep -q 'REF_ONLY' "$TEST_HOME/state/auto_merge.log"
  # ref와 worktree 모두 base로 복귀 + clean
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
}

@test "execute: TERM during post-checks reaps descendants, audits INTERRUPTED, releases lock" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_slow.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/slow.flag" ]; then touch "$TEST_HOME/slow.flag"; exit 0; fi
sleep 271830
EOF
  chmod +x "$TEST_HOME/mock_checks_slow.sh"

  ( cd "$d" && \
    LINT_EXTERNAL_DOCS_CMD="$MOCK_LINT" \
    RUN_CHECKS_CMD="$TEST_HOME/mock_checks_slow.sh" \
    CHECK_SCOPE_OMISSION_CMD="$MOCK_SCOPE" \
    STATE_DIR="$TEST_HOME/state" \
    exec "$SCRIPT_PATH" "$TEST_HOME/T999-test.md" --execute --branch ralph/T999 --base main ) \
    > "$TEST_HOME/term.log" 2>&1 & local ap=$!
  # post-check(sleep) 단계 진입 대기
  local i=0
  while [ ! -f "$TEST_HOME/slow.flag" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
  sleep 1
  kill -TERM "$ap" 2>/dev/null || true
  wait "$ap" 2>/dev/null || true
  sleep 1

  # 자손(sleep)까지 회수됐다
  [ -z "$(ps -eo args | awk '$1=="sleep" && $2=="271830"')" ]
  grep -q 'INTERRUPTED' "$TEST_HOME/state/auto_merge.log"
  # lock이 해제됐다
  [ ! -d "$TEST_HOME/state/auto_merge.lock.d" ]
}

@test "execute: post-check leaving background descendants is refused (no EXECUTED)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_bg.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/bg.flag" ]; then touch "$TEST_HOME/bg.flag"; exit 0; fi
( sleep 271831; echo late > "$d/late.txt" ) &
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_bg.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_bg.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  pkill -f 'sleep 271831' 2>/dev/null || true
  [ "$status" -eq 1 ]
  [[ "$output" != *"auto-merge executed"* ]]
  [[ "$output" == *"잔존 프로세스"* ]]
  ! grep -q $'\tEXECUTED$' "$TEST_HOME/state/auto_merge.log"
}

# ── 리뷰 13차 P1 회귀 ─────────────────────────────────────────────────────────

@test "execute: TERM during post-checks rolls unverified merge off base (no leftover 2-parent HEAD)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_slow2.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/slow2.flag" ]; then touch "$TEST_HOME/slow2.flag"; exit 0; fi
sleep 271832
EOF
  chmod +x "$TEST_HOME/mock_checks_slow2.sh"

  ( cd "$d" && \
    LINT_EXTERNAL_DOCS_CMD="$MOCK_LINT" \
    RUN_CHECKS_CMD="$TEST_HOME/mock_checks_slow2.sh" \
    CHECK_SCOPE_OMISSION_CMD="$MOCK_SCOPE" \
    STATE_DIR="$TEST_HOME/state" \
    exec "$SCRIPT_PATH" "$TEST_HOME/T999-test.md" --execute --branch ralph/T999 --base main ) \
    > "$TEST_HOME/term2.log" 2>&1 & local ap=$!
  local i=0
  while [ ! -f "$TEST_HOME/slow2.flag" ] && [ "$i" -lt 50 ]; do sleep 0.2; i=$((i+1)); done
  sleep 1
  kill -TERM "$ap" 2>/dev/null || true
  wait "$ap" 2>/dev/null || true
  pkill -f 'sleep 271832' 2>/dev/null || true

  # 미검증 merge가 base에 남지 않는다 — 신호 시점 CAS 롤백
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
  grep -q 'INTERRUPTED_ROLLED_BACK' "$TEST_HOME/state/auto_merge.log"
  # 정상 롤백됐으므로 recovery marker는 남지 않는다
  [ ! -e "$TEST_HOME/state/auto_merge.recovery" ]
}

@test "execute: recovery marker refuses new merges until manually cleared" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"
  mkdir -p "$TEST_HOME/state"
  touch "$TEST_HOME/state/auto_merge.recovery"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [[ "$output" == *"RECOVERY_REQUIRED 상태"* ]]
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  grep -q 'REFUSED:recovery-pending' "$TEST_HOME/state/auto_merge.log"
  # 리뷰 14차 P2: 거부 경로가 EXIT trap 설치 전에 종료해 lock을 남기지 않는다
  [ ! -d "$TEST_HOME/state/auto_merge.lock.d" ]
}

@test "execute: concurrent tracked change in rollback window is preserved (REF_ONLY, not reset away)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  echo base > "$d/tracked.md"
  git -C "$d" add tracked.md
  git -C "$d" commit -q -m "tracked file"

  # post-check가 (rollback 스냅샷 창의) 동시 변경을 흉내: tracked 파일 수정 후 exit 1
  cat > "$TEST_HOME/mock_checks_conc.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/conc.flag" ]; then touch "$TEST_HOME/conc.flag"; exit 0; fi
echo concurrent >> '$d/tracked.md'
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_conc.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_conc.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  # 동시 변경은 reset --hard로 파괴되지 않고 보존된다
  grep -q 'concurrent' "$d/tracked.md"
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
}

# ── 리뷰 14차 P1 회귀 ─────────────────────────────────────────────────────────

# P1: 커밋 생성 후 MERGE_HEAD만 남은 창에서의 TERM — `git merge --abort`가 rc=0으로
# '성공'해도(git reset --merge는 HEAD를 옮기지 않음) 2-parent merge가 base에 남았다.
# 판정은 abort rc가 아니라 최종 HEAD 상태로 해야 한다.
@test "execute: TERM in post-merge hook window (abort succeeds) still rolls merge off base" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  # post-merge hook: 커밋 완료 직후 MERGE_HEAD를 재생성(불운한 중단 창 시뮬레이션)
  # 하고 부모 auto_merge에 TERM을 보낸 뒤 대기한다.
  mkdir -p "$d/.git/hooks"
  cat > "$d/.git/hooks/post-merge" <<HOOK
#!/usr/bin/env bash
i=0; while [ ! -f "$TEST_HOME/am.pid" ] && [ "\$i" -lt 100 ]; do sleep 0.1; i=\$((i+1)); done
git rev-parse ralph/T999 > "\$(git rev-parse --git-dir)/MERGE_HEAD"
kill -TERM "\$(cat "$TEST_HOME/am.pid")" 2>/dev/null
sleep 30
HOOK
  chmod +x "$d/.git/hooks/post-merge"

  ( cd "$d" && \
    LINT_EXTERNAL_DOCS_CMD="$MOCK_LINT" \
    RUN_CHECKS_CMD="$MOCK_CHECKS" \
    CHECK_SCOPE_OMISSION_CMD="$MOCK_SCOPE" \
    STATE_DIR="$TEST_HOME/state" \
    exec "$SCRIPT_PATH" "$TEST_HOME/T999-test.md" --execute --branch ralph/T999 --base main ) \
    > "$TEST_HOME/hookterm.log" 2>&1 & local ap=$!
  echo "$ap" > "$TEST_HOME/am.pid"
  wait "$ap" 2>/dev/null || true
  pkill -f 'sleep 30' 2>/dev/null || true

  # 미검증 merge가 base에 남지 않는다 — abort '성공' 후에도 최종 상태로 판정해 CAS 롤백
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  [ -z "$(git -C "$d" status --porcelain)" ]
  [ ! -e "$d/.git/MERGE_HEAD" ]
  grep -q 'INTERRUPTED_ROLLED_BACK' "$TEST_HOME/state/auto_merge.log"
  [ ! -e "$TEST_HOME/state/auto_merge.recovery" ]
}

# P1: rollback의 blob 검증과 복원 사이에 들어온 tracked 변경은 파괴되지 않는다 —
# 전역 reset --hard 대신 경로별 내용 결속 복원. 잔여 변경은 REF_ONLY로 정직하게 기록.
@test "execute: change injected between rollback validation and restore is preserved" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  echo base > "$d/tracked.md"
  git -C "$d" add tracked.md
  git -C "$d" commit -q -m "tracked file"
  local base
  base="$(git -C "$d" rev-parse main)"

  # 1차 run_checks(eligibility)는 통과, post-merge run_checks는 실패 → rollback 경로
  cat > "$TEST_HOME/mock_checks_rb.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/rb.flag" ]; then touch "$TEST_HOME/rb.flag"; exit 0; fi
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_rb.sh"

  # 검증 루프의 첫 hash-object 호출 시점에 동시 변경을 주입하는 git wrapper —
  # "blob 검사 통과 후, 복원 전" 창을 결정적으로 재현한다.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/rbbin"
  cat > "$TEST_HOME/rbbin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "hash-object" ] && [ ! -f "$TEST_HOME/rb.injected" ]; then
  touch "$TEST_HOME/rb.injected"
  echo concurrent >> "$d/tracked.md"
fi
exec "$realgit" "\$@"
EOF
  chmod +x "$TEST_HOME/rbbin/git"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/rbbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_rb.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  # base ref는 복구되고, 주입된 동시 변경은 보존된다
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  grep -q 'concurrent' "$d/tracked.md"
  # merge 잔상(브랜치가 추가한 docs 파일)은 정리된다
  [ ! -e "$d/docs/file-1.md" ]
  # 잔여 변경이 남았으므로 완전 복구가 아니라 REF_ONLY로 기록된다
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
  # 복원용 임시/백업 파일 잔존 없음
  [ -z "$(find "$d" -name '.amrb*' 2>/dev/null)" ]
}

# ── 리뷰 15차 P1 회귀 ─────────────────────────────────────────────────────────

# P1: merge-added 경로의 동시 atomic replacement는 rollback이 삭제하지 않는다 —
# rename 캡처가 교체본을 잡아 원복·보존하고 REF_ONLY로 격하한다.
@test "execute: concurrent atomic replacement of merge-added path survives rollback" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_ar.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/ar.flag" ]; then touch "$TEST_HOME/ar.flag"; exit 0; fi
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_ar.sh"

  # 검증 루프의 첫 hash-object 시점에 merge-added 파일(docs/file-1.md)을
  # atomic rename으로 교체 — "검증 통과 후, 폐기 전" 창을 결정적으로 재현.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/arbin"
  cat > "$TEST_HOME/arbin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "hash-object" ] && [ ! -f "$TEST_HOME/ar.injected" ]; then
  touch "$TEST_HOME/ar.injected"
  printf 'replaced-by-writer\n' > "$d/docs/.repl.tmp"
  mv -f "$d/docs/.repl.tmp" "$d/docs/file-1.md"
fi
exec "$realgit" "\$@"
EOF
  chmod +x "$TEST_HOME/arbin/git"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/arbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_ar.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  # 교체본이 삭제되지 않고 보존된다
  [ -f "$d/docs/file-1.md" ]
  grep -q 'replaced-by-writer' "$d/docs/file-1.md"
  # 완전 복구(ROLLED_BACK)로 위장하지 않는다
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
  ! grep -q $'\tROLLED_BACK$' "$TEST_HOME/state/auto_merge.log"
  [ -z "$(find "$d" -name '.amrb*' 2>/dev/null)" ]
}

# P1: rollback 중 동시 index-only staged 변경은 지워지지 않는다 —
# 전역 read-tree --reset 대신 경로 단위 git reset.
@test "execute: concurrent index-only staged change survives rollback" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_ix.sh" <<EOF
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/ix.flag" ]; then touch "$TEST_HOME/ix.flag"; exit 0; fi
exit 1
EOF
  chmod +x "$TEST_HOME/mock_checks_ix.sh"

  # 검증 루프의 첫 hash-object 시점에 새 파일을 만들어 stage — index-only 동시 변경.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/ixbin"
  cat > "$TEST_HOME/ixbin/git" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "hash-object" ] && [ ! -f "$TEST_HOME/ix.injected" ]; then
  touch "$TEST_HOME/ix.injected"
  printf 'staged-concurrently\n' > "$d/staged-file.md"
  "$realgit" -C "$d" add staged-file.md
fi
exec "$realgit" "\$@"
EOF
  chmod +x "$TEST_HOME/ixbin/git"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/ixbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_ix.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  # staged 항목이 살아 있다 (과거: read-tree --reset이 조용히 지움)
  git -C "$d" diff --cached --name-only | grep -q '^staged-file.md$'
  [ -f "$d/staged-file.md" ]
}

# ── 리뷰 16차 P1 회귀 ─────────────────────────────────────────────────────────

# P1: blob 대조를 통과한 캡처본이라도 열린 FD가 남아 있으면 폐기하지 않는다 —
# 폐기(rm) 후 그 FD의 늦은 write는 orphan inode로 사라졌다(silent loss).
@test "execute: open FD on merge-added path defers discard - late write is not lost" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  command -v lsof >/dev/null 2>&1 || command -v fuser >/dev/null 2>&1 \
    || skip "lsof/fuser 없음 — open-FD 가드는 fail-closed(REF_ONLY)로만 동작"

  # post-merge run_checks: merge-added 파일에 FD를 연 writer를 남겨 두고 실패 →
  # rollback 창에서 그 파일의 폐기가 시도된다.
  cat > "$TEST_HOME/mock_checks_fd.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/fd.flag" ]; then touch "$TEST_HOME/fd.flag"; exit 0; fi
# merge-added 파일에 append FD를 연 채 대기하다 늦게 쓰는 writer.
# set -m: writer를 독립 프로세스 그룹으로 — post-check 그룹 회수에서 살아남아
# "외부 프로세스가 FD를 쥔" 실제 시나리오를 재현한다.
set -m
bash -c 'exec 3>>"$d/docs/file-1.md"; echo held > "$TEST_HOME/fd.held"; j=0; while [ ! -f "$TEST_HOME/fd.release" ] && [ "\$j" -lt 600 ]; do sleep 0.05; j=\$((j+1)); done; echo LATE-WRITE >&3' &
echo \$! > "$TEST_HOME/fd.pid"
i=0; while [ ! -f "$TEST_HOME/fd.held" ] && [ "\$i" -lt 100 ]; do sleep 0.05; i=\$((i+1)); done
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_fd.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_fd.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  # 열린 FD가 있으므로 폐기하지 않고 보존 — REF_ONLY로 정직하게 기록
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
  # writer의 늦은 write가 유실되지 않았다 (경로의 inode가 유지됨).
  # 시간 의존 없음: release 신호 후 write를 관찰한다 (게이트 부하 무관 — 결정적).
  touch "$TEST_HOME/fd.release"
  [ -f "$d/docs/file-1.md" ]
  local k=0
  while ! grep -q 'LATE-WRITE' "$d/docs/file-1.md" 2>/dev/null && [ "$k" -lt 100 ]; do sleep 0.05; k=$((k+1)); done
  grep -q 'LATE-WRITE' "$d/docs/file-1.md"
  [ -z "$(find "$d" -name '.amrb*' 2>/dev/null)" ]
}

# P1: "같은 경로"의 동시 index-only staged 변경도 rollback의 경로 단위 reset이
# 지우지 않는다 — index 항목이 merge 잔상이 아닐 때는 보존하고 REF_ONLY 격하.
@test "execute: same-path index-only staged change survives rollback index sync" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_sp.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/sp.flag" ]; then touch "$TEST_HOME/sp.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_sp.sh"

  # 검증 루프(loop1)의 첫 hash-object 시점 — index 동기화(잠금) "이전" 창 — 에
  # 같은 경로(docs/file-1.md)에 foreign 내용을 stage. 과거에는 이어지는
  # git reset -- <path>가 이를 조용히 지웠다. (index.lock 원자 결속 이후로는
  # 잠금 안의 identity 재검증이 이를 보고 보존한다. 잠금 "도중"의 stage는 git
  # 규약상 index.lock에 막혀 아예 끼어들 수 없다.)
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/spbin"
  cat > "$TEST_HOME/spbin/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "hash-object" ] && [ "\$2" = "--" ] && [ ! -f "$TEST_HOME/sp.injected" ]; then
  touch "$TEST_HOME/sp.injected"
  _b="\$(printf 'foreign-staged-content\n' | "$realgit" -C "$d" hash-object -w --stdin)"
  "$realgit" -C "$d" update-index --add --cacheinfo "100644,\$_b,docs/file-1.md"
fi
exec "$realgit" "\$@"
MOCK
  chmod +x "$TEST_HOME/spbin/git"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/spbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_sp.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  [ "$(git -C "$d" rev-parse main)" = "$base" ]
  # 같은 경로의 staged 항목이 reset으로 지워지지 않았다
  git -C "$d" diff --cached --name-only | grep -q '^docs/file-1.md$'
  [ "$(git -C "$d" show ":docs/file-1.md")" = "foreign-staged-content" ]
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
}

# P1(4차): index CAS 임계구역(index.lock 보유) 중 TERM — .git/index.lock·
# index.amrb.*·writer lock이 남아 이후 수동 Git 복구까지 막던 고착 제거 검증.
@test "execute: TERM during index CAS leaves no stuck locks (index.lock, index.amrb, writer lock)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  local base
  base="$(git -C "$d" rev-parse main)"

  cat > "$TEST_HOME/mock_checks_tm.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/tm.flag" ]; then touch "$TEST_HOME/tm.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_tm.sh"

  # rollback의 index CAS 구간(ls-files 호출 = index.lock 보유 중)에서 auto_merge
  # 프로세스에 TERM을 보낸다 — wrapper의 부모가 auto_merge 셸이다.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$TEST_HOME/tmbin"
  cat > "$TEST_HOME/tmbin/git" <<MOCK
#!/usr/bin/env bash
if [ "\$1" = "ls-files" ] && [ ! -f "$TEST_HOME/tm.sent" ]; then
  touch "$TEST_HOME/tm.sent"
  kill -TERM "\$PPID" 2>/dev/null
  sleep 1
fi
exec "$realgit" "\$@"
MOCK
  chmod +x "$TEST_HOME/tmbin/git"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/tmbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_tm.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -ne 0 ]
  # 신호가 실제로 CAS 구간에 도달했다
  [ -f "$TEST_HOME/tm.sent" ]
  # 고착 잔여물 없음 — 이후 수동 git 작업이 막히지 않는다
  [ ! -e "$d/.git/index.lock" ]
  [ -z "$(find "$d/.git" -name 'index.amrb.*' 2>/dev/null)" ]
  [ ! -d "$TEST_HOME/state/ticket_write.lock.d" ]
  [ ! -d "$TEST_HOME/state/auto_merge.lock.d" ]
  # git이 정상 동작한다
  git -C "$d" status --porcelain >/dev/null
}

# P1(5차): index.lock "생성 직후, 소유 기록 이전" 창의 TERM — 이제 소유 기록이
# 생성보다 먼저라 어느 시점의 신호든 정리된다. cp(생성 직후 첫 파일 연산) 시점
# 신호로 검증한다.
@test "execute: TERM right after index.lock creation (at cp) leaves no stuck lock" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_t2.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/t2.flag" ]; then touch "$TEST_HOME/t2.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_t2.sh"

  local realcp
  realcp="$(command -v cp)"
  mkdir -p "$TEST_HOME/t2bin"
  cat > "$TEST_HOME/t2bin/cp" <<MOCK
#!/usr/bin/env bash
case "\$1" in
  *".git/index")
    if [ ! -f "$TEST_HOME/t2.sent" ]; then
      touch "$TEST_HOME/t2.sent"
      kill -TERM "\$PPID" 2>/dev/null
      sleep 1
    fi
    ;;
esac
exec "$realcp" "\$@"
MOCK
  chmod +x "$TEST_HOME/t2bin/cp"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/t2bin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_t2.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -ne 0 ]
  [ -f "$TEST_HOME/t2.sent" ]
  [ ! -e "$d/.git/index.lock" ]
  [ -z "$(find "$d/.git" -name 'index.amrb.*' 2>/dev/null)" ]
  git -C "$d" status --porcelain >/dev/null
}

# P1(5차): quarantine 내구성 — common git dir(.git) 우선이라 worktree의
# git clean -fd가 닿지 않고, manifest가 함께 남는다.
@test "execute: quarantine lands in common git dir with manifest and survives git clean -fd" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_q.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/q.flag" ]; then touch "$TEST_HOME/q.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_q.sh"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_q.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  grep -q $'\tROLLED_BACK$' "$TEST_HOME/state/auto_merge.log"
  # 폐기된 merge-added 파일이 .git 아래 quarantine에 manifest 레코드와 함께 남는다
  # (4라운드 P1 #3: manifest는 append 파일이 아니라 레코드별 파일 — temp→fsync→
  # 원자 rename이므로 존재하는 레코드는 완전하고 참이다)
  [ -d "$d/.git/auto_merge.trash.d" ]
  [ -d "$d/.git/auto_merge.trash.d/manifest.d" ]
  local rec qfile
  rec="$(grep -l $'\tdocs/file-1.md\t' "$d/.git/auto_merge.trash.d/manifest.d/"*.tsv 2>/dev/null | head -1)"
  [ -n "$rec" ]
  qfile="$(awk -F'\t' 'END{print $4}' "$rec")"
  [ -f "$qfile" ]
  grep -q 'content 1' "$qfile"
  # git clean -fd에도 살아남는다 (.git은 clean 대상이 아님)
  git -C "$d" clean -fd >/dev/null 2>&1 || true
  [ -f "$qfile" ]
}

# P1(6차): 획득 실패(타 프로세스의 index.lock 존재) 직후의 신호 — 5차의 "획득 전
# 경로 등록"은 핸들러의 rm -f가 "남의" index.lock을 지웠다. 소유는 내용 토큰으로
# 판정하므로, 어느 시점의 신호에서도 foreign lock은 삭제되지 않아야 한다.
@test "execute: signal after failed index.lock acquisition preserves the foreign lock (token ownership)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_fl.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/fl.flag" ]; then touch "$TEST_HOME/fl.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_fl.sh"

  # index.lock 획득(ln) 직전에: (1) foreign lock을 먼저 만들어 획득을 실패시키고
  # (2) auto_merge 셸에 TERM을 보낸다 — 트랩은 ln 종료 직후(경로·토큰 등록 상태,
  # 획득 실패 분기 진입 전)에 실행된다. 정확히 5차 결함의 창이다.
  local realln
  realln="$(command -v ln)"
  mkdir -p "$TEST_HOME/flbin"
  cat > "$TEST_HOME/flbin/ln" <<MOCK
#!/usr/bin/env bash
for a in "\$@"; do
  case "\$a" in
    *".git/index.lock")
      if [ ! -f "$TEST_HOME/fl.sent" ]; then
        touch "$TEST_HOME/fl.sent"
        printf 'foreign-process-lock' > "$d/.git/index.lock"
        kill -TERM "\$PPID" 2>/dev/null
        sleep 1
      fi
      ;;
  esac
done
exec "$realln" "\$@"
MOCK
  chmod +x "$TEST_HOME/flbin/ln"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/flbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_fl.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -ne 0 ]
  [ -f "$TEST_HOME/fl.sent" ]
  # 남의 lock은 내용 그대로 보존된다 — rm 되지 않았다
  [ -e "$d/.git/index.lock" ]
  [ "$(cat "$d/.git/index.lock")" = "foreign-process-lock" ]
  # 우리 쪽 잔여물(token 임시 파일·임시 index)은 없다
  [ -z "$(find "$d/.git" -maxdepth 1 -name 'index.amrb*' 2>/dev/null)" ]
}

# 8라운드 후속 P1: cleanup의 release가 소유 확인 "전"에 canonical lock을 rename으로
# 들어냈다 — 획득 여부와 무관하게 release가 호출되므로, 살아 있는 foreign writer의
# lock이 빈 창 동안 canonical 경로에서 사라져 제3 writer가 획득했다 (상호배제 붕괴,
# 실측: canonical=third, displaced=live foreign). 이제 release는 획득 시 보관한
# 세션 token이 일치하는 lock에만 손을 댄다 — foreign lock은 한순간도 이동하지 않는다.
@test "execute: live foreign writer lock never leaves the canonical path (token-gated release, no exclusion gap)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  # 초기 clean 검사를 통과하도록 state/를 ignore (실제 repo와 동일 조건)
  printf 'state/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -q -m "ignore state"
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_fw.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/fw.flag" ]; then touch "$TEST_HOME/fw.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_fw.sh"

  # 살아 있는 foreign writer의 lock (token 파일 없음 — 다른 writer 계열)
  sleep 600 &
  local fpid=$!
  mkdir -p "$d/state/ticket_write.lock.d"
  echo "$fpid" > "$d/state/ticket_write.lock.d/pid"
  local ino_before gap_pid
  ino_before="$(stat -f '%i' "$d/state/ticket_write.lock.d/pid" 2>/dev/null || stat -c '%i' "$d/state/ticket_write.lock.d/pid")"
  # 관찰자: canonical lock이 한순간이라도 사라지면 GAP 기록
  ( while :; do [ -d "$d/state/ticket_write.lock.d" ] || echo GAP >> "$TEST_HOME/fw.gaps"; sleep 0.01; done ) &
  gap_pid=$!

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_fw.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  kill "$gap_pid" 2>/dev/null || true
  wait "$gap_pid" 2>/dev/null || true
  kill "$fpid" 2>/dev/null || true

  [ "$status" -eq 1 ]
  # 상호배제가 한순간도 깨지지 않았다 — 관찰 내내 canonical lock 존재
  [ ! -f "$TEST_HOME/fw.gaps" ]
  # foreign lock은 내용·inode 그대로 — 들어냈다 되돌린 것도 아니다
  [ "$(cat "$d/state/ticket_write.lock.d/pid")" = "$fpid" ]
  [ "$(stat -f '%i' "$d/state/ticket_write.lock.d/pid" 2>/dev/null || stat -c '%i' "$d/state/ticket_write.lock.d/pid")" = "$ino_before" ]
  # 들어낸 흔적(.rel/.acq)이 없다
  [ -z "$(ls -d "$d/state/ticket_write.lock.d.rel."* "$d/state/ticket_write.lock.d.acq."* 2>/dev/null || true)" ]
  # writer lock을 못 잡으므로 복원은 포기 — 잔상 보존(REF_ONLY)
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
}

# 8라운드 후속 P1: quarantine rename과 manifest 기록 사이에 죽으면 빈 .claim +
# .amrb-bak payload만 남아 원경로·worktree·merge OID를 알 수 없었다 — 결정적 복구
# 불가. 이제 rename "전"에 내구성 있는 intent metadata를 기록한다.
@test "execute: KILL right after the original is captured leaves deterministic intent metadata (intent precedes capture)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true
  # macOS: mktemp -d는 /var/..., git rev-parse --show-toplevel은 /private/var/... —
  # intent의 worktree는 물리 경로다. 비교 기준을 물리 경로로 정규화한다.
  local dphys
  dphys="$(cd "$d" && pwd -P)"

  cat > "$TEST_HOME/mock_checks_qi.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/qi.flag" ]; then touch "$TEST_HOME/qi.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_qi.sh"

  # 8라운드 후속 재리뷰 P1(#9)의 정확한 창: 원본을 .amrb-bak.<pid>로 "capture한
  # 직후" KILL — 종전에는 이 시점에 원본이 원경로에서 사라지고 hidden backup만
  # 남았으며 intent·manifest가 모두 없어 복구가 불가능했다.
  local realmv
  realmv="$(command -v mv)"
  mkdir -p "$TEST_HOME/qibin"
  cat > "$TEST_HOME/qibin/mv" <<MOCK
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in *.amrb-bak.*)
  "$realmv" "\$@"; rc=\$?
  kill -KILL "\$PPID" 2>/dev/null
  sleep 3
  exit \$rc
;; esac
exec "$realmv" "\$@"
MOCK
  chmod +x "$TEST_HOME/qibin/mv"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/qibin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_qi.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -ne 0 ]

  # 원본은 원경로에서 사라졌지만(capture됨), intent가 그 위치를 가리킨다
  local intent src wt capture dst payload
  intent="$(ls "$d/.git/auto_merge.trash.d/"*.intent 2>/dev/null | head -1)"
  [ -n "$intent" ]
  grep -q $'^src\tdocs/file-1.md$' "$intent"
  grep -Eq $'^merge\t[0-9a-f]{40}$' "$intent"
  grep -q $'^worktree\t'"$dphys"'$' "$intent"
  src="$(awk -F'\t' '$1=="src"{print $2}' "$intent")"
  wt="$(awk -F'\t' '$1=="worktree"{print $2}' "$intent")"
  capture="$(awk -F'\t' '$1=="capture"{print $2}' "$intent")"
  dst="$(awk -F'\t' '$1=="dst"{print $2}' "$intent")"
  # payload는 capture 또는 dst 중 한 곳에 반드시 존재한다 (유실 없음)
  payload=""
  [ -f "$dst" ] && payload="$dst"
  [ -z "$payload" ] && [ -f "$capture" ] && payload="$capture"
  [ -n "$payload" ]
  grep -q "content 1" "$payload"
  # manifest에는 이 격리의 행이 없다 — 기록 전 중단은 행이 아니라 intent로 식별된다
  if [ -f "$d/.git/auto_merge.trash.d/manifest.tsv" ]; then
    ! grep -q "$dst" "$d/.git/auto_merge.trash.d/manifest.tsv"
  fi
  # intent의 metadata만으로 실제 복원이 성립한다 (README의 복구 절차 그대로)
  mv "$payload" "$wt/$src"
  grep -q "content 1" "$d/docs/file-1.md"
}

# 8라운드 후속 P1: manifest 기록 실패가 rollback 성공으로 취급됐다 — 이제 기록
# 실패는 rename을 되돌리고 실패를 반환한다 (호출자가 원복·보존, REF_ONLY 격하).
@test "execute: quarantine manifest record failure is not success - rename undone, file preserved, REF_ONLY" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_qm.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/qm.flag" ]; then touch "$TEST_HOME/qm.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_qm.sh"

  # manifest.d 자리에 "파일" — 레코드 디렉터리 생성(mkdir -p)이 반드시 실패한다
  # (4라운드 P1 #3: append+사후검증 → 레코드별 파일 temp→fsync→rename 구조)
  mkdir -p "$d/.git/auto_merge.trash.d"
  touch "$d/.git/auto_merge.trash.d/manifest.d"

  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_qm.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  # rename이 되돌려져 파일은 원경로에 보존됐고, REF_ONLY로 격하됐다
  [ -f "$d/docs/file-1.md" ]
  grep -q "content 1" "$d/docs/file-1.md"
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
  # 격리 디렉터리에 payload·intent 잔여물이 없다 (거짓 기록·거짓 성공 없음)
  [ -z "$(ls "$d/.git/auto_merge.trash.d" 2>/dev/null | grep -v -e '^README.md$' -e '^manifest.d$' || true)" ]
  # worktree 쪽 capture 잔여물도 없다 (원복 완료)
  [ -z "$(ls -d "$d/docs/".amrb-bak.* 2>/dev/null || true)" ]
}

# 8라운드 후속 재리뷰 P1(#10) → 4라운드 P1(#1·#2): 기록 실패 시 payload는 capture를
# 떠나지 않는다(ln-forward). 원복(no-clobber)이 원경로의 동시 파일 때문에 실패하면
# 동시 파일을 덮지 않고, payload는 capture 디렉터리에 intent와 함께 보존되어
# 결정적 복구가 가능하다.
@test "execute: record failure + concurrent file at the original path - foreign file untouched, payload kept with intent" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_nc.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/nc.flag" ]; then touch "$TEST_HOME/nc.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_nc.sh"

  # manifest.d 자리에 "파일" → 레코드 기록이 반드시 실패한다 (4라운드 #3 구조)
  mkdir -p "$d/.git/auto_merge.trash.d"
  touch "$d/.git/auto_merge.trash.d/manifest.d"
  # capture 직후 "원경로"를 동시 파일이 선점하게 만든다 — 원복은 no-clobber여야 한다
  local realmv
  realmv="$(command -v mv)"
  mkdir -p "$TEST_HOME/ncbin"
  cat > "$TEST_HOME/ncbin/mv" <<MOCK
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in *.amrb-bak.*)
  # 6라운드 gate fixture: src는 위치가 아니라 "첫 비옵션 인수"로 추출 (mv 옵션 내성)
  src=""
  for a in "\$@"; do case "\$a" in -*) ;; *) src="\$a"; break ;; esac; done
  "$realmv" "\$@"; rc=\$?
  printf 'CONCURRENT-DO-NOT-CLOBBER\n' > "\$src"
  exit \$rc
;; esac
exec "$realmv" "\$@"
MOCK
  chmod +x "$TEST_HOME/ncbin/mv"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/ncbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_nc.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"

  # 동시 파일은 덮이지 않았다 (no-clobber 원복)
  grep -q "CONCURRENT-DO-NOT-CLOBBER" "$d/docs/file-1.md"
  # payload는 capture 디렉터리(payload 파일이 있으면 그것이 payload — 모호성 없음)에
  # intent와 함께 보존되어 결정적 복구가 가능하다
  local cap intent
  cap="$(ls "$d/docs/".amrb-bak.*.d/payload.* 2>/dev/null | head -1)"
  [ -n "$cap" ]
  grep -q "content 1" "$cap"
  intent="$(ls "$d/.git/auto_merge.trash.d/"*.intent 2>/dev/null | head -1)"
  [ -n "$intent" ]
  grep -q $'^src\tdocs/file-1.md$' "$intent"
  # intent의 capture 필드가 가리키는 payload가 실제로 존재하고 내용이 맞다
  local capfield
  capfield="$(awk -F'\t' '$1=="capture"{print $2}' "$intent")"
  [ -f "$capfield" ]
  grep -q "content 1" "$capfield"
  # intent의 복구 절차가 성립한다: dst payload 없음(파일 부재 = payload 아님) →
  # capture payload가 유일한 복구 근거다
  [ ! -f "$(awk -F'\t' '$1=="dst"{print $2}' "$intent")" ]
}

# 8라운드 후속 재리뷰 P1(#8): lock 디렉터리 rename 성공과 token 대입 사이의 TERM에서
# cleanup이 소유를 인지하지 못해 canonical writer lock이 잔존했다 (실측). 소유 증거
# (token)는 사전 구성 시점에 파일·셸 변수에 동시에 심어, rename이 성공하는 순간부터
# cleanup이 확인할 수 있어야 한다.
@test "execute: TERM right after the writer-lock rename succeeds leaves no canonical lock (token precedes rename)" {
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  printf 'state/\n' > "$d/.gitignore"
  git -C "$d" add .gitignore
  git -C "$d" commit -q -m "ignore state"
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_lk.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/lk.flag" ]; then touch "$TEST_HOME/lk.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_lk.sh"

  local realmv
  realmv="$(command -v mv)"
  mkdir -p "$TEST_HOME/lkbin"
  cat > "$TEST_HOME/lkbin/mv" <<MOCK
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in */state/ticket_write.lock.d)
  "$realmv" "\$@"; rc=\$?
  kill -TERM "\$PPID" 2>/dev/null
  exit \$rc
;; esac
exec "$realmv" "\$@"
MOCK
  chmod +x "$TEST_HOME/lkbin/mv"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/lkbin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_lk.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -ne 0 ]
  # canonical writer lock이 남지 않았다 — 다음 writer가 고착되지 않는다
  [ ! -d "$d/state/ticket_write.lock.d" ]
  [ -z "$(ls -d "$d/state/ticket_write.lock.d."* 2>/dev/null || true)" ]
}

@test "execute: TERM during post-check leaves no lock (traps precede acquisition) -> next run acquires normally" {
  # 재재리뷰 P1(#9) → 3라운드 P1(#1): 계약 정리 —
  #   - pid 없는 lock은 "회수하지 않는다": 기존 계약(동시 실행 간주, fail-closed
  #     거부·무접촉)을 유지한다. 위 'concurrent lock present' 테스트가 이를 고정한다.
  #   - 대신 우리 프로토콜은 반쪽 lock을 만들지 않는다: trap을 획득 "전"에 설치하고
  #     획득은 pid·token이 담긴 사전 구성 디렉터리의 원자 rename이다. 어느 시점의
  #     신호에서도 lock이 잔존하지 않아 다음 실행이 고착되지 않는다.
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs

  cat > "$TEST_HOME/mock_checks_slow.sh" <<EOF
#!/bin/sh
n=\$(cat "$TEST_HOME/slow.cnt" 2>/dev/null || echo 0); n=\$((n+1)); echo \$n > "$TEST_HOME/slow.cnt"
if [ \$n -ge 2 ]; then touch "$TEST_HOME/slow.inpost"; sleep 30; fi
exit 0
EOF
  chmod +x "$TEST_HOME/mock_checks_slow.sh"

  (cd "$d" && exec env \
    LINT_EXTERNAL_DOCS_CMD="$MOCK_LINT" \
    RUN_CHECKS_CMD="$TEST_HOME/mock_checks_slow.sh" \
    CHECK_SCOPE_OMISSION_CMD="$MOCK_SCOPE" \
    STATE_DIR="$TEST_HOME/state" \
    TICKETS_DIR="$TICKETS_DIR" \
    "$SCRIPT_PATH" "$TEST_HOME/T999-test.md" --execute --branch ralph/T999 --base main) \
    > "$TEST_HOME/slow.log" 2>&1 &
  local bg=$! i=0 rc=0
  while [ ! -f "$TEST_HOME/slow.inpost" ] && [ "$i" -lt 200 ]; do sleep 0.1; i=$((i+1)); done
  [ -f "$TEST_HOME/slow.inpost" ]
  sleep 0.3
  kill -TERM "$bg"
  wait "$bg" || rc=$?
  [ "$rc" -eq 143 ]
  # lock이 잔존하지 않는다 — 다음 실행이 'pid unknown'으로 고착되지 않는다
  [ ! -e "$TEST_HOME/state/auto_merge.lock.d" ]
  [ -z "$(ls -d "$TEST_HOME/state/auto_merge.lock.d."* 2>/dev/null || true)" ]

  rm -f "$TEST_HOME/slow.cnt" "$TEST_HOME/slow.inpost"
  run bash -c "cd '$d' && \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$MOCK_CHECKS' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 0 ]
  [[ "$output" == *"auto-merge executed"* ]]
}

@test "execute: intruder file planted at the reserved capture payload path is never clobbered (link(2) capture)" {
  # 5라운드 #3 → 6라운드 P1(#1): mv -n은 macOS에서 원자 no-clobber CAS가 아니다
  # (lstat+일반 rename) — capture 게시는 link(2)로 교체됐다. 예약된 payload 경로가
  # ln 직전에 선점되면 ln이 배타 실패하고 아무것도 이동하지 않는다
  # (원본 무손실·침입 파일 불변).
  local d="$TEST_HOME/repo"
  mkdir -p "$d"
  make_repo "$d" 1 docs
  make_ticket "$TEST_HOME/T999-test.md" true

  cat > "$TEST_HOME/mock_checks_ci.sh" <<MOCK
#!/usr/bin/env bash
if [ ! -f "$TEST_HOME/ci.flag" ]; then touch "$TEST_HOME/ci.flag"; exit 0; fi
exit 1
MOCK
  chmod +x "$TEST_HOME/mock_checks_ci.sh"

  local realln
  realln="$(command -v ln)"
  mkdir -p "$TEST_HOME/cibin"
  cat > "$TEST_HOME/cibin/ln" <<MOCK
#!/usr/bin/env bash
last=""
for a in "\$@"; do last="\$a"; done
case "\$last" in *.amrb-bak.*payload.*)
  if [ ! -e "\$last" ]; then printf 'FOREIGN-CAPTURE\n' > "\$last"; fi
;; esac
exec "$realln" "\$@"
MOCK
  chmod +x "$TEST_HOME/cibin/ln"

  run bash -c "cd '$d' && \
    PATH='$TEST_HOME/cibin:'\"\$PATH\" \
    LINT_EXTERNAL_DOCS_CMD='$MOCK_LINT' \
    RUN_CHECKS_CMD='$TEST_HOME/mock_checks_ci.sh' \
    CHECK_SCOPE_OMISSION_CMD='$MOCK_SCOPE' \
    STATE_DIR='$TEST_HOME/state' \
    '$SCRIPT_PATH' '$TEST_HOME/T999-test.md' --execute --branch ralph/T999 --base main"
  [ "$status" -eq 1 ]
  grep -q $'\tROLLED_BACK_REF_ONLY$' "$TEST_HOME/state/auto_merge.log"
  # 원본은 원경로에 무손실로 남았다 (capture 자체가 일어나지 않음 — ln 배타 실패)
  grep -q "content 1" "$d/docs/file-1.md"
  # 침입 파일은 덮이지 않았다
  local intr
  intr="$(ls "$d/docs/".amrb-bak.*.d/payload.* 2>/dev/null | head -1)"
  [ -n "$intr" ]
  grep -q "FOREIGN-CAPTURE" "$intr"
}
