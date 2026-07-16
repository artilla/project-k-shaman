#!/usr/bin/env bash
# set_mode.sh <mode> — ADR-0054: declaratively set the loop autonomy mode by
# writing state/loop_mode (file = the single source of truth). The running loop
# re-reads it at the next cycle boundary (never mid-ticket). CLI parity: a human
# can run this directly, or Mission Control dispatches it via the localhost-only
# `set_mode` exec command (T099 — non-localhost is approve-only).
#
# v1 accepts only `suggest` and `co-pilot`. Loosening into `autopilot` (queue-
# draining, minimal human-in-loop) is intentionally NOT reachable from this tool
# nor from Mission Control (ADR-0054 §6.3 b) — it stays a deliberate CLI launch
# decision (`run_loop.sh` without --safe-only), a separate future decision for MC.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

mode="${1:-}"
case "$mode" in
  suggest|co-pilot) : ;;
  autopilot)
    echo "❌ set_mode: 'autopilot' 진입은 v1에서 제외됩니다 (ADR-0054 §6.3 b)." >&2
    echo "   Autopilot은 별도 결정이며, CLI에서 'run_loop.sh'를 --safe-only 없이 직접 기동해야 합니다." >&2
    exit 2 ;;
  ""|*)
    echo "❌ set_mode: 알 수 없는 모드 '${mode}' (허용: suggest | co-pilot)." >&2
    exit 2 ;;
esac

mkdir -p state
# Declarative single token on line 1 (the loop reads only line 1); line 2 is a
# provenance comment for humans/Insights. Written in place (no unlink) so it is
# safe on restricted mounts; the loop and Mission Control both read line 1.
{
  printf '%s\n' "$mode"
  printf '# set_at=%s by=set_mode.sh\n' "$(date -Iseconds 2>/dev/null || date)"
} > state/loop_mode

echo "🔀 loop_mode='${mode}' 기록 (state/loop_mode). 실행 중 루프는 다음 사이클 경계에서 적용합니다."
