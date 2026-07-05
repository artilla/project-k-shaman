#!/usr/bin/env bash
# ticket_lifecycle.sh — ADR-0060: ORGANIZATIONAL status transitions only, via
# semantic verbs whose from-state guard encodes the allowed-transition whitelist.
# The file is the truth; this script is the writer (CLI parity). Mission Control
# dispatches it via the localhost-only `ticket_lifecycle` exec command (T099).
#
#   cancel <TXXX>   open                 -> skipped   (operator defers/cancels)
#   reopen <TXXX>   skipped | blocked    -> open      (operator retries)
#
# HARD GUARD — there is NO path to write done / awaiting-approval / forging /
# verify. Those execution/approval/merge states belong to the loop and approve.sh
# only. cancel/reopen never create or erase an approval trace: a reopened
# safe:false ticket is gated again by pick_next on the next pick (ADR-0007).
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

usage() { echo "usage: ticket_lifecycle.sh cancel <TXXX> | reopen <TXXX>" >&2; }

action="${1:-}"; id="${2:-}"

case "$id" in
  T[0-9][0-9][0-9]*) : ;;
  *) echo "❌ 잘못된 티켓 id: '${id}' (형식 TXXX)" >&2; exit 2 ;;
esac

# 대상은 docs/tickets/ 의 티켓만. DONE/·TEMPLATE·승인 마커는 절대 대상 아님.
shopt -s nullglob
matches=( docs/tickets/"${id}"-*.md )
if [ "${#matches[@]}" -eq 0 ]; then
  echo "❌ 티켓을 찾을 수 없습니다: ${id} (DONE 티켓·승인 마커는 전이 대상이 아닙니다)" >&2
  exit 2
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "❌ ${id}에 매칭되는 티켓이 여러 개입니다." >&2; exit 2
fi
file="${matches[0]}"
case "$(basename "$file")" in TEMPLATE.md) echo "❌ TEMPLATE은 전이 대상이 아닙니다." >&2; exit 2 ;; esac

fm_field() {
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $1==k":" { sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$file"
}

set_status() {  # status frontmatter 한 줄만 치환(본문·다른 키 무변경). 임시파일·unlink 비의존.
  local newv="$1" content
  content=$(awk -v val="$newv" '
    BEGIN { fm=0; done=0 }
    /^---$/ { fm++; print; next }
    (fm==1 && !done && $1=="status:") { print "status: " val; done=1; next }
    { print }
    END { if (!done) exit 9 }
  ' "$file") || { echo "❌ 프론트매터에 status 키가 없습니다." >&2; exit 4; }
  printf '%s\n' "$content" > "$file"
}

commit_edit() {  # 단일 감사 커밋(가역). git 저장소가 아니면 파일만 갱신.
  local msg="$1"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$file"
    if ! git diff --cached --quiet -- "$file"; then
      git commit -m "$msg" >/dev/null
    fi
  fi
}

cur="$(fm_field status || true)"

case "$action" in
  cancel)
    # from-state 가드: open 만 cancel 가능(실행/승인/머지/종결 상태는 거부).
    if [ "$cur" != "open" ]; then
      echo "❌ cancel은 open 티켓만 가능합니다 (${id} status='${cur}'). 진행 중 중단은 session_ctl abort, 승인은 approve.sh." >&2
      exit 3
    fi
    set_status "skipped"
    commit_edit "ticket_lifecycle(${id}): open→skipped"
    echo "🚫 ${id} open→skipped (취소 — 픽 큐에서 제외, 단일 감사 커밋·git revert 가역)."
    ;;
  reopen)
    # from-state 가드: skipped 또는 blocked 만 reopen 가능.
    case "$cur" in
      skipped|blocked) : ;;
      *) echo "❌ reopen은 skipped/blocked 티켓만 가능합니다 (${id} status='${cur}')." >&2; exit 3 ;;
    esac
    set_status "open"
    commit_edit "ticket_lifecycle(${id}): ${cur}→open"
    echo "↩️  ${id} ${cur}→open (재개 — 픽 큐 복귀. safe:false면 재픽 시 다시 승인 게이트. 감사 커밋·가역)."
    ;;
  *)
    usage; exit 2 ;;
esac
