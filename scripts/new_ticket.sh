#!/usr/bin/env bash
# new_ticket.sh — ADR-0064: create a NEW ticket. The file is the truth; this
# script is the writer (CLI parity). Mission Control dispatches it via the
# localhost-only `new_ticket` exec command (T099); the optional body arrives on
# STDIN. A human can run it directly.
#
#   new_ticket.sh create --title "..." [--priority P2] [--persona implementer] [--labels "a,b"]   # body on stdin
#
# SAFETY ANCHOR — created tickets are FORCED safe:false. They can never auto-run:
# execution/merge requires a docs/approvals/<T>.md marker (ADR-0007). The operator
# cannot set safe:true here. id is auto-assigned (max+1, collision-free). Other
# frontmatter gating fields are forced; only title/priority/persona/labels/body
# are operator input (validated). Body is rendered escape-first (ADR-0042).
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
MAX_BODY=16384

usage() { echo 'usage: new_ticket.sh create --title "<t>" [--priority P0|P1|P2|P3] [--persona implementer|planner|reviewer|security-reviewer] [--labels "a,b"]   (body on stdin)' >&2; }

[ "${1:-}" = "create" ] || { usage; exit 2; }
shift

title=""; priority="P2"; persona="implementer"; labels_csv=""
while [ $# -gt 0 ]; do
  case "$1" in
    --title)    title="$2"; shift ;;
    --priority) priority="$2"; shift ;;
    --persona)  persona="$2"; shift ;;
    --labels)   labels_csv="$2"; shift ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

# title: 필수·제어문자(개행·탭·DEL 포함) 금지·길이 상한.
# bash 글로브로 제어문자 전 범위를 한 번에 검출(개행 포함 — 줄 단위 grep으론 못 잡음).
[ -n "$title" ] || { echo "❌ --title은 필수입니다." >&2; exit 2; }
case "$title" in
  *[$'\001'-$'\037']*|*$'\177'*) echo "❌ title에 제어문자(개행·탭 등)는 허용되지 않습니다." >&2; exit 2 ;;
esac
[ "${#title}" -le 200 ] || { echo "❌ title이 200자를 초과합니다." >&2; exit 2; }

case "$priority" in P0|P1|P2|P3) : ;; *) echo "❌ priority는 P0|P1|P2|P3 (받음 '$priority')." >&2; exit 2 ;; esac
case "$persona" in implementer|planner|reviewer|security-reviewer) : ;; *) echo "❌ persona는 implementer|planner|reviewer|security-reviewer (받음 '$persona')." >&2; exit 2 ;; esac

# labels csv → 안전 토큰만 → YAML 배열.
labels_yaml='[]'
if [ -n "$labels_csv" ]; then
  IFS=',' read -r -a _raw <<< "$labels_csv"
  _arr=()
  for t in "${_raw[@]}"; do
    t="$(printf '%s' "$t" | tr -d '[:space:]')"
    [ -z "$t" ] && continue
    case "$t" in *[!A-Za-z0-9_-]*) echo "❌ 잘못된 라벨 토큰 '$t' (영숫자·하이픈·언더스코어만)." >&2; exit 2 ;; esac
    _arr+=("$t")
  done
  labels_yaml='['
  for i in "${!_arr[@]}"; do [ "$i" -gt 0 ] && labels_yaml+=", "; labels_yaml+="\"${_arr[$i]}\""; done
  labels_yaml+=']'
fi

# 본문(stdin, 선택) — NUL/크기 가드.
tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-newbody.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
if [ ! -t 0 ]; then cat > "$tmp"; else : > "$tmp"; fi
sz=$(wc -c < "$tmp" | tr -d ' ')
[ "$sz" -le "$MAX_BODY" ] || { echo "❌ 본문이 상한(${MAX_BODY}B)을 초과합니다 (${sz}B)." >&2; exit 2; }
if ! tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then echo "❌ 본문에 NUL 바이트가 있어 거부합니다." >&2; exit 2; fi

# id 자동 할당: docs/tickets/ + DONE/ 의 최대 T<NNN> + 1.
shopt -s nullglob
maxid=0
for f in docs/tickets/T[0-9]*.md docs/tickets/DONE/T[0-9]*.md; do
  n="$(basename "$f" | sed -n 's/^T0*\([0-9][0-9]*\)-.*/\1/p')"
  [ -n "$n" ] && [ "$n" -gt "$maxid" ] && maxid="$n"
done
newnum=$((maxid + 1))
id="$(printf 'T%03d' "$newnum")"

# 슬러그(title → kebab, 안전 문자, 길이 제한). 비면 'ticket'.
# BSD sed는 BRE의 `\+`를 one-or-more로 해석하지 않아 macOS에서 공백이 그대로
# 남았다. ERE(`-E`) + C locale로 GNU/BSD 양쪽에서 동일한 ASCII slug를 만든다.
slug="$(printf '%s' "$title" \
  | LC_ALL=C tr '[:upper:]' '[:lower:]' \
  | LC_ALL=C sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//' \
  | cut -c1-40 \
  | LC_ALL=C sed -E 's/-+$//')"
[ -n "$slug" ] || slug="ticket"
file="docs/tickets/${id}-${slug}.md"
[ -e "$file" ] && { echo "❌ 이미 존재합니다: $file (id 충돌)." >&2; exit 2; }

today="$(date +%Y-%m-%d)"
{
  printf -- '---\n'
  printf 'id: %s\n' "$id"
  printf 'title: %s\n' "$title"
  printf 'status: open\n'
  printf 'safe: false\n'              # 강제 — MC 생성물은 자동 실행 불가(승인 마커 필요).
  printf 'priority: %s\n' "$priority"
  printf 'persona: %s\n' "$persona"
  printf 'estimate: M\n'
  printf 'depends_on: []\n'
  printf 'blocks: []\n'
  printf 'labels: %s\n' "$labels_yaml"
  printf 'created: %s\n' "$today"
  printf 'spec_ref: docs/master-spec.md\n'
  printf -- '---\n\n'
  printf '# %s — %s\n\n' "$id" "$title"
  if [ "$sz" -gt 0 ]; then cat "$tmp"; else printf '## 1. 목표 (한 줄)\n> (작성 필요)\n'; fi
} > "$file"

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$file"
  git commit -m "new_ticket(${id}): ${title}" >/dev/null
fi
echo "🆕 ${id} 생성: ${file} (safe:false 강제 — 실행/merge엔 docs/approvals/${id}.md 승인 마커 필요. 단일 감사 커밋·git revert 가역)."
