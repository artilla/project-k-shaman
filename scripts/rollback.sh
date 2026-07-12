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

  # 가드 4 (리뷰 16차 P1): reset --hard는 tag 이후의 "모든" 커밋을 파괴한다 —
  # 이 티켓에 속하지 않는 커밋(다른 티켓의 사이클, telemetry, writer 감사 커밋,
  # 수동 커밋)이 tag 이후에 있으면 rollback이 그 변경까지 조용히 유실시킨다.
  # 발견 시 거부하고 revert 경로를 안내한다 (--yes로도 우회 불가, 격리 워크트리
  # 포함 — 격리 워크트리도 티켓 1개 범위를 넘는 파괴는 정당화되지 않는다).
  OWN_RE="^[0-9a-f]+ (${ID}: |telemetry\(${ID}\): |ticket_edit\(${ID}\): )"
  FOREIGN="$(git log --format='%h %s' "${TAG}..HEAD" | grep -Ev "$OWN_RE" || true)"
  if [ -n "$FOREIGN" ]; then
    echo "❌ ${TAG} 이후에 ${ID}에 속하지 않는 커밋이 있습니다 — reset --hard가 이를 파괴합니다:" >&2
    printf '%s\n' "$FOREIGN" >&2
    echo "   이 티켓의 커밋만 선별적으로 되돌리세요 (최신 → 과거 순):" >&2
    git log --format='%h %s' "${TAG}..HEAD" | grep -E "$OWN_RE" | awk '{print "     git revert " $1}' >&2 || true
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
