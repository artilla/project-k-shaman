#!/usr/bin/env bash
# ralph/scripts/report_failures.sh — state/failures.log 파서 및 집계 리포트
#
# TSV 포맷 (T009에서 확정): <ISO8601>\t<TICKET_ID>\t<STAGE>\t<RETRY>\t<MESSAGE>
#
# 사용법:
#   ./ralph/scripts/report_failures.sh              # state/failures.log 요약
#   ./ralph/scripts/report_failures.sh --tail N     # 최근 N개 실패 출력
#   ./ralph/scripts/report_failures.sh --log <path> # 로그 파일 경로 지정

set -euo pipefail

LOG_FILE=""
TAIL_N=""

while [ $# -gt 0 ]; do
  case "$1" in
    --log)
      LOG_FILE="$2"; shift
      ;;
    --tail)
      TAIL_N="$2"; shift
      ;;
    -h|--help)
      sed -n '2,10p' "$0"
      exit 0
      ;;
    *)
      echo "unknown option: $1" >&2
      exit 2
      ;;
  esac
  shift
done

if [ -z "$LOG_FILE" ]; then
  if [ -n "${RALPH_ROOT:-}" ]; then
    LOG_FILE="$RALPH_ROOT/state/failures.log"
  else
    LOG_FILE="state/failures.log"
  fi
fi

# --tail N: 최근 N개 원본 라인만 출력
if [ -n "$TAIL_N" ]; then
  if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
    echo "(no failures)"
    exit 0
  fi
  tail -n "$TAIL_N" "$LOG_FILE"
  exit 0
fi

# 요약 모드
if [ ! -f "$LOG_FILE" ] || [ ! -s "$LOG_FILE" ]; then
  echo "=== failures.log report ==="
  echo "Total failures: 0 (empty)"
  exit 0
fi

awk -F'\t' '
NF == 0 || $0 == "" { next }
NF < 5 {
  malformed++
  next
}
NF >= 5 {
  total++
  stage[$3]++
  ticket[$2]++
}
END {
  print "=== failures.log report ==="
  print "Total failures: " total
  print ""
  print "--- By stage ---"
  for (s in stage) print s ": " stage[s]
  print ""
  print "--- By ticket ---"
  for (t in ticket) print t ": " ticket[t]
  if (malformed > 0) {
    print ""
    print "Malformed lines: " malformed
  }
}
' "$LOG_FILE"
