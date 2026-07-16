#!/usr/bin/env bash
# spec_edit.sh — ADR-0068: edit the MOST governing document, docs/master-spec.md.
# This is a SEPARATE, more-gated path than doc_edit.sh (master-spec is NOT in the
# doc_edit allowlist). The file is the truth; this script is the writer (CLI
# parity). Mission Control pipes the new full content to STDIN via the localhost-
# only `spec_edit` exec command (T099); the server never writes the source itself.
#
#   spec_edit.sh set --reason "<why>"          # new full content on stdin
#   ./ralph/scripts/spec_edit.sh set --reason "..." < new-spec.md   # CLI parity
#
# EXTRA GATES over doc_edit (ADR-0068 §3.2):
#   - --reason REQUIRED (recorded in the audit commit: WHY the governing doc changed)
#   - a version snapshot master-spec.v<N>.md is written before replacing (rollback)
# Plus: full-content replace, escape-first render (ADR-0042), NUL/size/empty reject,
# single audit commit, localhost-only (server side). AUTONOMY: master-spec is NEVER
# written by the loop/orchestrator/grant — this is a human-confirmed action only.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
SPEC="docs/master-spec.md"
MAX_BYTES=262144   # 256KB
MIN_BYTES=64       # master-spec를 빈/거의-빈 파일로 만들지 않도록

usage() { echo 'usage: spec_edit.sh set --reason "<why>"   (content on stdin)' >&2; }

[ "${1:-}" = "set" ] || { usage; exit 2; }
shift
reason=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reason) reason="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# 사유 필수: 비어 있지 않음·제어문자 금지·길이 상한.
[ -n "$reason" ] || { echo "❌ --reason은 필수입니다 (왜 지배 문서를 바꾸는지 기록)." >&2; exit 2; }
case "$reason" in
  *[$'\001'-$'\037']*|*$'\177'*) echo "❌ reason에 제어문자는 허용되지 않습니다." >&2; exit 2 ;;
esac
[ "${#reason}" -le 300 ] || { echo "❌ reason이 300자를 초과합니다." >&2; exit 2; }

[ -f "$SPEC" ] || { echo "❌ $SPEC 가 없습니다." >&2; exit 2; }

# stdin 전체 내용 → temp(바이트 보존).
tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-spec.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

sz=$(wc -c < "$tmp" | tr -d ' ')
[ "$sz" -ge "$MIN_BYTES" ] || { echo "❌ 내용이 너무 짧습니다 (${sz}B < ${MIN_BYTES}B) — master-spec을 빈 파일로 만들 수 없습니다." >&2; exit 2; }
[ "$sz" -le "$MAX_BYTES" ] || { echo "❌ 내용이 상한(${MAX_BYTES}B)을 초과합니다 (${sz}B)." >&2; exit 2; }
if ! tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then echo "❌ 내용에 NUL 바이트가 있어 거부합니다." >&2; exit 2; fi

# 버전 스냅샷: 교체 전 현재 master-spec를 master-spec.v<N>.md로 보존(N = 기존 최대 + 1).
# ADR-0084: next-N 계산·내용 보존 로직을 snapshot_doc.sh로 도구화(동작 동일). 대상
# 문서는 불변(읽기→복사). snapshot_doc.sh가 스냅샷 경로를 stdout으로 반환한다.
SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
snap="$(RALPH_ROOT="$ROOT" bash "$SELF_DIR/snapshot_doc.sh" "$SPEC")"

# 전체 교체(in-place truncate-write, unlink 비의존).
new_content="$(cat "$tmp")"
printf '%s\n' "$new_content" > "$SPEC"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$SPEC" "$snap"
  if ! git diff --cached --quiet -- "$SPEC" "$snap"; then
    git commit -m "spec_edit: ${reason}" >/dev/null
  fi
fi
echo "📜 master-spec 전체 교체 (${sz}B) — 사유: ${reason}. 스냅샷 ${snap} 보존. 단일 감사 커밋·git revert 가역."
