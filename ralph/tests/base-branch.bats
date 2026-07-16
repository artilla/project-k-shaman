#!/usr/bin/env bats
# ralph/tests/base-branch.bats — detect_base_branch() 우선순위 6단계 회귀 테스트.
#
# 각 테스트는 mktemp -d 에 격리된 git repo를 생성.
# RALPH_ROOT 누수 차단 (T025 패턴): run_checks.sh 가 env -u RALPH_ROOT 로 호출함.

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  TEST_HOME="$(mktemp -d)"
  FAKE_HOME="$TEST_HOME/.fakehome"
  mkdir -p "$FAKE_HOME"
}

teardown() {
  rm -rf "$TEST_HOME"
}

# ── helpers ──────────────────────────────────────────────────────────────────

_init_repo() {
  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"
  printf '' > "$TEST_HOME/README"
  git -C "$TEST_HOME" add README
  git -C "$TEST_HOME" commit -q -m "init"
}

_run_detect() {
  run bash -c 'cd "$1" && source "$2/ralph/scripts/lib/base_branch.sh" && detect_base_branch' \
    -- "$TEST_HOME" "$REPO_ROOT"
}

_run_detect_isolated() {
  run env HOME="$FAKE_HOME" GIT_CONFIG_NOSYSTEM=1 \
    bash -c 'cd "$1" && source "$2/ralph/scripts/lib/base_branch.sh" && detect_base_branch' \
    -- "$TEST_HOME" "$REPO_ROOT"
}

# ── Case 1: origin/HEAD=main → main ─────────────────────────────────────────

@test "detect_base_branch: origin/HEAD points to main → returns main" {
  _init_repo
  # Set origin/HEAD symbolic ref directly (no real remote needed)
  git -C "$TEST_HOME" symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main

  _run_detect
  [ "$status" -eq 0 ]
  [ "$output" = "main" ]
}

# ── Case 2: no origin, init.defaultBranch=trunk → trunk ─────────────────────

@test "detect_base_branch: no origin, local init.defaultBranch=trunk → returns trunk" {
  _init_repo
  git -C "$TEST_HOME" config init.defaultBranch trunk

  _run_detect
  [ "$status" -eq 0 ]
  [ "$output" = "trunk" ]
}

# ── Case 3: no origin, no defaultBranch, master branch only → master ─────────

@test "detect_base_branch: no origin, no defaultBranch, only master branch → returns master" {
  _init_repo
  local cur_branch
  cur_branch=$(git -C "$TEST_HOME" symbolic-ref --short HEAD)
  if [ "$cur_branch" != "master" ]; then
    git -C "$TEST_HOME" branch -m "$cur_branch" master
  fi
  git -C "$TEST_HOME" branch -D main  2>/dev/null || true
  git -C "$TEST_HOME" branch -D trunk 2>/dev/null || true

  # Isolated HOME prevents global init.defaultBranch from interfering
  _run_detect_isolated
  [ "$status" -eq 0 ]
  [ "$output" = "master" ]
}

# ── Case 4: no signals → exit 1 + stderr diagnostic ─────────────────────────

@test "detect_base_branch: no detectable signals → exits non-zero with BASE_BRANCH hint" {
  # Empty repo: no commits → no branches, no origin
  git -C "$TEST_HOME" init -q
  git -C "$TEST_HOME" config user.email "test@example.com"
  git -C "$TEST_HOME" config user.name "Test"
  # No commit, so refs/heads/* do not exist

  # Isolated HOME + NOSYSTEM suppresses global init.defaultBranch config
  _run_detect_isolated
  [ "$status" -ne 0 ]
  # Stderr diagnostic must mention BASE_BRANCH so operators know the workaround
  [[ "$output" == *"BASE_BRANCH"* ]]
}
