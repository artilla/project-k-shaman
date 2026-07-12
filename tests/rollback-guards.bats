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
  # run_loop이 성공 사이클 종점에 남기는 소유권 증거 — annotation에 소유 커밋
  # OID 목록 (리뷰 16차 P1 4차: rollback은 이 목록"만" revert한다)
  git -C "$d" tag -a "cycle/T200-post" -m "owned-commits
$(git -C "$d" rev-parse HEAD)"
}

# 티켓 소유 커밋을 추가하고 post 태그를 소유 목록과 함께 갱신
_add_owned_commit() {  # <dir> <msg> [<file> <content>]
  local d="$1" msg="$2" f="${3:-file.txt}" c="${4:-x}"
  echo "$c" >> "$d/$f"
  git -C "$d" add "$f"
  git -C "$d" commit -q -m "$msg"
  local prev
  prev="$(git -C "$d" tag -l --format='%(contents)' cycle/T200-post | grep -E '^[0-9a-f]{40}$' || true)"
  git -C "$d" tag -f -a "cycle/T200-post" -m "owned-commits
$(git -C "$d" rev-parse HEAD)
$prev"
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

@test "R3: main worktree with --yes -> rolled back by revert (history preserved, no reset --hard)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled back T200 by revert"* ]]
  grep -q "v1" "$repo/file.txt"
  # 비가역 파괴가 아니다 — 원 커밋과 역커밋이 모두 히스토리에 남는다
  run git -C "$repo" log --format=%s
  [[ "$output" == *"T200: cycle change"* ]]
  [[ "$output" == *"Revert"* ]]
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

# ── 리뷰 16차 P1 회귀 ──────────────────────────────────────────────────────────

@test "R6: commits after the recorded cycle end -> refused (no bypass with --yes)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 기록된 종점(post 태그) 이후에 쌓인 커밋 — 소속과 무관하게 파괴 금지
  echo "other-ticket" > "$repo/other.txt"
  git -C "$repo" add other.txt
  git -C "$repo" commit -q -m "T300: unrelated cycle work"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"T300: unrelated cycle work"* ]]
  [[ "$output" == *"git revert"* ]]
  # 무관 커밋의 산출물은 파괴되지 않았다
  [ -f "$repo/other.txt" ]
  grep -q "v2" "$repo/file.txt"
}

@test "R7: recorded cycle range (cycle + telemetry + writer audit, post at HEAD) -> revert rollback proceeds" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  _add_owned_commit "$repo" "telemetry(T200): tokens_total" file.txt t
  _add_owned_commit "$repo" "ticket_edit(T200): priority P2→P1" file.txt e

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled back T200 by revert"* ]]
  grep -q "v1" "$repo/file.txt"
  # 히스토리 보존 (reset --hard 아님)
  run git -C "$repo" log --format=%s
  [[ "$output" == *"telemetry(T200): tokens_total"* ]]
  # 무효화된 종점 기록은 제거된다
  ! git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R8: subject-spoofed commit (T200: ...) without recorded evidence -> refused (subject is not ownership)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 종점 기록 이후의 수동 커밋 — subject가 "T200:"으로 보여도 own commit이 아니다.
  # 과거 subject 매칭 가드는 이를 own으로 오인해 reset --hard로 함께 파괴했다.
  echo "manual hotfix mixed with unrelated change" > "$repo/hotfix.txt"
  git -C "$repo" add hotfix.txt
  git -C "$repo" commit -q -m "T200: hotfix (manual, mixed content)"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"git revert"* ]]
  # 수동 커밋의 산출물은 파괴되지 않았다
  [ -f "$repo/hotfix.txt" ]
  grep -q "v2" "$repo/file.txt"
}

@test "R9: pre tag only, no post record, commits present -> destructive reset refused" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  git -C "$repo" tag -d "cycle/T200-post" >/dev/null

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"git revert"* ]]
  grep -q "v2" "$repo/file.txt"
}

@test "R10: unrelated commit inside the pre..post window is NOT reverted (owned OIDs only)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 사이클 도중 끼어든 무관 커밋 — 소유 목록에 없으므로 revert 대상이 아니다
  # (리뷰 16차 P1-3 4차: 범위 revert 금지, OID 고정)
  echo "concurrent" > "$repo/unrelated.txt"
  git -C "$repo" add unrelated.txt
  git -C "$repo" commit -q -m "docs: concurrent unrelated work"
  # post는 HEAD를 가리키되 annotation의 소유 목록에는 T200 커밋만 있다
  local owned
  owned="$(git -C "$repo" log --format=%H --grep='^T200: cycle change' -1)"
  git -C "$repo" tag -f -a "cycle/T200-post" -m "owned-commits
$owned"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"revert"* ]]
  # 무관 커밋의 산출물은 워크트리에 그대로 남는다 (revert되지 않음)
  [ -f "$repo/unrelated.txt" ]
  grep -q concurrent "$repo/unrelated.txt"
  # 티켓 소유 커밋만 되돌려졌다
  grep -q "v1" "$repo/file.txt"
  run git -C "$repo" log --format=%s
  [[ "$output" == *"docs: concurrent unrelated work"* ]]
  [[ "$output" == *"T200: cycle change"* ]]
}

@test "R11: post tag without owned-commit annotation -> automatic rollback refused (fail-closed)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 구 형식(무주석) 태그로 교체
  git -C "$repo" tag -f "cycle/T200-post"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"소유 커밋 목록"* ]]
  [[ "$output" == *"git revert"* ]]
  grep -q "v2" "$repo/file.txt"
}

@test "R12: mid-sequence revert failure (conflict) -> clean recovery, no REVERT_HEAD, no staged leftovers" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 소유 커밋 2개가 같은 줄을 순차 수정한 상태에서 annotation 순서를 "역순"으로
  # 기록 — 첫 revert(과거 커밋)가 최신 내용과 충돌해 sequencer가 REVERT_HEAD를
  # 남기며 실패한다. 상태 머신은 이를 정리하고 fail-closed로 끝나야 한다.
  # (git revert는 pre-commit/commit-msg 훅을 실행하지 않음 — 실측. 충돌이
  # 결정적 실패 주입 수단이다.)
  local A B
  A="$(git -C "$repo" rev-parse HEAD)"   # T200: cycle change (v1→v2)
  echo "v3" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "T200: second change"
  B="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" tag -f -a "cycle/T200-post" -m "owned-commits
$A
$B"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"revert 실패"* ]]
  # 중간상태 잔존 없음 — 수동 Git 작업이 막히지 않는다
  [ ! -e "$repo/.git/REVERT_HEAD" ]
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]
  grep -q "v3" "$repo/file.txt"
  # post 태그는 남아 있어 정리 후 재시도 가능하다
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R13: foreign commit injected after validation is not reverted (pinned OIDs, no HEAD TOCTOU)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"

  # 검증(소유 목록 확정) 이후, 첫 revert 직전에 foreign commit을 주입하는 wrapper
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin"
  cat > "$repo/gbin/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = "revert" ] && [ "\$2" != "--abort" ] && [ ! -f "$repo/.injected" ]; then
  touch "$repo/.injected"
  echo late > "$repo/foreign.txt"
  "$realgit" add foreign.txt
  "$realgit" -c user.email=f@f -c user.name=F commit -q -m "foreign: injected after validation"
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin/git"

  run bash -c 'cd "$1" && PATH="$1/gbin:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  # foreign commit과 산출물은 revert되지 않았다
  [ -f "$repo/foreign.txt" ]
  run git -C "$repo" log --format=%s
  [[ "$output" == *"foreign: injected after validation"* ]]
  # 소유 커밋은 되돌려졌다
  grep -q "v1" "$repo/file.txt"
}

@test "R14: mid-sequence failure is resumable and abort-only recovery preserves concurrent dirty files" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # C1(무관 파일)·A(file.txt v1→v2)는 owned, B(file.txt v2→v3)는 owned 아님 —
  # A revert가 B의 내용과 충돌해 2번째에서 실패한다 (부분 실행 상태).
  local C1 A
  # 동시 dirty 주입 대상(어떤 owned revert도 건드리지 않는 파일)
  echo "stable" > "$repo/stable.txt"
  git -C "$repo" add stable.txt
  git -C "$repo" commit -q -m "T200: stable (not owned)"
  echo "c1" > "$repo/other.txt"
  git -C "$repo" add other.txt
  git -C "$repo" commit -q -m "T200: c1"
  C1="$(git -C "$repo" rev-parse HEAD)"
  A="$(git -C "$repo" log --format=%H --grep='^T200: cycle change' -1)"
  echo "v3" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "T200: second (not owned)"
  git -C "$repo" tag -f -a "cycle/T200-post" -m "owned-commits
$C1
$A"

  # 충돌 revert(A) 직전에 동시 tracked 변경을 주입하는 wrapper — 복구가
  # reset --hard였다면 이 변경이 파괴된다 (5차 P1-7).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin2"
  cat > "$repo/gbin2/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = "revert" ] && [ "\$3" = "$A" ]; then
  echo "concurrent-dirty" >> "$repo/stable.txt"
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin2/git"

  run bash -c 'cd "$1" && PATH="$1/gbin2:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"revert 실패"* ]]
  [[ "$output" == *"재실행하면"* ]]
  # C1은 이미 되돌려졌고, 잔여 sequencer 상태 없음
  [ ! -e "$repo/.git/REVERT_HEAD" ]
  run git -C "$repo" log --format=%s -3
  [[ "$output" == *'Revert "T200: c1"'* ]]
  # abort-only 복구 — 동시 tracked 변경은 파괴되지 않았다
  grep -q "concurrent-dirty" "$repo/stable.txt"

  # 재실행(동시 dirty 정리 후): 거부되지 않고 C1은 건너뛴 채 A에서 같은 이유로 실패
  git -C "$repo" checkout -- stable.txt
  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"정합하지 않습니다"* ]]
  [[ "$output" == *"이미 되돌려짐"* ]]
  # C1 역커밋은 한 번만 존재한다 (중복 revert 없음)
  [ "$(git -C "$repo" log --format=%s | grep -c 'Revert "T200: c1"')" = "1" ]
}
