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
