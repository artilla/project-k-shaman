#!/usr/bin/env bash
# backfill_completed_at.sh — ADR-0048 일회성 git 이력 백필.
#
# 과거 DONE 티켓의 완료 시각을 done-move 커밋 날짜로 **추정**해, 측정값과 분리된
# 별도 필드 `completed_at_est`에 기록한다. 이는 추정값이며 측정(`completed_at`,
# 루프가 ADR-0046로 기록)과 절대 섞이지 않는다.
#
#  - 대상: docs/tickets/DONE/T*.md 중 completed_at·completed_at_est가 둘 다 없는 것.
#  - 측정값(`completed_at`)이 있으면 절대 건드리지 않는다(skip).
#  - done-move 날짜를 도출 못 하면 skip(fail-closed). started_at은 복원 불가 →
#    추정 cycle time은 만들지 않는다(lead/throughput만).
#  - 멱등: 이미 둘 중 하나가 있으면 skip. 재실행 안전.
#  - 사용자가 수동 실행하는 일회성 도구다(루프가 아니다).
#
# 사용:
#   ./ralph/scripts/backfill_completed_at.sh            # 기록 + 1회 커밋
#   ./ralph/scripts/backfill_completed_at.sh --dry-run  # 변경 없이 미리보기

set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] && DRY_RUN=1

# frontmatter에 key가 존재하는가(닫는 --- 전까지)
fm_has() {
  awk -v k="$1" '
    /^---[ \t]*$/ { fm = !fm; next }
    fm && $1 == k":" { found = 1 }
    END { exit !found }
  ' "$2"
}

# 닫는 --- 직전에 key: val 삽입
fm_add() {
  local file="$1" key="$2" val="$3" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/backfill.XXXXXX") || return 1
  awk -v k="$key" -v v="$val" '
    BEGIN { fm = 0 }
    /^---[ \t]*$/ {
      if (fm == 0) { fm = 1; print; next }
      if (fm == 1) { print k ": " v; fm = 2; print; next }
    }
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

written=0; skipped=0; nodate=0
shopt -s nullglob
for f in docs/tickets/DONE/T*.md; do
  if fm_has completed_at "$f" || fm_has completed_at_est "$f"; then
    skipped=$((skipped + 1)); continue
  fi
  d="$(git log --diff-filter=A --format='%aI' -1 -- "$f" 2>/dev/null | head -1)"
  if [ -z "$d" ]; then nodate=$((nodate + 1)); continue; fi
  if [ "$DRY_RUN" = "1" ]; then
    echo "would set: $f → completed_at_est: $d"
    written=$((written + 1)); continue
  fi
  if fm_add "$f" completed_at_est "$d" && git add "$f" 2>/dev/null; then
    written=$((written + 1))
  fi
done

echo "backfill: written=$written  skipped(이미 측정/추정 있음)=$skipped  nodate(done-move 도출 불가)=$nodate"
if [ "$DRY_RUN" = "0" ] && [ "$written" -gt 0 ]; then
  if git commit -m "telemetry(backfill): completed_at_est for $written DONE tickets (ADR-0048, estimated)" >/dev/null 2>&1; then
    echo "✅ committed: ${written}개 추정 completed_at_est 기록"
  else
    echo "⚠️  commit 실패/생략 — git status 확인"
  fi
fi
