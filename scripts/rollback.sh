#!/usr/bin/env bash
# rollback.sh — restore a ticket pre-cycle tag or point to the revert command.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  echo "usage: scripts/rollback.sh <TXXX>" >&2
}

[ "$#" -eq 1 ] || { usage; exit 2; }
ID="$1"
case "$ID" in
  T[0-9]*) ;;
  *) echo "invalid ticket id: $ID" >&2; exit 2 ;;
esac

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "not a git repository" >&2
  exit 2
}

TAG="cycle/${ID}-pre"
if git rev-parse -q --verify "refs/tags/${TAG}" >/dev/null; then
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
