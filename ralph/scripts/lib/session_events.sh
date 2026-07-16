#!/usr/bin/env bash
# Shared helpers for append-only session event logs under state/reservations.

session_state_root() {
  printf '%s\n' "${RALPH_STATE_ROOT:-${RALPH_ROOT:-$(pwd)}}"
}

session_json_escape() {
  awk 'BEGIN {
    s = ARGV[1]
    ARGV[1] = ""
    gsub(/\\/, "\\\\", s)
    gsub(/"/, "\\\"", s)
    gsub(/\t/, "\\t", s)
    gsub(/\r/, "\\r", s)
    gsub(/\n/, "\\n", s)
    printf "%s", s
  }' "$1"
}

session_event() {
  local id="${1:?session_event <TXXX> <actor> <action> <detail>}"
  local actor="${2:?session_event <TXXX> <actor> <action> <detail>}"
  local action="${3:?session_event <TXXX> <actor> <action> <detail>}"
  local detail="${4:-}"
  local root dir file ts actor_json action_json detail_json

  case "$id" in
    T[0-9][0-9][0-9]*) ;;
    *) echo "ERROR: invalid session id '$id'" >&2; return 2 ;;
  esac
  case "$actor" in
    human|system) ;;
    *) echo "ERROR: invalid session actor '$actor'" >&2; return 2 ;;
  esac

  root="$(session_state_root)"
  dir="$root/state/reservations/${id}.d"
  file="$dir/events.jsonl"

  if [ ! -d "$dir" ]; then
    echo "ERROR: reservation not found: $dir" >&2
    return 1
  fi

  ts="$(date -Iseconds)"
  actor_json="$(session_json_escape "$actor")"
  action_json="$(session_json_escape "$action")"
  detail_json="$(session_json_escape "$detail")"
  printf '{"ts":"%s","actor":"%s","action":"%s","detail":"%s"}\n' \
    "$ts" "$actor_json" "$action_json" "$detail_json" >> "$file"
}

archive_session_events() {
  local id="${1:?archive_session_events <TXXX>}"
  local root dir file archive

  root="$(session_state_root)"
  dir="$root/state/reservations/${id}.d"
  file="$dir/events.jsonl"
  archive="$root/.ralph/logs/${id}.events.jsonl"

  [ -s "$file" ] || return 0
  mkdir -p "$root/.ralph/logs"
  cp "$file" "$archive"
}
