# scripts/lib/write_lock.sh — 시스템 writer 공용 write lock (source 전용)
#
# 6라운드 P1(#2): ticket_body/ticket_edit/ticket_lifecycle/approve의 inline lock이
# stale 회수를 mv(canonical 이동)로 수행해, 관찰~mv 창에 들어온 live lock을
# canonical 밖으로 밀어냈다 — auto_merge/rollback만 고쳐서는 전체 상호배제 계약이
# 닫히지 않는다. 모든 writer가 이 lib 하나를 source한다.
#
# 계약 (auto_merge/rollback의 lock과 동일):
#   - 획득: pid·token이 "이미 담긴" 사전 구성 디렉터리의 원자 rename. 소유 증거는
#     내용이 아니라 inode — rename 전에 token 파일의 하드링크(.own.$$)를 보관한다.
#   - 해제: canonical/token이 내 inode(-ef)일 때만 token→pid→rmdir 순서로 내용물을
#     제거한다. canonical은 rmdir 직전까지 점유 상태이므로 foreign lock이 canonical을
#     떠나는 순간이 없다 (rename 해제의 상호배제 공백 제거).
#   - stale 회수: 이동 없는 해체 — 관찰한 token/pid 파일의 inode를 하드링크(.obs.$$)
#     로 결속하고, dead 재검증 후 -ef 성립 시에만 각 파일을 제거하고 rmdir한다.
#     그 사이 교체된 live lock은 inode가 달라 무접촉이며 rmdir 실패로 canonical에
#     그대로 남는다 (5라운드 P1 #2와 동일).
#   - 재진입: _TW_HELD 카운터 (approve의 단일 임계구역 계약 유지, 리뷰 14차 P1).
#   - pid 없는 lock은 회수하지 않는다 (동시 실행 간주 — 3라운드 계약).
#
# 사용: _TW_LOCK을 먼저 정의(기본 state/ticket_write.lock.d)한 뒤 source.

_TW_LOCK="${_TW_LOCK:-state/ticket_write.lock.d}"
_TW_HELD=0
_TW_TOKEN=""

_twl_reclaim_dead() {  # $1=lock dir → 0=해체 완료, 1=회수 불가(live/교체/잔여물)
  local _lk="$1" _obs="$1.obs.$$" _p
  rm -f "$_obs.t" "$_obs.p" 2>/dev/null || true
  _p="$(cat "$_lk/pid" 2>/dev/null || true)"
  [ -n "$_p" ] || return 1
  kill -0 "$_p" 2>/dev/null && return 1
  if [ -f "$_lk/token" ]; then
    ln "$_lk/token" "$_obs.t" 2>/dev/null || return 1
  fi
  if ! ln "$_lk/pid" "$_obs.p" 2>/dev/null; then
    rm -f "$_obs.t" 2>/dev/null || true
    return 1
  fi
  # 결속된 inode의 내용으로 dead를 재검증 — 교체된 새 lock의 pid가 아니어야 한다
  if [ "$(cat "$_obs.p" 2>/dev/null || true)" != "$_p" ] || kill -0 "$_p" 2>/dev/null; then
    rm -f "$_obs.t" "$_obs.p" 2>/dev/null || true
    return 1
  fi
  if [ -f "$_obs.t" ] && [ "$_lk/token" -ef "$_obs.t" ]; then
    rm -f "$_lk/token" 2>/dev/null || true
  fi
  if [ "$_lk/pid" -ef "$_obs.p" ]; then
    rm -f "$_lk/pid" 2>/dev/null || true
  fi
  rm -f "$_obs.t" "$_obs.p" 2>/dev/null || true
  rmdir "$_lk" 2>/dev/null || return 1
  return 0
}

_acquire_write_lock() {
  local _i=0 _p _pre="$_TW_LOCK.acq.$$" _own="$_TW_LOCK.own.$$"
  # 재진입 (리뷰 14차 P1): 결정(critical section)이 lock을 쥔 채 _safe_write를
  # 부를 수 있어야 approve/reject 상호 직렬화가 단일 임계구역으로 성립한다.
  if [ "${_TW_HELD:-0}" -gt 0 ]; then _TW_HELD=$((_TW_HELD+1)); return 0; fi
  mkdir -p "$(dirname "$_TW_LOCK")" 2>/dev/null || true
  _twl_mkpre() {
    rm -rf "$_pre" 2>/dev/null || true
    rm -f "$_own" 2>/dev/null || true
    mkdir "$_pre" 2>/dev/null || return 1
    _TW_TOKEN="twl.$$.${RANDOM}${RANDOM}${RANDOM}"
    echo "$$" > "$_pre/pid" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
    printf '%s' "$_TW_TOKEN" > "$_pre/token" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
    ln "$_pre/token" "$_own" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
  }
  _twl_mkpre || return 1
  while :; do
    if [ ! -e "$_TW_LOCK" ] && mv "$_pre" "$_TW_LOCK" 2>/dev/null; then
      # rename 경합으로 기존 lock "안"에 중첩됐을 수 있다 — inode+pid+비중첩으로 확정.
      if [ "$_TW_LOCK/token" -ef "$_own" ] \
         && [ "$(cat "$_TW_LOCK/pid" 2>/dev/null || true)" = "$$" ] \
         && [ ! -d "$_TW_LOCK/${_pre##*/}" ]; then
        _TW_HELD=1
        return 0
      fi
      rm -rf "$_TW_LOCK/${_pre##*/}" 2>/dev/null || true
      _twl_mkpre || return 1
    fi
    _p="$(cat "$_TW_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
      _twl_reclaim_dead "$_TW_LOCK" && continue
    fi
    _i=$((_i+1))
    if [ "$_i" -ge 100 ]; then
      rm -rf "$_pre" 2>/dev/null || true
      rm -f "$_own" 2>/dev/null || true
      echo "❌ ticket write lock 획득 실패(경합 지속) — ${_TW_LOCK} 확인" >&2
      return 1
    fi
    sleep 0.1
  done
}

_release_write_lock() {
  if [ "${_TW_HELD:-0}" -gt 1 ]; then _TW_HELD=$((_TW_HELD-1)); return 0; fi
  local _own="$_TW_LOCK.own.$$"
  rm -rf "$_TW_LOCK.acq.$$" 2>/dev/null || true
  rm -f "$_TW_LOCK.obs.$$.t" "$_TW_LOCK.obs.$$.p" 2>/dev/null || true
  if [ -f "$_own" ] && [ "$_TW_LOCK/token" -ef "$_own" ]; then
    rm -f "$_TW_LOCK/token" "$_TW_LOCK/pid" 2>/dev/null || true
    rmdir "$_TW_LOCK" 2>/dev/null \
      || echo "⚠️  write lock 디렉터리 정리 실패(예상 밖 잔여물) — 확인 필요: ${_TW_LOCK}" >&2
  fi
  rm -f "$_own" 2>/dev/null || true
  _TW_HELD=0
  return 0
}
