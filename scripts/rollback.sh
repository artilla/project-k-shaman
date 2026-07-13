#!/usr/bin/env bash
# rollback.sh — restore a ticket pre-cycle tag or point to the revert command.
#
# 리뷰 2차 P1-10: reset --hard + clean -fd는 무관한 작업까지 파괴할 수 있어 가드를 추가한다.
#   1. clean-tree 가드 — 추적 파일에 미커밋 변경이 있으면 거부 (reset --hard가 파괴,
#      --yes로도 우회 불가).
#   2. isolated-worktree 가드 — .ralph/wt-* 격리 워크트리에서는 기존처럼 즉시 실행.
#   3. 확인 가드 — 메인 워크트리는 --yes 플래그 또는 대화형 y 응답이 있어야 실행.
#      비대화형 + --yes 없음 → fail-closed 거부. clean -fd로 지워질 미추적 파일 목록을
#      실행 전에 보여준다.
#
# usage: scripts/rollback.sh <TXXX> [--yes]

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "usage: scripts/rollback.sh <TXXX> [--yes]" >&2
}

YES=0
ID=""
for arg in "$@"; do
  case "$arg" in
    --yes) YES=1 ;;
    -h|--help) usage; exit 0 ;;
    T[0-9]*) ID="$arg" ;;
    *) echo "unknown argument: $arg" >&2; usage; exit 2 ;;
  esac
done
[ -n "$ID" ] || { usage; exit 2; }

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not a git repository" >&2
  exit 2
}

in_isolated_worktree() {
  case "$ROOT" in
    */.ralph/wt-*) return 0 ;;
    *)             return 1 ;;
  esac
}

TAG="cycle/${ID}-pre"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
  # ── 3라운드 P1(#3) → 4라운드 P1(#5·#6): 시스템 writer lock ──────────────────────
  # clean 판정부터 reset/revert 수행·최종 검증·성공 보고까지 "전 과정"을 시스템
  # writer 프로토콜(state/ticket_write.lock.d — ticket_*.sh·auto_merge와 동일)
  # 아래에서 수행한다. 4라운드 #6: reset 경로도 이 lock 없이는 clean 검사~
  # reset --hard 사이에 들어온 tracked 변경을 파괴할 수 있었다 — 두 경로 모두
  # 획득 후에만 진행한다.
  # 한계(정직한 범위): lock은 프로토콜을 지키는 writer만 배제한다. 프로토콜 밖
  # raw git 개입은 어떤 lock으로도 막을 수 없다 — 그 경우 최종 검증(fail-closed)이
  # 성공 보고를 막는 것이 최선이며, 검증의 마지막 관측과 종료 사이의 잔여 창은
  # 원리적으로 제거 불가능하다 (아래 최종 검증 주석 참조).
  # 해제 계약(4라운드 #4·#6): rename 기반 해제는 확인~rename 창의 교체에서 foreign
  # lock을 canonical 밖으로 이동시켰다 — inode(-ef) 결속 + 내용물 제거(token→pid→
  # rmdir)로 교체한다. canonical은 rmdir 직전까지 점유 상태이므로 foreign lock이
  # canonical을 떠나는 순간이 없고, 극단 창의 결과도 '누수(fail-closed)'이지
  # 상호배제 공백이 아니다. EXIT trap이 모든 종료 경로의 해제를 덮는다.
  _RB_WL="state/ticket_write.lock.d"
  _RB_WL_TOKEN=""
  # 5라운드 P1(#2): 관찰한 dead lock을 "이동 없이" 해체한다 — token/pid 파일의
  # inode를 하드링크(.obs.$$)로 결속하고, dead 재검증 후 -ef가 성립할 때만 각
  # 파일을 제거하고 rmdir한다. 그 사이 교체된 live lock은 inode가 달라 무접촉이며
  # rmdir 실패로 canonical에 그대로 남는다 (foreign lock 무이동 — 상호배제 공백 없음).
  _rb_reclaim_dead() {  # $1=lock dir → 0=해체 완료, 1=회수 불가
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
  _rb_wl_acquire() {
    local _i=0 _p _pt _mp _mt _pre="$_RB_WL.acq.$$" _own="$_RB_WL.own.$$"
    mkdir -p state 2>/dev/null || true
    _rb_wl_mkpre() {
      rm -rf "$_pre" 2>/dev/null || true
      rm -f "$_own" 2>/dev/null || true
      mkdir "$_pre" 2>/dev/null || return 1
      _RB_WL_TOKEN="rb.$$.${RANDOM}${RANDOM}${RANDOM}"
      echo "$$" > "$_pre/pid" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
      printf '%s' "$_RB_WL_TOKEN" > "$_pre/token" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
      # 소유 증거는 내용이 아니라 inode — rename 전에 하드링크 보관 (4라운드 #4).
      ln "$_pre/token" "$_own" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
    }
    _rb_wl_mkpre || return 1
    while :; do
      if [ ! -e "$_RB_WL" ] && mv "$_pre" "$_RB_WL" 2>/dev/null; then
        # rename 경합으로 기존 lock "안"에 중첩됐을 수 있다 — inode+pid+비중첩으로 확정.
        if [ "$_RB_WL/token" -ef "$_own" ] \
           && [ "$(cat "$_RB_WL/pid" 2>/dev/null || true)" = "$$" ] \
           && [ ! -d "$_RB_WL/${_pre##*/}" ]; then
          return 0
        fi
        rm -rf "$_RB_WL/${_pre##*/}" 2>/dev/null || true
        _rb_wl_mkpre || return 1
      fi
      _p="$(cat "$_RB_WL/pid" 2>/dev/null || true)"
      if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
        # 5라운드 P1(#2): mv 기반 회수는 관찰~mv 창의 live lock을 canonical 밖으로
        # 밀어냈다 — 이동 없는 inode 결속 해체로 교체. 실패(교체된 live lock 등)는
        # 훔치지 않고 bounded 대기로 재시도한다.
        _rb_reclaim_dead "$_RB_WL" && continue
      fi
      _i=$((_i+1))
      if [ "$_i" -ge 100 ]; then rm -rf "$_pre" 2>/dev/null || true; rm -f "$_own" 2>/dev/null || true; return 1; fi
      sleep 0.1
    done
  }
  _rb_wl_release() {
    local _own="$_RB_WL.own.$$"
    rm -rf "$_RB_WL.acq.$$" 2>/dev/null || true
    rm -f "$_RB_WL.obs.$$.t" "$_RB_WL.obs.$$.p" 2>/dev/null || true
    if [ -f "$_own" ] && [ "$_RB_WL/token" -ef "$_own" ]; then
      rm -f "$_RB_WL/token" "$_RB_WL/pid" 2>/dev/null || true
      rmdir "$_RB_WL" 2>/dev/null \
        || echo "⚠️  writer lock 디렉터리 정리 실패(예상 밖 잔여물) — 확인 필요: ${_RB_WL}" >&2
    fi
    rm -f "$_own" 2>/dev/null || true
    return 0
  }
  trap '_rb_wl_release' EXIT
  if ! _rb_wl_acquire; then
    echo "❌ 시스템 writer lock(${_RB_WL}) 획득 실패 — clean 판정과 rollback을 직렬화할 수 없어 중단합니다 (fail-closed)." >&2
    exit 3
  fi

  # 가드 1: 추적 파일 미커밋 변경 → 거부.
  # 재리뷰 P1(#5): git status의 "실패"(rc≠0, 빈 출력)를 clean으로 오인하지 않는다 —
  # rc를 버리고 출력만 비교하던 세 지점(초기·공개 전·최종) 모두 rc 검사가 선행한다.
  if ! _RB_ST0="$(git status --porcelain --untracked-files=no)"; then
    echo "❌ git status 실패 — 작업트리 상태를 판정할 수 없어 중단합니다 (fail-closed)." >&2
    exit 3
  fi
  if [ -n "$_RB_ST0" ]; then
    echo "❌ 추적 파일에 미커밋 변경이 있습니다 — reset --hard가 이를 파괴합니다." >&2
    echo "   commit 또는 stash 후 다시 실행하세요." >&2
    git status --short --untracked-files=no >&2
    exit 3
  fi

  # 가드 4 (리뷰 16차 P1 재재설계 + 5차): 소유권은 post 태그 annotation의
  # "커밋 OID 목록"이다. 5차 보강:
  #   - 태그는 이름이 아니라 "해석 시점에 고정한 OID"로만 다룬다 (재해석 TOCTOU 제거)
  #   - 부분 실패 후 재실행 허용: post 이후의 커밋이 전부 "owned에 대한 우리 역커밋"
  #     일 때만 이어서 진행하고, 이미 되돌린 OID는 건너뛴다 (고착 제거)
  #   - merge commit(부모 2+)은 mainline 정보가 없어 자동 revert 불가 — 명시 거부
  PRE_OID="$(git rev-parse -q --verify "refs/tags/${TAG}^{commit}" || true)"
  POST_TAG="cycle/${ID}-post"
  # 7차 P1-6: 태그 ref는 "한 번"만 OID로 해석해 고정하고(POST_TAGOBJ), peeled
  # target(POST_OID)은 태그 "이름"이 아니라 그 고정 OID에서 파생한다 — 두 번의
  # 이름 해석 사이에 태그가 이동하면 annotation(이전 태그)과 target(새 태그)이
  # 서로 다른 시점에서 읽혀, 이전 소유 목록을 revert하고 새 cycle을 남긴 채
  # rc=0을 반환했다 (실측).
  POST_TAGOBJ="$(git rev-parse -q --verify "refs/tags/${POST_TAG}" 2>/dev/null || true)"
  POST_OID=""
  [ -n "$POST_TAGOBJ" ] && POST_OID="$(git rev-parse -q --verify "${POST_TAGOBJ}^{commit}" 2>/dev/null || true)"
  HEAD_OID="$(git rev-parse HEAD)"
  MODE_ROLLBACK=""
  # 3라운드 P1(#2): rev-list "실패"를 빈 결과(= pre 이후 커밋 없음)로 해석하면
  # reset 경로로 fail-open한다 — 조회 실패는 판정 불가로 즉시 중단한다.
  if ! _RB_AFTER_PRE="$(git rev-list -n 1 "${PRE_OID}..HEAD" 2>/dev/null)"; then
    echo "❌ ${TAG} 이후 커밋 조회(rev-list) 실패 — 모드를 판정할 수 없어 중단합니다 (fail-closed)." >&2
    exit 3
  fi
  if [ -z "$_RB_AFTER_PRE" ]; then
    MODE_ROLLBACK="reset"
  elif in_isolated_worktree; then
    MODE_ROLLBACK="reset"
  elif [ -n "$POST_OID" ] \
     && git merge-base --is-ancestor "$PRE_OID" "$POST_OID" 2>/dev/null \
     && git merge-base --is-ancestor "$POST_OID" "$HEAD_OID" 2>/dev/null; then
    MODE_ROLLBACK="revert"
  else
    echo "❌ ${TAG} 이후 커밋들이 기록된 사이클 종점(${POST_TAG})과 정합하지 않습니다 — 자동 롤백을 거부합니다 (--yes 우회 불가):" >&2
    git log --format='%h %s' "${PRE_OID}..HEAD" >&2
    echo "   이 티켓의 변경만 되돌리려면 해당 커밋을 선별 revert 하세요 (최신 → 과거 순):" >&2
    git log --format='   git revert %h  # %s' "${PRE_OID}..HEAD" >&2
    exit 3
  fi

  # 가드 2·3: 메인 워크트리는 명시적 확인 필요 (격리 워크트리는 즉시 실행).
  if ! in_isolated_worktree; then
    if [ "$MODE_ROLLBACK" = "reset" ]; then
      # 4라운드 P2: clean preview 실패(rc≠0)를 '지워질 것 없음'으로 오인하지 않는다 —
      # 미리보기 없이 파괴적 clean을 진행할 수 없다 (fail-closed).
      if ! UNTRACKED="$(git clean -nd 2>/dev/null)"; then
        echo "❌ git clean -nd(미리보기) 실패 — 삭제 대상을 확인할 수 없어 중단합니다 (fail-closed)." >&2
        exit 3
      fi
      if [ -n "$UNTRACKED" ]; then
        echo "⚠️  clean -fd로 삭제될 미추적 파일/디렉터리:" >&2
        printf '%s\n' "$UNTRACKED" >&2
      fi
      _PROMPT="메인 워크트리를 ${TAG}로 reset --hard + clean -fd 합니다"
    else
      echo "ℹ️  revert 기반 롤백 대상 커밋 (히스토리 보존, 역커밋 생성):" >&2
      git log --format='   %h %s' "${TAG}..HEAD" >&2
      _PROMPT="위 커밋들을 git revert로 되돌립니다"
    fi
    if [ "$YES" != "1" ]; then
      if [ -t 0 ]; then
        printf '⚠️  %s. 계속할까요? [y/N] ' "$_PROMPT" >&2
        read -r answer
        case "$answer" in
          y|Y|yes) ;;
          *) echo "취소됨." >&2; exit 3 ;;
        esac
      else
        echo "❌ 메인 워크트리 비대화형 실행 — --yes 플래그가 필요합니다 (fail-closed)." >&2
        exit 3
      fi
    fi
  fi

  if [ "$MODE_ROLLBACK" = "revert" ]; then
    # 8차 2회 P1(#4): 공개 대상은 symbolic HEAD가 아니라 "지금 checkout된 구체
    # branch ref"다. update-ref HEAD ...는 실행 시점에 HEAD가 가리키는 branch를
    # 갱신하므로, 같은 OID의 다른 branch로 전환하면 그 branch가 rollback되고
    # 원래 branch는 그대로인데 rc=0 + 태그 삭제가 일어났다 (실측). 검증 시점의
    # branch를 고정하고, 공개 직전 "여전히 그 branch에 있는지"까지 재검증한다.
    HEAD_REF="$(git symbolic-ref -q HEAD || true)"   # detached면 빈 문자열
    if [ -z "$HEAD_REF" ]; then
      echo "❌ detached HEAD 상태입니다 — 자동 revert 롤백은 branch 위에서만 수행합니다 (fail-closed)." >&2
      exit 3
    fi
    # 소유 OID 고정 — 태그 "이름" 재조회는 그 사이 태그 이동 시 다른 annotation을
    # 읽는 TOCTOU (6차 P1-5). 해석 시점에 고정한 tag object OID에서 직접 읽는다.
    # (annotated tag object의 message에서 OID 추출; lightweight/비태그 객체면
    # cat-file tag가 실패 → OWNED 빈 값 → 아래 fail-closed 거부)
    OWNED="$(git cat-file tag "$POST_TAGOBJ" 2>/dev/null | grep -E '^[0-9a-f]{40}$' || true)"
    if [ -z "$OWNED" ]; then
      echo "❌ ${POST_TAG}에 소유 커밋 목록(annotation)이 없습니다 — 자동 롤백 불가 (구 형식/수동 태그, fail-closed). 수동 선별 revert:" >&2
      git log --format='   git revert %h  # %s' "${PRE_OID}..HEAD" >&2
      exit 3
    fi
    RANGE_OIDS="$(git rev-list "${PRE_OID}..${POST_OID}" 2>/dev/null)" || {
      echo "❌ 소유 범위 조회 실패 — 자동 롤백을 거부합니다 (fail-closed)." >&2; exit 3; }
    for c in $OWNED; do
      case "$RANGE_OIDS" in
        *"$c"*) : ;;
        *)
          echo "❌ 소유 목록의 커밋 ${c}가 ${TAG}..${POST_TAG} 범위에 없습니다 — 기록 불일치, 자동 롤백을 거부합니다 (fail-closed)." >&2
          exit 3
          ;;
      esac
      # 리뷰 16차 P2(5차): merge commit은 mainline 정보 없이 자동 revert할 수 없다.
      # 3라운드 P1(#2): 조회 실패(rc≠0)를 '부모 0개'로 삼키지 않는다.
      if ! _rb_parents="$(git rev-list --parents -n 1 "$c" 2>/dev/null)"; then
        echo "❌ 소유 커밋 ${c}의 부모 조회 실패 — 자동 롤백을 거부합니다 (fail-closed)." >&2
        exit 3
      fi
      if [ "$(printf '%s' "$_rb_parents" | wc -w | tr -d ' ')" -gt 2 ]; then
        echo "❌ 소유 커밋 ${c}는 merge commit입니다 — 자동 revert 불가, 수동으로 'git revert -m <mainline> ${c}'를 실행하세요 (fail-closed)." >&2
        exit 3
      fi
    done

    # ── 8라운드 후속 재리뷰 P1(#6): revert 결과의 "정확한 identity" 검증 ──────────
    # git patch-id --stable은 whitespace를 무시한다 — 정상 'v1' revert 대신 'v 1'을
    # 만드는 같은-parent 커밋이 검증을 통과해 rc=0으로 공개됐다 (실측). 검증 축을
    # patch-id에서 "결과 tree의 경로별 (mode, blob OID) 정확 대조"로 바꾼다:
    #   (a) 후보 커밋이 parent 대비 바꾼 경로 ⊆ 소유 커밋 c가 바꾼 경로
    #   (b) c가 바꾼 모든 경로에서 후보의 (mode, blob) == c^의 (mode, blob)
    #       — 즉 c 직전 상태로 정확히 복원됐다 (c가 추가한 경로는 부재여야 한다)
    # whitespace·mode·심볼릭 변조는 전부 blob OID/mode 불일치로 걸린다.
    # 재리뷰 P1(#4): 경로 목록은 NUL(-z) 기반으로만 다룬다 — newline 기반
    # `diff-tree | sort`는 개행 포함 파일명을 C-quote 문자열/조각으로 갈라,
    # ls-tree가 양쪽 모두 빈 결과("부재 == 부재")를 반환해 위조 커밋이 "이미
    # 되돌려짐"으로 인정됐다 (실측: rc=0 + post 태그 삭제). 경로는 raw bytes
    # 그대로 전달하고, pathspec magic 오해석을 막기 위해 :(literal)로 고정한다.
    # 3라운드 P1(#2): ls-tree "실패"(rc≠0)와 "부재"(rc=0, 빈 출력)를 구분한다 —
    # 실패를 빈 결과로 삼키면 양쪽 모두 '부재'로 비교되어(부재==부재) 위조
    # 역커밋이 검증을 통과했다 (실측: rc=42 셔임에서 rc=0 + post 태그 삭제).
    # 성공 시 _RB_ENTRY에 "<mode> <oid>"(부재면 빈 문자열)를 담고 0을, git 실패
    # 시 1을 반환한다 — 호출자는 실패를 검증 실패로 전파한다 (fail-closed).
    _RB_ENTRY=""
    _rb_entry() {  # $1=commit-ish, $2=path(raw)
      local _out
      _out="$(git ls-tree --full-tree "$1" -- ":(literal)$2" 2>/dev/null)" || { _RB_ENTRY=""; return 1; }
      # mode·oid는 첫 두 필드 — 경로 quoting(C-quote)과 무관하게 안전하다.
      _RB_ENTRY="$(printf '%s\n' "$_out" | awk 'NF {print $1" "$3; exit}')"
      return 0
    }
    _rb_verify_revert() {  # $1=후보 커밋, $2=그 parent, $3=소유 커밋
      local _pp _q _e_new _e_base _cpf _npf _found
      git rev-parse -q --verify "${3}^{commit}" >/dev/null 2>&1 || return 1
      git rev-parse -q --verify "${3}^" >/dev/null 2>&1 || return 1   # root commit은 대상 아님
      _cpf="$(mktemp "${TMPDIR:-/tmp}/rb-cp.XXXXXX")" || return 1
      _npf="$(mktemp "${TMPDIR:-/tmp}/rb-np.XXXXXX")" || { rm -f "$_cpf"; return 1; }
      # diff 실패는 검증 실패다 (fail-closed — 빈 목록으로 위장 금지)
      if ! git diff-tree -r --name-only --no-commit-id -z "${3}^" "$3" > "$_cpf" 2>/dev/null \
         || ! git diff-tree -r --name-only --no-commit-id -z "$2" "$1" > "$_npf" 2>/dev/null; then
        rm -f "$_cpf" "$_npf"; return 1
      fi
      [ -s "$_cpf" ] || { rm -f "$_cpf" "$_npf"; return 1; }
      # (a) 후보가 바꾼 경로 ⊆ 소유 커밋의 경로 — NUL 레코드의 "정확 일치" 비교
      while IFS= read -r -d '' _pp; do
        _found=0
        while IFS= read -r -d '' _q; do
          [ "$_pp" = "$_q" ] && { _found=1; break; }
        done < "$_cpf"
        [ "$_found" -eq 1 ] || { rm -f "$_cpf" "$_npf"; return 1; }
      done < "$_npf"
      # (b) 경로별 정확 identity — c^ 상태로 정확히 복원됐는가.
      # ls-tree 실패는 부재가 아니라 검증 실패다 (3라운드 P1 #2).
      while IFS= read -r -d '' _pp; do
        _rb_entry "$1" "$_pp" || { rm -f "$_cpf" "$_npf"; return 1; }
        _e_new="$_RB_ENTRY"
        _rb_entry "${3}^" "$_pp" || { rm -f "$_cpf" "$_npf"; return 1; }
        _e_base="$_RB_ENTRY"
        [ "$_e_new" = "$_e_base" ] || { rm -f "$_cpf" "$_npf"; return 1; }
      done < "$_cpf"
      rm -f "$_cpf" "$_npf"
      return 0
    }

    # 5차 P1-7(재개 가능성): post 이후의 커밋은 전부 "owned에 대한 우리 역커밋"
    # 이어야 한다 — 그 외(외부 커밋)는 기존대로 거부. 이미 되돌린 OID는 건너뛴다.
    ALREADY=""
    if [ "$POST_OID" != "$HEAD_OID" ]; then
      # 3라운드 P1(#2): rev-list 실패를 '커밋 없음'으로 삼키면 post 이후 외부
      # 커밋 검사가 공허 통과한다 — 조회 실패는 즉시 중단 (fail-closed).
      if ! _RB_AFTER_POST="$(git rev-list "${POST_OID}..HEAD" 2>/dev/null)"; then
        echo "❌ ${POST_TAG} 이후 커밋 조회(rev-list) 실패 — 자동 롤백을 거부합니다 (fail-closed)." >&2
        exit 3
      fi
      for c in $_RB_AFTER_POST; do
        # 6차 P1-6: "This reverts commit <oid>" 문자열은 아무 커밋이나 본문에 위조할
        # 수 있다 — 문자열은 후보 선별로만 쓰고, 실제 역커밋인지는 patch-id로 검증한다:
        # 소유 커밋의 역방향 diff(o→o^)와 후보 커밋의 diff(c^→c)의 stable patch-id가
        # 일치해야만 "이미 되돌려짐"으로 인정. 불일치(위조·충돌 수동해소 등)는 외부
        # 커밋으로 간주해 거부한다 (fail-closed; 우리 스크립트의 revert는 무충돌
        # 성공만 남기므로 정상 재개 경로에서는 항상 일치한다).
        _rvof=""
        _cbody="$(git log -1 --format=%B "$c" 2>/dev/null || true)"
        for o in $OWNED; do
          case "$_cbody" in *"This reverts commit ${o}"*) ;; *) continue ;; esac
          # #6: patch-id가 아니라 tree의 경로별 (mode, blob) 정확 대조로 판정한다 —
          # whitespace만 다른 위조 역커밋을 "이미 되돌려짐"으로 인정하지 않는다.
          if _rb_verify_revert "$c" "${c}^" "$o"; then _rvof="$o"; fi
          break
        done
        if [ -z "$_rvof" ]; then
          echo "❌ ${POST_TAG} 이후에 소유 역커밋이 아닌 커밋(${c})이 있습니다 — 자동 롤백을 거부합니다 (fail-closed)." >&2
          echo "   이 티켓의 소유 커밋만 수동 선별 revert 하세요:" >&2
          for o in $OWNED; do echo "     git revert $o" >&2; done
          exit 3
        fi
        ALREADY="${ALREADY}${_rvof}
"
      done
    fi

    # 7차 P1-7: revert는 "격리 worktree/index"에서 수행한다. 6차의 경로 비교는
    # 실패 커밋과 "같은 경로"에 올라온 동시 staged 변경을 revert 자신의 잔상으로
    # 오인해 --abort로 파괴했다 — 경로 비교로는 해결되지 않는다. 격리 index에서는
    # 공유 index를 건드릴 수단 자체가 없다: 충돌·신호·실패 시 격리 worktree만
    # 버리고(메인 무변경, all-or-nothing), 성공 시에만 공개 전 재검증을 통과한
    # 결과를 ff-only로 원자 공개한다.
    _WT_BASE="$(mktemp -d "${TMPDIR:-/tmp}/rollback-wt.XXXXXX")" || { echo "❌ 격리 worktree temp 생성 실패." >&2; exit 3; }
    _WT="${_WT_BASE}/wt"
    # 6라운드 P1(#4): cleanup 자식도 deadline 아래에서 — worktree remove가 지연/
    # TERM 무시면 rollback과 writer lock이 무한정 남았다 (실측 7s+). 실패는 삼키지
    # 않고 플래그로 전파한다 (stale worktree 등록이 남으면 rc=0 금지).
    _rb_bounded() {  # deadline(5s)-capped 그룹 실행 — rc 반환 (신호 semantics 없음)
      local _pid _rc=0 _dl
      set -m
      "$@" &
      _pid=$!
      set +m
      _dl=$(( $(date +%s) + 5 ))
      while kill -0 -- "-${_pid}" 2>/dev/null && [ "$(date +%s)" -lt "$_dl" ]; do sleep 0.25; done
      if kill -0 -- "-${_pid}" 2>/dev/null; then
        kill -TERM -- "-${_pid}" 2>/dev/null || true
        sleep 0.25
        kill -0 -- "-${_pid}" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
      fi
      wait "$_pid" 2>/dev/null || _rc=$?
      return "$_rc"
    }
    _RB_WT_CLEAN_OK=1
    _rb_cleanup_wt() {
      # 멱등: 이미 정리된 뒤의 재호출이 실패로 오인되지 않도록 존재할 때만 시도
      if [ -d "$_WT" ]; then
        _rb_bounded git worktree remove --force "$_WT" >/dev/null 2>&1 || _RB_WT_CLEAN_OK=0
      fi
      _rb_bounded git worktree prune >/dev/null 2>&1 || true
      rm -rf "$_WT_BASE" 2>/dev/null || true
      [ -d "$_WT" ] && _RB_WT_CLEAN_OK=0
      return 0
    }
    # 8차 2회 P1(#6) → 8라운드 후속 P1(#2): 공개 여부를 shell boolean으로 들지
    # 않는다 — ref transaction commit과 대입 사이의 신호가 "메인 무변경"으로
    # 오판됐다 (실측: branch는 새 OID·태그 삭제·worktree 이전 상태인데 무변경
    # 보고). 판정 근거는 "지금 이 순간의 실제 ref 상태"뿐이다. 공개 이후로
    # 판정되면 복구 참조(refs/rollback/<ID>)를 기록하고 phase별 복구 절차를
    # 안내한다.
    _NEW=""
    _RB_SIG=""
    _RB_PHASE="main"
    # 재리뷰 P1(#8) → 3라운드 P1(#4): 복구 참조는 실행 소유권 + CAS로만 다룬다 —
    #   - 생성은 create-only CAS(expected-old="", 즉 "존재하지 않을 때만") —
    #     선행/동시 실행이 남긴 복구 증거를 절대 덮지 않는다. 선점돼 있으면 이 실행
    #     고유 이름(refs/rollback/<ID>-<ts>.<pid>)으로 기록한다.
    #   - "삭제하지 않는다": 이 실행이 만들지 않은 ref는 어떤 경로에서도 지우지
    #     않는다 — 같은 ID의 동시 실행이 서로의 복구 증거를 지우던 문제 제거.
    #   - 생성 "실패"는 전파한다: 존재하지 않는 ref를 복구 근거로 안내하지 않는다.
    #     메시지는 _rb_rref_note가 실제 상태(기록된 이름 또는 기록 실패 + 원 OID)를
    #     보고한다.
    _RB_RREF="refs/rollback/${ID}"
    _RB_RREF_STATE=""   # "" = 미기록, ok = 기록됨, fail = 기록 실패
    _rb_save_recovery() {
      [ -n "$_NEW" ] || { _RB_RREF_STATE="fail"; return 1; }
      [ "$_RB_RREF_STATE" = "ok" ] && return 0
      if git update-ref "$_RB_RREF" "$_NEW" "" >/dev/null 2>&1; then _RB_RREF_STATE="ok"; return 0; fi
      if [ "$(git rev-parse -q --verify "$_RB_RREF" 2>/dev/null || true)" = "$_NEW" ]; then _RB_RREF_STATE="ok"; return 0; fi
      _RB_RREF="refs/rollback/${ID}-$(date +%s).$$"
      if git update-ref "$_RB_RREF" "$_NEW" "" >/dev/null 2>&1; then _RB_RREF_STATE="ok"; return 0; fi
      _RB_RREF_STATE="fail"
      return 1
    }
    _rb_rref_note() {
      if [ "$_RB_RREF_STATE" = "ok" ]; then
        printf '복구 참조: %s' "$_RB_RREF"
      else
        printf '복구 참조 기록 실패 — 계산 결과 OID를 직접 보존·사용하세요: %s' "${_NEW:-없음}"
      fi
    }
    _rb_sig_report() {
      local _cur
      _cur="$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)"
      if [ -n "$_NEW" ] && [ "$_cur" = "$_NEW" ]; then
        _rb_save_recovery || true
        echo "❌ 신호로 중단됨 — ref 공개는 이미 완료됐습니다(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨). index/worktree는 이전 상태일 수 있습니다: 'git status' 확인 후 로컬 변경이 없으면 'git reset --hard HEAD'로 동기화하세요. $(_rb_rref_note)" >&2
      else
        # 재리뷰 P2: 메시지가 실제 tip을 보고한다 — 관측값과 다른 "무변경" 단정 금지.
        if [ "$_cur" = "$HEAD_OID" ] || [ -z "$_cur" ]; then
          echo "❌ 신호로 중단됨 — 격리 worktree만 정리했습니다 (메인 워크트리·index·HEAD는 변경되지 않았습니다)." >&2
        else
          _rb_save_recovery || true
          echo "❌ 신호로 중단됨 — ${HEAD_REF}의 현재 tip은 ${_cur}입니다 (검증 시점 ${HEAD_OID}, 계산 결과 ${_NEW:-없음}): 'git status'와 ref 상태를 직접 확인하세요.$([ -n "$_NEW" ] && echo " $(_rb_rref_note)")" >&2
        fi
      fi
    }
    _rb_on_sig() {
      _RB_SIG="$1"
      # read-tree/child 실행 중에는 기록만 — 전달·bounded reap은 그 루프가 소유
      [ "$_RB_PHASE" = "readtree" ] && return 0
      [ "$_RB_PHASE" = "child" ] && return 0
      _rb_cleanup_wt
      _rb_sig_report
      exit 130
    }
    trap '_rb_on_sig TERM' TERM
    trap '_rb_on_sig INT'  INT
    trap '_rb_on_sig HUP'  HUP
    # 5라운드 P1(#5): 장시간 git 자식(revert·worktree add)을 foreground로 돌리면
    # bash trap이 자식 종료까지 지연된다 — TERM을 무시하는 자식(30s shim 실측)에서
    # 프로세스와 writer lock이 계속 남았다. 자식을 별도 프로세스 그룹으로 돌리고
    # wait(신호에 즉시 깨어남) + absolute deadline(5s) 안에서 TERM→KILL→reap한다.
    _rb_run() {  # "$@"=명령 — rc 반환. 신호 수신 시 reap·정리·보고 후 여기서 130 종료.
      local _pid _rc=0 _dl
      _RB_PHASE="child"
      set -m
      "$@" &
      _pid=$!
      set +m
      while :; do
        _rc=0
        wait "$_pid" 2>/dev/null || _rc=$?
        if [ -n "$_RB_SIG" ]; then
          # 6라운드 P1(#3): 수명 검사는 leader PID가 아니라 "프로세스 그룹" —
          # leader만 죽고 TERM 무시 자손이 남는 재현이 확인됐다.
          _dl=$(( $(date +%s) + 5 ))
          kill -s TERM -- "-${_pid}" 2>/dev/null || true
          while kill -0 -- "-${_pid}" 2>/dev/null && [ "$(date +%s)" -lt "$_dl" ]; do sleep 0.25; done
          kill -0 -- "-${_pid}" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
          wait "$_pid" 2>/dev/null || true
          _RB_PHASE="main"
          _rb_cleanup_wt
          _rb_sig_report
          exit 130
        fi
        kill -0 "$_pid" 2>/dev/null || break
      done
      # 6라운드 P1(#3): leader 정상 종료 후 그룹 잔존 자손 — late write 방지를 위해
      # 회수하고, 잔존이 있었다는 사실 자체를 실패(rc=97)로 취급한다 (auto_merge
      # _run_in_group과 동일 계약).
      if kill -0 -- "-${_pid}" 2>/dev/null; then
        kill -TERM -- "-${_pid}" 2>/dev/null || true
        _dl=$(( $(date +%s) + 5 ))
        while kill -0 -- "-${_pid}" 2>/dev/null && [ "$(date +%s)" -lt "$_dl" ]; do sleep 0.25; done
        kill -0 -- "-${_pid}" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
        _RB_PHASE="main"
        return 97
      fi
      _RB_PHASE="main"
      return "$_rc"
    }
    if ! _rb_run git worktree add --detach "$_WT" "$HEAD_OID" >/dev/null 2>&1; then
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 격리 worktree 생성 실패 — 자동 롤백을 중단합니다 (fail-closed)." >&2
      exit 3
    fi

    # 8차 2회 P1(#7): 격리 worktree의 revert도 "저장소의" hook(post-commit 등)을
    # 실행한다 — hook이 만든 외부 커밋이 격리 HEAD에 쌓여 rollback 결과에 포함된
    # 채 rc=0으로 공개됐다 (실측). 롤백은 소유 커밋의 역커밋"만" 만들어야 하므로
    # 이 구간의 git은 hook을 전부 무력화한다 (core.hooksPath를 디렉터리가 아닌
    # 경로로 고정 — 어떤 hook도 발견되지 않는다).
    _rbgit() { git -c core.hooksPath=/dev/null -C "$_WT" "$@"; }

    _rb_failed=""
    _rb_made=0
    _rb_prev="$HEAD_OID"
    for c in $OWNED; do
      case "$ALREADY" in
        *"$c"*)
          echo "ℹ️  ${c} — 이미 되돌려짐 (이전 부분 실행), 건너뜀."
          continue
          ;;
      esac
      # 5라운드 P1(#5): revert도 _rb_run 경유 — TERM을 무시해도 bounded reap.
      if ! _rb_run _rbgit revert --no-edit "$c" >/dev/null 2>&1; then
        _rbgit revert --abort >/dev/null 2>&1 || true  # 격리 index — 파괴 대상 없음
        _rb_failed="$c"
        break
      fi
      # 8라운드 후속 P1(#3) + 재리뷰 P1(#6): 생성 "직후" 커밋별 검증. 개수만 세는
      # 검증은 같은 개수의 임의 커밋 교체를 통과시켰고(8차), patch-id 검증은
      # whitespace 변조('v1' → 'v 1')를 통과시켰다(재리뷰, 실측). 검증 축 두 개:
      #   (1) parent 고정: 생성 커밋의 parent == 직전 검증 커밋 (체인이 한 줄로
      #       고정된다 — 삽입/교체 즉시 탐지)
      #   (2) tree identity: 생성 커밋이 바꾼 경로가 소유 커밋의 경로 집합 안에 있고,
      #       그 경로마다 (mode, blob OID)가 c^와 정확히 일치 (whitespace·mode 변조 탐지)
      _rb_c_new="$(_rbgit rev-parse HEAD 2>/dev/null || true)"
      _rb_c_par="$(_rbgit rev-parse HEAD^ 2>/dev/null || true)"
      if [ -z "$_rb_c_new" ] || [ "$_rb_c_par" != "$_rb_prev" ] \
         || ! _rb_verify_revert "$_rb_c_new" "$_rb_c_par" "$c"; then
        _rb_cleanup_wt
        trap - INT TERM HUP
        echo "❌ ${c}의 revert로 생성된 커밋(${_rb_c_new:-?})이 검증에 실패했습니다 (parent 또는 tree identity 불일치 — 외부 개입 의심) — 공개하지 않았습니다 (fail-closed)." >&2
        echo "   소유 커밋 수동 선별 revert: git revert ${c}" >&2
        exit 3
      fi
      _rb_prev="$_rb_c_new"
      _rb_made=$((_rb_made+1))
    done

    if [ -n "$_rb_failed" ]; then
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ ${_rb_failed} revert 실패(충돌 등) — 격리 worktree에서 중단했습니다. 메인 워크트리·index·HEAD는 변경되지 않았습니다 (all-or-nothing)." >&2
      echo "   소유 커밋 수동 선별 revert (최신 → 과거 순):" >&2
      for c in $OWNED; do
        case "$ALREADY" in *"$c"*) : ;; *) echo "     git revert $c" >&2 ;; esac
      done
      exit 3
    fi
    _NEW="$(git -C "$_WT" rev-parse HEAD)"

    # 체인 종점 고정 (8라운드 후속 P1(#3)): 공개할 _NEW는 "마지막으로 검증한
    # 커밋"과 정확히 같아야 한다. 커밋 object는 content-addressed·불변이므로 이
    # 등식이 성립하면 HEAD_OID.._NEW 전체가 위 루프에서 커밋별로 검증한 그
    # 체인이다 — 루프 이후의 교체·삽입은 여기서 탐지된다.
    if [ "$_NEW" != "$_rb_prev" ]; then
      _rb_save_recovery || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 격리 rollback의 최종 HEAD(${_NEW})가 검증된 체인 종점(${_rb_prev})과 다릅니다 — 외부 개입, 공개하지 않았습니다 (fail-closed)." >&2
      echo "   $(_rb_rref_note)" >&2
      exit 3
    fi
    # 개수 검증은 유지한다 — 체인 검증의 이중 방어 (hook 무력화 포함 삼중).
    _rb_cnt="$(git rev-list --count "${HEAD_OID}..${_NEW}" 2>/dev/null || echo -1)"
    if [ "$_rb_cnt" != "$_rb_made" ]; then
      _rb_save_recovery || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 격리 rollback 결과에 예상 밖 커밋이 있습니다 (revert ${_rb_made}건, 실제 ${_rb_cnt}건 — hook 등 외부 개입) — 공개하지 않았습니다 (fail-closed)." >&2
      echo "   $(_rb_rref_note)" >&2
      exit 3
    fi

    # 공개 전 재검증 — 전부 성립할 때만 ff-only로 원자 공개 (fail-closed):
    #   (1) HEAD가 검증 시점 그대로, (2) 추적 파일 clean(동시 staged/변경 보존 —
    #   같은 경로 포함), (3) post 태그가 해석 시점의 tag object 그대로(태그가 새
    #   cycle로 이동했으면 이 결과는 낡은 것 — 경고가 아니라 거부, 7차 P1-6).
    _rb_publish_fail() {
      _rb_save_recovery || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ $1 — 공개하지 않았습니다 (fail-closed; 메인 워크트리·index 무변경)." >&2
      echo "   $(_rb_rref_note) — 검토 후 수동 병합하거나 재실행하세요." >&2
      exit 3
    }
    # 공개 전 사전 점검 (빠른 실패용 — "판정"은 아래 ref transaction의 CAS다):
    #   여전히 같은 branch 위에 있고, 추적 파일이 clean해야 한다.
    [ "$(git symbolic-ref -q HEAD || true)" = "$HEAD_REF" ] \
      || _rb_publish_fail "검증 후 checkout된 branch가 바뀌었습니다 (${HEAD_REF} → $(git symbolic-ref -q HEAD || echo detached))"
    # 재리뷰 P1(#5): status 실패(rc≠0)는 clean이 아니라 판정 불가 — 공개하지 않는다.
    if ! _rb_st_pre="$(git status --porcelain --untracked-files=no)"; then
      _rb_publish_fail "git status 실패 — 작업트리 상태를 판정할 수 없습니다"
    fi
    [ -z "$_rb_st_pre" ] || _rb_publish_fail "추적 파일에 동시 변경(staged 포함)이 생겼습니다"

    # 8차 2회 P1(#4·#5) → 8라운드 후속 P1(#1): 공개는 "하나의 ref transaction"
    # 이며 checkout 결속까지 그 안에서 검증한다.
    #   #4: 대상은 symbolic HEAD가 아니라 검증 시점에 고정한 구체 branch ref.
    #   #5: branch 갱신(old=HEAD_OID)과 태그 삭제(old=POST_TAGOBJ)를 한
    #       transaction으로 — 하나라도 어긋나면 아무것도 적용되지 않는다.
    #   후속 #1: branch ref CAS만으로는 "같은 OID의 다른 branch로 전환"을 잡지
    #       못했다 — 고정 branch는 rollback되는데 현재 checkout은 다른 branch라
    #       read-tree가 엉뚱한 worktree를 바꿨다 (실측: tracked dirty + rc=0).
    #       symref-verify(HEAD가 여전히 그 branch인지)를 같은 transaction에
    #       포함한다. 구 git(< 2.46, symref-verify 없음)은 transaction 직전
    #       재확인으로 창을 최소화하고, 공개 직후·동기화 직전 결속 재검증이
    #       (아래) 잘못된 worktree 변경을 항상 차단한다.
    # 재리뷰 P1(#5): symref 검증을 ref transaction "안"에 넣는 설계는 Git에서 성립
    # 하지 않는다 — probe는 no-deref가 없어 2.48에서 즉시 실패했고, 이를 고쳐도
    # HEAD symref 검증과 그 referent branch 갱신을 같은 transaction에 넣으면 Git이
    # "multiple updates for HEAD"로 거부한다. 그래서 transaction은 "ref 원자성"만
    # 담당하고(branch CAS + 태그 삭제), checkout 결속은 아래의 별도 계층이 담당한다:
    #   (i)   공개 직전 결속 사전 점검
    #   (ii)  공개 직후 결속 재검증 — 깨졌으면 worktree를 아예 건드리지 않는다
    #   (iii) 동기화 직후 결속 재검증 — 깨졌으면 우리가 만진 worktree를 원상복구한다
    #         (엉뚱한 branch의 worktree를 "지속적으로" 바꾼 채 끝나지 않는다)
    [ "$(git symbolic-ref -q HEAD || true)" = "$HEAD_REF" ] \
      || _rb_publish_fail "검증 후 checkout된 branch가 바뀌었습니다 (${HEAD_REF} → $(git symbolic-ref -q HEAD || echo detached))"
    _rb_txn_ok=1
    git update-ref --stdin >/dev/null 2>&1 <<REF_TXN || _rb_txn_ok=0
start
update ${HEAD_REF} ${_NEW} ${HEAD_OID}
delete refs/tags/${POST_TAG} ${POST_TAGOBJ}
prepare
commit
REF_TXN
    if [ "$_rb_txn_ok" != "1" ]; then
      # 어떤 old-value가 어긋났는지 진단해 보고한다 (모두 무변경 — 원자 거부)
      _rb_tag_now="$(git rev-parse -q --verify "refs/tags/${POST_TAG}" 2>/dev/null || true)"
      _rb_br_now="$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)"
      if [ "$_rb_tag_now" != "$POST_TAGOBJ" ]; then
        _rb_publish_fail "post 태그가 그 사이 변경되었습니다 (CAS 실패 — 낡은 결과를 공개하지 않습니다)"
      elif [ "$_rb_br_now" != "$HEAD_OID" ]; then
        _rb_publish_fail "검증 후 ${HEAD_REF}의 HEAD가 이동했습니다 (CAS 실패 — 그 사이 커밋/reset)"
      else
        _rb_publish_fail "ref transaction 거부 (CAS 실패 — checkout branch 결속 또는 동시 변경)"
      fi
    fi

    # 공개 직후 재검증 (8라운드 후속 P1(#1)): worktree 동기화는 "현재 checkout
    # == 공개한 branch == _NEW"일 때만 수행한다 — 결속이 깨졌으면 다른 branch의
    # worktree를 절대 건드리지 않는다.
    if [ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" != "$HEAD_REF" ] \
       || [ "$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)" != "$_NEW" ] \
       || [ "$(git rev-parse HEAD 2>/dev/null || true)" != "$_NEW" ]; then
      _rb_save_recovery || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ ref 공개는 완료됐지만(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨) 현재 checkout이 공개 branch와 결속되지 않습니다 — worktree를 건드리지 않았습니다. 해당 branch에서 'git status' 확인 후 동기화하세요. $(_rb_rref_note)" >&2
      exit 3
    fi

    # ref 공개 완료(원자). 워크트리·index 동기화는 two-tree merge(read-tree -m -u):
    # 변경 경로만 갱신하고, 로컬 변경과 충돌하면 덮지 않고 실패한다.
    # 8라운드 후속 P1(#5): read-tree child는 별도 프로세스 그룹 — TERM을 무시하는
    # child가 있어도 전달 → bounded 대기 → KILL → reap으로 수명을 소유한다.
    # 공개 후 미동기화 상태는 복구 참조(refs/rollback/<ID>)로 명시한다.
    _RB_PHASE="readtree"
    set -m
    git read-tree -m -u "$HEAD_OID" "$_NEW" 2>/dev/null &
    _rt_pid=$!
    set +m
    _rt_rc=0
    while :; do
      _rt_rc=0
      wait "$_rt_pid" 2>/dev/null || _rt_rc=$?
      if [ -n "$_RB_SIG" ]; then
        kill -s "$_RB_SIG" -- "-${_rt_pid}" 2>/dev/null || true
        _rt_i=0
        # 6라운드 P1(#3): 그룹 기준 수명 검사 (leader-only 금지)
        while kill -0 -- "-${_rt_pid}" 2>/dev/null && [ "$_rt_i" -lt 20 ]; do sleep 0.25; _rt_i=$((_rt_i+1)); done
        if kill -0 -- "-${_rt_pid}" 2>/dev/null; then
          kill -KILL -- "-${_rt_pid}" 2>/dev/null || true
        fi
        wait "$_rt_pid" 2>/dev/null || true
        _rb_cleanup_wt
        trap - INT TERM HUP
        _rb_save_recovery || true
        # 재리뷰 P2: 신호 메시지는 "지금 관측한 tip"을 함께 보고한다 — 공개 시점
        # 값만 단정하지 않는다.
        _rb_cur_now="$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)"
        echo "❌ 신호로 중단됨 — ref 공개는 완료됐고(공개 시점 ${HEAD_REF} = ${_NEW}, 현재 tip ${_rb_cur_now:-?}, ${POST_TAG} 삭제됨) worktree 동기화는 미완일 수 있습니다: 'git status' 확인 후 로컬 변경이 없으면 'git reset --hard HEAD'로 동기화하세요. $(_rb_rref_note)" >&2
        exit 130
      fi
      kill -0 "$_rt_pid" 2>/dev/null || break
    done
    # 6라운드 P1(#3): leader 종료 후 read-tree 그룹 잔존 자손 회수 — 잔존은 실패
    if kill -0 -- "-${_rt_pid}" 2>/dev/null; then
      kill -TERM -- "-${_rt_pid}" 2>/dev/null || true
      _rt_i=0
      while kill -0 -- "-${_rt_pid}" 2>/dev/null && [ "$_rt_i" -lt 20 ]; do sleep 0.25; _rt_i=$((_rt_i+1)); done
      kill -0 -- "-${_rt_pid}" 2>/dev/null && kill -KILL -- "-${_rt_pid}" 2>/dev/null
      _rt_rc=97
    fi
    _RB_PHASE="main"
    if [ "$_rt_rc" -ne 0 ]; then
      _rb_cleanup_wt
      trap - INT TERM HUP
      _rb_save_recovery || true
      echo "❌ ref 공개는 완료됐지만(${HEAD_REF} = ${_NEW}) 워크트리 동기화에 실패했습니다 — 로컬 변경과 충돌. 'git status' 확인 후 수동 동기화(git checkout -- <path>)가 필요합니다. $(_rb_rref_note)" >&2
      exit 3
    fi

    # (iii) 동기화 직후 결속 재검증 (재리뷰 P1(#7) 재수정): read-tree는 "그 시점의
    # ambient HEAD"가 가리키는 worktree에 적용된다. 사전 점검과 read-tree 사이에
    # 다른 branch로 전환되면 그 branch의 worktree/index를 바꾼 뒤에야 탐지된다.
    # 원상복구의 목표는 "지금 checkout된 그 commit의 tree"다 — 역방향
    # read-tree(_NEW→HEAD_OID)는 원 branch의 tree를 적용할 뿐이라, 다른 OID의
    # branch로 전환된 경우 tracked dirty가 남는데도 완료로 보고했다 (실측).
    # 우리가 적용한 two-tree merge(_NEW 기준)를 "현재 HEAD의 tree"로 되돌리고,
    # 되돌린 뒤 그 worktree가 실제로 clean한지까지 확인해서 보고한다.
    if [ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" != "$HEAD_REF" ]; then
      _rb_cur_oid="$(git rev-parse -q --verify HEAD 2>/dev/null || true)"
      _rb_undo_note="worktree 원상복구 실패 — 'git status'로 직접 확인하세요"
      if [ -n "$_rb_cur_oid" ] && git read-tree -m -u "$_NEW" "$_rb_cur_oid" 2>/dev/null; then
        # 복구 주장은 관측으로만 — status 실패/dirty면 완료라고 말하지 않는다.
        if _rb_undo_st="$(git status --porcelain --untracked-files=no 2>/dev/null)" && [ -z "$_rb_undo_st" ]; then
          _rb_undo_note="worktree 원상복구 완료 (현재 HEAD ${_rb_cur_oid} tree 기준)"
        else
          _rb_undo_note="worktree 원상복구를 시도했으나 잔여 변경이 남았습니다 — 'git status'로 직접 확인하세요"
        fi
      fi
      _rb_save_recovery || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 동기화 도중 checkout branch가 바뀌었습니다 (${HEAD_REF} → $(git symbolic-ref -q HEAD 2>/dev/null || echo detached)) — ${_rb_undo_note}. ref 공개는 완료됐습니다(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨): ${HEAD_REF}를 checkout한 뒤 'git status'로 동기화하세요. $(_rb_rref_note)" >&2
      exit 3
    fi
    _rb_cleanup_wt
    if [ "${_RB_WT_CLEAN_OK:-1}" -ne 1 ]; then
      _rb_save_recovery || true
      trap - INT TERM HUP
      echo "❌ 공개(${HEAD_REF} = ${_NEW})는 완료됐지만 격리 worktree 정리에 실패했습니다 — stale 등록이 남았을 수 있습니다: 'git worktree list' 확인 후 'git worktree prune'. 성공으로 보고하지 않습니다. $(_rb_rref_note)" >&2
      exit 3
    fi

    # 선행 실행의 복구 참조 (재리뷰 P1(#8) → 3라운드 P1(#4)): "삭제하지 않는다" —
    # 같은 ID의 선행/동시 실행이 남긴 refs/rollback/<ID>는 그 실행의 복구 증거이며,
    # ancestor 여부와 무관하게 이 실행이 지우면 동시 실행의 증거가 사라질 수 있다.
    # 보존하고 고지만 한다 (수동 정리는 소유자 판단).
    _rb_stale="$(git rev-parse -q --verify "refs/rollback/${ID}" 2>/dev/null || true)"
    if [ -n "$_rb_stale" ]; then
      echo "ℹ️  선행 복구 참조 refs/rollback/${ID}(${_rb_stale})가 있습니다 — 이 실행은 삭제하지 않고 보존합니다. 해당 실행의 복구가 끝났는지 확인 후 수동 삭제하세요." >&2
    fi

    # 종료 직전 최종 검증 (8라운드 후속 P1(#4) + 3라운드 P1(#3) → 4라운드 P1(#5)):
    # 성공 보고의 근거는 "writer lock 아래에서 관측한" ref·checkout·tracked 정합이다.
    #   - 프로토콜 writer는 lock으로 배제된다 — 검증~출력 창의 규약 내 주입은
    #     계약상 불가능하다.
    #   - 프로토콜 밖 raw git 개입은 lock으로도, 어떤 검증 반복으로도 "차단"할 수
    #     없다 (마지막 관측과 exit 사이의 창은 원리적으로 잔존). 이 검증이 보증하는
    #     것은 정확히 "마지막 관측 시점의 정합"이며, 성공 문구도 그 관측값(${_NEW})
    #     만을 주장한다.
    #   - 4라운드 #5: 관측 순서가 악용되지 않도록 tip 재확인을 "마지막"에 둔다 —
    #     종전에는 status가 마지막이라, status 응답과 동시에 주입된 커밋이 어떤
    #     검사에도 걸리지 않았다 (실측). 이제 status "이후" ref·HEAD를 다시 읽는다.
    _rb_final_fail() {
      _rb_save_recovery || true
      trap - INT TERM HUP
      echo "❌ $1 — 공개(${HEAD_REF} = ${_NEW})는 수행됐지만 성공으로 보고하지 않습니다. 'git status'로 상태를 확인하세요. $(_rb_rref_note)" >&2
      exit 3
    }
    _rb_final_verify() {
      [ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" = "$HEAD_REF" ] || return 2
      [ "$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)" = "$_NEW" ] || return 1
      [ "$(git rev-parse HEAD 2>/dev/null || true)" = "$_NEW" ] || return 3
      # 재리뷰 P1(#5): status 실패는 clean이 아니다 — 판정 불가로 실패.
      if ! _rb_fst="$(git status --porcelain --untracked-files=no 2>/dev/null)"; then return 4; fi
      [ -z "$_rb_fst" ] || return 5
      # 4라운드 P1(#5): status가 "마지막 관측"이면 status 응답과 동시에 주입된
      # 커밋이 어떤 검사에도 걸리지 않았다 (실측) — tip 정합을 status "이후"에
      # 한 번 더 재관측한다.
      [ "$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)" = "$_NEW" ] || return 1
      [ "$(git rev-parse HEAD 2>/dev/null || true)" = "$_NEW" ] || return 3
      return 0
    }
    _rb_v=0; _rb_final_verify || _rb_v=$?
    case "$_rb_v" in
      0) : ;;
      1) _rb_final_fail "공개 후 ${HEAD_REF}에 예상 밖 커밋이 있습니다 (대상 ref ≠ 공개 결과)" ;;
      2) _rb_final_fail "checkout branch가 공개 branch와 다릅니다" ;;
      3) _rb_final_fail "HEAD가 공개 결과와 다릅니다" ;;
      4) _rb_final_fail "git status 실패 — 작업트리 상태를 판정할 수 없습니다" ;;
      *) _rb_final_fail "추적 파일이 clean하지 않습니다 (index/worktree 부정합)" ;;
    esac
    echo "rolled back $ID by revert — ${HEAD_REF} = ${_NEW} (owned commits only; history preserved; 미추적 산출물은 보존됨; writer lock 하에 검증됨)"
    trap - INT TERM HUP
    exit 0
  fi

  # 6라운드 P1(#5): reset 경로도 신호·그룹 수명 관리 아래에서 — TERM 무시 자식이
  # parent 종료·lock 해제 후 뒤늦게 파괴적 reset/clean을 실행하지 않는다.
  _RS_SIG=""
  trap '_RS_SIG=TERM' TERM
  trap '_RS_SIG=INT'  INT
  trap '_RS_SIG=HUP'  HUP
  _rs_run() {  # "$@"=명령 — rc 반환(97=그룹 잔존 자손). 신호 시 그룹 reap 후 130 종료.
    local _pid _rc=0 _dl
    set -m
    "$@" &
    _pid=$!
    set +m
    while :; do
      _rc=0
      wait "$_pid" 2>/dev/null || _rc=$?
      if [ -n "$_RS_SIG" ]; then
        _dl=$(( $(date +%s) + 5 ))
        kill -s TERM -- "-${_pid}" 2>/dev/null || true
        while kill -0 -- "-${_pid}" 2>/dev/null && [ "$(date +%s)" -lt "$_dl" ]; do sleep 0.25; done
        kill -0 -- "-${_pid}" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
        wait "$_pid" 2>/dev/null || true
        echo "❌ 신호(${_RS_SIG})로 중단됨 — reset 자식 프로세스 그룹을 정리했습니다. 'git status'로 상태를 확인하세요 (부분 수행 가능)." >&2
        exit 130
      fi
      kill -0 "$_pid" 2>/dev/null || break
    done
    if kill -0 -- "-${_pid}" 2>/dev/null; then
      kill -TERM -- "-${_pid}" 2>/dev/null || true
      _dl=$(( $(date +%s) + 5 ))
      while kill -0 -- "-${_pid}" 2>/dev/null && [ "$(date +%s)" -lt "$_dl" ]; do sleep 0.25; done
      kill -0 -- "-${_pid}" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
      return 97
    fi
    return "$_rc"
  }
  if ! _rs_run git reset --hard "$PRE_OID" >/dev/null; then
    echo "❌ git reset 실패 또는 자식 그룹 잔존 — 중단합니다 (fail-closed). 'git status'로 상태를 확인하세요." >&2
    exit 3
  fi
  # 리뷰 16차 P1-8(5차): quarantine(state/auto_merge.trash.d)은 rollback의
  # clean -fd에서도 살아남아야 한다 — 명시 제외 (.gitignore에도 등재).
  # 4라운드 P1(#6): 이 실행이 쥔 writer lock 산출물도 clean이 지우면 안 된다.
  if ! _rs_run git clean -fd -e "state/auto_merge.trash.d" -e "state/ticket_write.lock.d" -e "state/ticket_write.lock.d.*" >/dev/null; then
    echo "❌ git clean 실패 또는 자식 그룹 잔존 — 중단합니다 (부분 정리 가능성). 'git status'로 상태를 확인하세요." >&2
    exit 3
  fi
  # 사이클 종점 기록은 reset으로 무효화됨 — 해석 시점 OID 고정 CAS로 제거.
  # 5라운드 P1(#6): CAS 삭제 실패(그 사이 태그 이동/재생성)를 무시하면 post 태그가
  # 남은 "부분 rollback"이 rc=0/restored로 위장됐다 — 실패는 실패로 보고한다.
  if [ -n "$POST_TAGOBJ" ]; then
    if ! git update-ref -d "refs/tags/${POST_TAG}" "$POST_TAGOBJ" 2>/dev/null; then
      echo "❌ reset은 수행됐지만 ${POST_TAG} 태그 삭제(CAS)가 실패했습니다 — 태그가 그 사이 변경된 것으로 보입니다 (부분 완료, 성공 아님). 태그 상태를 확인 후 수동 정리하세요: git tag -d ${POST_TAG}" >&2
      exit 3
    fi
  fi
  echo "restored $ID to $TAG"
  exit 0
fi

COMMIT="$(git log --format=%H --grep="^${ID}:" -1 || true)"
if [ -n "$COMMIT" ]; then
  echo "pre-cycle tag not found: $TAG" >&2
  echo "manual rollback command:" >&2
  echo "  git revert $COMMIT" >&2
  exit 1
fi

echo "no rollback target found for $ID" >&2
exit 1
