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

  # 가드 4 (리뷰 16차 P1 재재설계): post 태그는 "시간 경계"일 뿐 소유권 증거가
  # 아니다 — pre~post 사이에 끼어든 무관 커밋(동시 수동 커밋 등)도 범위에 포함되어
  # reset --hard가 함께 파괴했다. 따라서 커밋이 존재하는 범위에는 메인 워크트리에서
  # 비가역 파괴(reset --hard)를 절대 쓰지 않는다:
  #   (a) tag 이후 커밋 없음        → reset 경로 (워크트리/미추적 정리만)
  #   (b) 격리 워크트리(.ralph/wt-*) → reset 경로 (워크트리 전체가 폐기 대상)
  #   (c) 메인 + HEAD == cycle/<ID>-post (기록된 사이클 종점) → git revert 기반
  #       롤백: 범위의 커밋을 역커밋으로 되돌린다. 히스토리가 보존되므로 범위에
  #       무관 커밋이 섞여 있었어도 revert-of-revert로 복구 가능 (비가역 유실 없음).
  #   (d) 그 외 → 거부 + 수동 revert 안내 (fail-closed, --yes 우회 불가)
  POST_TAG="cycle/${ID}-post"
  MODE_ROLLBACK=""
  if [ -z "$(git rev-list -n 1 "${TAG}..HEAD" 2>/dev/null)" ]; then
    MODE_ROLLBACK="reset"
  elif in_isolated_worktree; then
    MODE_ROLLBACK="reset"
  elif git rev-parse -q --verify "refs/tags/${POST_TAG}^{commit}" >/dev/null \
     && [ "$(git rev-parse HEAD)" = "$(git rev-parse "refs/tags/${POST_TAG}^{commit}")" ] \
     && git merge-base --is-ancestor "refs/tags/${TAG}" "refs/tags/${POST_TAG}" 2>/dev/null; then
    MODE_ROLLBACK="revert"
  else
    echo "❌ ${TAG} 이후 커밋들이 기록된 사이클 종점(${POST_TAG})과 일치하지 않습니다 — 자동 롤백을 거부합니다 (--yes 우회 불가):" >&2
    git log --format='%h %s' "${TAG}..HEAD" >&2
    echo "   이 티켓의 변경만 되돌리려면 해당 커밋을 선별 revert 하세요 (최신 → 과거 순):" >&2
    git log --format='   git revert %h  # %s' "${TAG}..HEAD" >&2
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
    # 역순(최신→과거) revert — 충돌 시 전체 중단·원상 복구 (fail-closed).
    if ! git revert --no-commit "${TAG}..HEAD" >/dev/null 2>&1; then
      git revert --abort >/dev/null 2>&1 || git reset --merge >/dev/null 2>&1 || true
      echo "❌ revert 충돌 — 자동 롤백을 중단하고 원상 복구했습니다. 수동으로 선별 revert 하세요:" >&2
      git log --format='   git revert %h  # %s' "${TAG}..HEAD" >&2
      exit 3
    fi
    if git diff --cached --quiet; then
      echo "ℹ️  revert 결과 변경 없음 (이미 되돌려진 상태) — 커밋 생략."
      git reset -q --mixed HEAD >/dev/null 2>&1 || true
    else
      git commit -q -m "rollback(${ID}): revert ${TAG}..${POST_TAG}"
    fi
    git tag -d "$POST_TAG" >/dev/null 2>&1 || true
    echo "rolled back $ID by revert (history preserved; 미추적 산출물은 보존됨 — 필요 시 수동 정리)"
    exit 0
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
