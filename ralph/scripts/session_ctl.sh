#!/usr/bin/env bash
# session_ctl.sh — Live Sessions intervention CLI.
#
# 사용:
#   session_ctl.sh pause  <TXXX>   # STOP 시그널 + 이벤트 기록
#   session_ctl.sh resume <TXXX>   # CONT 시그널 + 이벤트 기록
#   session_ctl.sh abort <TXXX>    # TERM → KILL + reservation 해제
#   session_ctl.sh redirect <TXXX> "<지시>"  # abort + 티켓 지시 append + 재디스패치
#
# 가드 조건:
#   - reservation 디렉터리가 없으면 → nonzero exit
#   - meta의 pgid=unknown 이거나 숫자가 아니면 → 시그널 미전송 + nonzero exit
#   - pause/resume은 timeout_backend=bash-group에서만 허용
#   - abort/redirect는 cycle/<TXXX>-pre 태그가 있어야 실행
#
# 환경 변수:
#   RALPH_STATE_ROOT   state/ 루트 (기본: RALPH_ROOT 또는 pwd)
#   KILL_CMD           kill 명령 override (테스트용, 기본: kill)
#   SESSION_ABORT_GRACE_SECONDS  TERM 후 KILL 전 대기 초 (기본: 5)
#   SESSION_RUN_LOOP_CMD         redirect 재디스패치용 run_loop 경로 override
#   SESSION_REDIRECT_BACKGROUND  redirect 재디스패치 background 여부 (기본: 1)

set -euo pipefail

CMD="${1:-}"
TICKET_ID="${2:-}"
shift 2 2>/dev/null || true
REDIRECT_INSTRUCTION="$*"

usage() {
  echo "Usage: session_ctl.sh pause|resume|abort <TXXX> | session_ctl.sh redirect <TXXX> <instruction>" >&2
  exit 2
}

[ -n "$CMD" ] && [ -n "$TICKET_ID" ] || usage

case "$CMD" in
  pause|resume|abort|redirect) ;;
  *) echo "ERROR: unknown command '$CMD'. Expected pause, resume, abort, or redirect." >&2; usage ;;
esac

if [ "$CMD" = "redirect" ] && [ -z "$REDIRECT_INSTRUCTION" ]; then
  echo "ERROR: redirect requires a non-empty instruction." >&2
  usage
fi

# 티켓 ID 형식 검증
case "$TICKET_ID" in
  T[0-9][0-9][0-9]*)  ;;
  *) echo "ERROR: invalid ticket id '$TICKET_ID'. Expected T[0-9]{3,}." >&2; exit 2 ;;
esac

# state root 결정
if [ -n "${RALPH_STATE_ROOT:-}" ]; then
  STATE_ROOT="$RALPH_STATE_ROOT"
elif [ -n "${RALPH_ROOT:-}" ]; then
  STATE_ROOT="$RALPH_ROOT"
else
  STATE_ROOT="$(pwd)"
fi

RESERVATION_DIR="$STATE_ROOT/state/reservations/${TICKET_ID}.d"
META_FILE="$RESERVATION_DIR/meta"
EVENTS_FILE="$RESERVATION_DIR/events.jsonl"
ABORT_GRACE_SECONDS="${SESSION_ABORT_GRACE_SECONDS:-5}"

# kill 명령 (테스트 시 KILL_CMD로 override 가능)
KILL="${KILL_CMD:-kill}"

# session_events.sh 라이브러리 로드
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -f "$SCRIPT_DIR/lib/session_events.sh" ]; then
  # shellcheck source=./lib/session_events.sh
  . "$SCRIPT_DIR/lib/session_events.sh"
else
  session_event() { return 0; }
fi

# reservation 존재 확인
if [ ! -d "$RESERVATION_DIR" ]; then
  echo "ERROR: reservation not found for $TICKET_ID (expected $RESERVATION_DIR)" >&2
  exit 1
fi

# meta 읽기
if [ ! -f "$META_FILE" ]; then
  echo "ERROR: meta file not found: $META_FILE" >&2
  exit 1
fi

pgid="$(grep '^pgid=' "$META_FILE" | cut -d= -f2- || true)"
timeout_backend="$(grep '^timeout_backend=' "$META_FILE" | cut -d= -f2- || true)"
session_root="$(grep '^root=' "$META_FILE" | cut -d= -f2- || true)"

pgid="${pgid:-unknown}"
timeout_backend="${timeout_backend:-unknown}"
session_root="${session_root:-$STATE_ROOT}"

_reject() {
  local rejected_action="$1"
  echo "ERROR: $CMD rejected for $TICKET_ID — pgid='$pgid' timeout_backend='$timeout_backend'" >&2
  if [ "$CMD" = "pause" ] || [ "$CMD" = "resume" ]; then
    echo "       pause/resume requires pgid!=unknown and timeout_backend=bash-group." >&2
  else
    echo "       abort/redirect requires a reservation-owned numeric pgid." >&2
  fi
  RALPH_STATE_ROOT="$STATE_ROOT" session_event "$TICKET_ID" human "$rejected_action" \
    "pgid=${pgid} backend=${timeout_backend}" 2>/dev/null || true
  exit 1
}

_is_valid_pgid() {
  case "$pgid" in
    unknown|'') return 1 ;;
    *[!0-9]*)   return 1 ;;
  esac
  return 0
}

_require_valid_pgid() {
  if ! _is_valid_pgid; then
    _reject "${CMD}-rejected"
  fi
}

_require_bash_group_backend() {
  if [ "$timeout_backend" != "bash-group" ]; then
    _reject "${CMD}-rejected"
  fi
}

_require_cycle_tag() {
  local tag="cycle/${TICKET_ID}-pre"
  if ! git -C "$session_root" rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
    echo "ERROR: required restore tag not found: ${tag} (root=$session_root)" >&2
    exit 1
  fi
}

_process_group_alive() {
  kill -0 -- "-$pgid" 2>/dev/null
}

_send_group_signal() {
  local signal="$1"
  "$KILL" "-$signal" -- "-$pgid"
}

_restore_hint() {
  echo "restore: git -C \"$session_root\" reset --hard cycle/${TICKET_ID}-pre"
}

_cleanup_hint() {
  case "$session_root" in
    */.ralph/wt-*)
      echo "cleanup: git worktree remove \"$session_root\""
      ;;
  esac
}

_archive_and_release_reservation() {
  RALPH_STATE_ROOT="$STATE_ROOT" archive_session_events "$TICKET_ID" 2>/dev/null || true
  rm -rf "$RESERVATION_DIR"
}

_terminate_session() {
  local action="$1" detail="$2"

  _send_group_signal TERM
  sleep "$ABORT_GRACE_SECONDS"
  if _process_group_alive; then
    _send_group_signal KILL
  fi
  RALPH_STATE_ROOT="$STATE_ROOT" session_event "$TICKET_ID" human "$action" "$detail"
}

_find_ticket_file() {
  local matches=("$session_root"/docs/tickets/"${TICKET_ID}"-*.md)
  if [ ! -e "${matches[0]}" ]; then
    echo "ERROR: ticket file not found in session root: $session_root/docs/tickets/${TICKET_ID}-*.md" >&2
    exit 1
  fi
  printf '%s\n' "${matches[0]}"
}

_append_redirect_instruction() {
  local ticket_file="$1" ts
  ts="$(date -Iseconds)"

  if ! grep -q '^## 운영자 지시$' "$ticket_file"; then
    {
      echo ""
      echo "## 운영자 지시"
    } >> "$ticket_file"
  fi
  printf '\n- %s: %s\n' "$ts" "$REDIRECT_INSTRUCTION" >> "$ticket_file"

  git -C "$session_root" add "$ticket_file"
  git -C "$session_root" commit -m "${TICKET_ID}: operator redirect instruction" >/dev/null
}

_redispatch_ticket() {
  local run_loop_cmd="${SESSION_RUN_LOOP_CMD:-./ralph/scripts/run_loop.sh}"
  local redirect_log="$session_root/.ralph/logs/${TICKET_ID}.redirect.log"

  mkdir -p "$session_root/.ralph/logs"
  if [ "${SESSION_REDIRECT_BACKGROUND:-1}" = "0" ]; then
    (cd "$session_root" && RALPH_KEEP_DIRTY_ON_START=1 "$run_loop_cmd" "$TICKET_ID")
  else
    (
      cd "$session_root"
      RALPH_KEEP_DIRTY_ON_START=1 "$run_loop_cmd" "$TICKET_ID" > "$redirect_log" 2>&1
    ) &
    echo "redispatch: $run_loop_cmd $TICKET_ID"
    echo "redirect-log: $redirect_log"
  fi
}

_require_valid_pgid

# 정상 경로: 시그널 전송 + 이벤트 기록
case "$CMD" in
  pause)
    _require_bash_group_backend
    "$KILL" -STOP -- "-$pgid"
    RALPH_STATE_ROOT="$STATE_ROOT" session_event "$TICKET_ID" human "pause" "pgid=${pgid}"
    echo "⏸  $TICKET_ID paused (pgid=$pgid)"
    ;;
  resume)
    _require_bash_group_backend
    "$KILL" -CONT -- "-$pgid"
    RALPH_STATE_ROOT="$STATE_ROOT" session_event "$TICKET_ID" human "resume" "pgid=${pgid}"
    echo "▶  $TICKET_ID resumed (pgid=$pgid)"
    ;;
  abort)
    _require_cycle_tag
    _terminate_session abort "pgid=${pgid} backend=${timeout_backend}"
    _archive_and_release_reservation
    echo "⏹  $TICKET_ID aborted (pgid=$pgid)"
    _restore_hint
    _cleanup_hint
    ;;
  redirect)
    _require_cycle_tag
    ticket_file="$(_find_ticket_file)"
    _terminate_session abort "redirect pgid=${pgid} backend=${timeout_backend}"
    _append_redirect_instruction "$ticket_file"
    RALPH_STATE_ROOT="$STATE_ROOT" session_event "$TICKET_ID" human "redirect" "$REDIRECT_INSTRUCTION"
    _archive_and_release_reservation
    echo "↻  $TICKET_ID redirected"
    _restore_hint
    _cleanup_hint
    _redispatch_ticket
    ;;
esac
