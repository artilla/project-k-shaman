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
    # 8차 2회 P1(#6): 공개(ref transaction) "이후"의 신호는 더 이상 "메인 무변경"이
    # 아니다 — HEAD는 새 OID이고 index/worktree만 이전 상태일 수 있다. 공개 여부를
    # 상태로 들고 정확히 보고한다 (거짓 안심 금지).
    _RB_PUBLISHED=0
    _rb_sig_msg() {
      if [ "$_RB_PUBLISHED" = "1" ]; then
        echo "❌ 신호로 중단됨 — ref 공개는 이미 완료됐습니다(${HEAD_REF} = ${_NEW}). index/worktree가 이전 상태로 남았을 수 있습니다: 'git status' 확인 후 'git reset --hard HEAD'(로컬 변경이 없을 때만) 또는 'git checkout -- <path>'로 동기화하세요." >&2
      else
        echo "❌ 신호로 중단됨 — 격리 worktree만 정리했습니다 (메인 워크트리·index·HEAD는 변경되지 않았습니다)." >&2
      fi
    }
    trap '_rb_cleanup_wt; _rb_sig_msg; exit 130' INT TERM HUP
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

    # 결과 검증: 격리 HEAD에 쌓인 커밋 수가 "우리가 만든 revert 수"와 정확히
    # 같아야 한다 — hook·외부 개입이 만든 여분의 커밋이 결과에 섞이면 거부한다
    # (hook 무력화의 이중 방어, fail-closed).
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

    # 8차 2회 P1(#4·#5): 공개는 "하나의 ref transaction"이다.
    #   #4: 대상은 symbolic HEAD가 아니라 검증 시점에 고정한 구체 branch ref —
    #       update-ref HEAD는 실행 시점의 branch를 갱신해, 같은 OID의 다른 branch로
    #       전환하면 엉뚱한 branch를 rollback하고 rc=0을 반환했다 (실측).
    #   #5: 태그 검증(읽기)과 ref 공개가 분리돼 있으면, 그 사이 태그가 새 cycle로
    #       이동해도 낡은 rollback이 먼저 공개되고 태그 삭제만 나중에 실패했다.
    #       branch 갱신(old=HEAD_OID)과 태그 삭제(old=POST_TAGOBJ)를 한 transaction
    #       으로 묶으면, 둘 중 하나라도 old-value가 어긋나면 "아무것도" 적용되지
    #       않는다 — 낡은 결과의 부분 공개가 원리적으로 불가능하다.
    if ! git update-ref --stdin >/dev/null 2>&1 <<REF_TXN
start
update ${HEAD_REF} ${_NEW} ${HEAD_OID}
delete refs/tags/${POST_TAG} ${POST_TAGOBJ}
prepare
commit
REF_TXN
    then
      _rb_publish_fail "ref transaction 실패 — 그 사이 ${HEAD_REF} 또는 ${POST_TAG}가 변경되었습니다 (branch·태그 모두 무변경)"
    fi
    _RB_PUBLISHED=1   # 이 지점부터 "메인 무변경"은 더 이상 사실이 아니다 (#6)

    # ref 공개 완료(원자). 워크트리·index 동기화는 two-tree merge(read-tree -m -u):
    # 변경 경로만 갱신하고, 그 사이 생긴 로컬 변경과 충돌하면 덮지 않고 실패한다
    # (이때 ref는 이미 공개된 상태 — 동기화만 수동 필요, rc≠0으로 보고).
    if ! git read-tree -m -u "$HEAD_OID" "$_NEW" 2>/dev/null; then
      _rb_cleanup_wt
      trap - INT TERM HUP
      echo "❌ ref 공개는 완료됐지만(${HEAD_REF} = ${_NEW}) 워크트리 동기화에 실패했습니다 — 로컬 변경과 충돌. 'git status' 확인 후 수동 동기화(git checkout -- <path>)가 필요합니다." >&2
      exit 3
    fi
    _rb_cleanup_wt
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
