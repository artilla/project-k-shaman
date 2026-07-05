#!/usr/bin/env bash
# ticket_body.sh — ADR-0062: freeform, NON-LLM edit of an OPEN ticket's BODY
# (the markdown after the frontmatter). The file is the truth; this script is the
# writer (CLI parity). Mission Control pipes the proposed body to this script's
# STDIN via the localhost-only `ticket_body` exec command (T099) — the server
# never writes the source itself.
#
#   ticket_body.sh set <TXXX>      # new body on stdin
#   ./scripts/ticket_body.sh set T123 < newbody.md   # CLI parity
#
# HARD GUARD — replaces ONLY the body. The frontmatter block (---…---), and thus
# every execution-gating field (safe/status/id/depends_on), is preserved byte for
# byte. Only OPEN tickets; DONE / approval markers / TEMPLATE are refused. Body is
# rendered escape-first (ADR-0042) so it is data, never executed. NUL rejected,
# 16KB cap.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
MAX_BYTES=16384

usage() { echo "usage: ticket_body.sh set <TXXX>   (new body on stdin)" >&2; }

action="${1:-}"; id="${2:-}"
[ "$action" = "set" ] || { usage; exit 2; }
case "$id" in
  T[0-9][0-9][0-9]*) : ;;
  *) echo "❌ 잘못된 티켓 id: '${id}' (형식 TXXX)" >&2; exit 2 ;;
esac

shopt -s nullglob
matches=( docs/tickets/"${id}"-*.md )
if [ "${#matches[@]}" -eq 0 ]; then
  echo "❌ open 티켓을 찾을 수 없습니다: ${id} (DONE·승인 마커는 본문 편집 대상이 아닙니다)" >&2
  exit 2
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "❌ ${id}에 매칭되는 티켓이 여러 개입니다." >&2; exit 2
fi
file="${matches[0]}"
case "$(basename "$file")" in TEMPLATE.md) echo "❌ TEMPLATE은 편집 대상이 아닙니다." >&2; exit 2 ;; esac

# 하드 가드: open 상태만.
status="$(awk '/^---$/{fm++;next} fm==1 && $1=="status:"{sub(/^[^:]+:[ \t]*/,"");sub(/[ \t]+#.*$/,"");gsub(/^[ \t]+|[ \t]+$/,"");print;exit}' "$file")"
if [ "$status" != "open" ]; then
  echo "❌ ${id} status='${status}' — open 티켓만 본문 편집할 수 있습니다(실행/승인 게이트 보호)." >&2
  exit 3
fi

# 프론트매터 블록의 끝(2번째 ---) 라인 번호. 없으면 거부(프론트매터 무결성).
fm_end="$(awk '/^---$/{c++; if(c==2){print NR; exit}}' "$file")"
[ -n "$fm_end" ] || { echo "❌ ${id}에 닫힌 프론트매터 블록(---…---)이 없습니다." >&2; exit 4; }

# stdin → temp (바이트 보존). temp은 일반 tmpfs(마운트 제약 무관).
tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-body.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

sz=$(wc -c < "$tmp" | tr -d ' ')
if [ "$sz" -gt "$MAX_BYTES" ]; then
  echo "❌ 본문이 상한(${MAX_BYTES}B)을 초과합니다 (${sz}B)." >&2; exit 2
fi
# NUL 거부: NUL 제거본과 원본이 다르면 NUL 포함.
if ! tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then
  echo "❌ 본문에 NUL 바이트가 있어 거부합니다." >&2; exit 2
fi

# 프론트매터 블록(1..fm_end) 바이트 보존 + 빈 줄 + 새 본문. in-place 재기록(unlink 비의존).
content="$( head -n "$fm_end" "$file"; printf '\n'; cat "$tmp" )"
printf '%s\n' "$content" > "$file"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$file"
  if ! git diff --cached --quiet -- "$file"; then
    git commit -m "ticket_body(${id}): edit body" >/dev/null
  fi
fi
echo "✏️  ${id} 본문 교체 (${sz}B, 프론트매터 보존·단일 감사 커밋·git revert 가역)."
