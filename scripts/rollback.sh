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

  # 가드 4 (리뷰 16차 P1 재설계): 소유권은 commit subject 문자열이 아니라
  # "기록된 증거"로만 판단한다 — run_loop이 성공 사이클 종점에 남기는
  # cycle/<ID>-post 태그. subject 매칭은 스푸핑("T200: hotfix" 수동 커밋)과
  # 혼입 변경을 own commit으로 오분류해 reset --hard로 함께 파괴했다.
  #   허가 조건 (둘 중 하나, --yes로도 그 외 우회 불가):
  #     (a) tag 이후 커밋이 없음 — 워크트리/미추적 정리만 수행
  #     (b) cycle/<ID>-post가 존재하고, HEAD == post이며, pre가 post의 조상 —
  #         TAG..HEAD 전체가 기록된 "그 사이클"의 산출물임이 증명됨
  #   그 외에는 파괴를 거부하고 revert 경로를 안내한다 (fail-closed).
  POST_TAG="cycle/${ID}-post"
  ALLOW_RESET=0
  if [ -z "$(git rev-list -n 1 "${TAG}..HEAD" 2>/dev/null)" ]; then
    ALLOW_RESET=1
  elif git rev-parse -q --verify "refs/tags/${POST_TAG}^{commit}" >/dev/null \
     && [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/tags/${POST_TAG}^{commit}")" ] \
     && git merge-base --is-ancestor "refs/tags/${TAG}" "refs/tags/${POST_TAG}" 2>/dev/null; then
    ALLOW_RESET=1
  fi
  if [ "$ALLOW_RESET" != "1" ]; then
    echo "❌ ${TAG} 이후 커밋들이 기록된 사이클 종점(${POST_TAG})과 일치하지 않습니다 — reset --hard는 아래 커밋을 전부 파괴하므로 거부합니다 (--yes 우회 불가):" >&2
    git log --format='%h %s' "${TAG}..HEAD" >&2
    echo "   이 티켓의 변경만 되돌리려면 해당 커밋을 선별 revert 하세요 (최신 → 과거 순):" >&2
    git log --format='   git revert %h  # %s' "${TAG}..HEAD" >&2
    exit 3
  fi

  # 가드 2·3: 메인 워크트리는 명시적 확인 필요 (격리 워크트리는 즉시 실행).
  if ! in_isolated_worktree; then
    UNTRACKED="$(git clean -nd 2>/dev/null || true)"
    if [ -n "$UNTRACKED" ]; then
      echo "⚠️  clean -fd로 삭제될 미추적 파일/디렉터리:" >&2
      printf '%s\n' "$UNTRACKED" >&2
    fi
    if [ "$YES" != "1" ]; then
      if [ -t 0 ]; then
        printf '⚠️  메인 워크트리를 %s로 reset --hard + clean -fd 합니다. 계속할까요? [y/N] ' "$TAG" >&2
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

  git reset --hard "$TAG" >/dev/null
  git clean -fd >/dev/null
  # 사이클 종점 기록은 reset으로 무효화됨 — 잔존 post 태그 제거 (오판 방지 위생).
  git tag -d "$POST_TAG" >/dev/null 2>&1 || true
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
