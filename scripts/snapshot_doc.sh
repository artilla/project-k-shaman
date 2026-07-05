#!/usr/bin/env bash
# snapshot_doc.sh <doc-path> — ADR-0084: write <base>.v<N>.md preserving the CURRENT
# content of an allowlisted governing/operational doc (N = max existing + 1).
#
# Reusable .vN snapshot tooling — generalizes the master-spec.vN logic that lived
# inline in spec_edit.sh (ADR-0068). The target doc is UNCHANGED (read → copy). No
# commit: the snapshot rides the doc-edit commit that triggers it.
#
# Path-safe: only governing/operational docs (master-spec, runbook, persona skills,
# top-level docs/*.md). Tickets, ADRs, source, .vN snapshots themselves, arbitrary
# paths and `..`/traversal are REJECTED.
#
#   snapshot_doc.sh docs/master-spec.md   → prints docs/master-spec.v<N>.md
#
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

doc="${1:-}"
[ -n "$doc" ] || { echo "usage: snapshot_doc.sh <doc-path>" >&2; exit 2; }

# reject absolute paths and any parent traversal before normalizing.
case "$doc" in
  /*)    echo "❌ 절대 경로는 스냅샷 대상이 아닙니다: $doc" >&2; exit 2 ;;
  *..*)  echo "❌ 상위 경로(..)는 허용되지 않습니다: $doc" >&2; exit 2 ;;
esac
doc="${doc#./}"

# allowlist: governing/operational docs only.
allowed=0
case "$doc" in
  docs/master-spec.md|docs/runbook.md) allowed=1 ;;
  skills/implementer.md|skills/planner.md|skills/reviewer.md|skills/security-reviewer.md) allowed=1 ;;
  docs/decisions/*|docs/tickets/*) allowed=0 ;;   # ADRs/tickets are not version-snapshotted here
  docs/*.v[0-9]*.md)               allowed=0 ;;   # never snapshot a snapshot
  docs/*/*)                        allowed=0 ;;   # only top-level docs/*.md
  docs/*.md)                       allowed=1 ;;   # other top-level governing/operational docs
esac
[ "$allowed" = 1 ] || { echo "❌ 허용되지 않은 스냅샷 대상: '${doc}' (지배/운영 문서만 — 티켓·ADR·소스·.vN·하위 경로·임의 경로 거부)." >&2; exit 2; }

[ -f "$doc" ] || { echo "❌ 대상 문서가 없습니다: ${doc}" >&2; exit 2; }

# next-N over <base>.v[0-9]*.md (base = doc without the .md suffix).
base="${doc%.md}"
shopt -s nullglob
maxv=0
for f in "$base".v[0-9]*.md; do
  n="$(basename "$f" | sed -n 's/.*\.v\([0-9][0-9]*\)\.md$/\1/p')"
  [ -n "$n" ] && [ "$n" -gt "$maxv" ] && maxv="$n"
done
nextv=$((maxv + 1))
snap="${base}.v${nextv}.md"

# preserve current content (byte-preserving copy, unlink-independent). Target unchanged.
content="$(cat "$doc")"
printf '%s\n' "$content" > "$snap"

echo "$snap"
