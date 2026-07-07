#!/usr/bin/env bash
# run_loop.sh — Step 2 반자율 Ralph Loop. 1 티켓 = 1 사이클.
#
# 사이클: Pre-flight → Reserve(lock) → Persona dispatch → Verify → 페르소나 commit 검증
#
# 중요한 설계 변경 (이전 버전 대비):
#   - 예약은 git commit이 아니라 state/reservations/<TXXX>.d 디렉터리(원자적 mkdir)로 표현.
#       dry-run·실패 경로 모두 git history를 더럽히지 않는다.
#       페르소나의 단일 commit(status:done + git mv)만이 의미 있는 git 변경.
#   - ROOT 결정: RALPH_ROOT 환경변수 우선(반드시 절대경로) → cwd 기준(`pwd`).
#       orchestrator가 worktree 내부에서 호출했을 때 메인 루트로 튕겨 돌아가지 않는다.
#   - --no-reserve: orchestrator가 이미 lock을 잡은 티켓을 처리할 때 reserve 단계 skip.
#   - 메인 워크트리 보호: 메인에서는 `git reset/checkout` 자동 호출 안 함.
#       isolated worktree(.ralph/wt-*)에서만 자동 폐기 허용.
#
# 사용:
#   ./scripts/run_loop.sh                     # 다음 티켓 자동 선택, 1 사이클
#   ./scripts/run_loop.sh T002-something      # 특정 티켓
#   ./scripts/run_loop.sh --safe-only         # safe: true 만
#   ./scripts/run_loop.sh --dry-run           # 프롬프트만 출력, git/lock 변경 없음
#   ./scripts/run_loop.sh --count 5           # 최대 5 사이클 연속 실행
#   ./scripts/run_loop.sh T001 --no-reserve   # orchestrator가 이미 lock을 잡은 경우

set -euo pipefail

# ────────── ROOT 결정 ──────────
# RALPH_ROOT 환경변수가 있으면(반드시 절대경로여야 함) 그것을 사용, 없으면 현재 작업 디렉터리.
if [ -n "${RALPH_ROOT:-}" ]; then
  case "$RALPH_ROOT" in
    /*) ROOT="$RALPH_ROOT" ;;
    *)  echo "❌ RALPH_ROOT는 반드시 절대경로여야 합니다 (받은 값: '$RALPH_ROOT')" >&2; exit 2 ;;
  esac
else
  ROOT="$(pwd)"
fi
cd "$ROOT"

SAFE_ONLY=0
DRY_RUN=0
SPECIFIC_TICKET=""
CYCLES=1
NO_RESERVE=0   # orchestrator가 이미 reservation lock을 잡았다면 1로 호출
LOCK_OWNED=0   # ADR-0054: 이 세션이 state/lock을 보유 중인가(런타임 모드 전환 시 안전 판단)

while [ $# -gt 0 ]; do
  case "$1" in
    --safe-only)   SAFE_ONLY=1 ;;
    --dry-run)     DRY_RUN=1 ;;
    --count)       CYCLES="$2"; shift ;;
    --no-reserve)  NO_RESERVE=1 ;;
    -h|--help)     sed -n '2,32p' "$0"; exit 0 ;;
    T*)            SPECIFIC_TICKET="$1" ;;
    *)             echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p state state/reservations .ralph/logs

SESSION_STATE_ROOT="${RALPH_STATE_ROOT:-$ROOT}"
mkdir -p "$SESSION_STATE_ROOT/state/reservations" "$SESSION_STATE_ROOT/.ralph/logs"

if [ -f "$ROOT/scripts/lib/session_events.sh" ]; then
  # shellcheck source=./scripts/lib/session_events.sh
  . "$ROOT/scripts/lib/session_events.sh"
else
  session_event() { return 0; }
  archive_session_events() { return 0; }
fi

DEFAULT_HEADLESS_TIMEOUT_SECONDS=1200
SCALED_HEADLESS_TIMEOUT_SECONDS=2400

# ────────── git 가드 (dry-run에서는 통과) ──────────
GIT_REPO=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && GIT_REPO=1

if [ "$GIT_REPO" = "0" ] && [ "$DRY_RUN" = "0" ]; then
  echo "❌ 이 디렉터리는 git 저장소가 아닙니다. run_loop은 commit/git mv를 사용합니다." >&2
  echo "   현재 ROOT: $ROOT" >&2
  echo "   먼저 다음을 실행하세요:" >&2
  echo "       git init && git add . && git commit -m 'init: Ralph Loop template'" >&2
  echo "   또는 --dry-run으로 프롬프트만 미리 보기 가능합니다." >&2
  exit 2
fi

# ────────── 동시 실행 방지 (이 ROOT의 state/lock만 본다) ──────────
if [ "$DRY_RUN" = "0" ] && [ -f state/lock ]; then
  echo "🔒 state/lock 존재 — 누군가 실행 중이거나, 직전 사이클이 비정상 종료됨." >&2
  echo "   현재 ROOT: $ROOT" >&2
  echo "   확인 후 'rm $ROOT/state/lock' 으로 해제하세요." >&2
  exit 3
fi

# 정리할 reservation id 추적 (trap에서 사용)
OWNED_RESERVATIONS=()
cleanup() {
  rm -f state/lock 2>/dev/null || true
  rm -f state/current_ticket 2>/dev/null || true
  for id in "${OWNED_RESERVATIONS[@]:-}"; do
    if [ -n "$id" ]; then
      archive_session_events "$id" 2>/dev/null || true
      rm -rf "$SESSION_STATE_ROOT/state/reservations/${id}.d" 2>/dev/null || true
    fi
  done
}
trap cleanup EXIT
if [ "$DRY_RUN" = "0" ]; then touch state/lock; LOCK_OWNED=1; fi

add_failure() {
  # add_failure <ticket_id> <stage> <cycle_retry> <message>
  # TSV: <ISO8601>\t<TICKET_ID>\t<STAGE>\t<RETRY_OR_CYCLE>\t<MESSAGE>
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Iseconds)" "${1:-unknown}" "${2:-unknown}" "${3:-0}" "${4:-}" \
    >> state/failures.log
}

# ────────── 진단 번들 저장 ──────────
# save_headless_diagnostics <ticket_id> <stage> <timeout_seconds> [headless_rc]
# stage: idle-exit | no-commit | no-done-move | checks-failed | claude-exec-failed
#
# $RALPH_STATE_ROOT 또는 isolated worktree parent root 아래 state/headless-diagnostics/<id>/<timestamp>/ 에 저장.
# isolated worktree가 삭제되어도 진단 정보가 남도록 stable state root를 사용한다.
# git reset 전에 호출해야 diff가 보존된다.
diagnostics_state_root() {
  if [ -n "${RALPH_STATE_ROOT:-}" ]; then
    printf '%s\n' "$RALPH_STATE_ROOT"
    return 0
  fi

  case "$ROOT" in
    */.ralph/wt-*)
      printf '%s\n' "${ROOT%%/.ralph/wt-*}"
      return 0
      ;;
  esac

  printf '%s\n' "$SESSION_STATE_ROOT"
}

diagnostic_termination_class() {
  local stage="$1" rc="${2:-}"

  case "$stage" in
    idle-exit|no-commit|no-done-move|checks-failed)
      printf '%s\n' "$stage"
      ;;
    claude-exec-failed)
      case "$rc" in
        143)     printf '%s\n' "manual-term" ;;
        124|137) printf '%s\n' "timeout" ;;
        *)       printf '%s\n' "claude-exec-failed" ;;
      esac
      ;;
    *)
      printf '%s\n' "$stage"
      ;;
  esac
}

portable_stat_epoch() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null || return 1
}

portable_stat_size() {
  stat -f '%z' "$1" 2>/dev/null || stat -c '%s' "$1" 2>/dev/null || wc -c < "$1" 2>/dev/null
}

portable_epoch_iso() {
  local epoch="$1"
  date -r "$epoch" '+%Y-%m-%dT%H:%M:%S%z' 2>/dev/null || date -d "@$epoch" -Iseconds 2>/dev/null || printf '%s\n' "$epoch"
}

diagnostic_changed_files() {
  {
    git -C "$ROOT" diff --name-only HEAD 2>/dev/null || true
    git -C "$ROOT" diff --cached --name-only 2>/dev/null || true
    git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null || true
  } | sed '/^$/d' | sort -u
}

write_untracked_file_sizes() {
  local out="$1" file abs size
  : > "$out"
  git -C "$ROOT" ls-files --others --exclude-standard 2>/dev/null | while IFS= read -r file; do
    [ -n "$file" ] || continue
    abs="$ROOT/$file"
    [ -f "$abs" ] || continue
    size="$(portable_stat_size "$abs" | tr -d '[:space:]')"
    printf '%s\t%s\n' "$size" "$file"
  done > "$out"
}

write_changed_file_mtimes() {
  local out="$1" file abs epoch iso size
  : > "$out"
  diagnostic_changed_files | while IFS= read -r file; do
    [ -n "$file" ] || continue
    abs="$ROOT/$file"
    [ -e "$abs" ] || continue
    epoch="$(portable_stat_epoch "$abs" 2>/dev/null || true)"
    [ -n "$epoch" ] || continue
    iso="$(portable_epoch_iso "$epoch")"
    size="$(portable_stat_size "$abs" | tr -d '[:space:]')"
    printf '%s\t%s\t%s\n' "$iso" "$size" "$file"
  done > "$out"
}

last_worktree_change_at() {
  local file abs epoch latest=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    abs="$ROOT/$file"
    [ -e "$abs" ] || continue
    epoch="$(portable_stat_epoch "$abs" 2>/dev/null || true)"
    [ -n "$epoch" ] || continue
    if [ -z "$latest" ] || [ "$epoch" -gt "$latest" ]; then
      latest="$epoch"
    fi
  done <<EOF
$(diagnostic_changed_files)
EOF

  if [ -n "$latest" ]; then
    portable_epoch_iso "$latest"
  else
    printf '%s\n' "none"
  fi
}

save_headless_diagnostics() {
  local id="$1" stage="$2" timeout_sec="${3:-unknown}" headless_rc="${4:-}"
  local stable_state_root; stable_state_root="$(diagnostics_state_root)"
  local diag_root="$stable_state_root/state/headless-diagnostics"
  local ts; ts="$(date +%Y%m%dT%H%M%S)"
  local bundle_dir="$diag_root/${id}/${ts}"
  local headless_log="$ROOT/.ralph/logs/${id}.log"
  local reservation_dir="$SESSION_STATE_ROOT/state/reservations/${id}.d"
  local events_src="$reservation_dir/events.jsonl"
  local meta_src="$reservation_dir/meta"
  local termination_class; termination_class="$(diagnostic_termination_class "$stage" "$headless_rc")"

  mkdir -p "$bundle_dir" || return 0

  # headless log 복사
  if [ -f "$headless_log" ]; then
    cp "$headless_log" "$bundle_dir/headless.log"
  fi

  # events 복사 (있고 비어 있지 않을 때)
  if [ -f "$events_src" ] && [ -s "$events_src" ]; then
    cp "$events_src" "$bundle_dir/events.jsonl"
  fi

  # meta에서 timeout_backend / pgid 읽기
  local timeout_backend="unknown" pgid="unknown"
  if [ -f "$meta_src" ]; then
    timeout_backend="$(awk -F= '/^timeout_backend=/{print $2; exit}' "$meta_src" 2>/dev/null || true)"
    pgid="$(awk -F= '/^pgid=/{print $2; exit}' "$meta_src" 2>/dev/null || true)"
    [ -z "$timeout_backend" ] && timeout_backend="unknown"
    [ -z "$pgid" ]            && pgid="unknown"
  fi

  # git 상태 수집 (reset 전에 호출해야 diff가 유효)
  local git_status="" git_status_porcelain="" git_diff_stat="" git_log3="" last_change_at="none"
  if command -v git >/dev/null 2>&1 && git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git_status="$(git -C "$ROOT" status --short 2>/dev/null || true)"
    git_status_porcelain="$(git -C "$ROOT" status --porcelain=v1 --untracked-files=all 2>/dev/null || true)"
    git_diff_stat="$(git -C "$ROOT" diff --stat HEAD 2>/dev/null || true)"
    git_log3="$(git -C "$ROOT" log --oneline -3 2>/dev/null || true)"
    write_untracked_file_sizes "$bundle_dir/untracked-files.tsv"
    write_changed_file_mtimes "$bundle_dir/changed-files-mtime.tsv"
    last_change_at="$(last_worktree_change_at)"
    printf '%s\n' "$git_status_porcelain" > "$bundle_dir/git-status.porcelain"
  else
    : > "$bundle_dir/untracked-files.tsv"
    : > "$bundle_dir/changed-files-mtime.tsv"
    : > "$bundle_dir/git-status.porcelain"
  fi
  printf '%s\n' "$last_change_at" > "$bundle_dir/worktree-change.txt"

  # status.txt — key=value + git 상태
  {
    printf 'stage=%s\n'            "$stage"
    printf 'termination_class=%s\n' "$termination_class"
    printf 'ticket_id=%s\n'        "$id"
    printf 'headless_rc=%s\n'      "${headless_rc:-unknown}"
    printf 'command=%s\n'          "${CLAUDE_CMD:-claude}"
    printf 'model=%s\n'            "${CLAUDE_MODEL:-sonnet}"
    printf 'permission_mode=%s\n'  "${CLAUDE_PERMISSION_MODE:-bypassPermissions}"
    printf 'timeout_seconds=%s\n'  "$timeout_sec"
    printf 'timeout_backend=%s\n'  "$timeout_backend"
    printf 'pgid=%s\n'             "$pgid"
    printf 'headless_log_path=%s\n' "$headless_log"
    printf 'diagnosed_at=%s\n'     "$(date -Iseconds)"
    printf 'last_worktree_change_at=%s\n' "$last_change_at"
    printf '\n--- git status ---\n'
    printf '%s\n'                  "$git_status"
    printf '\n--- git status --porcelain=v1 --untracked-files=all ---\n'
    printf '%s\n'                  "$git_status_porcelain"
    printf '\n--- git log --oneline -3 ---\n'
    printf '%s\n'                  "$git_log3"
  } > "$bundle_dir/status.txt"

  # diff.stat — git reset 전 WIP 크기 파악 (untracked 크기 요약 포함)
  {
    printf '%s\n' "$git_diff_stat"
    if [ -s "$bundle_dir/untracked-files.tsv" ]; then
      printf '\n--- untracked files (bytes, path) ---\n'
      cat "$bundle_dir/untracked-files.tsv"
    fi
  } > "$bundle_dir/diff.stat"

  # summary.md — 사람이 읽는 요약
  {
    printf '# Headless Diagnostics — %s — %s\n\n' "$id" "$stage"
    printf '**stage**: %s\n'           "$stage"
    printf '**termination_class**: %s\n' "$termination_class"
    printf '**ticket**: %s\n'          "$id"
    printf '**headless_rc**: %s\n'     "${headless_rc:-unknown}"
    printf '**command**: `%s %s --permission-mode %s --model %s`\n' \
      "${CLAUDE_CMD:-claude}" "${CLAUDE_HEADLESS:--p}" \
      "${CLAUDE_PERMISSION_MODE:-bypassPermissions}" "${CLAUDE_MODEL:-sonnet}"
    printf '**timeout_seconds**: %ss\n'  "$timeout_sec"
    printf '**timeout_backend**: %s\n'   "$timeout_backend"
    printf '**pgid**: %s\n'             "$pgid"
    printf '**headless_log**: `%s`\n'   "$headless_log"
    printf '**diagnosed_at**: %s\n\n'   "$(date -Iseconds)"
    printf '**last_worktree_change_at**: %s\n\n' "$last_change_at"
    printf '## git status\n\n```\n%s\n```\n\n'          "$git_status"
    printf '## git status porcelain\n\n```\n%s\n```\n\n' "$git_status_porcelain"
    printf '## git diff --stat\n\n```\n%s\n```\n\n'     "$git_diff_stat"
    printf '## untracked files\n\n```\n'
    cat "$bundle_dir/untracked-files.tsv"
    printf '```\n\n'
    printf '## changed file mtimes\n\n```\n'
    cat "$bundle_dir/changed-files-mtime.tsv"
    printf '```\n\n'
    printf '## git log (last 3)\n\n```\n%s\n```\n'      "$git_log3"
  } > "$bundle_dir/summary.md"

  echo "📦 진단 번들 저장: $bundle_dir"
}

# isolated worktree(.ralph/wt-*) 안에서 실행 중인지
in_isolated_worktree() {
  case "$ROOT" in
    */.ralph/wt-*) return 0 ;;
    *)             return 1 ;;
  esac
}

# 티켓 frontmatter 필드 추출 (inline `# 주석` 제거 포함)
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

# 티켓 ID 추출 ("T001-foo.md" → "T001")
ticket_id_from_path() {
  local base; base=$(basename "$1" .md)
  echo "${base%%-*}"
}

# ADR-0046: frontmatter 필드 추가/갱신 — 닫는 `---` 직전에 삽입(기존 동일 키는 제거).
# 계측 타임스탬프(completed_at/started_at)를 DONE 티켓에 durable하게 남기기 위함.
fm_set_field() {
  local file="$1" key="$2" val="$3" tmp
  tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-fm.XXXXXX") || return 1
  awk -v k="$key" -v v="$val" '
    BEGIN { fm = 0 }
    /^---[ \t]*$/ {
      if (fm == 0) { fm = 1; print; next }
      if (fm == 1) { print k ": " v; fm = 2; print; next }
    }
    fm == 1 && $1 == k":" { next }   # drop existing same key (idempotent)
    { print }
  ' "$file" > "$tmp" && mv "$tmp" "$file"
}

# atomic reservation: mkdir로 검사. 성공: 0, 이미 차지됨: 1
reserve_ticket() {
  local id="$1" mode="${2:-standalone}"
  mkdir -p "$SESSION_STATE_ROOT/state/reservations"
  if mkdir "$SESSION_STATE_ROOT/state/reservations/${id}.d" 2>/dev/null; then
    {
      echo "pid=$$"
      echo "mode=$mode"
      echo "started_at=$(date -Iseconds)"
      echo "root=$ROOT"
      echo "pgid=unknown"
      echo "timeout_backend=unknown"
    } > "$SESSION_STATE_ROOT/state/reservations/${id}.d/meta"
    OWNED_RESERVATIONS+=("$id")
    return 0
  fi
  return 1
}

is_reserved() {
  local id="$1"
  [ -d "$SESSION_STATE_ROOT/state/reservations/${id}.d" ]
}

# 운영 관련 경로 whitelist에 해당하는 git status --porcelain 라인만 출력.
# "XY PATH" 및 "XY ORIG -> DEST" (rename) 형식 모두 처리.
# 출력이 비어 있으면 운영 경로에는 dirty 없음.
_op_dirty_lines() {
  git status --porcelain 2>/dev/null | awk '
    function is_op(p) {
      if (p ~ /^docs\/tickets\//)   return 1
      if (p ~ /^docs\/decisions\//) return 1
      if (p ~ /^docs\/approvals\//) return 1
      if (p == "docs/master-spec.md") return 1
      if (p == "docs/runbook.md")   return 1
      if (p == "README.md")         return 1
      if (p ~ /^scripts\//)         return 1
      if (p ~ /^skills\//)          return 1
      if (p ~ /^tests\//)           return 1
      if (p ~ /^state\//)           return 1
      if (p == ".gitignore")        return 1
      return 0
    }
    {
      rest = substr($0, 4)
      if (index(rest, " -> ") > 0) {
        n = split(rest, parts, " -> ")
        if (is_op(parts[1]) || is_op(parts[2])) print $0
      } else {
        if (is_op(rest)) print $0
      }
    }
  '
}

pick_next_ticket_path() {
  local out line ticket_line=""
  if [ "$SAFE_ONLY" = "1" ]; then
    out=$(./scripts/pick_next_ticket.sh --safe-only)
  else
    out=$(./scripts/pick_next_ticket.sh)
  fi
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    case "$line" in
      docs/tickets/*.md) ticket_line="$line" ;;
      *) echo "$line" >&2 ;;
    esac
  done <<< "$out"
  echo "$ticket_line"
}

approval_field() {
  local file="$1" key="$2"
  awk -v k="$key" '
    /^[A-Za-z_][A-Za-z0-9_]*:/ {
      if ($1 == k":") {
        sub(/^[^:]+:[ \t]*/, "")
        sub(/[ \t]+#.*$/, "")
        gsub(/^[ \t]+|[ \t]+$/, "")
        if ($0 ~ /^".*"$/) { sub(/^"/, ""); sub(/"$/, "") }
        print
        exit
      }
    }
  ' "$file"
}

validate_safe_false_approval() {
  local id="$1" marker="docs/approvals/${id}.md"
  local missing="" approved_by approved_at scope_confirmation rollback_plan

  if [ ! -f "$marker" ]; then
    echo "❌ ${id}는 safe:false. 승인이 필요합니다. ${marker}를 작성하세요."
    return 14
  fi

  approved_by=$(approval_field "$marker" approved_by || true)
  approved_at=$(approval_field "$marker" approved_at || true)
  scope_confirmation=$(approval_field "$marker" scope_confirmation || true)
  rollback_plan=$(approval_field "$marker" rollback_plan || true)

  [ -n "$approved_by" ] || missing="${missing} approved_by"
  [ -n "$approved_at" ] || missing="${missing} approved_at"
  [ -n "$scope_confirmation" ] || missing="${missing} scope_confirmation"
  [ -n "$rollback_plan" ] || missing="${missing} rollback_plan"

  if [ -n "$approved_at" ]; then
    case "$approved_at" in
      ????-??-??T??:??:??Z|????-??-??T??:??:??+??:??|????-??-??T??:??:??-??:??) ;;
      *) missing="${missing} approved_at(ISO8601)" ;;
    esac
  fi

  if [ -n "$missing" ]; then
    echo "❌ ${id} 승인 마커 형식 오류:${missing}. ${marker}를 보완하세요."
    return 14
  fi

  return 0
}

ticket_label_contains() {
  local labels="$1" wanted="$2"
  printf '%s\n' "$labels" \
    | tr '[]",' '    ' \
    | tr -s '[:space:]' '\n' \
    | grep -Fxq "$wanted"
}

headless_timeout_policy() {
  local file="$1" estimate labels label

  if [ -n "${CLAUDE_TIMEOUT_SECONDS:-}" ]; then
    echo "${CLAUDE_TIMEOUT_SECONDS}|operator override: CLAUDE_TIMEOUT_SECONDS"
    return 0
  fi

  estimate=$(field_of "$file" estimate || true)
  labels=$(field_of "$file" labels || true)

  if [ "$estimate" = "L" ]; then
    echo "${SCALED_HEADLESS_TIMEOUT_SECONDS}|ticket estimate:L; default ${DEFAULT_HEADLESS_TIMEOUT_SECONDS}s"
    return 0
  fi

  for label in ui frontend mission-control; do
    if ticket_label_contains "$labels" "$label"; then
      echo "${SCALED_HEADLESS_TIMEOUT_SECONDS}|ticket label:${label}; default ${DEFAULT_HEADLESS_TIMEOUT_SECONDS}s"
      return 0
    fi
  done

  echo "${DEFAULT_HEADLESS_TIMEOUT_SECONDS}|default"
}

# ADR-0054 §3.2: re-read the declarative state/loop_mode at the cycle boundary
# (before picking the next ticket) so a runtime mode switch — Mission Control's
# localhost-only set_mode, or a hand edit (CLI parity) — takes effect on the NEXT
# ticket, never mid-ticket. The loop stays the executor; the file is the truth.
#
# Mapping: suggest → dry-run(미실행 미리보기), co-pilot → safe-only(기본). Absent
# or unknown token → keep the startup flags (fail-safe). `autopilot` is NOT
# reachable via a runtime file switch (ADR-0054 §6.3 b) — entering Autopilot stays
# a deliberate CLI launch (run_loop.sh without --safe-only); the file switch warns
# and keeps the current mode.
#
# Safety: leaving dry-run mid-session needs the concurrency lock. If this session
# never acquired it (started in --dry-run) and another loop holds state/lock, we
# refuse to loosen and stay in dry-run — never steal the lock.
apply_loop_mode() {
  local mode_file="state/loop_mode" mode new_safe new_dry
  [ -f "$mode_file" ] || return 0
  mode=$(head -n1 "$mode_file" 2>/dev/null | tr -d '[:space:]' | tr 'A-Z' 'a-z')
  case "$mode" in
    suggest)          new_safe=1; new_dry=1 ;;
    co-pilot|copilot) new_safe=1; new_dry=0 ;;
    autopilot)
      echo "⚠️  loop_mode='autopilot'는 런타임 전환으로 진입할 수 없습니다(ADR-0054 §6.3 b). 현재 모드 유지 — Autopilot은 CLI 재기동(run_loop.sh, --safe-only 없이)으로만 진입." >&2
      return 0 ;;
    *) return 0 ;;   # unknown/empty token → keep current flags (fail-safe)
  esac
  if [ "$new_dry" = "0" ] && [ "$LOCK_OWNED" = "0" ]; then
    if [ -f state/lock ]; then
      echo "⚠️  loop_mode='${mode}' 요청이나 state/lock을 다른 세션이 보유 — dry-run 유지(락 탈취 금지)." >&2
      return 0
    fi
    touch state/lock && LOCK_OWNED=1
  fi
  if [ "$new_safe" != "$SAFE_ONLY" ] || [ "$new_dry" != "$DRY_RUN" ]; then
    echo "🔀 loop_mode='${mode}' 적용 — safe_only=${new_safe} dry_run=${new_dry} (사이클 경계)"
  fi
  SAFE_ONLY="$new_safe"; DRY_RUN="$new_dry"
}

cycle_one() {
  echo "════════════════════════════════════════════════════════"
  echo "RALPH LOOP — cycle start $(date -Iseconds)  cwd=$ROOT"
  if in_isolated_worktree; then echo "🌲 isolated worktree mode"; fi
  echo "════════════════════════════════════════════════════════"

  # ADR-0054 §3.2: honor a runtime mode switch at this cycle boundary.
  apply_loop_mode

  # ────────── 1. Pre-flight: 워크트리 청결 검사 ──────────
  # dry-run은 git/lock 변경이 없으므로 dirty 검사 자체가 의미 없음 → skip.
  # isolated worktree: 전체 dirty를 폐기 (기존 동작 유지).
  # 메인 워크트리: 운영 관련 경로(_op_dirty_lines)가 dirty일 때만 차단.
  #   비운영 사용자 파일(docs/manyfast-service-analysis.md 등)은 무시.
  if [ "$DRY_RUN" = "0" ] && [ "$GIT_REPO" = "1" ]; then
    if in_isolated_worktree; then
      if [ -n "$(git status --porcelain 2>/dev/null)" ]; then
        if [ "${RALPH_KEEP_DIRTY_ON_START:-0}" = "1" ]; then
          echo "ℹ️  isolated worktree dirty 상태 보존 — redirect 재디스패치"
        else
          echo "ℹ️  isolated worktree에서 dirty 상태 — 자동 폐기 허용"
          git reset --hard HEAD 2>/dev/null || true
          git clean -fd 2>/dev/null || true
        fi
      fi
    else
      if [ -n "$(_op_dirty_lines)" ]; then
        echo "⚠️  메인 워크트리가 dirty 상태입니다. 사용자 변경 보호를 위해 자동 사이클을 시작하지 않습니다."
        echo "   해결: 직접 commit/stash 후 다시 실행하거나, --dry-run으로 프롬프트만 미리 보세요."
        git status --short
        return 4
      fi
    fi
  fi

  # ────────── 2. Pick next ticket ──────────
  local ticket
  if [ -n "$SPECIFIC_TICKET" ]; then
    ticket=$(ls docs/tickets/${SPECIFIC_TICKET}*.md 2>/dev/null | head -1 || true)
  elif [ "$SAFE_ONLY" = "1" ]; then
    ticket=$(pick_next_ticket_path)
  else
    ticket=$(pick_next_ticket_path)
  fi

  if [ -z "$ticket" ]; then
    echo "📭 처리할 open 티켓 없음. 종료."
    return 10
  fi

  echo "🎫 티켓: $ticket"

  local id; id=$(ticket_id_from_path "$ticket")
  local cur_status; cur_status=$(field_of "$ticket" status)
  local safe; safe=$(field_of "$ticket" safe || true)
  if [ "$cur_status" != "open" ]; then
    if [ "$safe" = "false" ] && [ "$cur_status" = "awaiting-approval" ]; then
      :
    else
      echo "⚠️  티켓 status가 'open'이 아님(=$cur_status). 페르소나가 commit한 결과만 의미가 있습니다."
      return 11
    fi
  fi

  local safe_false_note=""
  if [ "$safe" = "false" ]; then
    if ! validate_safe_false_approval "$id"; then
      return 14
    fi
    safe_false_note=$(cat <<EOF

## safe:false 승인 정보
- 이 티켓은 인간 승인을 받은 safe:false 티켓입니다.
- 승인 마커: docs/approvals/${id}.md
- 승인 마커의 Scope/rollback 조건을 벗어나면 즉시 중단하고 BLOCK 처리하세요.
EOF
)
  fi

  if [ "$DRY_RUN" = "0" ] && [ "$GIT_REPO" = "1" ]; then
    git tag -f "cycle/${id}-pre" HEAD >/dev/null
    echo "🏷️  pre-cycle tag: cycle/${id}-pre"
  fi

  # ────────── 3. Reservation (lock 디렉터리) ──────────
  # 중요: --no-reserve 모드에서는 worker-local lock을 검증하지 않는다.
  #       (orchestrator의 lock은 메인 worktree의 state/reservations/ 에 있고,
  #        git worktree는 이 경로를 공유하지 않으므로 worker가 볼 수 없음.)
  #       orchestrator의 책임 분담을 신뢰한다.
  if [ "$DRY_RUN" = "0" ]; then
    if [ "$NO_RESERVE" = "1" ]; then
      echo "🔒 (orchestrator가 책임) lock 검증 skip — --no-reserve 모드"
    else
      if ! reserve_ticket "$id" standalone; then
        echo "⚠️  state/reservations/${id}.d 가 이미 존재 — 다른 워커가 처리 중."
        return 11
      fi
      echo "🔒 reserved: state/reservations/${id}.d"
    fi
    echo "$ticket" > state/current_ticket
  fi
  # dry-run은 state/current_ticket도 쓰지 않음 (P2-C 해결)

  # ────────── 4. Persona 라우팅 ──────────
  local persona; persona=$(field_of "$ticket" persona)
  [ -z "$persona" ] && persona="implementer"

  local skill_file="skills/${persona}.md"
  if [ ! -f "$skill_file" ]; then
    echo "❌ persona '$persona'에 대응하는 $skill_file 없음. 티켓을 다시 확인하세요."
    add_failure "${id:-unknown}" "unknown-persona" "${i:-0}" "persona='$persona'"
    return 12
  fi

  echo "🎭 persona: $persona  skill: $skill_file"

  local timeout_spec timeout_seconds timeout_reason
  timeout_spec=$(headless_timeout_policy "$ticket")
  timeout_seconds="${timeout_spec%%|*}"
  timeout_reason="${timeout_spec#*|}"

  # ────────── 5. Build prompt ──────────
  local persona_specific=""
  case "$persona" in
    implementer)
      persona_specific=$(cat <<'PEOF'
## 추가 의무 (DONE 이동)
구현·테스트가 끝나면, 동일 commit 안에 다음 단계를 반드시 포함하세요:
1. 이 티켓 파일의 frontmatter `status:`를 `done`으로 변경.
2. `git mv docs/tickets/<현재파일> docs/tickets/DONE/<현재파일>` 로 이동.
3. 위 둘과 코드 변경을 한 번에 `git commit -m "TXXX: <한 줄 요약>"` 으로 묶는다.

## 절대 하지 말 것
- master-spec.md 직접 수정 (필요하면 다른 티켓을 만들어 planner에게 위임)
- 메인 브랜치 직접 push
- 비밀키 접근/출력
PEOF
)
      ;;
    planner)
      persona_specific=$(cat <<'PEOF'
## planner의 권한
- master-spec.md 수정 가능
- docs/tickets/, docs/decisions/ 신규 작성 가능
- 코드 작성 금지 (그건 implementer 티켓으로 분리)

## 추가 의무 (DONE 이동)
명세/티켓 갱신이 끝나면, 동일 commit 안에:
1. 이 티켓 파일의 `status:`를 `done`으로 변경.
2. `git mv` 로 docs/tickets/DONE/ 이동.
3. 한 commit으로 묶어 `TXXX: <요약>` 메시지로 commit.
PEOF
)
      ;;
    reviewer)
      persona_specific=$(cat <<'PEOF'
## reviewer의 권한
- 코드 변경 금지. 검토 결과만 docs/reviews/<TXXX>.md 로 작성.
- 결과는 PASS / REQUEST CHANGES / REJECT 셋 중 하나로 명시.

## 추가 의무 (DONE 이동)
리뷰 산출물 작성 후 동일 commit 안에:
1. 이 티켓 `status:` → `done` (단 결과가 REJECT라면 `blocked`).
2. `git mv` 로 DONE/ 또는 ARCHIVE/ 이동.
3. 한 commit으로 묶기.
PEOF
)
      ;;
  esac

  local prompt
  prompt=$(cat <<EOF
당신은 \`$skill_file\`의 페르소나로 동작합니다.
이 페르소나의 규칙을 그대로 따르고, 그 외에 어떤 행동도 하지 마세요.

## 처리할 티켓
파일 경로: $ticket

티켓 본문:
\`\`\`markdown
$(cat "$ticket")
\`\`\`

## 참고 (수정 금지)
- $skill_file
- docs/runbook.md (특히 §3 실패 처리, §4 보안 3요소)
- docs/master-spec.md  ← planner만 수정 가능

## 작업 지시
1. $skill_file 의 의무 절차를 단계 번호 그대로 수행.
2. 변경 후 \`./scripts/run_checks.sh\` 가 0 exit 이어야 합니다.
3. 결과는 단일 commit. 메시지: \`${id}: <한 줄 요약>\`

$persona_specific
$safe_false_note
EOF
)

  # ────────── 5.5 Timeout 정책 (dry-run에서도 operator가 확인하도록) ──────────
  local timeout_spec timeout_seconds timeout_reason
  timeout_spec=$(headless_timeout_policy "$ticket")
  timeout_seconds="${timeout_spec%%|*}"
  timeout_reason="${timeout_spec#*|}"

  # ────────── 6. dry-run 처리 (git/lock 변경 없이 종료) ──────────
  if [ "$DRY_RUN" = "1" ]; then
    echo "── DRY RUN: 다음 프롬프트가 실행될 예정 ──"
    echo "$prompt"
    echo "⏱️  headless timeout: ${timeout_seconds}s (${timeout_reason})"
    echo "──────────────────────────────────────────"
    echo "(dry-run: 티켓 파일·git history·reservation 모두 변경 없음)"
    return 0
  fi

  # ────────── 7. Act (delegate to headless) ──────────
  echo "🤖 헤드리스 세션 디스패치..."
  local headless_log=".ralph/logs/${id}.log"
  {
    echo "ticket=$id"
    echo "started_at=$(date -Iseconds)"
    echo "root=$ROOT"
    echo "persona=$persona"
    echo "timeout_policy=$timeout_seconds"
    echo "timeout_reason=$timeout_reason"
  } > "$headless_log"
  echo "🧾 headless log: $headless_log"
  echo "⏱️  headless timeout: ${timeout_seconds}s (${timeout_reason})" | tee -a "$headless_log"
  session_event "$id" system dispatch "persona=$persona timeout=${timeout_seconds}s reason=$timeout_reason" 2>/dev/null || true

  local headless_rc reservation_meta
  reservation_meta="$SESSION_STATE_ROOT/state/reservations/${id}.d/meta"
  set +e
  CLAUDE_TIMEOUT_SECONDS="$timeout_seconds" \
    RALPH_SESSION_META_FILE="$reservation_meta" \
    RALPH_STATE_ROOT="$SESSION_STATE_ROOT" \
    ./scripts/run_headless.sh "$prompt" "$ROOT" 2>&1 | tee -a "$headless_log"
  headless_rc=${PIPESTATUS[0]}
  set -e

  if [ "$headless_rc" -ne 0 ]; then
    if [ "$headless_rc" = "124" ] || [ "$headless_rc" = "137" ]; then
      session_event "$id" system timeout "run_headless rc=$headless_rc" 2>/dev/null || true
    elif [ "$headless_rc" = "125" ]; then
      session_event "$id" system "idle-exit" "run_headless rc=$headless_rc" 2>/dev/null || true
    else
      session_event "$id" system failed "run_headless rc=$headless_rc" 2>/dev/null || true
    fi
    echo "❌ Claude 헤드리스 세션 실패"
    if [ "$headless_rc" = "125" ]; then
      add_failure "$id" "idle-exit" "${i:-0}" "$ticket"
      save_headless_diagnostics "$id" "idle-exit" "$timeout_seconds" "$headless_rc"
      return 15
    fi
    add_failure "$id" "claude-exec-failed" "${i:-0}" "$ticket"
    save_headless_diagnostics "$id" "claude-exec-failed" "$timeout_seconds" "$headless_rc"
    return 5
  fi
  session_event "$id" system completed "run_headless rc=0" 2>/dev/null || true

  # ────────── 8. Verify ──────────
  echo "🔍 검증..."
  if ! ./scripts/run_checks.sh; then
    echo "❌ run_checks.sh 실패"
    add_failure "$id" "checks-failed" "${i:-0}" "$ticket"
    save_headless_diagnostics "$id" "checks-failed" "$timeout_seconds"
    if in_isolated_worktree; then
      echo "↩️  isolated worktree → 자동 폐기 (git reset --hard)"
      git reset --hard HEAD 2>/dev/null || true
    else
      echo "ℹ️  메인 워크트리 → 자동 폐기 안 함. 인간이 git status 확인 후 결정하세요."
    fi
    return 6
  fi

  # ────────── 9. 페르소나가 commit + DONE 이동을 했는지 검증 ──────────
  # 운영 관련 경로에 미커밋 변경이 있으면 실패.
  # 비운영 사용자 파일(docs/manyfast-service-analysis.md 등)은 검사하지 않음.
  #
  # T308: rc=0인데 커밋/DONE 이동이 안 됐다면, 실패 처리 전에 "마무리 세션"을
  # 사이클당 딱 1회 재디스패치한다(무한 루프 금지) — WIP 품질은 양호한데 세션이
  # 커밋 의무(§2 절차 7–8) 전에 끝나는 패턴(runbook §3.7 분기 1 operator 회수)을
  # 줄이기 위함. idle-exit(125)·timeout(124)은 이미 그 이전(§7)에서 반환되므로
  # 이 블록에 도달하지 않는다 — 재프롬프트는 "정상 종료 후 마무리 누락"에만 적용.
  local wip_stage reprompted=0
  while :; do
    wip_stage=""
    if [ -n "$(_op_dirty_lines)" ]; then
      wip_stage="no-commit"
    elif [ -f "$ticket" ]; then
      wip_stage="no-done-move"
    fi

    [ -z "$wip_stage" ] && break

    if [ "$reprompted" = "1" ]; then
      echo "❌ 재프롬프트 후에도 미완(stage=$wip_stage) — 실패 처리."
      add_failure "$id" "$wip_stage" "${i:-0}" "$ticket"
      save_headless_diagnostics "$id" "$wip_stage" "$timeout_seconds"
      if [ "$wip_stage" = "no-commit" ] && in_isolated_worktree; then
        git reset --hard HEAD 2>/dev/null || true
      fi
      if [ "$wip_stage" = "no-commit" ]; then return 7; else return 8; fi
    fi

    echo "⚠️  세션이 커밋 없이 끝남(stage=$wip_stage) — 마무리 세션 1회 재프롬프트."
    session_event "$id" system reprompt "stage=$wip_stage" 2>/dev/null || true
    reprompted=1

    local reprompt_prompt
    reprompt_prompt=$(cat <<EOF
당신은 \`$skill_file\`의 페르소나로 동작합니다.
이 페르소나의 규칙을 그대로 따르고, 그 외에 어떤 행동도 하지 마세요.

## 상황
직전 세션이 이 티켓을 커밋 없이 끝냈습니다 (stage=$wip_stage). 새 세션이 이어받았습니다.

## 처리할 티켓
파일 경로: $ticket

## 지시
1. \`git status\`와 \`git diff\`로 직전 세션의 WIP를 검토하세요.
2. WIP가 티켓 수용 기준 내라면 $skill_file §2 절차 5–8(검증 → 단일 commit → DONE 이동)만
   완료하세요. 새 기능을 추가하거나 범위를 넓히지 마세요.
3. WIP가 수용 기준에 못 미치면, 가장 보수적인 방법으로 마저 구현한 뒤 동일 절차(5–8)를
   따르세요.

## 참고 (수정 금지)
- $skill_file
- docs/runbook.md (특히 §3 실패 처리, §4 보안 3요소)
- docs/master-spec.md  ← planner만 수정 가능
EOF
)

    echo "🤖 마무리 세션(재프롬프트) 디스패치... (stage=$wip_stage)" | tee -a "$headless_log"
    local reprompt_rc
    set +e
    CLAUDE_TIMEOUT_SECONDS="$timeout_seconds" \
      RALPH_SESSION_META_FILE="$reservation_meta" \
      RALPH_STATE_ROOT="$SESSION_STATE_ROOT" \
      ./scripts/run_headless.sh "$reprompt_prompt" "$ROOT" 2>&1 | tee -a "$headless_log"
    reprompt_rc=${PIPESTATUS[0]}
    set -e

    if [ "$reprompt_rc" -ne 0 ]; then
      echo "❌ 재프롬프트 헤드리스 세션 실패(rc=$reprompt_rc)."
      add_failure "$id" "$wip_stage" "${i:-0}" "$ticket"
      save_headless_diagnostics "$id" "$wip_stage" "$timeout_seconds" "$reprompt_rc"
      if [ "$wip_stage" = "no-commit" ] && in_isolated_worktree; then
        git reset --hard HEAD 2>/dev/null || true
      fi
      if [ "$wip_stage" = "no-commit" ]; then return 7; else return 8; fi
    fi

    if ! ./scripts/run_checks.sh; then
      echo "❌ 재프롬프트 후 run_checks.sh 실패"
      add_failure "$id" "checks-failed" "${i:-0}" "$ticket"
      save_headless_diagnostics "$id" "checks-failed" "$timeout_seconds"
      if in_isolated_worktree; then
        git reset --hard HEAD 2>/dev/null || true
      fi
      return 6
    fi
  done

  # ────────── 10. 계측 (ADR-0046): 완료 타임스탬프 영속 ──────────
  # DONE 티켓 frontmatter에 completed_at / started_at(reservation meta)을 durable하게
  # 기록한다. 별도 telemetry 커밋이며 페르소나 커밋과 분리된다. Mission Control은 이를
  # 읽어 사이클/리드 타임·완료 throughput을 집계한다(읽기 전용 — 영속은 루프 전담).
  # 실패해도 cycle 성공을 깨지 않도록 변경분을 되돌린다(트리 clean 유지).
  local done_file started_at_val completed_at_val
  done_file="docs/tickets/DONE/$(basename "$ticket")"
  if [ -f "$done_file" ]; then
    started_at_val=""
    [ -f "$reservation_meta" ] && started_at_val="$(awk -F= '/^started_at=/{print $2; exit}' "$reservation_meta" 2>/dev/null || true)"
    completed_at_val="$(date -Iseconds)"
    if fm_set_field "$done_file" completed_at "$completed_at_val" \
       && { [ -z "$started_at_val" ] || fm_set_field "$done_file" started_at "$started_at_val"; } \
       && git add "$done_file" 2>/dev/null \
       && git commit -m "telemetry(${id}): completed_at" >/dev/null 2>&1; then
      echo "🕒 telemetry: $id completed_at=$completed_at_val"
    else
      git checkout -- "$done_file" 2>/dev/null || true   # 실패 시 트리 clean 복원
    fi
  fi

  # ────────── 11. 계측 (ADR-0070): per-ticket 토큰 합계 영속 ──────────
  # 완료 티켓의 token_usage.log 세션들을 합산해 DONE frontmatter tokens_total(+in/out)을
  # durable하게 기록한다(measured 카운트만 — 비용은 reader가 요율로 추정·frontmatter 미영속).
  # completed_at과 동형: 분리 telemetry 커밋·실패 시 트리 복원(cycle 비치명). usage 없으면
  # 미기록(fail-closed, 0 아님). 로그 없음/TOKEN_TELEMETRY OFF면 무동작.
  local token_log="state/token_usage.log"
  if [ -f "$done_file" ] && [ -f "$token_log" ]; then
    local tok_sum tin tout ttot
    tok_sum="$(awk -F'\t' -v id="$id" '$2==id { ti+=$4; to+=$5; n++ } END { if (n>0) printf "%d %d", ti, to }' "$token_log" 2>/dev/null || true)"
    if [ -n "$tok_sum" ]; then
      tin="${tok_sum%% *}"; tout="${tok_sum##* }"; ttot=$((tin + tout))
      if fm_set_field "$done_file" tokens_total "$ttot" \
         && fm_set_field "$done_file" tokens_in "$tin" \
         && fm_set_field "$done_file" tokens_out "$tout" \
         && git add "$done_file" 2>/dev/null \
         && git commit -m "telemetry(${id}): tokens_total" >/dev/null 2>&1; then
        echo "🔢 telemetry: $id tokens_total=$ttot (in=$tin out=$tout)"
      else
        git checkout -- "$done_file" 2>/dev/null || true   # 실패 시 트리 clean 복원
      fi
    fi
  fi

  echo "✅ cycle done — $ticket → DONE/  (lock은 trap에서 정리됨)"
  rm -f state/current_ticket
  return 0
}

# ────────── Loop entry ──────────
# 종료 코드 정책:
#   - 모든 cycle 성공 → 0
#   - "처리할 티켓 없음(rc=10)"만 발생 → 0 (정상 idle)
#   - 한 번이라도 실패 cycle 발생 → 마지막 실패 rc 그대로 반환 (orchestrator·cron이 인지 가능)
#   - 연속 3회 실패 → 9 (lock 남김)
fails_in_a_row=0
any_failure_rc=0
for ((i=1; i<=CYCLES; i++)); do
  echo ""
  echo "▶ cycle $i / $CYCLES"
  if cycle_one; then
    fails_in_a_row=0
  else
    rc=$?
    if [ "$rc" = "10" ]; then break; fi   # 처리할 티켓 없음 → 정상 종료
    any_failure_rc=$rc
    fails_in_a_row=$((fails_in_a_row+1))
    if [ "$fails_in_a_row" -ge 3 ]; then
      echo "🛑 연속 3회 실패 — 자동 루프 정지. state/failures.log 확인."
      touch state/lock  # 의도적으로 lock 남김
      trap - EXIT
      for id in "${OWNED_RESERVATIONS[@]:-}"; do
        [ -n "$id" ] && rm -rf "state/reservations/${id}.d" 2>/dev/null || true
      done
      exit 9
    fi
  fi
done

echo ""
echo "🏁 Ralph loop session done. ($fails_in_a_row consecutive failures at end)"

# 한 사이클이라도 실패했다면 exit 0 절대 금지 — orchestrator가 worker 실패를 인지해야 함.
if [ "$any_failure_rc" != "0" ]; then
  echo "⚠️  한 사이클 이상 실패 — exit $any_failure_rc"
  exit "$any_failure_rc"
fi
