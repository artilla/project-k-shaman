#!/usr/bin/env bash
# orchestrator.sh — Step 3 헤드리스 + worktree 병렬 오케스트레이터.
#
# 메인 세션은 상태 파일만 본다. 실제 구현은 각 티켓별 git worktree에서
# 신선한(headless) Claude 세션이 실행한다.
#
# 동시성 모델 (이전 버전 대비 변경):
#   - 예약은 git commit이 아니라 state/reservations/<TXXX>.d 디렉터리(원자적 mkdir).
#       메인 git history를 noise로 더럽히지 않는다.
#   - orchestrator가 lock을 잡고 worker를 spawn → worker는 --no-reserve 모드로 호출.
#   - worker 종료 후 lock은 orchestrator가 정리. 실패해도 lock 남지 않음.
#
# Round end summary:
#   - 각 worker 브랜치(`ralph/TXXX`)에 들어 있는 commit을 명시적으로 사용자에게 보고.
#   - 자동 merge는 하지 않는다 (가역성 원칙). 사람이 검토 후 merge / PR 생성.
#
# 사용:
#   ./scripts/orchestrator.sh                  # 동시 워커 1, 한 라운드
#   ./scripts/orchestrator.sh --max 3          # 동시 워커 최대 3
#   ./scripts/orchestrator.sh --watch          # 새 티켓 들어오면 계속

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MAX_WORKERS=1
WATCH=0
WATCH_INTERVAL=60

while [ $# -gt 0 ]; do
  case "$1" in
    --max)            MAX_WORKERS="$2"; shift ;;
    --once)           WATCH=0 ;;
    --watch)          WATCH=1 ;;
    --watch-interval) WATCH_INTERVAL="$2"; shift ;;
    -h|--help)        sed -n '2,24p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
  shift
done

mkdir -p .ralph .ralph/logs state state/reservations docs/tickets/DONE

# ────────── git 가드 ──────────
if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "❌ 이 디렉터리는 git 저장소가 아닙니다. orchestrator는 worktree를 요구합니다." >&2
  echo "   먼저 다음을 실행하세요:" >&2
  echo "       git init && git add . && git commit -m 'init: Ralph Loop template'" >&2
  exit 2
fi

CURRENT_BRANCH=$(git symbolic-ref --short HEAD 2>/dev/null || echo "HEAD")
echo "📦 메인 브랜치: $CURRENT_BRANCH"
echo "👷 동시 워커: $MAX_WORKERS"

# ────────── 헬퍼 ──────────
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

ticket_id_from_path() {
  local base; base=$(basename "$1" .md)
  echo "${base%%-*}"
}

worker_ticket_safe() {
  local id="$1" wt="$ROOT/.ralph/wt-${id}" f

  for f in "$wt/docs/tickets/${id}-"*.md "$wt/docs/tickets/DONE/${id}-"*.md "$wt/docs/tickets/ARCHIVE/${id}-"*.md; do
    [ -f "$f" ] || continue
    field_of "$f" safe || true
    return 0
  done

  for f in "docs/tickets/${id}-"*.md "docs/tickets/DONE/${id}-"*.md "docs/tickets/ARCHIVE/${id}-"*.md; do
    [ -f "$f" ] || continue
    field_of "$f" safe || true
    return 0
  done

  echo ""
}

# atomic reservation lock — orchestrator 소유. 성공: 0, 이미 있음: 1
reserve_for_orchestrator() {
  local id="$1"
  if mkdir "state/reservations/${id}.d" 2>/dev/null; then
    {
      echo "pid=$$"
      echo "mode=orchestrated"
      echo "started_at=$(date -Iseconds)"
      echo "root=$ROOT"
    } > "state/reservations/${id}.d/meta"
    return 0
  fi
  return 1
}

release_reservation() {
  local id="$1"
  rm -rf "state/reservations/${id}.d" 2>/dev/null || true
}

pid_alive() { [ -n "$1" ] && kill -0 "$1" 2>/dev/null; }

COLLECTED_FAILURE_IDS=()

already_collected_failures() {
  local want="$1" id
  if [ "${#COLLECTED_FAILURE_IDS[@]}" -gt 0 ]; then
    for id in "${COLLECTED_FAILURE_IDS[@]}"; do
      [ "$id" = "$want" ] && return 0
    done
  fi
  return 1
}

# worker worktree의 state/failures.log를 메인 state/failures.log에 append.
# rc=0: 성공 또는 파일 없음/빈 파일/이미 회수됨(skip). rc=1: append 실패.
collect_worker_failures() {
  local id="$1"
  local wt_failures="$ROOT/.ralph/wt-${id}/state/failures.log"
  local main_failures="state/failures.log"

  already_collected_failures "$id" && return 0

  # 파일 없거나 빈 파일 → 조용히 skip
  [ -f "$wt_failures" ] && [ -s "$wt_failures" ] || return 0

  local line_count
  line_count=$(awk 'END{print NR}' "$wt_failures")

  mkdir -p state
  if ! cat "$wt_failures" >> "$main_failures" 2>/dev/null; then
    echo "  ❌ worker[$id] failures.log 회수 실패: $wt_failures"
    return 1
  fi
  COLLECTED_FAILURE_IDS+=("$id")
  echo "  📥 worker[$id] failures.log 회수: ${line_count} line(s) → state/failures.log"
  return 0
}

# ────────── 단일 워커 spawn ──────────
spawn_worker() {
  local ticket_path="$1"
  local id; id=$(ticket_id_from_path "$ticket_path")
  local wt=".ralph/wt-$id"
  local branch="ralph/$id"
  local pidfile=".ralph/wt-$id.pid"

  # 이미 실행 중인 워커가 있으면 spawn 스킵
  if [ -f "$pidfile" ]; then
    local prev; prev=$(cat "$pidfile" 2>/dev/null || echo "")
    if pid_alive "$prev"; then
      echo "  ⏭  worker[$id] 이미 실행 중 (pid=$prev). spawn 스킵."
      return 0
    fi
    rm -f "$pidfile"
  fi

  # 죽은 worktree 정리
  if git worktree list --porcelain | grep -q "worktree $ROOT/$wt"; then
    if [ ! -f "$pidfile" ] || ! pid_alive "$(cat "$pidfile" 2>/dev/null)"; then
      git worktree remove "$wt" 2>/dev/null || git worktree remove --force "$wt" 2>/dev/null || true
      git branch -D "$branch" 2>/dev/null || true
    else
      echo "  ⚠  worktree 존재하고 워커도 살아 있음 — 안전을 위해 spawn 중단"
      return 1
    fi
  fi

  if ! git worktree add -b "$branch" "$wt" "$CURRENT_BRANCH" >/dev/null; then
    echo "  ✗ worktree 생성 실패: $wt" >&2
    return 1
  fi

  echo "  ▶ worker[$id] worktree=$wt branch=$branch"

  # ────────── 핵심: 절대경로로 RALPH_ROOT 전달 + worktree 내부 스크립트 호출 ──────────
  # `$ROOT/$wt` 형태로 절대경로를 만들어야 worker 내부 cd "$ROOT" (=RALPH_ROOT)가 정상 작동.
  # `cd $wt` 후 `./scripts/run_loop.sh`를 호출하므로 worker의 ROOT 결정 로직(pwd)도 백업으로 같은 경로를 잡는다.
  local worker_root="$ROOT/$wt"

  # ────────── 로그는 worktree 바깥(.ralph/logs/)에 둔다 ──────────
  # worker가 시작 시 isolated worktree dirty cleanup(`git clean -fd`)을 하면
  # worktree 내부의 .ralph.log가 삭제될 수 있다. 메인 .ralph/logs/는 worktree 외부이므로 안전.
  local logfile="$ROOT/.ralph/logs/${id}.log"
  (
    cd "$worker_root"
    RALPH_ROOT="$worker_root" ./scripts/run_loop.sh "$id" --count 1 --no-reserve
  ) >"$logfile" 2>&1 &

  local pid=$!
  echo "$pid" > "$pidfile"
  echo "    pid=$pid log=$logfile"
  return 0
}

# ────────── 라운드 진행 ──────────
RESERVED_IN_ROUND=()  # 이번 라운드에서 reserve한 id 목록 (cleanup 대상)

cleanup_orchestrator() {
  local id
  for id in "${RESERVED_IN_ROUND[@]:-}"; do
    if [ -n "$id" ]; then
      release_reservation "$id" || true
    fi
  done
  return 0
}
trap cleanup_orchestrator EXIT

run_round() {
  local active=0
  RESERVED_IN_ROUND=()

  while [ "$active" -lt "$MAX_WORKERS" ]; do
    local next; next=$(./scripts/pick_next_ticket.sh)
    [ -z "$next" ] && break

    local id; id=$(ticket_id_from_path "$next")

    if ! reserve_for_orchestrator "$id"; then
      echo "  ⏭  $id 이미 reserved — 다음 후보로"
      continue
    fi
    RESERVED_IN_ROUND+=("$id")

    if spawn_worker "$next"; then
      active=$((active+1))
    else
      release_reservation "$id"
      # RESERVED_IN_ROUND에서 제거
      local new_arr=()
      for r in "${RESERVED_IN_ROUND[@]:-}"; do [ "$r" != "$id" ] && new_arr+=("$r"); done
      RESERVED_IN_ROUND=("${new_arr[@]:-}")
    fi
  done

  if [ "$active" = "0" ]; then
    echo "📭 처리할 티켓 없음."
    return 10
  fi

  echo "⏳ $active worker(s) 진행 중..."
  # macOS 기본 Bash 3.2는 `declare -A` 미지원 → indexed array에 "id|rc" 라인으로 저장.
  WORKER_RC_LINES=()
  for pidfile in .ralph/*.pid; do
    [ -f "$pidfile" ] || continue
    local pid; pid=$(cat "$pidfile")
    local pid_id; pid_id=$(basename "$pidfile" .pid | sed 's/^wt-//')
    local rc
    set +e
    wait "$pid" 2>/dev/null
    rc=$?
    set -e
    WORKER_RC_LINES+=("$pid_id|$rc")
    rm -f "$pidfile"
  done

  # 조회 헬퍼
  rc_for() {
    local want="$1" line
    for line in "${WORKER_RC_LINES[@]:-}"; do
      case "$line" in
        "$want|"*) echo "${line#*|}"; return ;;
      esac
    done
    echo "?"
  }

  # ────────── worker failures.log 회수 ──────────
  # reservation 정리·round summary 전에 실행하여 worktree 삭제와 무관하게 보존.
  # 같은 라운드에서 RESERVED_IN_ROUND의 각 ID는 최대 한 번만 처리되므로 중복 append 없음.
  local round_failed=0
  for id in "${RESERVED_IN_ROUND[@]:-}"; do
    if ! collect_worker_failures "$id"; then
      echo "  💥 worker[$id] failures.log 회수 실패 — round를 실패로 표시"
      round_failed=1
    fi
  done

  # 워커 종료 → orchestrator 측 reservation 정리
  for id in "${RESERVED_IN_ROUND[@]:-}"; do
    release_reservation "$id"
  done

  # ────────── Round summary: 각 worker 브랜치 + exit code 보고 ──────────
  echo ""
  echo "════════ Round summary ════════"
  local main_ref; main_ref=$(git symbolic-ref --short HEAD 2>/dev/null || echo "$CURRENT_BRANCH")
  for id in "${RESERVED_IN_ROUND[@]:-}"; do
    local branch="ralph/$id"
    local logfile="$ROOT/.ralph/logs/${id}.log"
    local rc; rc=$(rc_for "$id")
    local safe; safe=$(worker_ticket_safe "$id")
    local approval_marker=""
    if [ "$safe" = "false" ]; then
      approval_marker="         ⚠️  HUMAN APPROVAL REQUIRED FOR MERGE — safe:false"
    fi

    if ! git show-ref --verify --quiet "refs/heads/$branch"; then
      echo "  • $id: 브랜치 없음 — spawn 자체가 실패 (worker rc=$rc)"
      [ -n "$approval_marker" ] && echo "$approval_marker"
      round_failed=1
      continue
    fi

    local commits; commits=$(git log "$main_ref..$branch" --oneline 2>/dev/null || true)
    if [ -n "$commits" ] && [ "$rc" = "0" ]; then
      echo "  ✅ $id: rc=$rc, ralph/$id 브랜치에 다음 commit 생성됨"
      echo "$commits" | sed 's/^/         /'
      [ -n "$approval_marker" ] && echo "$approval_marker"
      echo "         → 검토 후 'git merge --no-ff $branch' 하거나 PR을 생성하세요."
    elif [ -n "$commits" ]; then
      echo "  ⚠️  $id: rc=$rc 이지만 브랜치에 commit 있음 — 부분 진행 가능성. 검토 필요."
      echo "$commits" | sed 's/^/         /'
      [ -n "$approval_marker" ] && echo "$approval_marker"
      echo "         → WIP 회수 후보. git diff/run_checks/scope 검토 후 회수 판단 (runbook §3)"
      round_failed=1
    else
      echo "  ❌ $id: rc=$rc, 브랜치에 commit 없음"
      [ -n "$approval_marker" ] && echo "$approval_marker"
      echo "         → rc=5 timeout이면 .ralph/wt-${id} worktree에 미커밋 WIP가 있을 수 있음. worktree diff 확인 후 회수/수동작성/재시도 판단 (runbook §3)"
      round_failed=1
    fi

    if [ -f "$logfile" ] && [ "$rc" != "0" ]; then
      echo "         ── log tail ($logfile) ──"
      tail -10 "$logfile" | sed 's/^/         /'
    fi
  done
  echo "════════════════════════════════"

  echo ""
  if [ "$round_failed" = "1" ]; then
    echo "⚠️  round complete with failures. (worker 브랜치는 메인에 자동 merge되지 않습니다 — 가역성 원칙)"
    return 11
  fi
  echo "✅ round complete. (worker 브랜치는 메인에 자동 merge되지 않습니다 — 가역성 원칙)"
  return 0
}

# ────────── 테스트 전용: RALPH_TEST_COLLECT_ONLY ──────────
# RALPH_TEST_COLLECT_ONLY=id1[,id2,...] 로 설정하면 지정된 worker ID 목록에 대해
# collect_worker_failures만 실행하고 종료. production 경로(run_round)에는 진입하지 않는다.
if [ -n "${RALPH_TEST_COLLECT_ONLY:-}" ]; then
  _rc=0
  IFS=',' read -r -a _ids <<< "$RALPH_TEST_COLLECT_ONLY"
  for _id in "${_ids[@]}"; do
    collect_worker_failures "$_id" || _rc=1
  done
  exit "$_rc"
fi

# ────────── main ──────────
if [ "$WATCH" = "1" ]; then
  echo "👀 watch 모드: ${WATCH_INTERVAL}s 마다 새 티켓 확인. (Ctrl-C로 종료)"
  while true; do
    run_round || true
    sleep "$WATCH_INTERVAL"
  done
else
  run_round
fi
