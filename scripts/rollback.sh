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
  # 가드 1: 추적 파일 미커밋 변경 → 거부.
  if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
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
  if [ -z "$(git rev-list -n 1 "${PRE_OID}..HEAD" 2>/dev/null)" ]; then
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
      UNTRACKED="$(git clean -nd 2>/dev/null || true)"
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
      if [ "$(git rev-list --parents -n 1 "$c" 2>/dev/null | wc -w | tr -d ' ')" -gt 2 ]; then
        echo "❌ 소유 커밋 ${c}는 merge commit입니다 — 자동 revert 불가, 수동으로 'git revert -m <mainline> ${c}'를 실행하세요 (fail-closed)." >&2
        exit 3
      fi
    done

    # 5차 P1-7(재개 가능성): post 이후의 커밋은 전부 "owned에 대한 우리 역커밋"
    # 이어야 한다 — 그 외(외부 커밋)는 기존대로 거부. 이미 되돌린 OID는 건너뛴다.
    ALREADY=""
    if [ "$POST_OID" != "$HEAD_OID" ]; then
      for c in $(git rev-list "${POST_OID}..HEAD" 2>/dev/null); do
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
          _pid_o="$(git diff "$o" "$o^" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1; exit}' || true)"
          _pid_c="$(git diff "$c^" "$c" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1; exit}' || true)"
          if [ -n "$_pid_o" ] && [ "$_pid_o" = "$_pid_c" ]; then _rvof="$o"; fi
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
    _rb_cleanup_wt() {
      git worktree remove --force "$_WT" >/dev/null 2>&1 || true
      git worktree prune >/dev/null 2>&1 || true
      rm -rf "$_WT_BASE" 2>/dev/null || true
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
    _rb_sig_report() {
      local _cur
      _cur="$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)"
      if [ -n "$_NEW" ] && [ "$_cur" = "$_NEW" ]; then
        git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
        echo "❌ 신호로 중단됨 — ref 공개는 이미 완료됐습니다(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨). index/worktree는 이전 상태일 수 있습니다: 'git status' 확인 후 로컬 변경이 없으면 'git reset --hard HEAD'로 동기화하세요. 복구 참조: refs/rollback/${ID}" >&2
      else
        echo "❌ 신호로 중단됨 — 격리 worktree만 정리했습니다 (메인 워크트리·index·HEAD는 변경되지 않았습니다)." >&2
      fi
    }
    _rb_on_sig() {
      _RB_SIG="$1"
      # read-tree child 실행 중에는 기록만 — 전달·bounded reap은 그 루프가 소유
      [ "$_RB_PHASE" = "readtree" ] && return 0
      _rb_cleanup_wt
      _rb_sig_report
      exit 130
    }
    trap '_rb_on_sig TERM' TERM
    trap '_rb_on_sig INT'  INT
    trap '_rb_on_sig HUP'  HUP
    if ! git worktree add --detach "$_WT" "$HEAD_OID" >/dev/null 2>&1; then
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
      if ! _rbgit revert --no-edit "$c" >/dev/null 2>&1; then
        _rbgit revert --abort >/dev/null 2>&1 || true  # 격리 index — 파괴 대상 없음
        _rb_failed="$c"
        break
      fi
      # 8라운드 후속 P1(#3): 생성 "직후" 커밋별 검증 — 개수만 세는 검증은 정상
      # revert를 같은 개수의 임의 커밋으로 교체해도 통과했다 (실측: 임의 파일과
      # foreign commit이 공개됨). 검증 축 두 개:
      #   (1) parent 고정: 생성 커밋의 parent == 직전 검증 커밋 (체인이 한 줄로
      #       고정된다 — 삽입/교체 즉시 탐지)
      #   (2) patch-id: 생성 커밋의 diff == 소유 커밋의 역방향 diff (stable
      #       patch-id 비교 — 내용이 정확히 "그 revert"임을 증명)
      _rb_c_new="$(_rbgit rev-parse HEAD 2>/dev/null || true)"
      _rb_c_par="$(_rbgit rev-parse HEAD^ 2>/dev/null || true)"
      _pid_own="$(git diff "$c" "$c^" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1; exit}' || true)"
      _pid_new="$(git diff "${_rb_c_new}^" "$_rb_c_new" 2>/dev/null | git patch-id --stable 2>/dev/null | awk '{print $1; exit}' || true)"
      if [ -z "$_rb_c_new" ] || [ "$_rb_c_par" != "$_rb_prev" ] \
         || [ -z "$_pid_own" ] || [ "$_pid_own" != "$_pid_new" ]; then
        _rb_cleanup_wt
        trap - INT TERM HUP
        echo "❌ ${c}의 revert로 생성된 커밋(${_rb_c_new:-?})이 검증에 실패했습니다 (parent 또는 patch-id 불일치 — 외부 개입 의심) — 공개하지 않았습니다 (fail-closed)." >&2
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
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 격리 rollback의 최종 HEAD(${_NEW})가 검증된 체인 종점(${_rb_prev})과 다릅니다 — 외부 개입, 공개하지 않았습니다 (fail-closed)." >&2
      echo "   계산 결과는 refs/rollback/${ID} 에 보존했습니다." >&2
      exit 3
    fi
    # 개수 검증은 유지한다 — 체인 검증의 이중 방어 (hook 무력화 포함 삼중).
    _rb_cnt="$(git rev-list --count "${HEAD_OID}..${_NEW}" 2>/dev/null || echo -1)"
    if [ "$_rb_cnt" != "$_rb_made" ]; then
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ 격리 rollback 결과에 예상 밖 커밋이 있습니다 (revert ${_rb_made}건, 실제 ${_rb_cnt}건 — hook 등 외부 개입) — 공개하지 않았습니다 (fail-closed)." >&2
      echo "   계산 결과는 refs/rollback/${ID} 에 보존했습니다." >&2
      exit 3
    fi

    # 공개 전 재검증 — 전부 성립할 때만 ff-only로 원자 공개 (fail-closed):
    #   (1) HEAD가 검증 시점 그대로, (2) 추적 파일 clean(동시 staged/변경 보존 —
    #   같은 경로 포함), (3) post 태그가 해석 시점의 tag object 그대로(태그가 새
    #   cycle로 이동했으면 이 결과는 낡은 것 — 경고가 아니라 거부, 7차 P1-6).
    _rb_publish_fail() {
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ $1 — 공개하지 않았습니다 (fail-closed; 메인 워크트리·index 무변경)." >&2
      echo "   계산된 롤백 결과는 refs/rollback/${ID} 에 보존했습니다 — 검토 후 수동 병합하거나 재실행하세요." >&2
      exit 3
    }
    # 공개 전 사전 점검 (빠른 실패용 — "판정"은 아래 ref transaction의 CAS다):
    #   여전히 같은 branch 위에 있고, 추적 파일이 clean해야 한다.
    [ "$(git symbolic-ref -q HEAD || true)" = "$HEAD_REF" ] \
      || _rb_publish_fail "검증 후 checkout된 branch가 바뀌었습니다 (${HEAD_REF} → $(git symbolic-ref -q HEAD || echo detached))"
    [ -z "$(git status --porcelain --untracked-files=no)" ] || _rb_publish_fail "추적 파일에 동시 변경(staged 포함)이 생겼습니다"

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
    _rb_symref=1
    if ! _rb_probe_err="$(printf 'start\nsymref-verify HEAD %s\nabort\n' "$HEAD_REF" | LC_ALL=C git update-ref --stdin 2>&1 >/dev/null)"; then
      case "$_rb_probe_err" in
        *"unknown command"*) _rb_symref=0 ;;  # 구 git — fallback (아래 재검증이 방어)
        *) _rb_publish_fail "checkout이 ${HEAD_REF}와 결속되지 않습니다 (symref 검증 실패: ${_rb_probe_err})" ;;
      esac
    fi
    if [ "$_rb_symref" = "1" ]; then
      _rb_txn_ok=1
      git update-ref --stdin >/dev/null 2>&1 <<REF_TXN || _rb_txn_ok=0
start
symref-verify HEAD ${HEAD_REF}
update ${HEAD_REF} ${_NEW} ${HEAD_OID}
delete refs/tags/${POST_TAG} ${POST_TAGOBJ}
prepare
commit
REF_TXN
    else
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
    fi
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
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ ref 공개는 완료됐지만(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨) 현재 checkout이 공개 branch와 결속되지 않습니다 — worktree를 건드리지 않았습니다. 해당 branch에서 'git status' 확인 후 동기화하세요. 복구 참조: refs/rollback/${ID}" >&2
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
        while kill -0 "$_rt_pid" 2>/dev/null && [ "$_rt_i" -lt 20 ]; do sleep 0.25; _rt_i=$((_rt_i+1)); done
        if kill -0 "$_rt_pid" 2>/dev/null; then
          kill -KILL -- "-${_rt_pid}" 2>/dev/null || true
        fi
        wait "$_rt_pid" 2>/dev/null || true
        _rb_cleanup_wt
        trap - INT TERM HUP
        git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
        echo "❌ 신호로 중단됨 — ref 공개는 완료됐고(${HEAD_REF} = ${_NEW}, ${POST_TAG} 삭제됨) worktree 동기화는 미완일 수 있습니다: 'git status' 확인 후 로컬 변경이 없으면 'git reset --hard HEAD'로 동기화하세요. 복구 참조: refs/rollback/${ID}" >&2
        exit 130
      fi
      kill -0 "$_rt_pid" 2>/dev/null || break
    done
    _RB_PHASE="main"
    if [ "$_rt_rc" -ne 0 ]; then
      _rb_cleanup_wt
      trap - INT TERM HUP
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      echo "❌ ref 공개는 완료됐지만(${HEAD_REF} = ${_NEW}) 워크트리 동기화에 실패했습니다 — 로컬 변경과 충돌. 'git status' 확인 후 수동 동기화(git checkout -- <path>)가 필요합니다. 복구 참조: refs/rollback/${ID}" >&2
      exit 3
    fi
    _rb_cleanup_wt

    # 종료 직전 최종 검증 (8라운드 후속 P1(#4)): 성공 보고의 근거는 "지금"의
    # ref·checkout·tracked 정합이다 — 공개 후 끼어든 foreign commit이 있으면
    # 성공 문구를 내지 않고 복구 참조를 삭제하지 않는다 (fail-closed).
    _rb_final_fail() {
      git update-ref "refs/rollback/${ID}" "$_NEW" >/dev/null 2>&1 || true
      trap - INT TERM HUP
      echo "❌ $1 — 공개(${HEAD_REF} = ${_NEW})는 수행됐지만 성공으로 보고하지 않습니다. 'git status'로 상태를 확인하세요. 복구 참조: refs/rollback/${ID}" >&2
      exit 3
    }
    [ "$(git rev-parse -q --verify "$HEAD_REF" 2>/dev/null || true)" = "$_NEW" ] \
      || _rb_final_fail "공개 후 ${HEAD_REF}에 예상 밖 커밋이 있습니다 (대상 ref ≠ 공개 결과)"
    [ "$(git symbolic-ref -q HEAD 2>/dev/null || true)" = "$HEAD_REF" ] \
      || _rb_final_fail "checkout branch가 공개 branch와 다릅니다"
    [ -z "$(git status --porcelain --untracked-files=no)" ] \
      || _rb_final_fail "추적 파일이 clean하지 않습니다 (index/worktree 부정합)"
    trap - INT TERM HUP
    git update-ref -d "refs/rollback/${ID}" >/dev/null 2>&1 || true
    echo "rolled back $ID by revert (owned commits only; history preserved; 미추적 산출물은 보존됨)"
    exit 0
  fi

  git reset --hard "$PRE_OID" >/dev/null
  # 리뷰 16차 P1-8(5차): quarantine(state/auto_merge.trash.d)은 rollback의
  # clean -fd에서도 살아남아야 한다 — 명시 제외 (.gitignore에도 등재).
  git clean -fd -e "state/auto_merge.trash.d" >/dev/null
  # 사이클 종점 기록은 reset으로 무효화됨 — 해석 시점 OID 고정 CAS로 제거.
  if [ -n "$POST_TAGOBJ" ]; then
    git update-ref -d "refs/tags/${POST_TAG}" "$POST_TAGOBJ" >/dev/null 2>&1 || true
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
