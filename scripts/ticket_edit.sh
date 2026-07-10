#!/usr/bin/env bash
# ticket_edit.sh — ADR-0058: structured, auditable, NON-LLM edits to a ticket's
# ORGANIZATIONAL metadata only (priority, labels). The file is the truth; this
# script is the writer (CLI parity). Mission Control dispatches it via the
# localhost-only `ticket_edit` exec command (T099). A human can run it directly.
#
# HARD GUARD — this script ONLY ever rewrites the `priority` or `labels` line of
# an OPEN ticket's frontmatter. It NEVER touches execution-gating fields
# (safe / status / id / depends_on), NEVER edits DONE tickets, the TEMPLATE, or
# approval markers. priority/labels carry no execution/approval/merge meaning, so
# they are orthogonal to the safe:false gate (ADR-0007).
#
# 사용:
#   ./scripts/ticket_edit.sh set-priority T123 P1
#   ./scripts/ticket_edit.sh set-labels   T123 "ui,autonomy,test"
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

usage() { echo "usage: ticket_edit.sh set-priority <TXXX> <P0|P1|P2|P3> | set-labels <TXXX> \"<csv>\"" >&2; }

action="${1:-}"; id="${2:-}"; value="${3:-}"

case "$id" in
  T[0-9][0-9][0-9]*) : ;;
  *) echo "❌ 잘못된 티켓 id: '${id}' (형식 TXXX)" >&2; exit 2 ;;
esac

# 대상은 docs/tickets/ 의 open 티켓만. DONE/·TEMPLATE·승인 마커는 절대 대상 아님.
shopt -s nullglob
matches=( docs/tickets/"${id}"-*.md )
if [ "${#matches[@]}" -eq 0 ]; then
  echo "❌ open 티켓을 찾을 수 없습니다: ${id} (DONE 티켓·승인 마커는 편집 대상이 아닙니다)" >&2
  exit 2
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "❌ ${id}에 매칭되는 티켓이 여러 개입니다." >&2; exit 2
fi
file="${matches[0]}"

# 리뷰 9차 P1: canonical 경계 — symlink 티켓(외부 파일 연결)은 쓰기 대상이 아니다.
if [ -h "$file" ] || [ ! -f "$file" ]; then
  echo "❌ 티켓이 symlink이거나 regular file이 아닙니다 — 거부 (fail-closed)." >&2
  exit 2
fi
_tdir_real="$(cd "$(dirname "$file")" && pwd -P)"
if [ "$_tdir_real" != "$(pwd -P)/docs/tickets" ]; then
  echo "❌ 티켓 물리 경로가 canonical docs/tickets가 아닙니다 (symlink 디렉터리?) — 거부." >&2
  exit 2
fi

case "$(basename "$file")" in TEMPLATE.md) echo "❌ TEMPLATE은 편집 대상이 아닙니다." >&2; exit 2 ;; esac

fm_field() {  # frontmatter 키 1개 읽기
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $1==k":" { sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$file"
}

# 하드 가드: open 상태만 편집(실행/승인/머지 의미가 있는 다른 상태는 거부).
status="$(fm_field status || true)"
if [ "$status" != "open" ]; then
  echo "❌ ${id} status='${status}' — open 티켓만 메타 편집할 수 있습니다(실행/승인 게이트 보호)." >&2
  exit 3
fi

# frontmatter의 지정 키 1줄만 awk로 치환(본문·다른 키 무변경). 임시파일·unlink 비의존.
rewrite_key() {
  local key="$1" newline="$2" content
  content=$(awk -v key="$key" -v line="$newline" '
    BEGIN { fm=0; done=0 }
    /^---$/ { fm++; print; next }
    (fm==1 && !done && $1==key":") { print line; done=1; next }
    { print }
    END { if (!done) exit 9 }
  ' "$file") || { echo "❌ 프론트매터에 '${key}' 키가 없습니다." >&2; exit 4; }
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

case "$action" in
  set-priority)
    case "$value" in
      P0|P1|P2|P3) : ;;
      *) echo "❌ priority는 P0|P1|P2|P3 중 하나여야 합니다 (받음: '${value}')." >&2; exit 2 ;;
    esac
    old="$(fm_field priority || echo '?')"
    rewrite_key priority "priority: ${value}"
    commit_edit "ticket_edit(${id}): priority ${old}→${value}"
    echo "✏️  ${id} priority ${old}→${value} (단일 감사 커밋, git revert 가역)."
    ;;
  set-labels)
    # csv → 안전 토큰만 허용(영숫자·하이픈·언더스코어). YAML 배열로 직렬화.
    IFS=',' read -r -a raw <<< "${value}"
    arr=()
    for t in "${raw[@]}"; do
      t="$(printf '%s' "$t" | tr -d '[:space:]')"
      [ -z "$t" ] && continue
      case "$t" in
        *[!A-Za-z0-9_-]*) echo "❌ 잘못된 라벨 토큰: '${t}' (영숫자·하이픈·언더스코어만)." >&2; exit 2 ;;
      esac
      arr+=("$t")
    done
    yaml='['
    for i in "${!arr[@]}"; do
      [ "$i" -gt 0 ] && yaml+=", "
      yaml+="\"${arr[$i]}\""
    done
    yaml+=']'
    old="$(fm_field labels || echo '?')"
    rewrite_key labels "labels: ${yaml}"
    commit_edit "ticket_edit(${id}): labels → ${yaml}"
    echo "✏️  ${id} labels → ${yaml} (단일 감사 커밋, git revert 가역)."
    ;;
  *)
    usage; exit 2 ;;
esac
