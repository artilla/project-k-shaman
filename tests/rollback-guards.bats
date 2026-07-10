#!/usr/bin/env bats
# tests/rollback-guards.bats — 리뷰 2차 P1-10: rollback.sh 파괴 방지 가드 회귀 테스트.
#
#   가드 1: 추적 파일 미커밋 변경 → 거부 (exit 3)
#   가드 2: isolated worktree(.ralph/wt-*)는 즉시 실행 (자동화 경로 보존)
#   가드 3: 메인 워크트리 비대화형 + --yes 없음 → 거부 (exit 3), --yes 있으면 실행

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TEST_BASE="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_BASE"
}

# _make_repo <dir> — rollback.sh가 든 git repo + cycle/T200-pre 태그 + 태그 후 커밋 1개
_make_repo() {
  local d="$1"
  mkdir -p "$d/scripts"
  cp "$REPO_ROOT/scripts/rollback.sh" "$d/scripts/rollback.sh"
  chmod +x "$d/scripts/rollback.sh"

  git -C "$d" init -q
  git -C "$d" config user.email "test@example.com"
  git -C "$d" config user.name "Test"

  echo "v1" > "$d/file.txt"
  git -C "$d" add .
  git -C "$d" commit -q -m "init"
  git -C "$d" tag "cycle/T200-pre"

  echo "v2" > "$d/file.txt"
  git -C "$d" add file.txt
  git -C "$d" commit -q -m "T200: cycle change"
}

@test "R1: dirty tracked files -> refused exit 3 (protects work from reset --hard)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  echo "uncommitted" >> "$repo/file.txt"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"미커밋 변경"* ]]
  # 파일이 파괴되지 않았어야 한다
  grep -q "uncommitted" "$repo/file.txt"
}

@test "R2: main worktree non-interactive without --yes -> refused exit 3 (fail-closed)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"--yes"* ]]
  # 롤백되지 않았어야 한다
  grep -q "v2" "$repo/file.txt"
}

@test "R3: main worktree with --yes -> restored to pre-cycle tag" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored T200"* ]]
  grep -q "v1" "$repo/file.txt"
}

@test "R4: isolated worktree (.ralph/wt-*) runs immediately without --yes even non-interactive" {
  local repo="$TEST_BASE/.ralph/wt-x"
  _make_repo "$repo"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"restored T200"* ]]
  grep -q "v1" "$repo/file.txt"
}

@test "R5: no pre-cycle tag -> legacy behavior kept (revert guidance, exit 1)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  git -C "$repo" tag -d "cycle/T200-pre" >/dev/null

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 1 ]
  [[ "$output" == *"git revert"* ]]
}
