#!/usr/bin/env bash
# pick_next_ticket.sh — 다음에 처리할 티켓 1개의 경로를 stdout에 출력.
#
# 동적 경로 탐색(JIT). 워터폴 사전 종속성 정의 대신, 현재 시점에서
# (1) 의존성이 모두 done이고 (2) 우선순위가 가장 높고 (3) safe 라벨이 맞는
# 첫 번째 티켓을 고른다.
#
# 사용:
#   ./scripts/pick_next_ticket.sh             # 모든 open 중에서 선택
#   ./scripts/pick_next_ticket.sh --safe-only # safe: true 만
#
# stdout: 티켓 파일 경로 (없으면 빈 문자열, exit 0).
# safe:false skip 메시지도 stdout에 출력될 수 있으므로, 호출자는
# `^docs/tickets/.*\.md$` 라인만 티켓 경로로 해석해야 한다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SAFE_ONLY=0
[ "${1:-}" = "--safe-only" ] && SAFE_ONLY=1

# 프론트매터 필드 추출 (yq가 없는 환경 가정 — awk로 처리)
# inline `# 주석`도 제거한다 (TEMPLATE이 가진 주석이 실제 값에 섞이지 않도록).
field_of() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^---$/ { fm = !fm; next }
    fm && $1 == k":" {
      sub(/^[^:]+:[ \t]*/, "")
      sub(/[ \t]+#.*$/, "")
      gsub(/^[ \t]+|[ \t]+$/, "")
      print
      exit
    }
  ' "$file"
}

# 우선순위 점수: P0=0, P1=1, P2=2, P3=3 (작을수록 먼저)
priority_score() {
  case "$1" in
    P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; P3) echo 3 ;; *) echo 9 ;;
  esac
}

ticket_id_from_path() {
  local base; base=$(basename "$1" .md)
  echo "${base%%-*}"
}

set_status() {
  local file="$1" new_status="$2" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-status.XXXXXX")
  awk -v new_status="$new_status" '
    /^---$/ { fm = !fm; print; next }
    fm && $1 == "status:" {
      print "status: " new_status
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

mark_awaiting_approval() {
  local file="$1" id="$2"
  local status
  status=$(field_of "$file" status || true)
  [ "$status" = "awaiting-approval" ] && return 0

  set_status "$file" "awaiting-approval"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$file"
    if ! git diff --cached --quiet -- "$file"; then
      git commit -m "ralph: mark $id awaiting-approval" >/dev/null
    fi
  fi
}

shopt -s nullglob
candidates=()
for f in docs/tickets/T*.md; do
  [ "$(basename "$f")" = "TEMPLATE.md" ] && continue

  status=$(field_of "$f" status || true)
  # 'open' 만 후보. done/skipped/blocked/awaiting-approval 는 제외.
  [ "$status" = "open" ] || continue

  # Reservation lock(state/reservations/<TXXX>.d)이 잡혀 있으면 다른 워커가 처리 중 → 제외.
  base=$(basename "$f" .md)
  id="${base%%-*}"
  if [ -d "state/reservations/${id}.d" ]; then continue; fi

  safe=$(field_of "$f" safe || true)
  # 리뷰 2차 P1-6: safe는 정확히 'true'|'false'만 허용. 과거에는 "false가 아니면 후보"라서
  # 누락·오타('True', 'yes' 등) 티켓이 승인 게이트 없이 실행됐다 — fail-closed로 제외.
  case "$safe" in
    true) ;;
    false)
      if [ "$SAFE_ONLY" = "1" ]; then
        mark_awaiting_approval "$f" "$id"
        echo "[SKIP] $id — safe:false, 승인 필요. awaiting-approval 상태로 변경됨."
      else
        echo "[SKIP] $id — safe:false, 승인 필요. 명시적 run_loop 호출과 docs/approvals/${id}.md가 필요합니다."
      fi
      continue
      ;;
    *)
      echo "[SKIP] $id — safe 필드 비정상('${safe:-누락}'): 'true'|'false'만 허용. fail-closed로 제외 — 티켓 frontmatter를 고치세요."
      continue
      ;;
  esac
  candidates+=("$f")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  exit 0  # 빈 출력 = 처리할 게 없음
fi

# 의존성 해소된 것만 (depends_on의 모든 티켓이 done이거나 비어있음)
deps_satisfied() {
  local file="$1"
  local deps
  deps=$(awk '
    /^---$/ { fm = !fm; next }
    fm && $1 == "depends_on:" {
      sub(/^[^:]+:[ \t]*/, ""); gsub(/[][]/, ""); print; exit
    }
  ' "$file")
  [ -z "$deps" ] && return 0
  IFS=',' read -ra arr <<< "$deps"
  for dep in "${arr[@]}"; do
    dep=$(echo "$dep" | tr -d '" '"'"' ')
    [ -z "$dep" ] && continue
    if [ ! -f "docs/tickets/DONE/${dep}-"*.md ] 2>/dev/null && \
       ! ls docs/tickets/DONE/${dep}-*.md >/dev/null 2>&1; then
      return 1
    fi
  done
  return 0
}

ready=()
for f in "${candidates[@]}"; do
  if deps_satisfied "$f"; then ready+=("$f"); fi
done

[ "${#ready[@]}" -eq 0 ] && exit 0

# 우선순위 + 파일명으로 정렬
best=""; best_score=999
for f in "${ready[@]}"; do
  p=$(field_of "$f" priority || echo P9)
  s=$(priority_score "$p")
  if [ "$s" -lt "$best_score" ] || { [ "$s" -eq "$best_score" ] && [[ "$f" < "$best" ]]; }; then
    best="$f"; best_score=$s
  fi
done

echo "$best"
