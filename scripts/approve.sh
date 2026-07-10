#!/usr/bin/env bash
# approve.sh — create a run_loop-compatible approval marker or reject a ticket.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage:
  scripts/approve.sh <TXXX>
  scripts/approve.sh --reject "reason" <TXXX>
EOF
}

REJECT_REASON=""
ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reject)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REJECT_REASON="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    T*)
      ID="$1"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$ID" ] || { usage >&2; exit 2; }
case "$ID" in
  T[0-9]*) ;;
  *) echo "invalid ticket id: $ID" >&2; exit 2 ;;
esac

shopt -s nullglob
matches=(docs/tickets/"$ID"-*.md)
if [ "${#matches[@]}" -eq 0 ]; then
  echo "ticket not found: $ID" >&2
  exit 1
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "multiple tickets match $ID" >&2
  printf '  %s\n' "${matches[@]}" >&2
  exit 1
fi
TICKET="${matches[0]}"

# 리뷰 9차 P1: canonical 경계 — symlink 티켓에 승인 마커를 만들거나 status를 바꾸지 않는다.
if [ -h "$TICKET" ] || [ ! -f "$TICKET" ]; then
  echo "❌ 티켓이 symlink이거나 regular file이 아닙니다 — 거부 (fail-closed)." >&2
  exit 2
fi
_tdir_real="$(cd "$(dirname "$TICKET")" && pwd -P)"
if [ "$_tdir_real" != "$(pwd -P)/docs/tickets" ]; then
  echo "❌ 티켓 물리 경로가 canonical docs/tickets가 아닙니다 (symlink 디렉터리?) — 거부." >&2
  exit 2
fi


set_status() {
  local file="$1" new_status="$2" tmp ok
  # 리뷰 5차 P1: 교체 전에 frontmatter 유효성을 검증한다 — CRLF 티켓(opener 불일치)은
  # 아무것도 안 바꾸면서 rc=0을 반환했고, `---trailing` closer는 본문 status:까지
  # 변조했다. opener(1행 정확히 ---)·closer(정확히 ---)·status 정확히 1회가 아니면
  # 원본을 건드리지 않고 실패한다.
  ok=$(awk '
    NR == 1 { if ($0 != "---") { print "no"; exit }; next }
    !closed && $0 == "---" { closed = 1; next }
    !closed && substr($0, 1, 7) == "status:" { n++ }
    END { if (closed && n == 1) print "yes"; else print "no" }
  ' "$file")
  if [ "$ok" != "yes" ]; then
    echo "❌ $file: frontmatter가 유효하지 않아 status를 변경할 수 없습니다 (1행 '---' opener, '---' closer, status 정확히 1회 필요 — CRLF 여부도 확인하세요)." >&2
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/approve-status.XXXXXX")
  # 리뷰 3차 P1: 최초 frontmatter 블록만 수정 (본문 `---` 블록의 status: 라인 보호)
  awk -v new_status="$new_status" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && $0 == "---" { fm = 2; print; next }
    fm == 1 && substr($0, 1, 7) == "status:" { print "status: " new_status; next }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

if [ -n "$REJECT_REASON" ]; then
  set_status "$TICKET" "skipped"
  {
    printf '\n## Rejection\n\n'
    printf -- '- rejected_at: "%s"\n' "$(date -Iseconds)"
    printf -- '- reason: "%s"\n' "$REJECT_REASON"
  } >> "$TICKET"
  echo "rejected $ID: $REJECT_REASON"
  exit 0
fi

mkdir -p docs/approvals
MARKER="docs/approvals/${ID}.md"
APPROVER="${RALPH_APPROVED_BY:-}"
if [ -z "$APPROVER" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  APPROVER="$(git config user.name || true)"
fi
APPROVER="${APPROVER:-$(whoami)}"

# ADR-0037 §3.4: draft scope_confirmation / rollback_plan from the ticket's
# §변경 범위 / §롤백 sections instead of a bare TODO placeholder. The draft is a
# starting point — a human still confirms (the marker is committed and audited).
section_oneline() {
  # $1=file, $2=heading keyword → first ~3 content lines as one compact line.
  # 리뷰 4차 P2: `| head -3`은 긴 섹션에서 head 조기 종료 → awk SIGPIPE(141)로
  # pipefail+set -e 아래 스크립트 전체가 죽었다 — 3줄 제한을 awk 내부에서 처리.
  awk -v kw="$2" '
    /^##[[:space:]]/ { if (inSec) exit; inSec = (index($0, kw) > 0); next }
    inSec {
      line=$0
      gsub(/^[[:space:]]*[-*>][[:space:]]*/, "", line)
      gsub(/^[[:space:]]*\[[ xX]\][[:space:]]*/, "", line)
      gsub(/[`*#]/, "", line)
      gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
      if (line ~ /^```/) next
      if (line ~ /[^[:space:]]/) { print line; if (++n >= 3) exit }
    }
  ' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//'
}
yaml_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-400; }

SCOPE_DRAFT="$(section_oneline "$TICKET" '변경 범위')"
[ -n "$SCOPE_DRAFT" ] || SCOPE_DRAFT="$(section_oneline "$TICKET" 'Scope')"
[ -n "$SCOPE_DRAFT" ] || SCOPE_DRAFT="TODO: confirm exact approved scope for $ID"
ROLLBACK_DRAFT="$(section_oneline "$TICKET" '롤백')"
[ -n "$ROLLBACK_DRAFT" ] || ROLLBACK_DRAFT="$(section_oneline "$TICKET" 'Reversibility')"
[ -n "$ROLLBACK_DRAFT" ] || ROLLBACK_DRAFT="git revert <commit>"

if [ ! -f "$MARKER" ]; then
  cat > "$MARKER" <<EOF
approved_by: "$APPROVER"
approved_at: "$(date -Iseconds)"
scope_confirmation: "$(yaml_escape "$SCOPE_DRAFT")"
rollback_plan: "$(yaml_escape "$ROLLBACK_DRAFT")"
EOF
fi

echo "approval marker ready: $MARKER"
if [ -n "${EDITOR:-}" ]; then
  "$EDITOR" "$MARKER"
else
  echo "EDITOR is not set; edit $MARKER before running run_loop."
fi

# 리뷰 2차 P1-7: 실행기(run_loop)와 동일한 단일 검증기로 마커를 즉시 판정해 안내한다.
# 여기서 ok가 아니면 run_loop도 같은 이유로 거부한다 — 승인 직후 바로 고칠 수 있게 표시.
if command -v node >/dev/null 2>&1 && [ -f "$ROOT/mission-control/approval.mjs" ]; then
  VALIDATION="$(node "$ROOT/mission-control/approval.mjs" "$ROOT" "$ID" 2>&1 || true)"
  echo "validator: $VALIDATION"
  case "$VALIDATION" in
    ok) ;;
    stale*) echo "⚠️  티켓 §변경 범위가 마커와 불일치(stale) — run_loop가 거부합니다. 마커를 삭제 후 재실행하세요." ;;
    malformed*) echo "⚠️  필수 필드 누락(malformed) — run_loop가 거부합니다. $MARKER를 보완하세요." ;;
    unverifiable*) echo "⚠️  scope 검증 불가(unverifiable) — run_loop가 거부합니다. 티켓에 '## 변경 범위' 섹션을 추가하고 마커 scope_confirmation을 맞추세요." ;;
  esac
fi
