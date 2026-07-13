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

@test "R13: foreign commit injected after validation -> publish refused, nothing lost (isolated worktree, ff-only CAS)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"

  # 검증(소유 목록 확정) 이후, 격리 worktree의 첫 revert 직전에 메인 HEAD에
  # foreign commit을 주입하는 wrapper — 7차 P1-7 설계에서 revert는 격리
  # worktree에서 계산되고, 공개는 HEAD 불변 재검증 + ff-only라 주입을 감지해
  # 공개를 거부한다 (foreign도 소유 revert 결과도 잃지 않음, fail-closed).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin"
  cat > "$repo/gbin/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" revert "*) is_revert=1 ;; *) is_revert=0 ;; esac
case " \$* " in *" --abort "*) is_revert=0 ;; esac
if [ "\$is_revert" = "1" ] && [ ! -f "$repo/.injected" ]; then
  touch "$repo/.injected"
  echo late > "$repo/foreign.txt"
  "$realgit" add foreign.txt
  "$realgit" -c user.email=f@f -c user.name=F commit -q -m "foreign: injected after validation"
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin/git"

  run bash -c 'cd "$1" && PATH="$1/gbin:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"HEAD가 이동"* ]]
  # foreign commit과 산출물은 그대로 — 아무것도 revert/공개되지 않았다
  [ -f "$repo/foreign.txt" ]
  run git -C "$repo" log --format=%s -1
  [[ "$output" == *"foreign: injected after validation"* ]]
  grep -q "v2" "$repo/file.txt"
  # 계산 결과는 refs/rollback에 보존되어 수동 검토 가능
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
  # 종점 기록은 삭제되지 않았다
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
  # 격리 worktree 잔여물 없음
  [ "$(git -C "$repo" worktree list | wc -l | tr -d ' ')" = "1" ]
}

@test "R14: conflict is all-or-nothing (main untouched, concurrent dirty preserved), pre-existing partial state resumes" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # C1(무관 파일)·A(file.txt v1→v2)는 owned, B(file.txt v2→v3)는 owned 아님 —
  # A revert가 B의 내용과 충돌해 실패한다.
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

  # 충돌 revert(A) 직전에 메인에 동시 tracked 변경을 주입하는 wrapper — 7차
  # P1-7: revert는 격리 worktree에서 수행되므로 메인의 동시 변경을 파괴할 수단
  # 자체가 없다 (5차의 reset --hard도, 6차의 --abort 오인도 성립 불가).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin2"
  cat > "$repo/gbin2/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in
  *" revert "*)
    case " \$* " in *" $A"*) echo "concurrent-dirty" >> "$repo/stable.txt" ;; esac
    ;;
esac
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin2/git"

  run bash -c 'cd "$1" && PATH="$1/gbin2:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"revert 실패"* ]]
  [[ "$output" == *"all-or-nothing"* ]]
  # 메인은 완전 무변경 — sequencer 상태도, 부분 revert 커밋도 없다
  [ ! -e "$repo/.git/REVERT_HEAD" ]
  [ "$(git -C "$repo" log --format=%s | grep -c 'Revert "T200: c1"')" = "0" ]
  # 동시 tracked 변경은 파괴되지 않았다
  grep -q "concurrent-dirty" "$repo/stable.txt"
  grep -q "v3" "$repo/file.txt"
  # 격리 worktree 잔여물 없음
  [ "$(git -C "$repo" worktree list | wc -l | tr -d ' ')" = "1" ]

  # 구 버전/수동 부분 실행이 남긴 "post 이후 소유 역커밋"은 재개 경로로 인정:
  # C1의 실제 역커밋을 만들어 두면, 재실행은 C1을 건너뛰고 A에서 같은 이유로 실패
  git -C "$repo" checkout -- stable.txt
  git -C "$repo" revert --no-edit "$C1" >/dev/null 2>&1
  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"정합하지 않습니다"* ]]
  [[ "$output" == *"이미 되돌려짐"* ]]
  # C1 역커밋은 한 번만 존재한다 (중복 revert 없음)
  [ "$(git -C "$repo" log --format=%s | grep -c 'Revert "T200: c1"')" = "1" ]
}

@test "R15: forged 'This reverts commit' body without matching patch -> refused, not treated as already-reverted" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 6차 P1-6: post 이후에 소유 OID를 본문에 "적기만 한" 커밋 — 실제 역패치가
  # 아니다. 문자열 매칭만 믿으면 이를 "이미 되돌려짐"으로 오인해 소유 커밋을
  # 건너뛰고 성공(태그 삭제)까지 보고한다. patch-id 검증은 이를 외부 커밋으로
  # 판정해 거부해야 한다.
  local owned
  owned="$(git -C "$repo" rev-parse HEAD)"
  echo "not-a-revert" > "$repo/fake.txt"
  git -C "$repo" add fake.txt
  git -C "$repo" commit -q -m "chore: misc

This reverts commit ${owned}."

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"소유 역커밋이 아닌"* ]]
  # 아무것도 되돌려지지 않았고(오인 스킵 없음) 위조 커밋 산출물도 보존
  grep -q "v2" "$repo/file.txt"
  [ -f "$repo/fake.txt" ]
  # 종점 기록은 삭제되지 않았다 (성공 오보 없음)
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R16: concurrent staged changes during revert conflict - same path AND foreign path both fully preserved (isolated index)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # R12와 같은 충돌 구성: annotation 역순 → 첫 revert(A: v1→v2)가 최신 v3와 충돌.
  local A B
  A="$(git -C "$repo" rev-parse HEAD)"
  echo "v3" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "T200: second change"
  B="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" tag -f -a "cycle/T200-post" -m "owned-commits
$A
$B"

  # 격리 worktree의 revert가 충돌로 실패하는 순간, 메인 index에 (a) 실패 커밋과
  # "같은 경로"(file.txt)의 새 내용과 (b) 무관 경로를 stage하는 wrapper —
  # 7차 P1-7: 6차의 경로 비교는 (a)를 revert 잔상으로 오인해 --abort로 파괴했다.
  # 격리 index 설계에서는 메인 index를 만질 수단이 없어 둘 다 보존된다.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin3"
  cat > "$repo/gbin3/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" revert "*) is_revert=1 ;; *) is_revert=0 ;; esac
case " \$* " in *" --abort "*) is_revert=0 ;; esac
if [ "\$is_revert" = "1" ]; then
  "$realgit" "\$@"
  rc=\$?
  if [ "\$rc" -ne 0 ] && [ ! -f "$repo/.r16" ]; then
    touch "$repo/.r16"
    echo "same-path staged content" > "$repo/file.txt"
    echo "foreign staged content" > "$repo/foreign-staged.txt"
    "$realgit" add file.txt foreign-staged.txt
  fi
  exit \$rc
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin3/git"

  run bash -c 'cd "$1" && PATH="$1/gbin3:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"revert 실패"* ]]
  # 메인 index·worktree는 손대지 않았다 — 같은 경로 staged 내용까지 그대로다
  [ ! -e "$repo/.git/REVERT_HEAD" ]
  run git -C "$repo" diff --cached --name-only
  [[ "$output" == *"file.txt"* ]]
  [[ "$output" == *"foreign-staged.txt"* ]]
  grep -q "same-path staged content" "$repo/file.txt"
  grep -q "foreign staged content" "$repo/foreign-staged.txt"
  # staged blob 내용도 보존됐다 (index에서 직접 확인)
  [ "$(git -C "$repo" show :file.txt)" = "same-path staged content" ]
  # 격리 worktree 잔여물 없음
  [ "$(git -C "$repo" worktree list | wc -l | tr -d ' ')" = "1" ]
}

@test "R17: post tag moved to another cycle during revert -> publish refused from the pinned tag object (no stale rollback)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 7차 P1-6: annotation과 peeled target은 해석 시점에 고정한 tag object에서만
  # 파생하고, 공개 직전 태그가 그 object 그대로인지 재검증한다 — 태그가 새
  # cycle로 이동했으면 낡은 결과를 공개하지 않는다 (과거: 이전 annotation의
  # 커밋을 revert하고 rc=0 + CAS 실패 경고만 출력).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin4"
  cat > "$repo/gbin4/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" revert "*) is_revert=1 ;; *) is_revert=0 ;; esac
case " \$* " in *" --abort "*) is_revert=0 ;; esac
if [ "\$is_revert" = "1" ] && [ ! -f "$repo/.r17" ]; then
  touch "$repo/.r17"
  "$realgit" tag -f -a "cycle/T200-post" -m "owned-commits
moved-to-new-cycle" HEAD >/dev/null 2>&1
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin4/git"

  run bash -c 'cd "$1" && PATH="$1/gbin4:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"태그가 그 사이 변경"* ]]
  # 아무것도 공개되지 않았고, 이동된 태그는 그대로 남아 있다
  grep -q "v2" "$repo/file.txt"
  git -C "$repo" tag -l --format='%(contents)' cycle/T200-post | grep -q "moved-to-new-cycle"
  # 계산 결과는 refs/rollback에 보존
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R18: branch reset backwards between re-verification and publish -> CAS refuses (ff-only would resurrect removed commits)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8차: merge --ff-only는 "검증 시점 OID"와 비교하지 않는다 — 재검증과 merge
  # 사이에 branch가 과거(pre)로 reset되면 _NEW는 여전히 그 과거의 자손이라
  # ff가 성공해, 동시 reset이 제거한 커밋을 되살리며 rc=0을 반환했다.
  # update-ref old-value CAS는 이를 원자적으로 거부한다.
  # 공개 직전 두 번째 status 호출 시점에 backward reset을 주입하는 wrapper
  # (첫 status는 시작 가드 — 그 이후 검증·revert가 끝난 뒤의 창을 노린다).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin5"
  cat > "$repo/gbin5/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = "status" ]; then
  c=0; [ -f "$repo/.r18.count" ] && c=\$(cat "$repo/.r18.count")
  c=\$((c+1)); echo "\$c" > "$repo/.r18.count"
  if [ "\$c" = "2" ]; then
    "$realgit" reset -q --hard cycle/T200-pre
  fi
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin5/git"

  run bash -c 'cd "$1" && PATH="$1/gbin5:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"CAS 실패"* ]]
  # 동시 reset의 결과가 보존됐다 — 제거된 커밋이 되살아나지 않았다
  [ "$(git -C "$repo" rev-parse HEAD)" = "$(git -C "$repo" rev-parse cycle/T200-pre)" ]
  grep -q "v1" "$repo/file.txt"
  run git -C "$repo" log --format=%s
  [[ "$output" != *"Revert"* ]]
  # 계산 결과는 refs/rollback에 보존
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R19: switching to another branch at the same OID -> publish targets the pinned branch ref, refused on switch" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8차 2회 P1(#4): 공개가 symbolic HEAD를 갱신해, 검증 후 "같은 OID의 다른
  # branch"로 전환하면 그 branch가 rollback되고 원래 branch는 그대로인데 rc=0 +
  # 태그 삭제까지 일어났다 (실측). 이제 검증 시점의 구체 branch ref를 고정하고,
  # 공개 직전 그 branch 위에 있는지 재검증한다.
  git -C "$repo" branch other       # master와 같은 OID
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin6"
  cat > "$repo/gbin6/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" revert "*) is_revert=1 ;; *) is_revert=0 ;; esac
case " \$* " in *" --abort "*) is_revert=0 ;; esac
if [ "\$is_revert" = "1" ] && [ ! -f "$repo/.r19" ]; then
  touch "$repo/.r19"
  "$realgit" symbolic-ref HEAD refs/heads/other   # 같은 OID의 다른 branch로 전환
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin6/git"

  run bash -c 'cd "$1" && PATH="$1/gbin6:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"branch가 바뀌었습니다"* ]]
  # 어느 branch도 rollback되지 않았고, 태그도 살아 있다
  [ "$(git -C "$repo" rev-parse refs/heads/master)" = "$(git -C "$repo" rev-parse refs/heads/other)" ]
  run git -C "$repo" log --format=%s refs/heads/other
  [[ "$output" != *"Revert"* ]]
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R20: repository hooks cannot inject commits into the rollback (hooks disabled in the isolated worktree)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8차 2회 P1(#7): 격리 worktree의 revert도 저장소 hook을 실행해, post-commit
  # hook이 만든 외부 커밋이 rollback 결과에 포함된 채 rc=0으로 공개됐다 (실측).
  mkdir -p "$repo/.git/hooks"
  cat > "$repo/.git/hooks/post-commit" <<'HOOK'
#!/usr/bin/env bash
[ -f "$GIT_DIR/.hookran" ] && exit 0
touch "$GIT_DIR/.hookran"
echo "injected by hook" > hook-artifact.txt
git add hook-artifact.txt
git -c user.email=h@h -c user.name=H commit -q -m "hook: injected commit" --no-verify
HOOK
  chmod +x "$repo/.git/hooks/post-commit"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  # 소유 커밋만 되돌아갔고, hook 커밋·산출물은 rollback 결과에 없다
  grep -q "v1" "$repo/file.txt"
  [ ! -f "$repo/hook-artifact.txt" ]
  run git -C "$repo" log --format=%s
  [[ "$output" != *"hook: injected commit"* ]]
  # 공개된 커밋은 우리 revert 하나뿐이다
  [ "$(git -C "$repo" rev-list --count 'cycle/T200-pre..HEAD')" = "2" ]
  [ "$(git -C "$repo" log --format=%s | grep -c 'Revert')" = "1" ]
}

@test "R21: branch switch at the ref-transaction call -> worktree is never touched, published state honestly reported" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8라운드 후속 P1(#1) → 재리뷰 P1(#5): symref 검증을 ref transaction "안"에 넣는
  # 설계는 Git에서 성립하지 않는다 (probe는 no-deref 없이 2.48에서 실패하고, HEAD
  # symref 검증과 그 referent branch 갱신을 같은 transaction에 넣으면 "multiple
  # updates for HEAD"로 거부된다). transaction은 ref 원자성만 담당하고, checkout
  # 결속은 공개 직전/직후의 별도 검증 계층이 담당한다 — 결속이 깨지면 worktree를
  # 아예 건드리지 않고 공개 상태를 정직하게 보고한다.
  git -C "$repo" branch other       # master와 같은 OID
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin7"
  cat > "$repo/gbin7/git" <<WRAP
#!/usr/bin/env bash
if [ "\$1" = "update-ref" ] && [ "\$2" = "--stdin" ]; then
  c=0; [ -f "$repo/.r21" ] && c=\$(cat "$repo/.r21"); c=\$((c+1)); echo \$c > "$repo/.r21"
  if [ "\$c" = "1" ]; then "$realgit" -C "$repo" symbolic-ref HEAD refs/heads/other; fi
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin7/git"

  run bash -c 'cd "$1" && PATH="$1/gbin7:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  # 현재 checkout(other)의 worktree·index는 절대 바뀌지 않는다
  grep -q "v2" "$repo/file.txt"
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]
  run git -C "$repo" log --format=%s refs/heads/other
  [[ "$output" != *"Revert"* ]]
  # 공개 여부와 무관하게 복구 근거가 남는다
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R25: a whitespace-forged revert (same patch-id, different blob) is refused - tree identity, not patch-id" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 재리뷰 P1(#6): git patch-id --stable은 whitespace를 무시한다 — 정상 'v1' revert
  # 대신 'v 1'을 만드는 같은-parent 커밋이 검증을 통과해 rc=0으로 공개됐다 (실측).
  # 검증 축을 결과 tree의 경로별 (mode, blob OID) 정확 대조로 바꿨다.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin11"
  cat > "$repo/gbin11/git" <<'WRAP'
#!/usr/bin/env bash
REAL=__REALGIT__
wt=""; prev=""
for a in "$@"; do [ "$prev" = "-C" ] && wt="$a"; prev="$a"; done
case " $* " in *" revert "*) is_r=1;; *) is_r=0;; esac
case " $* " in *" --abort "*) is_r=0;; esac
if [ "$is_r" = 1 ] && [ -n "$wt" ]; then
  "$REAL" "$@"; rc=$?
  if [ $rc -eq 0 ] && [ ! -f "$wt/.r25" ]; then
    touch "$wt/.r25"
    "$REAL" -C "$wt" reset -q --hard HEAD^
    printf 'v 1\n' > "$wt/file.txt"        # whitespace만 다르다 — patch-id는 동일
    "$REAL" -C "$wt" add file.txt
    "$REAL" -C "$wt" -c user.email=e@e -c user.name=E \
      commit -qm 'Revert "T200: cycle change"' >/dev/null 2>&1
  fi
  exit $rc
fi
exec "$REAL" "$@"
WRAP
  sed -i '' "s|__REALGIT__|$realgit|" "$repo/gbin11/git" 2>/dev/null \
    || sed -i "s|__REALGIT__|$realgit|" "$repo/gbin11/git"
  chmod +x "$repo/gbin11/git"

  run bash -c 'cd "$1" && PATH="$1/gbin11:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"검증에 실패"* ]]
  # 위조본은 공개되지 않았다 — 원본 그대로, 태그 생존
  grep -q "^v2$" "$repo/file.txt"
  run git -C "$repo" log --format=%s
  [[ "$output" != *"Revert"* ]]
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R26: branch switch DURING read-tree -> the other branch's worktree is restored, not left modified" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 재리뷰 P1(#7): 공개 직후 결속 검사를 통과한 "뒤" checkout이 바뀌면, read-tree가
  # 다른 branch의 worktree/index를 먼저 바꾼 뒤에야 실패했다 (실측). Git은 "HEAD 결속
  # + worktree 갱신"의 원자 연산을 주지 않으므로, 동기화 직후 결속이 깨진 것을 탐지하면
  # 우리가 적용한 two-tree merge를 역방향으로 되돌려 그 worktree를 원상복구한다.
  git -C "$repo" branch other       # master와 같은 OID
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin12"
  cat > "$repo/gbin12/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" read-tree "*)
  if [ ! -f "$repo/.r26" ]; then
    touch "$repo/.r26"
    "$realgit" -C "$repo" symbolic-ref HEAD refs/heads/other
  fi
;; esac
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin12/git"

  run bash -c 'cd "$1" && PATH="$1/gbin12:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"checkout branch가 바뀌었습니다"* ]]
  # other의 worktree는 원상복구됐다 — rollback 내용이 남지 않는다
  grep -q "^v2$" "$repo/file.txt"
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]
  # other ref 자체도 무변경 (공개는 고정 branch인 master에만 적용됐다)
  [ "$(git -C "$repo" rev-parse refs/heads/other)" != "$(git -C "$repo" rev-parse refs/heads/master)" ]
  run git -C "$repo" log --format=%s refs/heads/other
  [[ "$output" != *"Revert"* ]]
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R22: TERM while a signal-ignoring read-tree child runs -> KILL escalation, published state reported from real refs (rc=130)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8라운드 후속 P1(#2·#5): (a) 공개 직후의 신호가 shell boolean 미대입 창에서
  # "메인 무변경"으로 오판됐다 — 판정은 실제 ref 상태로 한다. (b) read-tree
  # child가 TERM을 무시하면 프로세스가 계속 살았다 — 별도 프로세스 그룹 +
  # bounded 대기 + KILL + reap.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin8"
  cat > "$repo/gbin8/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" read-tree "*)
  trap '' TERM
  kill -TERM \$PPID 2>/dev/null
  sleep 30
  exit 0
;; esac
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin8/git"

  local t0 t1
  t0="$(date +%s)"
  run bash -c 'cd "$1" && PATH="$1/gbin8:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  t1="$(date +%s)"
  [ "$status" -eq 130 ]
  # TERM 무시 child에 붙잡히지 않았다 (bounded reap — 30초 sleep보다 훨씬 이름)
  [ $(( t1 - t0 )) -lt 20 ]
  # 공개 여부는 실제 ref 상태로 정직 보고: branch는 rollback 결과, 태그 삭제
  [[ "$output" == *"공개는 완료"* ]]
  [[ "$output" == *"refs/rollback/T200"* ]]
  run git -C "$repo" log --format=%s -1 refs/heads/master
  [[ "$output" == *"Revert"* ]]
  ! git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R23: revert commit replaced by a same-count arbitrary commit -> per-commit parent/tree-identity verification refuses" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8라운드 후속 P1(#3): 개수만 세는 검증은 정상 revert를 같은 개수의 임의
  # 커밋으로 교체해도 통과시켰다 (실측: 임의 파일·foreign commit 공개). 이제
  # 생성 직후 커밋별로 (1) parent 체인 (2) 결과 tree의 경로별 (mode, blob) identity를
  # 검증한다 (재리뷰 #6: patch-id는 whitespace를 무시해 위조를 통과시켰다).
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin9"
  cat > "$repo/gbin9/git" <<'WRAP'
#!/usr/bin/env bash
REAL=__REALGIT__
wt=""; prev=""
for a in "$@"; do [ "$prev" = "-C" ] && wt="$a"; prev="$a"; done
case " $* " in *" revert "*) is_r=1;; *) is_r=0;; esac
case " $* " in *" --abort "*) is_r=0;; esac
if [ "$is_r" = 1 ] && [ -n "$wt" ]; then
  "$REAL" "$@"; rc=$?
  if [ $rc -eq 0 ] && [ ! -f "$wt/.r23" ]; then
    touch "$wt/.r23"
    "$REAL" -C "$wt" reset -q --hard HEAD^
    echo evil > "$wt/evil.txt"
    "$REAL" -C "$wt" add evil.txt
    "$REAL" -C "$wt" -c user.email=e@e -c user.name=E commit -qm "evil: same-count replacement" >/dev/null 2>&1
  fi
  exit $rc
fi
exec "$REAL" "$@"
WRAP
  sed -i '' "s|__REALGIT__|$realgit|" "$repo/gbin9/git" 2>/dev/null \
    || sed -i "s|__REALGIT__|$realgit|" "$repo/gbin9/git"
  chmod +x "$repo/gbin9/git"

  run bash -c 'cd "$1" && PATH="$1/gbin9:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"tree identity 불일치"* || "$output" == *"검증에 실패"* ]]
  # 아무것도 공개되지 않았다 — 임의 커밋·파일 없음, 태그 생존
  grep -q "v2" "$repo/file.txt"
  [ ! -f "$repo/evil.txt" ]
  run git -C "$repo" log --format=%s
  [[ "$output" != *"evil"* ]]
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R24: foreign commit lands after publish, before worktree sync -> final verification withholds success (recovery ref kept)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 8라운드 후속 P1(#4): 공개(ref transaction) 후 branch에 foreign commit이
  # 끼어들어도 read-tree 뒤 rc=0이었다 — HEAD에 foreign 포함 + tracked dirty를
  # 성공으로 보고. 이제 종료 직전 "대상 ref == 공개 결과, checkout 정합,
  # tracked clean"을 전부 확인하고, 실패 시 성공 문구를 내지 않는다.
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin10"
  cat > "$repo/gbin10/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" read-tree "*)
  if [ ! -f "$repo/.r24" ]; then
    touch "$repo/.r24"
    "$realgit" -C "$repo" -c user.email=f@f -c user.name=F commit -q --allow-empty -m "foreign: post-publish"
  fi
;; esac
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin10/git"

  run bash -c 'cd "$1" && PATH="$1/gbin10:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"예상 밖 커밋"* ]]
  # 복구 참조는 삭제되지 않았다 — 상태 확인·수동 정리를 위한 근거
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
  # foreign commit은 보존된다 (파괴 없음)
  run git -C "$repo" log --format=%s -1
  [[ "$output" == *"foreign: post-publish"* ]]
}

@test "R27: branch switch to a DIFFERENT-OID branch during read-tree -> that branch's own tree is restored" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 재재리뷰 P1(#7): 역방향 read-tree(_NEW→HEAD_OID)는 "원 branch의 tree"를 적용할
  # 뿐이라, 다른 OID의 branch로 전환된 경우 tracked dirty가 남는데도 '원상복구
  # 완료'로 보고했다 (실측). 복구 목표는 "지금 checkout된 commit의 tree"다.
  local base_br other_oid
  base_br="$(git -C "$repo" symbolic-ref --short HEAD)"
  git -C "$repo" checkout -q -b other cycle/T200-pre
  echo "OTHER" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m "other: divergent"
  other_oid="$(git -C "$repo" rev-parse HEAD)"
  git -C "$repo" checkout -q "$base_br"
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin14"
  cat > "$repo/gbin14/git" <<WRAP
#!/usr/bin/env bash
case " \$* " in *" read-tree "*)
  if [ ! -f "$repo/.r27" ]; then
    touch "$repo/.r27"
    "$realgit" -C "$repo" symbolic-ref HEAD refs/heads/other
  fi
;; esac
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin14/git"

  run bash -c 'cd "$1" && PATH="$1/gbin14:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"checkout branch가 바뀌었습니다"* ]]
  # other의 worktree는 "other의 tree"로 복원됐다 — 원 branch(v2)의 tree가 아니다
  grep -q "^OTHER$" "$repo/file.txt"
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]
  # other ref 무변경, 공개는 고정 branch에만 적용
  [ "$(git -C "$repo" rev-parse refs/heads/other)" = "$other_oid" ]
  run git -C "$repo" log --format=%s "refs/heads/$base_br"
  [[ "$output" == *"Revert"* ]]
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
}

@test "R28: forged 'already reverted' commit touching a newline-named file -> refused (NUL-based path verification)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 재재리뷰 P1(#4): newline 기반 diff-tree|sort는 개행 포함 파일명을 C-quote
  # 문자열/조각으로 갈라 ls-tree가 양쪽 모두 빈 결과를 반환 — 위조 커밋이 "이미
  # 되돌려짐"으로 인정되어 rc=0 + post 태그 삭제까지 재현됐다 (실측).
  local nlf own
  nlf="$(printf 'bad\nname.txt')"
  _add_owned_commit "$repo" "T200: newline file" "$nlf" "v1"
  own="$(git -C "$repo" rev-parse HEAD)"
  printf 'EVIL\n' > "$repo/$nlf"
  git -C "$repo" add -A
  git -C "$repo" -c user.email=f@f -c user.name=F commit -q -m "forge

This reverts commit ${own}."

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"소유 역커밋이 아닌 커밋"* ]]
  # 아무것도 공개되지 않았다 — 태그 생존, 위조 내용 그대로(파괴 없음)
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
  grep -q "^EVIL$" "$repo/$nlf"
}

@test "R29: legitimate rollback of an owned commit with a newline-named file succeeds (no false rejection)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  local nlf
  nlf="$(printf 'bad\nname.txt')"
  _add_owned_commit "$repo" "T200: newline file" "$nlf" "v1"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled back T200 by revert"* ]]
  [ ! -e "$repo/$nlf" ]
  grep -q "^v1$" "$repo/file.txt"
  [ -z "$(git -C "$repo" status --porcelain --untracked-files=no)" ]
  ! git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R30: git status failing with empty output (rc!=0) is not treated as clean -> refused, nothing published" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 재재리뷰 P1(#5): 초기·공개 전·최종 검사가 출력만 비교하고 rc를 버려, 빈
  # 출력+rc=42에서 rollback이 성공 공개되고 태그도 삭제됐다 (실측).
  local realgit tip
  realgit="$(command -v git)"
  tip="$(git -C "$repo" rev-parse HEAD)"
  mkdir -p "$repo/gbin15"
  cat > "$repo/gbin15/git" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "status" ] && exit 42; done
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin15/git"

  run bash -c 'cd "$1" && PATH="$1/gbin15:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"git status 실패"* ]]
  [ "$(git -C "$repo" rev-parse HEAD)" = "$tip" ]
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R31: pre-existing recovery ref is never clobbered nor deleted - evidence preserved regardless of ancestry" {
  # 재재리뷰 P1(#8) → 3라운드 P1(#4): refs/rollback/<ID>를 무조건 덮거나 삭제해
  # 선행 복구 증거가 사라졌고, 같은 ID의 "동시 실행"에서는 ancestor 판정 삭제도
  # 다른 실행의 증거를 지울 수 있다 — 이 실행이 만들지 않은 ref는 어떤 경로에서도
  # 삭제하지 않는다 (보존 + 고지만).
  # (a) 공개 결과에 포함되지 않는 foreign 증거 → 보존 + 고지
  local repo="$TEST_BASE/keep"
  _make_repo "$repo"
  local foreign
  foreign="$(git -C "$repo" commit-tree "$(git -C "$repo" rev-parse 'HEAD^{tree}')" -m foreign </dev/null)"
  git -C "$repo" update-ref refs/rollback/T200 "$foreign"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled back T200 by revert"* ]]
  [[ "$output" == *"보존합니다"* ]]
  [ "$(git -C "$repo" rev-parse refs/rollback/T200)" = "$foreign" ]

  # (b) 공개 결과의 ancestor인 증거도 삭제하지 않는다 — 동시 실행의 복구 증거일 수 있다
  local repo2="$TEST_BASE/contained" pre2
  _make_repo "$repo2"
  pre2="$(git -C "$repo2" rev-parse 'cycle/T200-pre^{commit}')"
  git -C "$repo2" update-ref refs/rollback/T200 "$pre2"

  run bash -c 'cd "$1" && ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo2"
  [ "$status" -eq 0 ]
  [[ "$output" == *"rolled back T200 by revert"* ]]
  [ "$(git -C "$repo2" rev-parse refs/rollback/T200)" = "$pre2" ]
}

@test "R32: ls-tree failing (rc!=0) during revert-identity verification is not treated as 'absent' -> forged revert refused" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 3라운드 P1(#2): ls-tree 실패를 빈 결과로 삼키면 양쪽 모두 '부재'로 비교되어
  # 위조 역커밋이 인정됐다 (실측: rc=42 셔임에서 rc=0 + 위조 내용 보존 + post
  # 태그 삭제). 실패는 부재가 아니라 검증 실패다.
  local own
  own="$(git -C "$repo" rev-parse HEAD)"
  echo "EVIL" > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" -c user.email=f@f -c user.name=F commit -q -m "forge

This reverts commit ${own}."
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin16"
  cat > "$repo/gbin16/git" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "ls-tree" ] && exit 42; done
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin16/git"

  run bash -c 'cd "$1" && PATH="$1/gbin16:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  grep -q "^EVIL$" "$repo/file.txt"
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R33: rev-list failing (rc!=0) is not treated as 'no commits after pre' -> refused, no reset path (fail-closed)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 3라운드 P1(#2): rev-list 실패를 빈 결과로 해석하면 reset 경로로 fail-open —
  # 조회 실패는 판정 불가로 즉시 중단한다.
  local tip realgit
  tip="$(git -C "$repo" rev-parse HEAD)"
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin17"
  cat > "$repo/gbin17/git" <<WRAP
#!/usr/bin/env bash
for a in "\$@"; do [ "\$a" = "rev-list" ] && exit 42; done
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin17/git"

  run bash -c 'cd "$1" && PATH="$1/gbin17:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" == *"rev-list) 실패"* ]]
  [ "$(git -C "$repo" rev-parse HEAD)" = "$tip" ]
  grep -q "^v2$" "$repo/file.txt"
  git -C "$repo" rev-parse -q --verify "refs/tags/cycle/T200-post" >/dev/null
}

@test "R34: commit injected concurrently with the LAST status observation -> success withheld (tip re-checked after status)" {
  local repo="$TEST_BASE/main"
  _make_repo "$repo"
  # 4라운드 P1(#5): 최종 검증이 ref/HEAD를 먼저 읽고 status를 마지막에 관측했다 —
  # status가 clean을 반환하면서 "동시에" 커밋이 주입되면 어떤 검사에도 걸리지
  # 않고 rc=0 + 성공 문구가 나왔다 (실측: 실제 tip은 foreign). 이제 status 이후
  # tip을 재관측한다. (writer lock은 프로토콜 writer만 배제한다 — raw git 개입은
  # 이 재관측이 성공 보고를 막는 fail-closed가 최선이다.)
  local realgit
  realgit="$(command -v git)"
  mkdir -p "$repo/gbin18"
  cat > "$repo/gbin18/git" <<WRAP
#!/usr/bin/env bash
is_status=0
for a in "\$@"; do [ "\$a" = "status" ] && is_status=1; done
if [ "\$is_status" = 1 ] && ! "$realgit" rev-parse -q --verify refs/tags/cycle/T200-post >/dev/null 2>&1 && [ ! -f "$repo/.r34" ]; then
  # post 태그 삭제 후의 첫 status = 최종 검증의 status — clean 결과를 돌려주면서
  # 동시에 foreign commit을 주입한다
  touch "$repo/.r34"
  st="\$("$realgit" "\$@")"
  "$realgit" -c user.email=f@f -c user.name=F commit -q --allow-empty -m "foreign: with status" 2>/dev/null
  printf '%s' "\$st"
  exit 0
fi
exec "$realgit" "\$@"
WRAP
  chmod +x "$repo/gbin18/git"

  run bash -c 'cd "$1" && PATH="$1/gbin18:$PATH" ./scripts/rollback.sh T200 --yes < /dev/null' _ "$repo"
  [ "$status" -eq 3 ]
  [[ "$output" != *"rolled back"* ]]
  [[ "$output" == *"예상 밖 커밋"* ]]
  # 복구 참조가 남는다
  git -C "$repo" rev-parse -q --verify "refs/rollback/T200" >/dev/null
  run git -C "$repo" log --format=%s -1
  [[ "$output" == *"foreign: with status"* ]]
}
