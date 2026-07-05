#!/usr/bin/env bash
# doc_edit.sh — ADR-0066: edit an ALLOWLISTED governing operational document
# (runbook / persona playbooks). The file is the truth; this script is the writer
# (CLI parity). Mission Control pipes the new full content to STDIN via the
# localhost-only `doc_edit` exec command (T099); the server never writes the
# source itself.
#
#   doc_edit.sh set <doc-key>          # new full content on stdin
#   ./scripts/doc_edit.sh set runbook < new-runbook.md   # CLI parity
#
# HARD GUARD — doc-key (NOT a raw path) maps to a fixed allowlist. master-spec is
# NOT in the list (ADR-0042 deferred its editing pending a Non-goals amendment),
# so it cannot be reached. Tickets/ADRs/source/approval markers are unreachable —
# no path traversal is expressible. Full-content replace (no partial patch). NUL
# rejected, 256KB cap, empty rejected. Body is rendered escape-first (ADR-0042).
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
MAX_BYTES=262144   # 256KB
MIN_BYTES=16       # 지배 문서를 빈/거의-빈 파일로 만들지 않도록

usage() { echo 'usage: doc_edit.sh set <runbook|skill:implementer|skill:planner|skill:reviewer|skill:security-reviewer> [--snapshot]   (content on stdin)' >&2; }

# doc-key → 고정 경로(allowlist). master-spec·티켓·ADR·소스는 포함하지 않는다.
key_to_path() {
  case "$1" in
    runbook)                 echo "docs/runbook.md" ;;
    skill:implementer)       echo "skills/implementer.md" ;;
    skill:planner)           echo "skills/planner.md" ;;
    skill:reviewer)          echo "skills/reviewer.md" ;;
    skill:security-reviewer) echo "skills/security-reviewer.md" ;;
    *) return 1 ;;
  esac
}

action="${1:-}"; key="${2:-}"
[ "$action" = "set" ] || { usage; exit 2; }

# ADR-0086: optional --snapshot (opt-in). Default unchanged (git-history audit,
# ADR-0066) — only when --snapshot is passed do we preserve a .vN before replace.
do_snapshot=0
shift 2 2>/dev/null || { usage; exit 2; }
while [ $# -gt 0 ]; do
  case "$1" in
    --snapshot) do_snapshot=1 ;;
    *) echo "❌ 알 수 없는 인자: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

file="$(key_to_path "$key")" || { echo "❌ 허용되지 않은 doc-key: '${key}' (master-spec·티켓·ADR·소스·임의 경로는 편집 불가)." >&2; exit 2; }
[ -f "$file" ] || { echo "❌ 대상 문서가 없습니다: $file" >&2; exit 2; }

# stdin 전체 내용 → temp(바이트 보존). temp은 일반 tmpfs(마운트 제약 무관).
tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-doc.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

sz=$(wc -c < "$tmp" | tr -d ' ')
[ "$sz" -ge "$MIN_BYTES" ] || { echo "❌ 내용이 너무 짧습니다 (${sz}B < ${MIN_BYTES}B) — 지배 문서를 빈 파일로 만들 수 없습니다." >&2; exit 2; }
[ "$sz" -le "$MAX_BYTES" ] || { echo "❌ 내용이 상한(${MAX_BYTES}B)을 초과합니다 (${sz}B)." >&2; exit 2; }
if ! tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then echo "❌ 내용에 NUL 바이트가 있어 거부합니다." >&2; exit 2; fi

# ADR-0086: opt-in 버전 스냅샷 — 교체 전 현재 내용을 snapshot_doc.sh로 .vN 보존
# (재사용 도구, 경로 안전 이중 대조). 미선택이면 현행(스냅샷 미생성).
snap=""
if [ "$do_snapshot" = 1 ]; then
  SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  snap="$(RALPH_ROOT="$ROOT" bash "$SELF_DIR/snapshot_doc.sh" "$file")"
fi

# 전체 교체(in-place, 임시→대상 복사). 대상 파일만 truncate-write(unlink 비의존).
content="$(cat "$tmp")"
printf '%s\n' "$content" > "$file"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$file" ${snap:+"$snap"}
  if ! git diff --cached --quiet -- "$file" ${snap:+"$snap"}; then
    git commit -m "doc_edit(${key}): replace ${file}" >/dev/null
  fi
fi
echo "📝 ${key} (${file}) 전체 교체 (${sz}B, 단일 감사 커밋·git revert 가역)${snap:+ · 스냅샷 ${snap} 보존}. master-spec은 편집 대상이 아닙니다."
