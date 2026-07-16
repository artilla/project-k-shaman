#!/usr/bin/env bash
# autopilot_grant.sh — issue / revoke a finite, self-expiring grant that
# authorizes UNATTENDED CONTINUOUS operation (orchestrator --watch). ADR-0056.
#
# IMPORTANT: this grant does NOT authorize safe:false auto-forging. The
# orchestrator never auto-forges safe:false (pick_next_ticket always skips it).
# The grant only authorizes the orchestrator to KEEP draining safe:true tickets
# unattended, bounded by budget (max tickets) and expiry (absolute time). When
# either is exhausted the watch loop stops on its own (default-tightens).
#
# CLI parity: Mission Control (localhost) dispatches this same script via the
# `autopilot_grant`/`autopilot_revoke` exec commands (T099 — localhost only).
#
# 사용:
#   ./ralph/scripts/autopilot_grant.sh issue --budget 1 --expiry-min 30
#   ./ralph/scripts/autopilot_grant.sh revoke
#   ./ralph/scripts/autopilot_grant.sh status
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
GRANT="state/autopilot_grant"

usage() { echo "usage: autopilot_grant.sh issue --budget N --expiry-min M | revoke | status" >&2; }

cmd="${1:-}"; shift || true
case "$cmd" in
  issue)
    budget=1; expiry_min=30
    while [ $# -gt 0 ]; do
      case "$1" in
        --budget)     budget="$2"; shift ;;
        --expiry-min) expiry_min="$2"; shift ;;
        *) echo "unknown arg: $1" >&2; exit 2 ;;
      esac
      shift
    done
    case "$budget" in ''|*[!0-9]*) echo "❌ budget는 양의 정수여야 합니다" >&2; exit 2 ;; esac
    case "$expiry_min" in ''|*[!0-9]*) echo "❌ expiry-min은 양의 정수여야 합니다" >&2; exit 2 ;; esac
    [ "$budget" -ge 1 ] || { echo "❌ budget>=1" >&2; exit 2; }
    [ "$expiry_min" -ge 1 ] || { echo "❌ expiry-min>=1" >&2; exit 2; }
    now=$(date +%s); exp=$((now + expiry_min * 60))
    human=$(date -r "$exp" -Iseconds 2>/dev/null || date -d "@$exp" -Iseconds 2>/dev/null || echo "$exp")
    mkdir -p state
    # epoch expiry → orchestrator/server는 정수 비교만(date 파싱 비의존, 이식성).
    {
      printf 'budget=%s\n' "$budget"
      printf 'expiry_epoch=%s\n' "$exp"
      printf 'issued_by=%s\n' "${AUTOPILOT_GRANT_BY:-cli}"
      printf 'issued_at=%s\n' "$(date -Iseconds 2>/dev/null || date)"
      printf 'expiry_human=%s\n' "$human"
    } > "$GRANT"
    echo "🟢 autopilot grant 발급 — budget=${budget}건, expiry=${expiry_min}분 후(${human})."
    echo "   무인 연속 운영(orchestrator --watch)을 인가합니다. safe:false는 자동 실행되지 않으며 merge/close에는 승인 마커가 계속 필요합니다."
    ;;
  revoke)
    # budget=0으로 무효화(감사 흔적 보존, unlink 비의존).
    {
      printf 'budget=0\n'
      printf 'revoked_at=%s\n' "$(date -Iseconds 2>/dev/null || date)"
    } > "$GRANT"
    echo "🔴 autopilot grant 철회 — 무인 연속 운영 즉시 중단(비상 브레이크)."
    ;;
  status)
    if [ -f "$GRANT" ]; then cat "$GRANT"; else echo "no grant"; fi
    ;;
  *)
    usage; exit 2 ;;
esac
