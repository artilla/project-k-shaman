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

# 9라운드 P1(#1): meta-lock의 내용물 파일명은 "incarnation-고유"다 —
# pid.<mid>/token.<mid> (mid = pid.시각.난수). 경로 기반 rm은 항상 "-ef 확인과
# rm 사이" 창에서 successor의 파일을 지울 수 있었다 (실측: R1 정지 → R2 해체 →
# R3 획득 → R1 재개 시 R3 token 삭제). 고유 이름에서는 그 창이 구조적으로 없다:
#   - 죽은 incarnation의 파일명은 successor의 이름공간과 절대 겹치지 않는다 —
#     정지했다 재개한 reclaimer의 rm은 이미 사라진 이름에 대한 no-op이다.
#   - canonical 디렉터리 제거는 rmdir뿐이다 — live incarnation은 사전 구성
#     rename으로 항상 파일을 담은 채 도착하므로(빈 상태로 존재하는 순간이 없음)
#     rmdir이 successor를 제거하는 일도 구조적으로 없다.
#   - 부분 상태 회복: 파일이 하나도 없는 빈 meta(해체 도중 죽음)는 누구든
#     rmdir로 안전하게 치울 수 있고(비어 있을 때만 성공), token만 남은 meta는
#     발생하지 않는다(pid를 항상 마지막에 지운다).
_TWL_META_MID=""
_twl_meta_acquire() {  # $1=main lock dir → 0=meta 획득(소유 증거 .rec.d.own.$$), 1=실패(양보)
  local _meta="$1.rec.d" _mpre="$1.rec.d.pre.$$" _mown="$1.rec.d.own.$$" _mobs="$1.rec.d.obs.$$"
  local _mid _mp _pf _f _dmid _cp
  _mid="$$.$(date +%s 2>/dev/null || echo 0).${RANDOM}${RANDOM}"
  rm -rf "$_mpre" 2>/dev/null || true
  rm -f "$_mown" "$_mobs.p" 2>/dev/null || true
  mkdir "$_mpre" 2>/dev/null || return 1
  echo "$$" > "$_mpre/pid.$_mid" 2>/dev/null || { rm -rf "$_mpre" 2>/dev/null || true; return 1; }
  printf 'meta.%s' "$_mid" > "$_mpre/token.$_mid" 2>/dev/null || { rm -rf "$_mpre" 2>/dev/null || true; return 1; }
  ln "$_mpre/token.$_mid" "$_mown" 2>/dev/null || { rm -rf "$_mpre" 2>/dev/null || true; return 1; }
  if [ ! -e "$_meta" ] && mv "$_mpre" "$_meta" 2>/dev/null; then
    if [ "$_meta/token.$_mid" -ef "$_mown" ] && [ ! -d "$_meta/${_mpre##*/}" ]; then
      _TWL_META_MID="$_mid"
      return 0
    fi
    rm -rf "$_meta/${_mpre##*/}" 2>/dev/null || true
    rm -f "$_mown" 2>/dev/null || true
    return 1
  fi
  rm -rf "$_mpre" 2>/dev/null || true
  rm -f "$_mown" 2>/dev/null || true
  # ── 기존 meta 처리 (해체 후에도 이번 획득은 양보 — 호출자 루프가 재시도) ──
  _pf=""
  for _f in "$_meta"/pid.*; do
    [ -e "$_f" ] && { _pf="$_f"; break; }
  done
  if [ -z "$_pf" ]; then
    # 11라운드 P1(#1): pid 파일 없는 meta의 잔재 회수 — 단일 glob 스냅샷의
    # 이름만 다룬다. token.<mid>는 mid에 creator pid가 박혀 있어(mid=pid.시각.난수)
    # creator가 죽었을 때만 회수한다: live incarnation의 token은 creator가 살아
    # 있어 무접촉이고(이 glob이 successor를 잡아도 안전), 부분 해제(token rm
    # 실패 + pid rm 성공)가 남긴 죽은 token.<mid>는 회수돼 영구 고착이 없다.
    for _f in "$_meta"/*; do
      [ -e "$_f" ] || continue
      case "${_f##*/}" in
        pid.*) : ;;   # 이 스냅샷에 pid가 보이면 새 incarnation일 수 있다 — 무접촉 양보
        token.*)
          _cp="${_f##*/token.}"; _cp="${_cp%%.*}"
          case "$_cp" in
            ''|*[!0-9]*) : ;;
            *) kill -0 "$_cp" 2>/dev/null || rm -f "$_f" 2>/dev/null ;;
          esac
          ;;
        pid|token)
          # (구버전 호환) 고정 이름 잔재 — 구버전 pid가 죽었을 때만 정리
          _mp="$(cat "$_meta/pid" 2>/dev/null || true)"
          if [ -z "$_mp" ] || ! kill -0 "$_mp" 2>/dev/null; then
            rm -f "$_f" 2>/dev/null
          fi
          ;;
      esac
    done
    # rmdir은 비어 있을 때만 성공한다 — 잔재가 남았으면(live successor 포함)
    # 그대로 두고 양보한다 (무접촉).
    rmdir "$_meta" 2>/dev/null || true
    return 1
  fi
  _mp="$(cat "$_pf" 2>/dev/null || true)"
  [ -n "$_mp" ] || return 1
  kill -0 "$_mp" 2>/dev/null && return 1
  # dead 재검증은 관찰한 pid 파일 inode에 결속 — 이후의 rm들은 incarnation-고유
  # 이름이라 언제 재개되어도 successor를 건드릴 수 없다.
  # 10라운드 P1(#2): 검증 "이후"의 glob 재확장 금지 — 정지~재개 사이에 dir이
  # 교체되면 재확장된 token.* glob이 successor의 token을 지웠다 (실측). 파괴
  # 대상 이름은 전부 관찰한 pid 파일의 mid에서 유도한다(token.<mid>) — 죽은
  # incarnation의 고정 이름뿐이라 언제 재개돼도 successor와 겹치지 않는다.
  _dmid="${_pf##*/pid.}"
  if ln "$_pf" "$_mobs.p" 2>/dev/null; then
    if [ "$(cat "$_mobs.p" 2>/dev/null || true)" = "$_mp" ] && ! kill -0 "$_mp" 2>/dev/null \
       && [ "$_pf" -ef "$_mobs.p" ]; then
      rm -f "$_meta/token.$_dmid" 2>/dev/null || true
      rm -f "$_meta/pid.$_dmid" 2>/dev/null || true
      rmdir "$_meta" 2>/dev/null || true
    fi
    rm -f "$_mobs.p" 2>/dev/null || true
  fi
  return 1
}
_twl_meta_release() {  # $1=main lock dir
  local _meta="$1.rec.d" _mown="$1.rec.d.own.$$" _mid="${_TWL_META_MID:-}"
  # 12라운드 P1(#1) → 13라운드 P1(#3): 해체는 token.<mid>→pid.<mid>→rmdir "각
  # 단계를 검증"하며 진행한다. 어느 단계든 실패하면 소유 증거(.own·mid)를
  # 유지한 채 rc=1을 전파해 재호출이 남은 단계부터 이어간다 — 종전에는 token
  # 삭제 성공 후 pid 삭제 실패가 rc=0으로 위장됐고(반대편 부분 실패), token
  # 삭제 실패 시 .own을 지워 재시도 자체가 불가능했다 (실측). mid-고유
  # 이름이므로 어떤 재시도 단계도 남의 파일과 겹치지 않는다.
  if [ -n "$_mid" ] && [ -f "$_mown" ]; then
    if [ "$_meta/token.$_mid" -ef "$_mown" ]; then
      rm -f "$_meta/token.$_mid" 2>/dev/null || true
      if [ -e "$_meta/token.$_mid" ]; then
        echo "[WARN] meta-lock token 삭제 실패 — 소유 증거를 유지하고 실패를 전파합니다 (재시도 가능): $_meta/token.$_mid" >&2
        return 1
      fi
    elif [ -e "$_meta/token.$_mid" ] || [ -L "$_meta/token.$_mid" ]; then
      echo "[WARN] meta-lock token.<mid>가 내 inode가 아닙니다(예상 밖 재생성) — 무접촉, 해제 실패: $_meta/token.$_mid" >&2
      return 1
    fi
    if [ -e "$_meta/pid.$_mid" ]; then
      rm -f "$_meta/pid.$_mid" 2>/dev/null || true
      if [ -e "$_meta/pid.$_mid" ]; then
        echo "[WARN] meta-lock pid 삭제 실패 — 소유 증거를 유지하고 실패를 전파합니다 (재시도 가능): $_meta/pid.$_mid" >&2
        return 1
      fi
    fi
    if [ -d "$_meta" ]; then
      rmdir "$_meta" 2>/dev/null || true
      if [ -d "$_meta" ]; then
        echo "[WARN] meta-lock 디렉터리 정리 실패(예상 밖 잔여물) — 소유 증거를 유지하고 실패를 전파합니다: $_meta" >&2
        return 1
      fi
    fi
  fi
  rm -f "$_mown" 2>/dev/null || true
  if [ -e "$_mown" ] || [ -L "$_mown" ]; then
    echo "[WARN] meta-lock 소유 증거(.own) 삭제 실패 — 실패를 전파합니다 (재시도 가능): $_mown" >&2
    return 1
  fi
  _TWL_META_MID=""
  return 0
}

_twl_reclaim_dead() {  # $1=lock dir → 0=해체 완료, 1=회수 불가(live/교체/경합/잔여물)
  local _lk="$1" _obs="$1.obs.$$" _p _rc=1
  rm -f "$_obs.t" "$_obs.p" 2>/dev/null || true
  _p="$(cat "$_lk/pid" 2>/dev/null || true)"
  if [ -z "$_p" ]; then
    # 10라운드 P1(#3): 해제 도중 'token rm 실패 + pid rm 성공'이 남긴 token-only
    # 잔재 — live lock은 항상 pid를 갖는다(사전 구성 rename + 해제는 token→pid
    # 순서라 pid 없는 live 상태가 없다). 내용물이 "정확히 token 하나"일 때만,
    # meta 직렬화 아래에서 회수한다: meta를 쥔 동안에는 canonical이 교체될 수
    # 없으므로(교체는 선행 해체가 필요하고 해체는 meta 직렬화) 고정 이름 rm이
    # successor를 건드릴 수 없다. 그 외 pid 없는 lock은 기존 계약대로 무접촉.
    [ -d "$_lk" ] || return 1
    [ -f "$_lk/token" ] || return 1
    [ "$(ls -A "$_lk" 2>/dev/null | wc -l | tr -d ' ')" = "1" ] || return 1
    _twl_meta_acquire "$_lk" || return 1
    if [ -d "$_lk" ] && [ ! -f "$_lk/pid" ] && [ -f "$_lk/token" ] \
       && [ "$(ls -A "$_lk" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
      rm -f "$_lk/token" 2>/dev/null || true
      rmdir "$_lk" 2>/dev/null && _rc=0
    fi
    _twl_meta_release "$_lk"
    return "$_rc"
  fi
  kill -0 "$_p" 2>/dev/null && return 1
  # 7라운드 P1(#2): 해체는 meta-lock 아래에서만 — 참여자 간 -ef→rm 창 제거.
  # 8라운드 P1(#1): meta-lock 자체도 원자 rename + inode 결속 (_twl_meta_acquire).
  _twl_meta_acquire "$_lk" || return 1
  if [ -f "$_lk/token" ]; then
    if ! ln "$_lk/token" "$_obs.t" 2>/dev/null; then
      _twl_meta_release "$_lk"
      return 1
    fi
  fi
  if ! ln "$_lk/pid" "$_obs.p" 2>/dev/null; then
    rm -f "$_obs.t" 2>/dev/null || true
    _twl_meta_release "$_lk"
    return 1
  fi
  if [ "$(cat "$_obs.p" 2>/dev/null || true)" = "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
    if [ ! -f "$_obs.t" ] || [ "$_lk/token" -ef "$_obs.t" ]; then
      [ -f "$_obs.t" ] && rm -f "$_lk/token" 2>/dev/null
      if [ "$_lk/pid" -ef "$_obs.p" ]; then
        rm -f "$_lk/pid" 2>/dev/null || true
      fi
      rmdir "$_lk" 2>/dev/null && _rc=0
    fi
  fi
  rm -f "$_obs.t" "$_obs.p" 2>/dev/null || true
  _twl_meta_release "$_lk"
  return "$_rc"
}

# 7라운드 P2: EXIT trap이 release를 우회한 경로(스킵/대기 중 TERM)가 남긴
# .own/.acq/.obs 부속물을 다음 획득 시점에 gc한다 — 이름의 pid가 죽어 있을 때만.
_twl_gc_artifacts() {
  local _f _pid _pf
  # 8라운드 P2: meta-lock(.rec.d — 내부 pid 기준)도 gc 대상이다.
  # 9라운드 P1(#1b): pid 파일이 "없는" meta(해체 도중 죽음)도 회수한다 —
  # _twl_meta_acquire의 기존-meta 처리 경로가 잔재 정리와 rmdir을 수행한다.
  if [ -d "$_TW_LOCK.rec.d" ]; then
    _pf=""
    for _f in "$_TW_LOCK.rec.d"/pid.*; do
      [ -e "$_f" ] && { _pf="$_f"; break; }
    done
    _pid=""
    [ -n "$_pf" ] && _pid="$(cat "$_pf" 2>/dev/null || true)"
    if [ -z "$_pid" ] || ! kill -0 "$_pid" 2>/dev/null; then
      _twl_meta_acquire "$_TW_LOCK" >/dev/null 2>&1 && _twl_meta_release "$_TW_LOCK"
    fi
  fi
  for _f in "$_TW_LOCK".own.* "$_TW_LOCK".acq.* "$_TW_LOCK".obs.*.t "$_TW_LOCK".obs.*.p             "$_TW_LOCK".rec.d.pre.* "$_TW_LOCK".rec.d.own.* "$_TW_LOCK".rec.d.obs.*; do
    [ -e "$_f" ] || continue
    _pid="${_f##*.}"
    case "$_pid" in t|p) _pid="${_f%.*}"; _pid="${_pid##*.}" ;; esac
    case "$_pid" in
      ''|*[!0-9]*) continue ;;
    esac
    kill -0 "$_pid" 2>/dev/null && continue
    rm -rf "$_f" 2>/dev/null || true
  done
  return 0
}

_acquire_write_lock() {
  local _i=0 _p _pre="$_TW_LOCK.acq.$$" _own="$_TW_LOCK.own.$$"
  # 재진입 (리뷰 14차 P1): 결정(critical section)이 lock을 쥔 채 _safe_write를
  # 부를 수 있어야 approve/reject 상호 직렬화가 단일 임계구역으로 성립한다.
  if [ "${_TW_HELD:-0}" -gt 0 ]; then _TW_HELD=$((_TW_HELD+1)); return 0; fi
  mkdir -p "$(dirname "$_TW_LOCK")" 2>/dev/null || true
  _twl_gc_artifacts
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
    # 9라운드 P1(#5) 파생: "완전히 빈" canonical lock 디렉터리는 해제 마무리(rmdir)
    # 직전에 죽은 잔재다 — live lock은 사전 구성 rename으로 항상 내용을 담고 도착하고
    # 내용이 있는 동안은 무접촉 계약이 유지된다. 빈 디렉터리 회수는 rmdir뿐이라
    # (비어 있을 때만 성공) 어떤 race에서도 live lock을 제거할 수 없다.
    if [ -z "$_p" ] && [ -d "$_TW_LOCK" ]; then
      if [ -z "$(ls -A "$_TW_LOCK" 2>/dev/null)" ]; then
        rmdir "$_TW_LOCK" 2>/dev/null || true
      else
        # 10라운드 P1(#3): token-only 잔재(해제 도중 token rm 실패 + pid rm 성공)는
        # meta 직렬화 아래에서 회수한다 — 그 외 조합은 기존대로 무접촉 대기.
        _twl_reclaim_dead "$_TW_LOCK" && continue
      fi
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
  local _own="$_TW_LOCK.own.$$" _p
  rm -rf "$_TW_LOCK.acq.$$" 2>/dev/null || true
  rm -f "$_TW_LOCK.obs.$$.t" "$_TW_LOCK.obs.$$.p" 2>/dev/null || true
  # 12라운드 P1(#1) → 13라운드 P1(#3): token→pid→rmdir 각 단계를 "검증"하며
  # 해체한다. 어느 단계든 실패하면 소유 증거(.own)를 유지한 채 rc=1을 전파해
  # 재호출이 남은 단계부터 이어간다 — 종전에는 (a) token 삭제 성공 후 pid 삭제
  # 실패가 rc=0으로 위장되어 살아 있는 내 pid의 pid-only lock이 남아 재획득이
  # 영구 대기했고, (b) token 삭제 실패 시 .own을 지워 재시도가 불가능했다 (실측).
  if [ -f "$_own" ]; then
    if [ "$_TW_LOCK/token" -ef "$_own" ]; then
      rm -f "$_TW_LOCK/token" 2>/dev/null || true
      if [ -e "$_TW_LOCK/token" ]; then
        echo "⚠️  write lock token 삭제 실패 — 소유 증거를 유지하고 실패를 전파합니다 (재시도 가능): ${_TW_LOCK}" >&2
        return 1
      fi
    elif [ -e "$_TW_LOCK/token" ] || [ -L "$_TW_LOCK/token" ]; then
      # canonical token이 내 inode가 아니다 — 남의 lock 무접촉, stale own만 정리
      rm -f "$_own" 2>/dev/null || true   # canonical token이 내 inode가 아니다 — 남의 lock 무접촉, stale own만 정리
      if [ -e "$_own" ] || [ -L "$_own" ]; then
        echo "⚠️  write lock 소유 증거(.own) 삭제 실패 (재시도 가능): $_own" >&2
        return 1
      fi
      _TW_HELD=0
      return 0
    fi
    # token은 (이번 또는 앞선 시도에서) 제거됨 — 내 잔재의 남은 단계를 잇는다
    if [ -d "$_TW_LOCK" ]; then
      if [ -f "$_TW_LOCK/pid" ]; then
        _p="$(cat "$_TW_LOCK/pid" 2>/dev/null || true)"
        if [ "$_p" != "$$" ]; then
          rm -f "$_own" 2>/dev/null || true   # 내 pid가 아니다 — 남의 잔재 무접촉
          if [ -e "$_own" ] || [ -L "$_own" ]; then
            echo "⚠️  write lock 소유 증거(.own) 삭제 실패 (재시도 가능): $_own" >&2
            return 1
          fi
          _TW_HELD=0
          return 0
        fi
        rm -f "$_TW_LOCK/pid" 2>/dev/null || true
        if [ -e "$_TW_LOCK/pid" ]; then
          echo "⚠️  write lock pid 삭제 실패 — 소유 증거를 유지하고 실패를 전파합니다 (재시도 가능): ${_TW_LOCK}" >&2
          return 1
        fi
      fi
      rmdir "$_TW_LOCK" 2>/dev/null || true
      if [ -d "$_TW_LOCK" ]; then
        echo "⚠️  write lock 디렉터리 정리 실패(예상 밖 잔여물) — 소유 증거를 유지하고 실패를 전파합니다: ${_TW_LOCK}" >&2
        return 1
      fi
    fi
  fi
  rm -f "$_own" 2>/dev/null || true
  if [ -e "$_own" ] || [ -L "$_own" ]; then
    echo "⚠️  write lock 소유 증거(.own) 삭제 실패 — 실패를 전파합니다 (재시도 가능): $_own" >&2
    return 1
  fi
  _TW_HELD=0
  return 0
}
