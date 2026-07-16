#!/usr/bin/env bash
# snapshot_ls.sh [<doc-path>] — ADR-0094: READ-ONLY inventory of .vN snapshots.
#
# Surfaces what <base>.v<N>.md snapshots exist (count · N values · latest) so the
# accumulation produced by snapshot_doc.sh (ADR-0084) / doc_edit --snapshot
# (ADR-0086) is visible. OBSERVE-ONLY: reads the filesystem and prints — never
# writes, deletes, prunes, or commits. Deletion / retention enforcement is a
# SEPARATE decision (destructive — needs its own ADR + confirmation gate).
#
#   snapshot_ls.sh ralph/docs/runbook.md   → inventory for one base
#   snapshot_ls.sh                   → inventory for every allowlisted base w/ snapshots
#
# Path-safety mirrors snapshot_doc.sh: absolute paths, `..` traversal, snapshots
# themselves (.vN), tickets, ADRs, sub-paths and arbitrary paths are REJECTED.
# Exit 0 on success, 2 on bad argument / rejected path.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

# emit a single base's inventory line (numeric-sorted N, count, latest). Reads only.
inventory_one() {
  local base="$1" f n
  local -a ns=()
  shopt -s nullglob
  for f in "$base".v[0-9]*.md; do
    n="$(basename "$f" | sed -n 's/.*\.v\([0-9][0-9]*\)\.md$/\1/p')"
    [ -n "$n" ] && ns+=("$n")
  done
  shopt -u nullglob
  if [ "${#ns[@]}" -eq 0 ]; then
    printf '%s · 0개 (스냅샷 없음)\n' "$base"
    return 0
  fi
  # numeric sort
  local sorted latest list
  sorted="$(printf '%s\n' "${ns[@]}" | sort -n)"
  latest="$(printf '%s\n' "$sorted" | tail -1)"
  list="$(printf 'v%s,' $sorted)"; list="${list%,}"
  printf '%s · %d개 · %s · 최신 v%s\n' "$base" "${#ns[@]}" "$list" "$latest"
}

# resolve + validate a single doc arg into its base (mirrors snapshot_doc.sh).
resolve_base() {
  local doc="$1"
  case "$doc" in
    /*)    echo "❌ 절대 경로는 인벤토리 대상이 아닙니다: $doc" >&2; exit 2 ;;
    *..*)  echo "❌ 상위 경로(..)는 허용되지 않습니다: $doc" >&2; exit 2 ;;
  esac
  doc="${doc#./}"
  local allowed=0
  case "$doc" in
    docs/master-spec.md|ralph/docs/runbook.md) allowed=1 ;;
    ralph/skills/implementer.md|ralph/skills/planner.md|ralph/skills/reviewer.md|ralph/skills/security-reviewer.md) allowed=1 ;;
    docs/decisions/*|docs/tickets/*) allowed=0 ;;   # ADRs/tickets are not snapshotted here
    docs/*.v[0-9]*.md)               allowed=0 ;;   # never inventory a snapshot itself
    docs/*/*)                        allowed=0 ;;   # only top-level docs/*.md
    docs/*.md)                       allowed=1 ;;   # other top-level governing/operational docs
  esac
  [ "$allowed" = 1 ] || { echo "❌ 허용되지 않은 인벤토리 대상: '${doc}' (지배/운영 문서만 — 티켓·ADR·소스·.vN·하위 경로·임의 경로 거부)." >&2; exit 2; }
  printf '%s' "${doc%.md}"
}

doc="${1:-}"
if [ -n "$doc" ]; then
  base="$(resolve_base "$doc")"
  inventory_one "$base"
  exit 0
fi

# no arg → inventory every allowlisted base that has snapshots (deterministic order).
shopt -s nullglob
bases=()
for f in docs/*.v[0-9]*.md ralph/docs/*.v[0-9]*.md ralph/skills/*.v[0-9]*.md; do
  # strip the .vN.md suffix to recover the base doc path.
  b="$(printf '%s' "$f" | sed -E 's/\.v[0-9]+\.md$//')"
  # only top-level docs/*.md or persona skills (allowlist parity); skip sub-paths
  # other than the persona skills directory.
  case "$b" in
    docs/*/*) continue ;;   # sub-path snapshots (e.g. docs/onboarding/*) are not allowlisted bases
  esac
  doc="${b}.md"
  case "$doc" in
    docs/master-spec.md|ralph/docs/runbook.md|docs/*.md) ok=1 ;;
    ralph/skills/implementer.md|ralph/skills/planner.md|ralph/skills/reviewer.md|ralph/skills/security-reviewer.md) ok=1 ;;
    *) ok=0 ;;
  esac
  [ "$ok" = 1 ] || continue
  bases+=("$b")
done
shopt -u nullglob

if [ "${#bases[@]}" -eq 0 ]; then
  echo "스냅샷 없음 (인벤토리 비어 있음)."
  exit 0
fi
printf '%s\n' "${bases[@]}" | sort -u | while IFS= read -r b; do
  inventory_one "$b"
done
