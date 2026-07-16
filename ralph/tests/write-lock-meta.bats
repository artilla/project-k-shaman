#!/usr/bin/env bats
# ralph/tests/write-lock-meta.bats — 9~10라운드: meta-lock incarnation-고유 이름 계약 회귀.
# write_lock.sh를 직접 source해 리뷰가 재현한 interleaving을 그대로 재생한다.

REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"

setup() {
  TEST_HOME="$(mktemp -d)"
}

teardown() {
  rm -rf "$TEST_HOME"
}

@test "WL1: reclaimer paused before teardown cannot damage a successor meta (mid-bound names, no glob re-expansion)" {
  # 10라운드 P1(#2): R1 정지 → R2 해체 → R3 획득 → R1 재개. 파괴 대상 이름이
  # 관찰한 pid의 mid에서 유도되므로 successor의 token/pid는 무접촉이어야 한다.
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    ( : ) & dead=$!; wait "$dead" || true
    M="$_TW_LOCK.rec.d"
    mkdir "$M"; echo "$dead" > "$M/pid.$dead.0.21"; printf m > "$M/token.$dead.0.21"
    R1_PF="$M/pid.$dead.0.21"; R1_DMID="${R1_PF##*/pid.}"
    ln "$R1_PF" "$M.obs.r1.p"
    _twl_meta_acquire "$_TW_LOCK" >/dev/null 2>&1 || true   # R2: 완전 해체
    _twl_meta_acquire "$_TW_LOCK" || exit 90                # R3: 새 live meta
    # R1 재개 — 해체의 파괴 구간(관찰 mid에서 유도한 고정 이름 + rmdir)
    rm -f "$M/token.$R1_DMID" 2>/dev/null
    rm -f "$M/pid.$R1_DMID" 2>/dev/null
    rmdir "$M" 2>/dev/null
    ls "$M"/token.* >/dev/null 2>&1 || exit 91
    ls "$M"/pid.* >/dev/null 2>&1 || exit 92
    _twl_meta_release "$_TW_LOCK"
    [ ! -e "$M" ] || exit 93
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL2: empty-meta cleanup path never deletes a successor token (no token.* re-glob after observation)" {
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    M="$_TW_LOCK.rec.d"
    # R1: 빈 meta 관찰(글롭 시점) → 정지 → R2 rmdir → R3 획득 → R1 재개
    mkdir "$M"; rmdir "$M"
    _twl_meta_acquire "$_TW_LOCK" || exit 90   # R3
    # R1 재개 — empty-branch의 파괴 구간은 구버전 고정 이름 rm + rmdir뿐
    rm -f "$M/token" 2>/dev/null
    rmdir "$M" 2>/dev/null
    ls "$M"/token.* >/dev/null 2>&1 || exit 91
    _twl_meta_release "$_TW_LOCK"
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL3: a token-only canonical lock (failed-release residue) is reclaimed under meta serialization" {
  # 10라운드 P1(#3): token rm 실패 + pid rm 성공이 남긴 token-only lock —
  # 이후 writer가 영구 고착되지 않고 meta 아래에서 회수한다.
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    mkdir "$_TW_LOCK"; printf tkn > "$_TW_LOCK/token"
    _acquire_write_lock || exit 90
    [ "$(cat "$_TW_LOCK/pid" 2>/dev/null)" = "$$" ] || exit 91
    _release_write_lock
    [ ! -e "$_TW_LOCK" ] || exit 92
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL4: a pid-less lock with foreign content is NOT reclaimed (no-touch contract preserved)" {
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    mkdir "$_TW_LOCK"; printf x > "$_TW_LOCK/token"; printf y > "$_TW_LOCK/foreign"
    _twl_reclaim_dead "$_TW_LOCK" && exit 90   # 회수되면 안 된다
    [ -f "$_TW_LOCK/token" ] || exit 91
    [ -f "$_TW_LOCK/foreign" ] || exit 92
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL5: a token.<mid>-only meta (partial release: token rm failed, pid rm succeeded) is reclaimed once its creator is dead" {
  # 11라운드 P1(#1): 부분 해제가 남긴 token.<mid> 잔재 — mid의 creator pid가 죽어
  # 있으면 다음 획득/GC가 회수한다 (영구 고착 없음).
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    ( : ) & dead=$!; wait "$dead" || true
    M="$_TW_LOCK.rec.d"
    mkdir "$M"; printf m > "$M/token.$dead.0.31"   # pid.<mid>는 이미 삭제된 상태
    _twl_gc_artifacts
    [ ! -e "$M" ] || exit 91
    # 회수 후 meta 획득이 정상 동작한다
    _twl_meta_acquire "$_TW_LOCK" || exit 92
    _twl_meta_release "$_TW_LOCK"
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL6: a token.<mid> whose creator is ALIVE is never touched (live successor safe under snapshot cleanup)" {
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    sleep 30 & lp=$!
    M="$_TW_LOCK.rec.d"
    mkdir "$M"; printf m > "$M/token.$lp.0.41"
    _twl_gc_artifacts
    st=0
    [ -f "$M/token.$lp.0.41" ] || st=91
    kill "$lp" 2>/dev/null || true
    exit $st
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL7: release removes pid only after the token removal is VERIFIED - a live creator never leaves a token-only residue" {
  # 12라운드 P1(#1): 종전 해제는 token rm 실패를 무시하고 pid를 지워, "살아 있는"
  # creator의 token-only 잔재를 만들었다 — WL5의 회수는 creator가 죽어야만
  # 작동하므로 장기 실행 creator 동안 모든 writer가 고착됐다 (실측). 이제 pid는
  # token 삭제가 확인된 뒤에만 지운다: 실패 시 pid가 남아 소유가 정직하게
  # 표시되고(성공 경로들이 live-pid 경합으로 처리), creator 종료 후 정상 stale
  # 해체가 회수한다. meta 해제는 같은 실패를 rc=1로 전파한다.
  [ "$(id -u)" = "0" ] && skip "root는 파일 모드를 우회한다 — rm 실패 재현 불가"
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    # (a) 메인 lock: token rm 실패 → pid 유지 (token-only 잔재 금지)
    _acquire_write_lock || exit 90
    chmod 555 "$_TW_LOCK"
    _release_write_lock 2>/dev/null || true
    [ -f "$_TW_LOCK/token" ] || exit 91   # token이 남았는데
    [ -f "$_TW_LOCK/pid" ]   || exit 92   # pid도 반드시 남는다 (부분 해제 금지)
    [ "$(cat "$_TW_LOCK/pid")" = "$$" ] || exit 93
    chmod u+w "$_TW_LOCK"
    rm -f "$_TW_LOCK/token" "$_TW_LOCK/pid"; rmdir "$_TW_LOCK" 2>/dev/null || true
    # (b) meta-lock: token rm 실패 → rc=1 전파 + pid.<mid> 유지
    _twl_meta_acquire "$_TW_LOCK" || exit 94
    mid="$_TWL_META_MID"
    M="$_TW_LOCK.rec.d"
    chmod 555 "$M"
    if _twl_meta_release "$_TW_LOCK" 2>/dev/null; then chmod u+w "$M"; exit 95; fi
    [ -f "$M/token.$mid" ] || { chmod u+w "$M"; exit 96; }
    [ -f "$M/pid.$mid" ]   || { chmod u+w "$M"; exit 97; }
    chmod u+w "$M"
    rm -f "$M/token.$mid" "$M/pid.$mid"; rmdir "$M" 2>/dev/null || true
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}

@test "WL8: partial release failure keeps ownership evidence and rc=1 - a retry finishes the remaining stages (no rc=0 disguise, no pid-only wedge)" {
  # 13라운드 P1(#3): (a) token 삭제 성공 후 pid 삭제 실패가 rc=0으로 위장되어
  # 살아 있는 내 pid의 pid-only lock이 남았고(재획득 영구 대기), (b) token 삭제
  # 실패 시 .own을 지워 재시도 자체가 불가능했다 (실측). 이제 각 단계를 검증하고
  # 실패 시 소유 증거를 유지한 채 rc=1을 전파하며, 재호출이 남은 단계부터
  # 이어간다.
  [ "$(id -u)" = "0" ] && skip "root는 파일 모드를 우회한다 — rm 실패 재현 불가"
  run bash -c '
    set -u
    cd "$1" && mkdir state
    _TW_LOCK="state/ticket_write.lock.d"
    source "$2/ralph/scripts/lib/write_lock.sh"
    # (a) 메인 lock: token 제거 후 pid 삭제가 실패하는 상태(반대편 부분 실패)
    _acquire_write_lock || exit 90
    rm -f "$_TW_LOCK/token"          # 1단계 완료 상태를 재현
    chmod 555 "$_TW_LOCK"
    if _release_write_lock 2>/dev/null; then chmod u+w "$_TW_LOCK"; exit 91; fi  # rc=0 위장 금지
    [ -f "$_TW_LOCK/pid" ]           || { chmod u+w "$_TW_LOCK"; exit 92; }  # pid 유지(정직)
    [ -f "$_TW_LOCK.own.$$" ]        || { chmod u+w "$_TW_LOCK"; exit 93; }  # 소유 증거 유지
    chmod u+w "$_TW_LOCK"
    _release_write_lock || exit 94   # 재시도가 남은 단계를 완료한다
    [ ! -e "$_TW_LOCK" ]             || exit 95
    [ ! -e "$_TW_LOCK.own.$$" ]      || exit 96
    # (b) 메인 lock: token 삭제 실패 → own 유지 → 재시도로 전체 해체
    _acquire_write_lock || exit 80
    chmod 555 "$_TW_LOCK"
    if _release_write_lock 2>/dev/null; then chmod u+w "$_TW_LOCK"; exit 81; fi
    [ -f "$_TW_LOCK/token" ]         || { chmod u+w "$_TW_LOCK"; exit 82; }
    [ -f "$_TW_LOCK.own.$$" ]        || { chmod u+w "$_TW_LOCK"; exit 83; }
    chmod u+w "$_TW_LOCK"
    _release_write_lock || exit 84
    [ ! -e "$_TW_LOCK" ]             || exit 85
    # (c) meta-lock: 같은 계약 — 부분 실패 rc=1 + own·mid 유지, 재시도 완료
    _twl_meta_acquire "$_TW_LOCK" || exit 70
    mid="$_TWL_META_MID"
    M="$_TW_LOCK.rec.d"
    rm -f "$M/token.$mid"            # 1단계 완료 상태를 재현
    chmod 555 "$M"
    if _twl_meta_release "$_TW_LOCK" 2>/dev/null; then chmod u+w "$M"; exit 71; fi
    [ -f "$M/pid.$mid" ]             || { chmod u+w "$M"; exit 72; }
    [ -f "$M.own.$$" ]               || { chmod u+w "$M"; exit 73; }   # own 유지
    [ "$_TWL_META_MID" = "$mid" ]    || { chmod u+w "$M"; exit 74; }   # mid 유지
    chmod u+w "$M"
    _twl_meta_release "$_TW_LOCK" || exit 75
    [ ! -e "$M" ]                    || exit 76
    [ ! -e "$M.own.$$" ]             || exit 77
    exit 0
  ' _ "$TEST_HOME" "$REPO_ROOT"
  [ "$status" -eq 0 ]
}
