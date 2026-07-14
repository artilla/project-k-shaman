#!/usr/bin/env bash
# db_migrate.sh — db/migrations/*.sql 을 순서대로 멱등 적용한다.
#
# 소유권 계약 (리뷰 15차 P1 + 16차 P1):
#   - transaction: 각 마이그레이션은 runner가 --single-transaction으로 감싸고,
#     파일 내용은 DO 블록의 EXECUTE(SPI) 안에서 실행한다 — transaction control·
#     psql meta command·COPY FROM STDIN은 "서버"가 원자 컨텍스트에서 거부한다.
#     runner는 SQL을 수정하지도, 수제 파서로 판정하지도 않는다 (16차 P1 재재수정).
#   - ledger: version 기록(INSERT INTO schema_migrations)은 runner가 같은
#     transaction에서 수행한다. SQL 파일이 marker를 빠뜨려도 재실행되지 않는다.
#   - 동시 실행: pg_advisory_xact_lock으로 직렬화. 패자는 승자 commit 후 guard
#     예외로 중단되고, 실패 후 ledger 재조회로 skip을 판정한다(16차 P1: 출력
#     문자열 매칭 판정 금지).
#   - --status: 읽기 전용 — 어떤 쓰기도 하지 않는다 (16차 P1).
#   - fail-closed: 접속/query 실패는 'pending'이 아니라 오류(rc≠0)다.
#   - 실행 원본(16차 P1 7차): apply는 작업트리 파일이 아니라 "HEAD에 커밋된
#     Git blob"의 bytes만 실행한다 — immutable·content-addressed. 작업트리가
#     커밋과 다르면 거부한다.
#   - 신호(16차 P1 7차): migration psql은 별도 프로세스 그룹 — TERM/INT/HUP을
#     전달하고 bounded reap + 서버 backend 종료 확인 후 runner가 종료한다.
#
# 연결 정보: .env.local 의 DATABASE_URL. 구성요소를 분해해 PG* 환경변수로
# 전달한다 (password의 '$' 등 특수문자 안전).
# 리뷰 16차 P1: query string의 schema 파라미터는 더 이상 무시하지 않는다 —
# 애플리케이션(Prisma)이 schema=X를 보는데 runner가 search_path 기본값(public)에
# 적용하면 서로 다른 스키마를 보게 된다. schema는 식별자 검증 후 search_path로
# 고정하고, 그 외 파라미터(connection_limit 등)만 무시한다.
# 한계: percent-encoding·IPv6 literal은 지원하지 않는다 — 감지 시 명시 거부.
#
# 사용:
#   ./scripts/db_migrate.sh            # 미적용 마이그레이션 전부 적용
#   ./scripts/db_migrate.sh --status   # 적용 상태 출력 (접속 실패는 rc≠0)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() { echo "usage: db_migrate.sh [--status]" >&2; }

# 리뷰 15차 P1: 옵션 오타(--statsu 등)가 apply 경로로 새지 않는다 — 알 수 없는
# 인수는 usage 실패(rc=2).
MODE="apply"
case "${1:-}" in
  "") : ;;
  --status) MODE="status" ;;
  *) echo "❌ 알 수 없는 인수: '$1'" >&2; usage; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "❌ 인수가 너무 많습니다." >&2; usage; exit 2; }

ENV_FILE="${ENV_FILE:-.env.local}"
[ -f "$ENV_FILE" ] || { echo "❌ ${ENV_FILE} 이 없습니다." >&2; exit 2; }

# 리뷰 16차 P2: sed|head는 대형 파일에서 SIGPIPE(rc=141) 무진단 종료가 가능 —
# 입력을 끝까지 소비하는 awk 단일 패스로 첫 선언만 추출.
# 4라운드 P2: `tr -d`는 값 "안"의 모든 quote 문자까지 삭제해 값을 변형했다
# (password에 quote가 있으면 다른 자격증명으로 접속) — 양끝의 "같은 종류 쌍"일
# 때만 벗긴다 (frontmatter 파서와 동일 계약).
_strip_pair_quotes() {  # $1=값 → stdout
  local _v="$1"
  case "$_v" in
    \"*\") _v="${_v#\"}"; _v="${_v%\"}" ;;
    \'*\') _v="${_v#\'}"; _v="${_v%\'}" ;;
  esac
  printf '%s' "$_v"
}
DB_URL="$(awk '!f && sub(/^DATABASE_URL=/, "") { v = $0; f = 1 } END { if (f) print v }' "$ENV_FILE")"
DB_URL="$(_strip_pair_quotes "$DB_URL")"
[ -n "$DB_URL" ] || { echo "❌ ${ENV_FILE} 에 DATABASE_URL 이 없습니다." >&2; exit 2; }

# 리뷰 15차 P2: 수동 파서의 한계를 명시 거부로 — percent-encoding('%')·IPv6('[')는
# 잘못 분해된 채 진행하지 않는다.
case "$DB_URL" in
  *%*|*\[*)
    echo "❌ DATABASE_URL에 percent-encoding 또는 IPv6 literal이 있습니다 — 이 파서가 지원하지 않는 형식입니다 (PGHOST/PGUSER 등 PG* 환경변수로 직접 지정하세요)." >&2
    exit 2
    ;;
esac

# postgres://user:pass@host:port/dbname?params → 구성요소 분해
_rest="${DB_URL#*://}"
_userinfo="${_rest%%@*}"
_hostpart="${_rest#*@}"
PGUSER="${_userinfo%%:*}"
PGPASSWORD="${_userinfo#*:}"
_hostport="${_hostpart%%/*}"
PGHOST="${_hostport%%:*}"
PGPORT="${_hostport#*:}"; [ "$PGPORT" = "$PGHOST" ] && PGPORT=5432
_dbq="${_hostpart#*/}"
PGDATABASE="${_dbq%%\?*}"

# 리뷰 16차 P1: schema 파라미터 존중 (기본 public). 안전한 식별자만 허용 —
# search_path/CREATE SCHEMA에 들어가므로 검증 실패는 거부한다 (fail-closed).
_query=""
case "$_dbq" in *\?*) _query="${_dbq#*\?}" ;; esac
PGSCHEMA="public"
if [ -n "$_query" ]; then
  # 리뷰 16차 P2: sed|head는 긴 중복 파라미터에서 SIGPIPE(rc=141)로 무진단 종료했다
  # (set -o pipefail) — 입력을 끝까지 소비하는 awk 단일 패스로 추출.
  _sch="$(printf '%s' "$_query" | tr '&' '\n' | awk -F= '$1=="schema" && !f {v=$2; f=1} END {if (f) print v}')"
  if [ -n "$_sch" ]; then
    case "$_sch" in
      [A-Za-z_]*) ;;
      *) echo "❌ DATABASE_URL schema 파라미터가 유효한 식별자가 아닙니다: '$_sch'" >&2; exit 2 ;;
    esac
    case "$_sch" in
      *[!A-Za-z0-9_]*) echo "❌ DATABASE_URL schema 파라미터가 유효한 식별자가 아닙니다: '$_sch'" >&2; exit 2 ;;
    esac
    # 리뷰 16차 P2: 63자(NAMEDATALEN-1) 초과는 서버가 잘라 다른 이름이 된다 —
    # 원래 이름으로 성공을 보고하지 않도록 명시 거부 (검증기가 ASCII만 통과시키므로
    # 문자수 == 바이트수).
    if [ "${#_sch}" -gt 63 ]; then
      echo "❌ DATABASE_URL schema 이름이 63자를 초과합니다 (PostgreSQL 식별자 한계): '$_sch'" >&2
      exit 2
    fi
    PGSCHEMA="$_sch"
  fi
fi

# 재재리뷰 P1 #3(b): runtime app role 목록 — 005의 진입점 EXECUTE·schema USAGE
# 대상이다 (migration 실행 role이 아니라 "애플리케이션이 접속하는 role").
# env MIGRATION_APP_ROLES 우선, 없으면 ENV_FILE의 선언을 읽는다. 쉼표 구분,
# 각 이름은 schema와 같은 식별자 규칙으로 검증한다 (SET LOCAL literal에 들어가므로
# 검증 실패는 거부 — fail-closed). 비어 있으면 migration이 실행 role로 fallback.
if [ -n "${MIGRATION_APP_ROLES+x}" ]; then
  _MIG_APP_ROLES="$MIGRATION_APP_ROLES"
else
  _MIG_APP_ROLES="$(awk '!f && sub(/^MIGRATION_APP_ROLES=/, "") { v = $0; f = 1 } END { if (f) print v }' "$ENV_FILE")"
  _MIG_APP_ROLES="$(_strip_pair_quotes "$_MIG_APP_ROLES")"   # 4라운드 P2: 쌍 quote만 제거
fi
# 5라운드 live blocker(#7): 미지정을 경고+진행이 아니라 fail-closed로 — ACL 대상이
# 실행 role로 "확정"되고 ledger 때문에 재실행되지 않으므로, 실행 role fallback은
# 명시적 opt-in(@self)일 때만 허용한다. --status는 읽기 전용이라 요구하지 않는다.
_MIG_SELF_OK=0
if [ "$_MIG_APP_ROLES" = "@self" ]; then
  _MIG_SELF_OK=1
  _MIG_APP_ROLES=""
fi
if [ "$MODE" = "apply" ] && [ -z "$_MIG_APP_ROLES" ] && [ "$_MIG_SELF_OK" -ne 1 ]; then
  echo "❌ MIGRATION_APP_ROLES가 지정되지 않았습니다 — 005의 진입점 ACL(EXECUTE·schema USAGE) 대상이 migration 실행 role로 '확정'되고, ledger 때문에 이후 변경해도 005는 재실행되지 않습니다 (fail-closed)." >&2
  echo "   runtime role을 지정하세요: MIGRATION_APP_ROLES=<role[,role...]> (env 또는 ${ENV_FILE})." >&2
  echo "   실행 role 자체가 runtime role이면 명시적으로 승인하세요: MIGRATION_APP_ROLES=@self" >&2
  exit 2
fi
if [ -n "$_MIG_APP_ROLES" ]; then
  case "$_MIG_APP_ROLES" in
    *[!A-Za-z0-9_,]*)
      echo "❌ MIGRATION_APP_ROLES에 허용되지 않는 문자가 있습니다 (role은 [A-Za-z_][A-Za-z0-9_]*, 구분자는 ','): '${_MIG_APP_ROLES}'" >&2
      exit 2
      ;;
  esac
  # 3라운드 P2: 빈 원소는 셸 word-splitting에서 소리 없이 사라져 for 루프 검증에
  # 잡히지 않았다 (a,,b 허용) — 분리 전에 문자열 패턴으로 직접 거부한다.
  case ",${_MIG_APP_ROLES}," in
    *,,*)
      echo "❌ MIGRATION_APP_ROLES에 빈 role 이름(선행/후행/중복 쉼표)이 있습니다: '${_MIG_APP_ROLES}'" >&2
      exit 2
      ;;
  esac
  _mig_roles_ifs="$IFS"; IFS=','
  for _mr in $_MIG_APP_ROLES; do
    case "$_mr" in
      "") IFS="$_mig_roles_ifs"; echo "❌ MIGRATION_APP_ROLES에 빈 role 이름이 있습니다: '${_MIG_APP_ROLES}'" >&2; exit 2 ;;
      [A-Za-z_]*) : ;;
      *) IFS="$_mig_roles_ifs"; echo "❌ MIGRATION_APP_ROLES role 이름이 유효한 식별자가 아닙니다: '${_mr}'" >&2; exit 2 ;;
    esac
    if [ "${#_mr}" -gt 63 ]; then
      IFS="$_mig_roles_ifs"
      echo "❌ MIGRATION_APP_ROLES role 이름이 63자를 초과합니다 (PostgreSQL 식별자 한계): '${_mr}'" >&2
      exit 2
    fi
  done
  IFS="$_mig_roles_ifs"
fi

export PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
# 리뷰 16차 P1(7차): 신호 시 서버 쪽 종료 확인의 식별자 — 이 runner의 모든
# 접속이 같은 application_name을 쓴다 (pg_stat_activity로 잔존 backend 판정).
export PGAPPNAME="db_migrate.$$"
# 리뷰 16차 P1: 식별자 quoting — unquoted 식별자는 서버가 소문자로 접는다.
# schema=AppData가 실제로는 appdata에 적용되면서 로그에는 AppData로 표시됐다.
# 검증된 식별자를 quote해 대소문자 그대로(애플리케이션/Prisma와 동일 의미) 사용.
export PGOPTIONS="-c client_min_messages=warning -c search_path=\"${PGSCHEMA}\""

# 리뷰 15차 P2: 흔한 psql 위치(macOS libpq keg)를 PATH 폴백으로 추가.
if ! command -v psql >/dev/null 2>&1; then
  for _d in /usr/local/opt/libpq/bin /opt/homebrew/opt/libpq/bin; do
    [ -x "$_d/psql" ] && PATH="$_d:$PATH" && break
  done
fi
command -v psql >/dev/null 2>&1 || { echo "❌ psql 이 PATH에 없습니다 (brew install libpq 후 PATH 추가)." >&2; exit 2; }

# ── 리뷰 16차 P1(7차) → 재재리뷰 P1 #1: 신호 계약 ────────────────────────────────
# runner가 TERM/INT/HUP을 받으면 psql "프로세스 그룹" 전체에 신호를 전달하고,
# bounded reap(전달 → 대기 → KILL) 후 서버 쪽 backend 종료까지 확인하고 나서
# 종료한다.
#
# 재재리뷰 P1 #1: bash의 trap은 "포그라운드 자식이 끝난 뒤"에야 실행되고, command
# substitution(`$( )`) 안의 자식은 부모가 subshell 종료까지 기다린다 — 최종 ledger
# 조회를 명령치환으로 돌리던 _mig_query_bg, 그리고 초기 접속·bootstrap·applied()의
# foreground psql이 전부 TERM 처리를 psql 종료 뒤로 미뤘다 (실측: DB35 elapsed≥5s).
# 이제 runner의 "모든" psql은 단 하나의 helper(_mig_psql)를 거친다: 별도 프로세스
# 그룹의 background job + wait(신호에 즉시 깨어남) + 출력은 파일 경유로 부모 셸
# 변수(_MIG_OUT)에 담는다 — 명령치환·foreground 대기 구조가 어디에도 남지 않는다.
# 4라운드 P2 → 5라운드 P2(#8): temp 목록은 bash 배열 — 공백만이 아니라 "개행"이
# 포함된 TMPDIR에서도 경로가 조각나지 않는다 (개행 구분 목록은 개행 경로에서
# dbmig-q.* 잔존, 실측).
_MIG_TMPS=()
_mig_tmp_add() { _MIG_TMPS+=("$1"); }
_mig_cleanup_tmps() {
  local _t
  if [ "${#_MIG_TMPS[@]}" -gt 0 ]; then
    for _t in "${_MIG_TMPS[@]}"; do
      rm -f "$_t" 2>/dev/null || true
    done
  fi
  _MIG_TMPS=()
}
_MIG_SIG=""
_mig_sig_num() { case "$1" in INT) echo 2 ;; HUP) echo 1 ;; *) echo 15 ;; esac; }
# 리뷰 16차 8라운드 후속 P1: handler는 phase-aware — psql이 실행 중(phase=psql)일
# 때만 기록하고 전달·reap은 _mig_psql의 루프가 소유한다. 그 외 모든 구간(phase=run)
# 은 진행 중 transaction이 없으므로 trap이 temp 정리 후 "즉시" 128+N으로 종료한다.
_MIG_PHASE="run"
_mig_on_sig() {
  _MIG_SIG="$1"
  [ "$_MIG_PHASE" = "psql" ] && return 0
  local _snum
  _snum="$(_mig_sig_num "$1")"
  _mig_cleanup_tmps
  echo "❌ 신호(${1}) 수신 — 즉시 중단합니다 (진행 중 transaction 없음; 이미 적용된 migration은 유효)." >&2
  exit $((128 + _snum))
}
trap '_mig_on_sig TERM' TERM
trap '_mig_on_sig INT'  INT
trap '_mig_on_sig HUP'  HUP
trap '_mig_cleanup_tmps' EXIT

# 리뷰 16차 P1(8차): 신호 이후에는 어떤 작업도 새로 시작하지 않는다 — psql phase
# 에서 기록된 신호가 정상 복귀 경로로 새어나온 경계를 막는 방어선.
_mig_check_sig() {
  [ -n "$_MIG_SIG" ] || return 0
  local _snum
  _snum="$(_mig_sig_num "$_MIG_SIG")"
  _mig_cleanup_tmps
  echo "❌ 신호(${_MIG_SIG}) 수신 — 새 작업을 시작하지 않고 중단합니다 (이미 적용된 migration은 유효, 진행 중 transaction 없음)." >&2
  exit $((128 + _snum))
}

# 서버 쪽 종료 확인 — 3라운드 P1(#8): drain probe도 foreground psql이면 안 된다.
# probe psql이 응답하지 않으면(지연 셔임 실측: TERM 후 8초에도 runner 생존) 신호
# 처리 전체가 unbounded가 된다. probe를 별도 프로세스 그룹의 background로 돌리고
# per-probe 시간 제한(TERM→KILL→reap)과 전체 drain 예산을 강제한다 — 예산을
# 넘기면 포기하고 실패를 반환한다 (호출자가 경고 후 즉시 종료).
# 8라운드(환경 내성): zombie를 reap하지 않는 PID 1 컨테이너에서는 죽은 그룹이
# `kill -0 -- -PGID`에 계속 "존재"로 잡혀, 신호 처리 루프가 deadline을 전부
# 소진했다 (실측: DB35·DB40 3s 상한 초과 — reap되지 않은 셔임 자손 zombie).
# zombie는 어떤 write도 할 수 없으므로 기다릴 대상이 아니다 — 그룹 생존은
# "비-zombie 구성원 존재"로 판정한다. pgrep/ps를 쓸 수 없으면 보수적으로 기존
# kill -0 판정을 유지한다 (fail-closed: 살아 있다고 가정).
_mig_group_alive() {  # $1=PGID → 0=비-zombie 구성원 존재, 1=그룹 없음/전원 zombie
  kill -0 -- "-$1" 2>/dev/null || return 1
  local _pids _p _st
  _pids="$(pgrep -g "$1" 2>/dev/null || true)"
  [ -n "$_pids" ] || return 0
  for _p in $_pids; do
    # 9라운드 P1(#6): ps "실패"(rc≠0)와 "소멸"(정상 조회에 빈 결과)을 구분한다 —
    # ps가 고장난 환경에서 빈 출력을 소멸로 읽으면 live 그룹을 dead로 판정해
    # TERM/KILL·late-child 회수를 건너뛴다 (fail-open). 판정 불가면 kill -0으로
    # 존재가 확인되는 한 보수적으로 "생존"으로 간주한다 (fail-closed).
    if _st="$(ps -o stat= -p "$_p" 2>/dev/null)"; then
      _st="$(printf '%s' "$_st" | tr -d '[:space:]')"
      case "$_st" in
        Z*|z*) : ;;   # zombie — 이미 죽었고 reap만 안 됨
        "")    : ;;   # 조회는 성공했는데 상태가 비어 있음 — 그 사이 소멸로 간주
        *) return 0 ;;
      esac
    else
      # ps 실패 — 상태를 판정할 수 없다. 존재가 확인되면 생존으로 간주.
      kill -0 "$_p" 2>/dev/null && return 0
    fi
  done
  return 1
}
_mig_probe() {  # $1=SQL, $2=제한(0.25s 스텝 수) → 결과는 $_MIG_PROBE_OUT, rc≠0=실패/시간초과
  local _f _pid _i=0 _rc=0
  _MIG_PROBE_OUT=""
  _f="$(mktemp "${TMPDIR:-/tmp}/dbmig-probe.XXXXXX")" || return 1
  set -m
  psql -X -tAc "$1" > "$_f" 2>/dev/null &
  _pid=$!
  set +m
  # 6라운드 P1(#7): probe도 그룹 기준 수명 검사 — leader-only 검사 금지
  while _mig_group_alive "$_pid" && [ "$_i" -lt "$2" ]; do sleep 0.25; _i=$((_i+1)); done
  if _mig_group_alive "$_pid"; then
    kill -TERM -- "-${_pid}" 2>/dev/null || true
    sleep 0.25
    _mig_group_alive "$_pid" && kill -KILL -- "-${_pid}" 2>/dev/null
    wait "$_pid" 2>/dev/null || true
    rm -f "$_f"
    return 1
  fi
  wait "$_pid" 2>/dev/null || _rc=$?
  _MIG_PROBE_OUT="$(cat "$_f" 2>/dev/null || true)"
  rm -f "$_f"
  return "$_rc"
}
_mig_server_drain() {  # $1=absolute deadline(epoch초) — 신호 처리 전체와 "공유"
  # 4라운드 P1(#8): drain의 자체 예산이 main psql reap과 "합산"되어 전체 상한이
  # 계약(5s)을 넘었다 (실측: main·probe 모두 TERM 무시 시 9.057s). drain은 이제
  # 독립 예산이 없다 — 호출자가 신호 수신 시점에 고정한 하나의 absolute deadline
  # 안에서만 probe하고, 예산 소진 시 즉시 포기·실패를 반환한다.
  local _q="select count(*) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" _term_done=0 _now
  while :; do
    _now="$(date +%s)"
    [ "$_now" -lt "$1" ] || return 1
    if _mig_probe "$_q" 2 && [ "$_MIG_PROBE_OUT" = "0" ]; then return 0; fi
    if [ "$_term_done" -eq 0 ]; then
      _term_done=1
      _now="$(date +%s)"
      [ "$_now" -lt "$1" ] || return 1
      _mig_probe "select pg_terminate_backend(pid) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" 2 || true
    fi
  done
}

# 유일한 psql 실행 경로 — job control(set -m)로 별도 프로세스 그룹에 배치.
# 인수는 psql에 그대로 전달, stdout+stderr는 $_MIG_OUT에 담긴다. 반환: psql rc.
# 신호 수신 시 전달·bounded reap·서버 drain·temp 정리 후 여기서 128+N으로 종료한다.
_MIG_OUT=""
_mig_psql() {
  local _qout _pid _rc _i _snum
  _mig_check_sig  # 신호가 이미 기록됐으면 psql을 아예 띄우지 않는다
  _qout="$(mktemp "${TMPDIR:-/tmp}/dbmig-q.XXXXXX")" || { echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _mig_tmp_add "$_qout"
  # 이 구간의 신호는 trap이 기록만 한다(phase=psql) — 전달·bounded reap·서버
  # drain·종료는 아래 루프가 소유한다. 루프 밖으로 정상 복귀할 때 run으로 되돌린다.
  _MIG_PHASE="psql"
  set -m
  psql "$@" > "$_qout" 2>&1 &
  _pid=$!
  set +m
  while :; do
    _rc=0
    wait "$_pid" 2>/dev/null || _rc=$?
    if [ -n "$_MIG_SIG" ]; then
      # 4라운드 P1(#8): 신호 처리 전체(main psql reap + 서버 drain)가 "하나의"
      # absolute deadline(수신 +5s)을 공유한다 — 종전에는 reap 최대 5s와 drain
      # 예산 ≈4s가 합산되어 상한이 9s를 넘었다 (실측 9.057s). 예산 소진 시
      # KILL·포기 후 즉시 종료한다.
      _mig_deadline=$(( $(date +%s) + 5 ))
      kill -s "$_MIG_SIG" -- "-${_pid}" 2>/dev/null || true
      # 6라운드 P1(#7): 수명 검사는 leader PID가 아니라 "프로세스 그룹" — leader가
      # 먼저 죽으면 TERM 무시 자손에 KILL이 가지 않아 자손이 생존했다 (실측).
      # 8라운드: 판정은 zombie-aware(_mig_group_alive) — reap 안 된 zombie만 남은
      # 그룹을 기다리며 deadline을 소진하지 않는다.
      while _mig_group_alive "$_pid" && [ "$(date +%s)" -lt "$_mig_deadline" ]; do sleep 0.25; done
      if _mig_group_alive "$_pid"; then
        kill -KILL -- "-${_pid}" 2>/dev/null || true
      fi
      wait "$_pid" 2>/dev/null || true
      # 7라운드 P2: 종료 문구가 drain 결과와 상충하지 않는다 — 확인 실패 시
      # '확인했다'고 말하지 않는다.
      if _mig_server_drain "$_mig_deadline"; then
        _mig_drain_note="서버 backend 종료를 확인했습니다"
      else
        echo "⚠️  서버에 이 runner의 backend가 아직 남아 있을 수 있습니다 — pg_stat_activity(application_name=${PGAPPNAME})를 확인하세요." >&2
        _mig_drain_note="서버 backend 종료는 예산 내에 확인하지 못했습니다"
      fi
      _snum="$(_mig_sig_num "$_MIG_SIG")"
      _mig_cleanup_tmps
      echo "❌ 신호(${_MIG_SIG})로 중단됨 — psql 프로세스 그룹에 신호를 전달했고, ${_mig_drain_note} (미완료 transaction은 서버가 rollback)." >&2
      exit $((128 + _snum))
    fi
    kill -0 "$_pid" 2>/dev/null || break
  done
  # 6라운드 P1(#7): leader 정상 종료 후 그룹 잔존 자손 회수 — late write 방지
  # (8라운드: zombie-aware — 전원 zombie인 그룹은 잔존이 아니다)
  if _mig_group_alive "$_pid"; then
    kill -TERM -- "-${_pid}" 2>/dev/null || true
    _i=0
    while _mig_group_alive "$_pid" && [ "$_i" -lt 8 ]; do sleep 0.25; _i=$((_i+1)); done
    _mig_group_alive "$_pid" && kill -KILL -- "-${_pid}" 2>/dev/null
  fi
  _MIG_PHASE="run"
  _MIG_OUT="$(cat "$_qout" 2>/dev/null || true)"
  rm -f "$_qout"
  return "$_rc"
}

# 접속 자체를 먼저 검증 — 이후의 모든 판정이 이 위에서만 유효하다 (fail-closed).
if ! _mig_psql -X -tAc "select 1"; then
  echo "❌ DB 접속 실패: ${PGDATABASE} @ ${PGHOST}:${PGPORT} — 상태를 판정할 수 없습니다 (fail-closed)." >&2
  exit 3
fi

# 동시 runner 직렬화 키 (고정 상수 — 아래 apply 루프와 부트스트랩이 공유).
ADVISORY_KEY=721363011

# applied <version> — 0=적용됨, 1=미적용. query 실패는 즉시 중단 (pending으로 위장 금지).
applied() {
  # 리뷰 16차 P1(4차): ledger 참조는 전부 schema-qualified — migration 내용의
  # SET LOCAL search_path가 unqualified 참조를 다른 schema로 돌려도 영향 없음.
  # 재재리뷰 P1 #1: 명령치환 psql 금지 — _mig_psql(background+wait) 경유.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select count(*) from \"${PGSCHEMA}\".schema_migrations where version = '$1'"; then
    echo "❌ ledger 조회 실패(version=$1): $_MIG_OUT" >&2
    exit 3
  fi
  [ "$_MIG_OUT" = "1" ]
}

# ── 리뷰 16차 P1(7차): 실행 원본은 "커밋된 Git blob" — immutable·content-addressed.
# 이중 읽기+cmp 안정성 검사는 같은 mutable inode를 두 번 읽을 뿐이라, 두 읽기가
# 동일한 torn 내용을 얻으면 통과했다 (실측: 어느 완성본에도 없던 혼합 SQL이
# rc=0으로 적용·ledger 기록). N회 재독으로는 원리적으로 해결되지 않는다 —
# apply는 파일이 아니라 HEAD에 커밋된 blob의 bytes"만" 실행한다:
#   - blob OID는 내용의 해시(content-addressed)이고 object는 immutable이다.
#     snapshot을 blob OID로 재해시해 일치할 때만 실행한다 — 판정과 실행이 같은
#     불변 bytes에 결속된다.
#   - 작업트리가 커밋 내용과 다르면(미커밋 수정·미추적/누락 *.sql) 적용 의도와
#     실행 내용이 갈라진 상태다 — 적용하지 않는다 (fail-closed).
#   - 커밋은 시작 시점에 한 번 고정한다(_SRC_COMMIT) — 실행 중 HEAD 이동 무관.
git rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
  echo "❌ git 저장소가 아닙니다 — migration은 커밋된 blob에서만 실행합니다 (fail-closed)." >&2
  exit 2
}
_SRC_COMMIT="$(git rev-parse --verify 'HEAD^{commit}' 2>/dev/null)" || {
  echo "❌ HEAD 커밋을 해석할 수 없습니다 — migration은 커밋된 blob에서만 실행합니다." >&2
  exit 2
}
_MIG_NAMES="$(git ls-tree --name-only "${_SRC_COMMIT}:db/migrations" 2>/dev/null | grep -E '\.sql$' | sort || true)"
[ -n "$_MIG_NAMES" ] || { echo "❌ ${_SRC_COMMIT} 커밋에 db/migrations/*.sql 이 없습니다." >&2; exit 2; }
_WORK_NAMES="$(for _wf in db/migrations/*.sql; do [ -e "$_wf" ] && basename "$_wf"; done | sort)"
if [ "$_MIG_NAMES" != "$_WORK_NAMES" ]; then
  echo "❌ 작업트리의 마이그레이션 목록이 커밋(${_SRC_COMMIT})과 다릅니다 — 미추적/누락 파일을 커밋하거나 정리한 뒤 실행하세요 (fail-closed)." >&2
  diff <(printf '%s\n' "$_MIG_NAMES") <(printf '%s\n' "$_WORK_NAMES") >&2 || true
  exit 1
fi
if ! git diff --quiet "$_SRC_COMMIT" -- db/migrations 2>/dev/null; then
  echo "❌ db/migrations/ 에 커밋되지 않은 변경이 있습니다 — 커밋된 blob과 파일이 갈라져 적용하지 않습니다 (fail-closed)." >&2
  git --no-pager diff --stat "$_SRC_COMMIT" -- db/migrations >&2 || true
  exit 1
fi

# ── 리뷰 16차 P1(8차 2회): 공개 마이그레이션의 "완전 manifest" ──────────────────
# 8차 1회의 pin은 파일별 checksum 대조에 그쳐 세 구멍이 남았다 (실측):
#   (a) 커밋에서 004를 "삭제"하면 001·002·003·005만 적용하고 rc=0/up-to-date —
#       pin은 존재하는 파일만 검사했다.
#   (b) 이미 적용된 version은 apply 루프의 skip 분기에서 pin 검사 자체를 건너뛰어,
#       배포된 DB에 대해 공개본 변조가 무검증으로 통과했다.
#   (c) 이번에 공개할 005가 pin 목록에 없었다.
# 이제 manifest는 "공개된 전 version의 이름+sha256 전량"이며, apply/status 어느
# 경로든 시작 전에 다음을 강제한다 (적용 여부·순서와 무관, fail-closed):
#   0. 모든 migration 이름은 고정 폭 3자리 숫자 prefix(NNN_) + [A-Za-z0-9_]다 —
#      비정형 이름은 정렬·대역 비교·SQL literal 어디서도 신뢰할 수 없다 (거부)
#   1. manifest의 모든 version이 커밋에 존재하고(substring이 아니라 "정확한
#      파일명 집합" 대조) bytes가 정확히 일치 — 001~005 전부 동일 규칙, 예외 없음
#      (8라운드 후속 P1: 005만 checksum 비교를 생략하는 하드코딩 우회가 있었다)
#   2. 커밋의 published 대역(manifest 최대 version 이하)에 manifest 밖 파일 없음
#   3. manifest 밖 신규 version(미공개)은 manifest 최대 version보다 커야 한다
# 새 version을 공개(push)할 때 그 sha256을 여기에 추가하는 것이 릴리스 계약이다.
_MANIFEST="001_init a1296198221932cf0313dec362ef9ff5d4336ab935cdf17f9f1981b9efeb4a4b
002_schema_contract_fixes 40965ac72a0442177abeff67bd53a0c6ec2e30be1e53bf19499f66a1aa6114c7
003_soft_delete_invariant b7b7a364f1dc5418097e906f122c6eac221b676741381ca06e395b33c54855cb
004_soft_delete_contract 94525fde054c473e87e06d060089f81e9475d65669cbe19953a12b5f591e66a4
005_ownership_repair_and_lock_contract de44c03e386272b4a06aa7e36b8c354b1cbea830fc3c1721fdaf2fcd73b36af5"
_MANIFEST_MAX="005"

_sha_of_blob() {  # $1=커밋 내 경로 → sha256 (blob bytes 그대로; 셸 변수 경유 없음)
  git cat-file blob "${_SRC_COMMIT}:$1" 2>/dev/null \
    | { shasum -a 256 2>/dev/null || sha256sum 2>/dev/null; } | awk '{print $1; exit}'
}

_mig_verify_manifest() {
  local _v _want _got _n _seq _rc=0
  # 0) 이름 형식: 고정 폭 3자리 숫자 + '_' + [A-Za-z0-9_]만. 이 검증이
  #    이후의 문자열 정렬 비교(대역 판정)와 SQL literal 삽입('$v')을 안전하게 한다.
  for _n in $_MIG_NAMES; do
    _v="${_n%.sql}"
    case "$_v" in
      [0-9][0-9][0-9]_?*) : ;;
      *)
        echo "❌ ${_n}: migration 이름이 고정 폭 3자리 숫자 형식(NNN_name.sql)이 아닙니다 (fail-closed)." >&2
        _rc=1; continue
        ;;
    esac
    case "$_v" in
      *[!A-Za-z0-9_]*)
        echo "❌ ${_n}: migration 이름에 허용되지 않는 문자가 있습니다 ([A-Za-z0-9_].sql 만 허용, fail-closed)." >&2
        _rc=1
        ;;
    esac
  done
  [ "$_rc" -eq 0 ] || return "$_rc"
  # 1) manifest 전량: "정확한 파일명 집합" 대조(-Fx; substring 매칭은 상위 이름에
  #    포함된 공개 이름을 존재로 오판했다) + bytes 일치 — 전 항목 동일 규칙.
  while read -r _v _want; do
    [ -n "$_v" ] || continue
    if ! printf '%s\n' "$_MIG_NAMES" | grep -Fxq "${_v}.sql"; then
      echo "❌ 공개된 마이그레이션 ${_v}.sql 이 커밋(${_SRC_COMMIT})에 없습니다 — 공개본 삭제/누락/개명은 허용되지 않습니다 (fail-closed)." >&2
      _rc=1; continue
    fi
    _got="$(_sha_of_blob "db/migrations/${_v}.sql")"
    if [ "$_got" != "$_want" ]; then
      echo "❌ ${_v}: 공개본 checksum과 다릅니다 (expected ${_want}, got ${_got:-?}) — 공개된 마이그레이션의 내용 변경은 허용되지 않습니다. 변경분은 새 version(00N_*.sql)으로 작성하세요 (fail-closed)." >&2
      _rc=1
    fi
  done <<MANIFEST_EOF
$_MANIFEST
MANIFEST_EOF
  # 2·3) 커밋 쪽 파일이 manifest와 정합하는지 — 등재 여부도 첫 열 "정확 대조"로
  #      판정한다. published 대역 내 미등재 금지, 미공개 version은 최대치 초과만.
  for _n in $_MIG_NAMES; do
    _v="${_n%.sql}"
    if printf '%s\n' "$_MANIFEST" | awk '{print $1}' | grep -Fxq "$_v"; then
      continue
    fi
    _seq="${_v%%_*}"
    if [ "$_seq" \< "$_MANIFEST_MAX" ] || [ "$_seq" = "$_MANIFEST_MAX" ]; then
      echo "❌ ${_v}: 공개 대역(≤ ${_MANIFEST_MAX})의 version인데 manifest에 없습니다 — 공개본 교체/추가는 허용되지 않습니다 (fail-closed)." >&2
      _rc=1
    fi
  done
  return "$_rc"
}
_mig_verify_manifest || exit 1

if [ "$MODE" = "status" ]; then
  # 리뷰 16차 P1: status는 읽기 전용 — 어떤 쓰기도 하지 않는다 (ledger가 없으면
  # 만들지 않고 전부 pending으로 보고).
  # 리뷰 16차 P2(8차 2회): inventory는 apply와 "같은" HEAD 커밋 기준이다 —
  # 과거에는 status가 작업트리를, apply가 HEAD를 봐서 미추적 migration을
  # pending으로 보여주면서 실제 apply는 거부하는 불일치가 있었다. (작업트리
  # 발산 자체는 위 preflight가 이미 거부하므로 두 경로의 목록이 항상 같다.)
  echo "── DB: ${PGDATABASE} @ ${PGHOST}:${PGPORT} (schema: ${PGSCHEMA}, commit: ${_SRC_COMMIT})"
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select to_regclass('\"${PGSCHEMA}\".schema_migrations') is not null"; then
    echo "❌ ledger 존재 확인 실패: $_MIG_OUT" >&2
    exit 3
  fi
  _ledger="$_MIG_OUT"
  [ "$_ledger" = "t" ] || echo "   (schema_migrations 없음 — 아직 한 번도 적용되지 않은 DB)"
  for _name in $_MIG_NAMES; do
    v="${_name%.sql}"
    if [ "$_ledger" = "t" ] && applied "$v"; then echo "  ✓ $v (applied)"; else echo "  · $v (pending)"; fi
  done
  # 7라운드 P1(#5): 마지막 조회의 자손 정리 중 기록된 신호가 exit 0으로 유실됐다
  # (실측: rc=0 + applied 5). 종료 직전 최종 검사로 128+N 종료를 보장한다.
  _mig_check_sig
  exit 0
fi

# 신호 계약·psql 실행 경로(_mig_psql)는 위(접속 검증 앞)에서 정의됐다 —
# 재재리뷰 P1 #1: apply 경로도 같은 helper 하나만 쓴다.

# 14라운드 P2 → 15라운드 P1(#2·#3)·P2: 배포 preflight — bootstrap(schema/ledger
# 생성)과 apply "이전"에 배포 identity 계약을 전부 확정한다. 종전에는 (a) 잘못된
# named role로도 bootstrap이 schema·빈 ledger를 남겼고, (b) MIGRATION_OWNER의
# 문법·존재·적용 가능성 검증이 사후라 fresh 배포에서 001~005와 ledger 5행이 먼저
# commit됐고, (c) named role의 "미래 소유자로의 SET ROLE 가능성"도 사후 거부였다
# (전부 실측 — 비원자 배포 상태 잔존).
if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select current_user"; then
  echo "❌ preflight: 실행 role 조회 실패: ${_MIG_OUT}" >&2
  exit 3
fi
_mig_pre_cur="$_MIG_OUT"
# (1) MIGRATION_OWNER: 문법 → 존재 → 적용 방식. runner는 소유자 이전을 수행하지
# 않으므로, pending migration이 있는 배포에서 실행 role과 다른 owner pin은 만들
# 수 없는 상태에 대한 승인이다 — 시작 전에 거부한다. pin의 용도는 "이미 그
# 소유자로 배포된 DB"의 검증 승인이다.
if [ -n "${MIGRATION_OWNER:-}" ]; then
  case "$MIGRATION_OWNER" in
    ""|*[!A-Za-z0-9_]*)
      echo "❌ preflight: MIGRATION_OWNER가 유효한 식별자가 아닙니다: '${MIGRATION_OWNER}' (fail-closed)." >&2
      exit 2
      ;;
  esac
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select exists (select 1 from pg_roles where rolname = '${MIGRATION_OWNER}')"; then
    echo "❌ preflight: MIGRATION_OWNER 조회 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ "$_MIG_OUT" != "t" ]; then
    echo "❌ preflight: MIGRATION_OWNER role '${MIGRATION_OWNER}'가 존재하지 않습니다 — 배포 전에 거부합니다 (fail-closed)." >&2
    exit 1
  fi
fi
# pending 판정 + 기존 ledger 소유자 결속 — ledger가 없으면 전부 pending, 있으면
# manifest 대비 미적용 여부. 15라운드 P1(#2)는 fresh(ledger 없음)만 다뤘다 —
# 16라운드 P1(#3): "이미 부분 배포된"(ledger 존재) DB에서 실행 role이 기존
# 소유자와 다르면, pending 적용이 새 객체를 다른 소유자로 만들어 배포 identity를
# 깬다 (실측: owner A의 001~004에 runner B로 005 적용 후 사후 mismatch). 기존
# ledger 소유자를 읽어 배포 소유자 anchor에 결속한다.
_mig_pending=0
_mig_ledger_owner=""
if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select to_regclass('\"${PGSCHEMA}\".schema_migrations') is not null"; then
  echo "❌ preflight: ledger 존재 확인 실패: ${_MIG_OUT}" >&2
  exit 3
fi
if [ "$_MIG_OUT" != "t" ]; then
  _mig_pending=1
else
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce((select r.rolname from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_roles r on r.oid = c.relowner where n.nspname = '${PGSCHEMA}' and c.relname = 'schema_migrations'), '')"; then
    echo "❌ preflight: 기존 ledger 소유자 조회 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _mig_ledger_owner="$_MIG_OUT"
  for _name in $_MIG_NAMES; do
    applied "${_name%.sql}" || { _mig_pending=1; break; }
  done
fi
# 배포 소유자 anchor: 명시 pin > 기존 ledger 소유자(부분 배포) > 실행 role(fresh).
if [ -n "${MIGRATION_OWNER:-}" ]; then
  _mig_expected_owner="$MIGRATION_OWNER"
elif [ -n "$_mig_ledger_owner" ]; then
  _mig_expected_owner="$_mig_ledger_owner"
else
  _mig_expected_owner="$_mig_pre_cur"
fi
# 재재리뷰 P1(#1): 명시 pin은 기존 ledger 소유자를 "재지정"하지 않는다 — runner는
# 소유자 이전을 수행하지 않으므로, pin의 유일한 용도는 "이미 그 소유자로 배포된
# DB"의 검증 승인이다. 기존 ledger 소유자(A)가 있는데 그와 다른 pin(예: 실행
# role B)을 주면, 종전에는 pin이 anchor를 무조건 이겨(_mig_expected_owner=pin)
# 기존 소유자 A를 가린 채 실행 role로 pending을 적용하고 ledger가 4→5행이 된
# 뒤에야 사후 anchor 검사에서 rc=1이었다 (실측). 적용 전에 거부한다.
if [ -n "${MIGRATION_OWNER:-}" ] && [ -n "$_mig_ledger_owner" ] && [ "$MIGRATION_OWNER" != "$_mig_ledger_owner" ]; then
  echo "❌ preflight: MIGRATION_OWNER pin('${MIGRATION_OWNER}')이 기존 ledger 소유자('${_mig_ledger_owner}')와 다릅니다 — pin은 소유자를 재지정하지 않으며, 이미 그 소유자로 배포된 DB의 검증 승인일 뿐입니다. 소유자 변경은 별도 절차로 수행하고, 검증 승인이면 MIGRATION_OWNER='${_mig_ledger_owner}'로 지정하세요. 배포 전에 거부합니다 (fail-closed)." >&2
  exit 1
fi
# 배포 소유자 identity는 아래 preflight drift 스캔과 advisory 트랜잭션 내부 guard의
# SQL literal에 삽입되므로 식별자 문자셋을 강제한다 (fail-closed).
case "$_mig_expected_owner" in
  ""|*[!A-Za-z0-9_]*)
    echo "❌ preflight: 배포 소유자 identity가 유효한 식별자가 아닙니다: '${_mig_expected_owner}' (fail-closed)." >&2
    exit 2
    ;;
esac
# pending 적용은 "배포 소유자"가 수행해야 한다 — runner는 소유자 이전을 하지
# 않으므로 새 객체는 실행 role 소유가 된다. 실행 role ≠ 배포 소유자면 새 객체가
# anchor와 어긋나므로 적용 "전"에 거부한다.
if [ "$_mig_pending" -eq 1 ] && [ "$_mig_pre_cur" != "$_mig_expected_owner" ]; then
  echo "❌ preflight: pending migration이 있는데 실행 role('${_mig_pre_cur}')이 배포 소유자('${_mig_expected_owner}'$([ -n "$_mig_ledger_owner" ] && [ -z "${MIGRATION_OWNER:-}" ] && echo ' — 기존 ledger 소유자')$([ -n "${MIGRATION_OWNER:-}" ] && echo ' — MIGRATION_OWNER pin'))과 다릅니다 — runner는 소유자 이전을 수행하지 않으므로 새로 만들어지는 객체는 실행 role 소유가 되어 배포 identity와 어긋납니다. 배포 소유자로 접속해 적용하세요. 배포 전에 거부합니다 (fail-closed)." >&2
  exit 1
fi
# 재재리뷰 P1(#2): 배포 소유자 anchor는 ledger(schema_migrations) 소유자만 봤다 —
# 보호 테이블·helper의 소유자 drift(예: events가 다른 role 소유)는 apply 후
# _mig_verify_acl에서야 잡혀 005가 commit되고 ledger가 4→5행이 된 뒤 rc=1이었다
# (실측). pending 적용 "전"에, 현재 존재하는 보호 테이블과 helper(진입점 제외)의
# 소유자가 전부 배포 소유자와 같은지 확인한다 — 아직 만들어지지 않은 객체는
# 카탈로그에 행이 없어 자연히 건너뛴다 (fresh·부분 배포 무해).
if [ "$_mig_pending" -eq 1 ]; then
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || '=' || r.rolname as v from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_roles r on r.oid = c.relowner where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and r.rolname <> '${_mig_expected_owner}' union all select p.proname || '()=' || r.rolname from pg_proc p join pg_namespace n on n.oid = p.pronamespace join pg_roles r on r.oid = p.proowner where n.nspname = '${PGSCHEMA}' and p.proname in ('users_scrub_on_delete','reject_rows_for_deleted_user','sessions_guard','events_guard','events_scrub_marker_immutable','purchases_user_id_immutable') and r.rolname <> '${_mig_expected_owner}') s"; then
    echo "❌ preflight: 보호 객체 소유자 확인 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ preflight: 보호 객체 소유자가 배포 소유자('${_mig_expected_owner}')와 다릅니다: ${_MIG_OUT} — 소유자는 ACL과 무관하게 hard-delete가 가능하므로, drift가 있는 채로 pending을 적용하면 배포 identity가 깨집니다. ALTER TABLE/FUNCTION ... OWNER TO ${_mig_expected_owner}; 로 정리(또는 정당한 변경이면 MIGRATION_OWNER로 승인) 후 재실행하세요. 배포 전에 거부합니다 (fail-closed)." >&2
    exit 1
  fi
fi
# (2) 명시 runtime role: 존재 → SUPERUSER → 배포 소유자로의 SET/INHERIT/ADMIN 경로.
_mig_pre_owner="$_mig_expected_owner"
if [ -n "$_MIG_APP_ROLES" ]; then
  _mig_roles_ifs="$IFS"; IFS=','
  for _mr in $_MIG_APP_ROLES; do
    IFS="$_mig_roles_ifs"
    [ -n "$_mr" ] || { IFS=','; continue; }
    if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce((select case when rolsuper then 'superuser' else 'ok' end from pg_roles where rolname = '${_mr}'), 'missing')"; then
      echo "❌ preflight: runtime role '${_mr}' 조회 실패: ${_MIG_OUT}" >&2
      exit 3
    fi
    case "$_MIG_OUT" in
      ok) : ;;
      missing)
        echo "❌ preflight: MIGRATION_APP_ROLES의 role '${_mr}'가 존재하지 않습니다 — 배포(bootstrap·005·ledger 기록) 전에 거부합니다 (fail-closed)." >&2
        exit 1 ;;
      *)
        echo "❌ preflight: MIGRATION_APP_ROLES의 role '${_mr}'가 SUPERUSER입니다 — ACL·RLS를 전부 우회하므로 유일 진입점 계약이 성립하지 않습니다. 배포 전에 거부합니다 (fail-closed)." >&2
        exit 1 ;;
    esac
    # 15라운드 P1(#3) → 16라운드 P1(#1·#2): 배포 소유자(미래 테이블 owner)로의
    # 세 경로 전부를 적용 "전"에 검사한다 (PG16 의미). SET=전환(SET ROLE로 전권),
    # INHERIT=상속(소유자 권한 직접 실효 — DELETE/TRUNCATE), ADMIN=재부여(다른
    # login에 SET 가능 membership을 찍어 우회 escalation). 종전 SET-only는
    # INHERIT TRUE(사후 실효 검사에서야 rc=1)와 ADMIN TRUE(최종까지 rc=0)를
    # 놓쳤다 (전부 실측, PG16).
    if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select concat_ws(',', case when pg_has_role('${_mr}', '${_mig_pre_owner}', 'SET') then 'SET' end, case when pg_has_role('${_mr}', '${_mig_pre_owner}', 'USAGE') then 'INHERIT' end, case when pg_has_role('${_mr}', '${_mig_pre_owner}', 'MEMBER WITH ADMIN OPTION') then 'ADMIN' end)"; then
      echo "❌ preflight: role '${_mr}' membership 조회 실패: ${_MIG_OUT}" >&2
      exit 3
    fi
    if [ -n "$_MIG_OUT" ]; then
      echo "❌ preflight: MIGRATION_APP_ROLES의 role '${_mr}'가 배포 소유자 role('${_mig_pre_owner}')에 대해 [${_MIG_OUT}] 경로를 가집니다 — SET(전환)·INHERIT(상속)·ADMIN(재부여) 어느 것이든 진입점을 우회한 hard-delete로 이어집니다 (ADR 0004 위반). REVOKE ${_mig_pre_owner} FROM ${_mr}; (또는 GRANT ... WITH SET FALSE, INHERIT FALSE, ADMIN FALSE) 후 재실행하세요. 배포 전에 거부합니다 (fail-closed)." >&2
      exit 1
    fi
    IFS=','
  done
  IFS="$_mig_roles_ifs"
fi

# ledger 부트스트랩 (apply 전용 — 존재 보장, 이후 guard/INSERT가 의존).
# 리뷰 15차 P1: CREATE TABLE IF NOT EXISTS도 동시 실행에서 pg_type 충돌로 실패할 수
# 있다 — advisory lock 아래에서 수행해 부트스트랩 자체를 직렬화한다.
# 리뷰 16차 P1: schema 파라미터가 public이 아니면 스키마도 여기서 보장한다.
# 리뷰 16차 P1(4차): ledger DDL도 schema-qualified (search_path 무관).
_bootstrap_ddl="CREATE TABLE IF NOT EXISTS \"${PGSCHEMA}\".schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
# 재재리뷰 P1 #1: bootstrap도 foreground psql이 아니라 _mig_psql 경유 — TERM이
# psql 종료까지 지연되지 않는다.
if [ "$PGSCHEMA" = "public" ]; then
  _mig_psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
    -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
    -c "$_bootstrap_ddl" || { echo "❌ schema_migrations 부트스트랩 실패: $_MIG_OUT" >&2; exit 3; }
else
  _mig_psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
    -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
    -c "CREATE SCHEMA IF NOT EXISTS \"${PGSCHEMA}\"" \
    -c "$_bootstrap_ddl" || { echo "❌ schema/ledger 부트스트랩 실패: $_MIG_OUT" >&2; exit 3; }
fi

# 4라운드 → 5라운드(#7): 미지정은 위에서 fail-closed로 거부된다. 여기 도달하는
# 빈 목록은 @self 명시 승인뿐 — 정보성 고지만 남긴다.
if [ -z "$_MIG_APP_ROLES" ]; then
  echo "ℹ️  MIGRATION_APP_ROLES=@self — 005 진입점 ACL(EXECUTE·schema USAGE)을 migration 실행 role(${PGUSER})에 부여합니다 (명시 승인됨)." >&2
fi

# Owner 검증은 단순 재조회만으로는 EXECUTE와 원자적으로 결속되지 않는다. 외부
# ALTER ... OWNER가 guard 직후 첫 DDL의 lock 대기 중에 commit되면, advisory lock을
# 따르지 않는 세션은 종전 guard를 빠져나갈 수 있었다. transaction이 끝날 때까지
# 보호 relation은 ACCESS SHARE로, 기존 보호 function은 동일 COMMENT 재설정으로
# object lock을 보유한다. COMMENT는 현재 값을 그대로 사용하므로 의미 변경은 없고,
# owner가 lock 전에 바뀌면 아래 guard가 잡으며 lock 뒤 변경은 commit까지 대기한다.
_mig_emit_owner_locks() {
  printf '%s\n' "DO \$ownerlocks\$ DECLARE _r record;"
  printf '%s\n' "BEGIN"
  printf '%s\n' "  FOR _r IN SELECT n.nspname, c.relname FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace WHERE n.nspname = '${PGSCHEMA}' AND c.relname IN ('schema_migrations','users','sessions','streaks','user_fortunes','events','purchases') AND c.relkind IN ('r','p') ORDER BY c.relname LOOP"
  printf '%s\n' "    EXECUTE format('LOCK TABLE %I.%I IN ACCESS SHARE MODE', _r.nspname, _r.relname);"
  printf '%s\n' "  END LOOP;"
  printf '%s\n' "  FOR _r IN SELECT p.oid, n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) AS args, obj_description(p.oid, 'pg_proc') AS description FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace WHERE n.nspname = '${PGSCHEMA}' AND p.proname IN ('users_scrub_on_delete','reject_rows_for_deleted_user','sessions_guard','events_guard','events_scrub_marker_immutable','purchases_user_id_immutable','app_soft_delete_user') ORDER BY p.proname LOOP"
  printf '%s\n' "    EXECUTE format('COMMENT ON FUNCTION %I.%I(%s) IS %L', _r.nspname, _r.proname, _r.args, _r.description);"
  printf '%s\n' "  END LOOP;"
  printf '%s\n' "END \$ownerlocks\$;"
}

_mig_emit_owner_guard() {
  printf '%s\n' "DO \$ownerguard\$ DECLARE _exp text := '${_mig_expected_owner}'; _bad text;"
  printf '%s\n' "BEGIN"
  printf '%s\n' "  SELECT c.relname || '=' || r.rolname INTO _bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_roles r ON r.oid = c.relowner WHERE n.nspname = '${PGSCHEMA}' AND c.relname = 'schema_migrations' AND r.rolname <> _exp LIMIT 1;"
  printf '%s\n' "  IF FOUND THEN RAISE EXCEPTION 'deploy owner guard(ledger): %, expected % (fail-closed)', _bad, _exp; END IF;"
  printf '%s\n' "  SELECT c.relname || '=' || r.rolname INTO _bad FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace JOIN pg_roles r ON r.oid = c.relowner WHERE n.nspname = '${PGSCHEMA}' AND c.relname IN ('users','sessions','streaks','user_fortunes','events','purchases') AND r.rolname <> _exp LIMIT 1;"
  printf '%s\n' "  IF FOUND THEN RAISE EXCEPTION 'deploy owner guard(table): %, expected % (fail-closed)', _bad, _exp; END IF;"
  printf '%s\n' "  SELECT p.proname || '()=' || r.rolname INTO _bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_roles r ON r.oid = p.proowner WHERE n.nspname = '${PGSCHEMA}' AND p.proname IN ('users_scrub_on_delete','reject_rows_for_deleted_user','sessions_guard','events_guard','events_scrub_marker_immutable','purchases_user_id_immutable') AND r.rolname <> _exp LIMIT 1;"
  printf '%s\n' "  IF FOUND THEN RAISE EXCEPTION 'deploy owner guard(helper): %, expected % (fail-closed)', _bad, _exp; END IF;"
  printf '%s\n' "  SELECT p.proname || '()=' || r.rolname INTO _bad FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace JOIN pg_roles r ON r.oid = p.proowner WHERE n.nspname = '${PGSCHEMA}' AND p.proname = 'app_soft_delete_user' AND r.rolname <> 'shaman_softdelete' LIMIT 1;"
  printf '%s\n' "  IF FOUND THEN RAISE EXCEPTION 'deploy owner guard(entrypoint): %, expected shaman_softdelete (fail-closed)', _bad; END IF;"
  printf '%s\n' "END \$ownerguard\$;"
}

for _name in $_MIG_NAMES; do
  _mig_check_sig  # 8차: bootstrap·직전 migration 사이에 온 신호 — 새 작업 시작 금지
  v="${_name%.sql}"
  if applied "$v"; then
    echo "── skip  $v (이미 적용됨)"
    continue
  fi
  echo "── apply $v"
  # 리뷰 16차 P1 재재수정: 원자성 경계를 수제 파서(AWK scanner)가 아니라 "서버"가
  # 강제한다. 파일 내용을 고유 dollar-quote 리터럴로 감싸 DO 블록의 EXECUTE(SPI)로
  # 실행하면, 원자 컨텍스트에서 서버 자신이 다음을 거부한다 (전부 실측 검증):
  #   - transaction control(BEGIN/COMMIT/ROLLBACK/…):
  #     "EXECUTE of transaction commands is not implemented" → 전체 rollback
  #   - psql meta command(\i 외부 파일 포함·\! 셸 실행 등): psql이 해석하지 않고
  #     (dollar-quote 내부) 서버에 도달해 syntax error — 셸/포함 실행 자체가 불가능
  #   - COPY FROM STDIN: "cannot COPY to/from client in PL/pgSQL"
  #   - E-string·중첩 dollar-quote·form-feed·주석: 서버의 실제 lexer가 처리
  #     (수제 파서의 오탐/미탐 소멸)
  # 남은 파서 의존은 "고유 태그가 내용에 문자열로 존재하지 않음" 포함 검사뿐이다.
  # 리뷰 16차 P1(5차→7차): checksum과 실행 내용은 "runner 소유 snapshot 하나"에서
  # 얻되, snapshot의 원천은 mutable 파일이 아니라 고정 커밋의 "blob"이다 (위
  # preflight 주석 참조). blob OID 재해시로 snapshot bytes를 검증한다 — torn
  # read·in-place 변조·atomic replace 전부 무관해진다.
  _blob="$(git rev-parse -q --verify "${_SRC_COMMIT}:db/migrations/${_name}" 2>/dev/null || true)"
  if [ -z "$_blob" ]; then
    echo "❌ $v: 커밋(${_SRC_COMMIT})에서 blob을 해석할 수 없습니다 — 적용하지 않습니다 (fail-closed)." >&2
    exit 1
  fi
  _snap="$(mktemp "${TMPDIR:-/tmp}/dbmig-snap.XXXXXX")" || { echo "❌ snapshot temp 생성 실패." >&2; exit 3; }
  _mig_tmp_add "$_snap"
  if ! git cat-file blob "$_blob" > "$_snap" 2>/dev/null; then
    rm -f "$_snap"; echo "❌ $v: blob 읽기 실패 (${_blob})." >&2; exit 3
  fi
  if [ "$(git hash-object -t blob -- "$_snap" 2>/dev/null)" != "$_blob" ]; then
    rm -f "$_snap"
    echo "❌ $v: snapshot이 blob ${_blob}과 일치하지 않습니다 — 적용하지 않습니다 (fail-closed)." >&2
    exit 1
  fi
  # 리뷰 16차 P1(8차 2회, 실측): 검증한 blob과 "실제 실행 SQL"이 달랐다 —
  # _content="$(cat "$_snap")"의 command substitution은 (a) NUL byte를 버리고
  # (b) 후행 개행을 전부 제거한다. 즉 <유효 SQL><NUL> migration이 변형된 채
  # 적용되고 ledger에도 기록됐다: blob 검증은 통과했는데 서버가 본 bytes는
  # 다른 것이다. 셸 변수 round-trip을 완전히 제거하고, wrapper는 snapshot
  # "파일 자체"를 스트림으로 이어붙여 구성한다 (bytes 무변형).
  #   - NUL: SQL 텍스트에 있을 수 없고 서버 프로토콜도 텍스트다 — 포함 시 거부.
  #   - 개행: 태그가 내용에 개행 없이 밀착한다 — EXECUTE 문자열에 원본 밖의
  #     byte가 단 하나도 추가되지 않는다 (아래 서버측 octet_length+md5가 강제).
  if [ ! -s "$_snap" ]; then
    rm -f "$_snap"
    echo "❌ $v: 빈 마이그레이션 파일 — 적용할 수 없습니다." >&2
    exit 1
  fi
  # NUL 검출: 셸은 NUL을 변수에 담을 수 없으므로($'\x00'는 빈 패턴) grep 패턴으로
  # 찾을 수 없다 — NUL을 지운 크기와 원본 크기를 비교한다 (bytes 기준, portable).
  _raw_sz="$(wc -c < "$_snap" | tr -d ' ')"
  _nonul_sz="$(LC_ALL=C tr -d '\000' < "$_snap" | wc -c | tr -d ' ')"
  if [ "$_raw_sz" != "$_nonul_sz" ]; then
    rm -f "$_snap"
    echo "❌ $v: NUL byte가 포함되어 있습니다 — SQL로 실행할 수 없습니다 (fail-closed)." >&2
    exit 1
  fi
  # 리뷰 16차 8라운드 후속 P2: wrapper가 dollar-quote 앞뒤에 개행을 넣어 서버의
  # EXECUTE 문자열이 blob보다 길었다(suffix \n). 이제 (a) 태그가 내용에 개행 없이
  # 밀착하고, (b) "서버 자신이" 실행 직전 octet_length+md5로 EXECUTE 문자열이
  # 검증된 blob과 byte-identical함을 강제한다 — 한 byte라도 다르면 예외로 전체
  # rollback (encoding 변환이 끼어든 경우도 여기서 거부된다, fail-closed).
  _mig_md5="$(cat "$_snap" | { md5sum 2>/dev/null || md5 2>/dev/null; } | awk '{print $1; exit}')"
  case "$_mig_md5" in
    *[!0-9a-f]*|"") _mig_md5="" ;;
  esac
  if [ -z "$_mig_md5" ] || [ "${#_mig_md5}" -ne 32 ]; then
    rm -f "$_snap"
    echo "❌ $v: md5 계산 실패 — 실행 문자열의 byte-identity를 검증할 수 없어 실행하지 않습니다 (fail-closed)." >&2
    exit 3
  fi
  # dollar-quote 태그 충돌 검사도 파일 bytes에 대해 직접 수행 (변수 경유 없음).
  _t1=""; _t2=""
  while :; do
    _t1="do_${RANDOM}${RANDOM}${RANDOM}"
    _t2="sql_${RANDOM}${RANDOM}${RANDOM}"
    [ "$_t1" != "$_t2" ] || continue
    LC_ALL=C grep -qF -e "\$${_t1}\$" -e "\$${_t2}\$" "$_snap" 2>/dev/null && continue
    break
  done
  _pre="$(mktemp "${TMPDIR:-/tmp}/dbmig-pre.XXXXXX")" || { rm -f "$_snap"; echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _post="$(mktemp "${TMPDIR:-/tmp}/dbmig-post.XXXXXX")" || { rm -f "$_snap" "$_pre"; echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _wrap="$(mktemp "${TMPDIR:-/tmp}/dbmig.XXXXXX")" || { rm -f "$_snap" "$_pre" "$_post"; echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _mig_tmp_add "$_pre"; _mig_tmp_add "$_post"; _mig_tmp_add "$_wrap"
  {
    printf 'SELECT pg_advisory_xact_lock(%s);\n' "$ADVISORY_KEY"
    # 재재리뷰 P1 #3(b): runtime app role 목록을 GUC로 주입 — 값은 위에서 식별자
    # 규칙([A-Za-z0-9_,])으로 검증됐으므로 single-quote literal에 안전하다.
    printf "SET LOCAL shaman.app_roles = '%s';\n" "$_MIG_APP_ROLES"
    printf 'DO $mig$ BEGIN\n'
    printf "  IF EXISTS (SELECT 1 FROM \"%s\".schema_migrations WHERE version = '%s') THEN\n" "$PGSCHEMA" "$v"
    printf "    RAISE EXCEPTION 'migration %% is already applied', '%s';\n" "$v"
    printf '  END IF;\n'
    printf 'END $mig$;\n'
    # preflight 재조회만으로는 guard 뒤 외부 ALTER OWNER를 막지 못한다. 실제 객체
    # lock을 먼저 확보한 뒤 guard를 실행하고, migration SQL 자체가 identity를
    # 깨뜨리는 경우도 같은 transaction에서 rollback되도록 EXECUTE 뒤 재검증한다.
    _mig_emit_owner_locks
    _mig_emit_owner_guard
    printf 'DO $%s$ DECLARE _mig_sql text := $%s$' "$_t1" "$_t2"
  } > "$_pre" || { rm -f "$_snap" "$_pre" "$_post" "$_wrap"; echo "❌ 래퍼 작성 실패." >&2; exit 3; }
  {
    printf '$%s$;\nBEGIN\n' "$_t2"
    printf "  IF octet_length(_mig_sql) <> %s OR md5(_mig_sql) <> '%s' THEN\n" "$_raw_sz" "$_mig_md5"
    printf "    RAISE EXCEPTION 'migration %s: EXECUTE string differs from the verified blob (fail-closed)';\n" "$v"
    printf '  END IF;\n'
    printf '  EXECUTE _mig_sql;\n'
    printf 'END $%s$;\n' "$_t1"
    _mig_emit_owner_guard
    printf "INSERT INTO \"%s\".schema_migrations (version) VALUES ('%s') ON CONFLICT (version) DO NOTHING;\n" "$PGSCHEMA" "$v"
  } > "$_post" || { rm -f "$_snap" "$_pre" "$_post" "$_wrap"; echo "❌ 래퍼 작성 실패." >&2; exit 3; }
  cat "$_pre" "$_snap" "$_post" > "$_wrap" \
    || { rm -f "$_snap" "$_pre" "$_post" "$_wrap"; echo "❌ 래퍼 스크립트 작성 실패." >&2; exit 3; }
  # 실행 직전 최종 확인: wrapper의 "SQL 구간 bytes"를 byte offset으로 잘라내
  # snapshot과 정확히 일치하는지 대조한다 — 검증한 blob과 실제 실행 bytes가
  # 한 byte라도 다르면 실행하지 않는다 (8차 2회 P1의 근본 계약).
  _pre_sz="$(wc -c < "$_pre" | tr -d ' ')"
  _snap_sz="$(wc -c < "$_snap" | tr -d ' ')"
  _cut="$(mktemp "${TMPDIR:-/tmp}/dbmig-cut.XXXXXX")" || { rm -f "$_snap" "$_pre" "$_post" "$_wrap"; echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _mig_tmp_add "$_cut"
  dd if="$_wrap" of="$_cut" bs=1 skip="$_pre_sz" count="$_snap_sz" status=none 2>/dev/null || true
  if ! cmp -s "$_cut" "$_snap"; then
    rm -f "$_snap" "$_pre" "$_post" "$_wrap" "$_cut"
    echo "❌ $v: wrapper에 담긴 SQL bytes가 검증된 blob과 다릅니다 — 실행하지 않습니다 (fail-closed)." >&2
    exit 1
  fi
  rm -f "$_snap" "$_pre" "$_post" "$_cut"
  # 단일 transaction 안에서: advisory lock → applied 재확인(guard) → SQL(EXECUTE)
  # → ledger 기록. 동시 runner의 패자는 lock 대기 후 guard의 예외로 중단된다.
  _rc=0
  _mig_psql -X -v ON_ERROR_STOP=1 -q --single-transaction -f "$_wrap" || _rc=$?
  _out="$_MIG_OUT"
  rm -f "$_wrap"
  if [ "$_rc" -ne 0 ]; then
    # 리뷰 16차 P1(오류 오판): 출력 문자열 매칭으로 skip을 판정하지 않는다 —
    # 마이그레이션 SQL의 임의 오류 메시지에 'ALREADY_APPLIED'가 포함되면 실패한
    # (미적용) 마이그레이션이 skip으로 위장되고 runner가 rc=0으로 계속 진행했다.
    # 판정의 근거는 ledger 재조회 하나뿐이다: 실패 후에도 적용 기록이 있으면
    # 동시 runner의 승리(guard 예외로 우리 transaction만 중단), 없으면 진짜 실패.
    if applied "$v"; then
      echo "── skip  $v (동시 runner가 방금 적용함)"
      continue
    fi
    echo "❌ $v 적용 실패 — transaction rollback됨 (ledger 미기록, 부분 적용 없음):" >&2
    printf '%s\n' "$_out" >&2
    exit 1
  fi
  # 적용 후 ledger 재확인 — 기록 없이 성공으로 출력하지 않는다.
  if ! applied "$v"; then
    echo "❌ $v: SQL은 통과했으나 ledger 기록이 확인되지 않습니다 — 수동 확인 필요." >&2
    exit 1
  fi
  echo "   ✓ $v"
  # 8차 2회 P1: "마지막" migration의 post-apply ledger 조회 중에 온 신호는
  # 루프 상단 검사에 닿지 못하고 그대로 사라져, 4초 뒤 rc=0 / up-to-date로
  # 종료했다 (실측). 매 iteration 끝과 최종 성공 직전에도 신호를 확인한다 —
  # 이 시점의 종료는 "여기까지는 정상 적용, 나머지는 미적용"이다.
  _mig_check_sig
done

# ── 6라운드 P1(#6): ACL 구성 증거 ────────────────────────────────────────────────
# ledger가 005를 applied로 기록하면 runner는 skip한다 — 그 사이 MIGRATION_APP_ROLES가
# 바뀌어도 ACL은 재구성되지 않는데 종전에는 up-to-date(rc=0)로 보고했다 (실측:
# late_app의 EXECUTE=false). 성공 보고의 전제로, 요청된 각 role이 진입점 EXECUTE와
# schema USAGE를 "실제로" 갖는지 서버에서 확인한다. 진입점이 아직 없으면(005 미적용
# 세트) 검증 대상이 없고, @self는 적용 주체라 자명하다.
_mig_verify_acl() {
  # 7라운드 P1(#4) → 8라운드 P1(#6): 증거는 '요청 role의 권한 보유'만이 아니라
  # ADR 0004의 정확한 배포 계약 전체다 —
  #   (a) ledger가 005 적용을 기록했으면 진입점 함수가 "존재"해야 한다 (drift 탐지)
  #   (b) PUBLIC에 EXECUTE가 없어야 한다
  #   (c) EXECUTE grantee 집합 == {요청 roles(@self는 실행 사용자), 정의자 role} —
  #       정확한 집합이다: 잔존 grant(구 role·@self 시절의 실행 사용자·migration
  #       사용자에게 얹은 불필요 EXECUTE 포함)는 전부 위반이다. 8라운드 P1(#6):
  #       종전에는 current_user를 무조건 허용해, 비-superuser migration 사용자의
  #       불필요 EXECUTE가 rc=0으로 통과했다 (실측; OWNER TO 이전 시 구 소유자
  #       ACL 항목은 새 소유자로 "치환"되므로 실행 사용자의 흔적은 정상 상태에
  #       존재하지 않는다 — 존재 자체가 잔존 grant다).
  #   (d) 요청 각 role(@self 포함)의 실효 EXECUTE + schema USAGE
  #   (e) 8라운드 P1(#6): 카탈로그 identity — proowner=shaman_softdelete,
  #       prosecdef=true, search_path 고정(pg_catalog, <schema>, pg_temp).
  #       함수 "존재"만으로는 계약이 인증되지 않는다: owner 변경(예: postgres)·
  #       SECURITY INVOKER 전환은 실제 호출을 깨뜨리는데도 rc=0이었다 (실측).
  local _r _g _applied _fn_exists _cur _allowed _ident _o_nm _rest _sd _sp_ok _sp_cur _fn _fn_sd _fn_fp
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select count(*) from \"${PGSCHEMA}\".schema_migrations where version like '005\\_%'"; then
    echo "❌ ACL 검증(ledger) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _applied="$_MIG_OUT"
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select to_regprocedure('\"${PGSCHEMA}\".app_soft_delete_user(bigint)') is not null"; then
    echo "❌ ACL 검증 query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _fn_exists="$_MIG_OUT"
  if [ "$_applied" = "0" ]; then
    return 0   # 005 미적용 세트 — 검증 대상 없음
  fi
  if [ "$_fn_exists" != "t" ]; then
    echo "❌ ledger는 005 적용을 기록했지만 진입점 함수(app_soft_delete_user)가 존재하지 않습니다 — drift(외부 DROP?). 성공으로 보고하지 않습니다 (fail-closed)." >&2
    exit 1
  fi
  # (e) 카탈로그 identity — ADR 0004 배포 계약: 소유자·SECURITY DEFINER·search_path
  # 고정까지 서버 카탈로그에서 그대로 확인한다. 비교는 공백 정규화(치환) 후 —
  # GUC 목록 직렬화의 공백 차이에 판정이 흔들리지 않는다. 식별자 quoting은
  # quote_ident로 서버가 직접 재구성해 대조한다 (schema 대소문자 안전).
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select r.rolname || '|' || p.prosecdef::text || '|' || (replace(coalesce((select option_value from pg_options_to_table(p.proconfig) where option_name = 'search_path'), ''), ' ', '') = 'pg_catalog,' || quote_ident('${PGSCHEMA}') || ',pg_temp')::text || '|' || coalesce((select option_value from pg_options_to_table(p.proconfig) where option_name = 'search_path'), '(미설정)') from pg_proc p join pg_roles r on r.oid = p.proowner where p.oid = '\"${PGSCHEMA}\".app_soft_delete_user(bigint)'::regprocedure"; then
    echo "❌ ACL 검증(카탈로그 identity) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _ident="$_MIG_OUT"
  _o_nm="${_ident%%|*}"; _rest="${_ident#*|}"
  _sd="${_rest%%|*}"; _rest="${_rest#*|}"
  _sp_ok="${_rest%%|*}"; _sp_cur="${_rest#*|}"
  if [ "$_o_nm" != "shaman_softdelete" ]; then
    echo "❌ 진입점 함수의 소유자가 '${_o_nm}'입니다 — ADR 0004는 proowner=shaman_softdelete(정의자 role)를 요구합니다. SECURITY DEFINER 컨텍스트가 달라져 실제 호출이 role 경계에서 거부됩니다. ALTER FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) OWNER TO shaman_softdelete; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if [ "$_sd" != "true" ]; then
    echo "❌ 진입점 함수가 SECURITY DEFINER가 아닙니다(prosecdef=false) — 진입점 밖 삭제를 막는 role 경계가 무력화되고 실제 호출이 실패합니다. ALTER FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) SECURITY DEFINER; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if [ "$_sp_ok" != "true" ]; then
    echo "❌ 진입점 함수의 search_path 고정이 계약과 다릅니다 (현재: ${_sp_cur}) — ADR 0004는 'pg_catalog, ${PGSCHEMA}, pg_temp' 고정을 요구합니다 (pg_temp shadowing 차단). ALTER FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) SET search_path = pg_catalog, \"${PGSCHEMA}\", pg_temp; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select current_user"; then
    echo "❌ ACL 검증(current_user) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _cur="$_MIG_OUT"
  # (f) 9라운드 P1(#7): 정의자 role 불변식 — 005의 role 검증(DO $role$)과 같은
  # 기준을 "성공 보고 전"에도 재확인한다. ledger 때문에 005는 재실행되지 않으므로,
  # 이후의 drift(LOGIN 재부여·member 추가·상위 role 편입)는 여기서만 잡힌다.
  #   - NOLOGIN: LOGIN이면 이 role로 직접 접속해 진입점을 우회할 수 있다.
  #   - member: superuser·migration 실행 role 외의 member는 SET ROLE 우회 가능.
  #   - 상위 membership: 정의자 컨텍스트가 상속으로 최소 권한을 초과한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select r.rolcanlogin::text || '|' || coalesce((select count(*) from pg_auth_members m join pg_roles mr on mr.oid = m.member where m.roleid = r.oid and (m.set_option or m.inherit_option or m.admin_option) and not mr.rolsuper and mr.rolname <> current_user), 0)::text || '|' || coalesce((select count(*) from pg_auth_members m where m.member = r.oid and (m.set_option or m.inherit_option or m.admin_option)), 0)::text || '|' || concat_ws(',', case when r.rolsuper then 'SUPERUSER' end, case when r.rolcreaterole then 'CREATEROLE' end, case when r.rolcreatedb then 'CREATEDB' end, case when r.rolreplication then 'REPLICATION' end, case when r.rolbypassrls then 'BYPASSRLS' end) from pg_roles r where r.rolname = 'shaman_softdelete'"; then
    echo "❌ ACL 검증(정의자 role 불변식) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _ident="$_MIG_OUT"
  if [ -z "$_ident" ]; then
    echo "❌ 정의자 role shaman_softdelete가 존재하지 않습니다 — drift(외부 DROP ROLE?). 성공으로 보고하지 않습니다 (fail-closed)." >&2
    exit 1
  fi
  _o_nm="${_ident%%|*}"; _rest="${_ident#*|}"
  _sd="${_rest%%|*}"; _rest="${_rest#*|}"
  _sp_cur="${_rest%%|*}"; _rest="${_rest#*|}"
  _sp_ok="$_rest"
  if [ "$_o_nm" != "false" ]; then
    echo "❌ 정의자 role shaman_softdelete에 LOGIN이 부여되어 있습니다 — 직접 접속으로 진입점을 우회할 수 있습니다 (ADR 0004 위반). ALTER ROLE shaman_softdelete NOLOGIN; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if [ "$_sd" != "0" ]; then
    echo "❌ 정의자 role shaman_softdelete에 허용되지 않은 member가 ${_sd}명 있습니다 — SET(전환)·INHERIT(상속)·ADMIN(재부여) 옵션이 켜진 member는 진입점을 우회해 직접 삭제할 수 있습니다 (허용 예외: superuser·migration 실행 role·전 옵션 FALSE membership; PG16 의미론). 해당 membership을 REVOKE한 뒤 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if [ "$_sp_cur" != "0" ]; then
    echo "❌ 정의자 role shaman_softdelete가 상위 role ${_sp_cur}개의 member입니다(SET/INHERIT/ADMIN 옵션 보유) — 정의자 컨텍스트가 상속·전환으로 최소 권한을 초과할 수 있습니다. REVOKE <role> FROM shaman_softdelete (또는 전 옵션 FALSE로 재부여) 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # 10라운드 P1(#6): role "속성" drift — SUPERUSER·CREATEROLE·CREATEDB·
  # REPLICATION·BYPASSRLS 어느 것도 정의자 role에 있으면 안 된다 (SECURITY
  # DEFINER 컨텍스트가 그 권한 전부로 실행된다).
  if [ -n "$_sp_ok" ]; then
    echo "❌ 정의자 role shaman_softdelete에 허용되지 않은 속성이 있습니다: ${_sp_ok} — SECURITY DEFINER 진입점이 이 권한으로 실행됩니다 (ADR 0004 위반). ALTER ROLE shaman_softdelete NOSUPERUSER NOCREATEROLE NOCREATEDB NOREPLICATION NOBYPASSRLS; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (g) 9~11라운드: 005가 설치한 7개 함수 전부의 identity — 존재, SECURITY 모드
  # (진입점만 DEFINER), search_path 고정, 그리고 본문 fingerprint(md5(prosrc)) +
  # language. 같은 signature·search_path의 no-op 본문 교체(11라운드 P1 #5 실측:
  # 직접 삭제 성공 / 진입점 RETURN true가 rc=0)는 fingerprint 불일치로 거부된다.
  # fingerprint는 공개 005 blob의 함수 본문에서 파생된 상수다 — 005를 재공개하면
  # _MANIFEST와 함께 갱신하는 것이 릴리스 계약이다.
  # 12라운드 P1(#4): fingerprint는 실행 계약 "전체"다 — prosrc·language·SECURITY
  # 모드에 더해 volatility·strict·retset·parallel·leakproof·반환형·인자명/모드·
  # identity args·owner·전체 proconfig(정확히 search_path 하나)를 대조한다.
  # (실측 rc=0이던 우회: IMMUTABLE 전환, lock_timeout 추가, 인자명 변경, 반환형
  # text 재생성, helper owner 변경 — 전부 거부된다.)
  # owner 계약: 진입점=shaman_softdelete(정의자), helper=배포 주체(= users 테이블
  # 소유자와 동일 — 005를 적용한 role이 테이블과 helper를 함께 소유한다).
  for _r in \
    'app_soft_delete_user(bigint)|definer|ffd2fbfec20b415c23c5231c2e46c67c|boolean|p_user bigint|p_user' \
    'users_scrub_on_delete()|invoker|a7db056a8d00469e55316a4d899a94bc|trigger||' \
    'reject_rows_for_deleted_user()|invoker|74fba7cba220486510d0d5adff25bbba|trigger||' \
    'sessions_guard()|invoker|5a5f763401b89be7d57594d1c12a76ae|trigger||' \
    'events_guard()|invoker|b31d35088836700bb9eca21ad7a914d0|trigger||' \
    'events_scrub_marker_immutable()|invoker|4ef2fd80ff807fdf617e9a32b7fdd229|trigger||' \
    'purchases_user_id_immutable()|invoker|b2bafff2e9d456222a49a73f8c4a3e2a|trigger||'; do
    _fn="${_r%%|*}"; _rest="${_r#*|}"
    _fn_sd="${_rest%%|*}"; _rest="${_rest#*|}"
    _fn_fp="${_rest%%|*}"; _rest="${_rest#*|}"
    _fn_rt="${_rest%%|*}"; _rest="${_rest#*|}"
    _fn_ar="${_rest%%|*}"; _fn_an="${_rest#*|}"
    if [ "$_fn_sd" = "definer" ]; then
      _fn_own="(select oid from pg_roles where rolname = 'shaman_softdelete')"
    else
      _fn_own="(select c.relowner from pg_class c where c.oid = to_regclass('\"${PGSCHEMA}\".users'))"
    fi
    if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce((select concat_ws(',', case when (case when p.prosecdef then 'definer' else 'invoker' end) <> '${_fn_sd}' then 'security' end, case when md5(p.prosrc) <> '${_fn_fp}' then 'body' end, case when l.lanname <> 'plpgsql' then 'language' end, case when p.provolatile <> 'v' then 'volatility' end, case when p.proisstrict then 'strict' end, case when p.proretset then 'retset' end, case when p.proparallel <> 'u' then 'parallel' end, case when p.proleakproof then 'leakproof' end, case when p.prorettype <> '${_fn_rt}'::regtype then 'rettype='||p.prorettype::regtype end, case when coalesce(array_to_string(p.proargnames, ','), '') <> '${_fn_an}' then 'argnames' end, case when p.proargmodes is not null then 'argmodes' end, case when pg_get_function_identity_arguments(p.oid) <> '${_fn_ar}' then 'args' end, case when p.proowner <> ${_fn_own} then 'owner='||p.proowner::regrole end, case when coalesce((select string_agg(replace(x, ' ', ''), ';' order by x) from unnest(p.proconfig) x), '') <> 'search_path=pg_catalog,' || quote_ident('${PGSCHEMA}') || ',pg_temp' then 'config='||coalesce(array_to_string(p.proconfig, ';'), '(없음)') end) from pg_proc p join pg_language l on l.oid = p.prolang where p.oid = to_regprocedure('\"${PGSCHEMA}\".${_fn}')), 'missing')"; then
      echo "❌ ACL 검증(함수 ${_fn}) query 실패: ${_MIG_OUT}" >&2
      exit 3
    fi
    if [ "$_MIG_OUT" = "missing" ]; then
      echo "❌ 005가 설치한 함수 ${_fn}가 존재하지 않습니다 — drift(외부 DROP?). 성공으로 보고하지 않습니다 (fail-closed)." >&2
      exit 1
    fi
    if [ -n "$_MIG_OUT" ]; then
      echo "❌ 함수 ${_fn}의 실행 계약이 공개 005의 정의와 다릅니다 (위반: ${_MIG_OUT}) — 본문·속성 변조는 계약 위반입니다. 005의 정의대로 복원 후 재실행하세요 (fail-closed)." >&2
      exit 1
    fi
  done
  # (h) 10라운드 P1(#5) → 11라운드 P1(#4): 트리거의 "정의 전체" — 존재·활성·
  # 함수 결속(tgfoid를 schema까지 정확히), tgtype(BEFORE/ROW/이벤트 비트),
  # args 없음, WHEN 없음, 컬럼 목록까지 대조한다. 같은 이름을 AFTER DELETE로
  # 재생성하거나 다른 schema의 동명 함수에 연결하는 우회(실측 rc=0)를 거부한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select t.tgname || '(' || t.tbl || '):' || case when c.oid is null then 'table-missing' when tg.oid is null then 'missing' when tg.tgenabled <> 'O' then 'disabled' when tg.tgfoid is distinct from to_regprocedure('\"${PGSCHEMA}\".' || t.fn || '()') then 'wrong-function=' || coalesce((select np.nspname || '.' || pp.proname from pg_proc pp join pg_namespace np on np.oid = pp.pronamespace where pp.oid = tg.tgfoid), '?') when tg.tgtype <> t.typ then 'wrong-type=' || tg.tgtype when tg.tgnargs <> 0 then 'has-args' when tg.tgqual is not null then 'has-when' when coalesce((select string_agg(a.attname, ',' order by a.attname) from pg_attribute a where a.attrelid = tg.tgrelid and a.attnum = any(string_to_array(tg.tgattr::text, ' ')::int2[])), '') <> t.cols then 'wrong-columns=' || coalesce((select string_agg(a.attname, ',' order by a.attname) from pg_attribute a where a.attrelid = tg.tgrelid and a.attnum = any(string_to_array(tg.tgattr::text, ' ')::int2[])), '(없음)') else 'ok' end as v from (values ('trg_users_scrub_on_delete','users','users_scrub_on_delete',19,'deleted_at'),('trg_sessions_no_deleted_user','sessions','sessions_guard',23,'user_id'),('trg_streaks_no_deleted_user','streaks','reject_rows_for_deleted_user',23,'user_id'),('trg_user_fortunes_no_deleted_user','user_fortunes','reject_rows_for_deleted_user',23,'user_id'),('trg_events_no_deleted_user','events','events_guard',23,'session_id,user_id'),('trg_purchases_no_deleted_user','purchases','reject_rows_for_deleted_user',7,''),('trg_purchases_user_id_immutable','purchases','purchases_user_id_immutable',19,'user_id'),('trg_events_scrub_marker_immutable','events','events_scrub_marker_immutable',19,'scrubbed_at')) as t(tgname,tbl,fn,typ,cols) left join pg_class c on c.oid = to_regclass('\"${PGSCHEMA}\".' || t.tbl) left join pg_trigger tg on tg.tgrelid = c.oid and tg.tgname = t.tgname) x where v not like '%:ok'"; then
    echo "❌ ACL 검증(트리거 계약) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ soft-delete 계약 트리거가 온전하지 않습니다: ${_MIG_OUT} — DROP/DISABLE/함수 교체는 계약 위반입니다 (ADR 0004). 005의 정의대로 복원 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (h-2) 12라운드 P1(#5): 허용 trigger "집합"의 정확 비교 — 계약 trigger 8개가
  # 온전해도 보호 테이블에 추가 trigger를 붙이면 계약 밖 동작이 끼어든다 (실측:
  # sessions에 추가 BEFORE trigger로 삭제 사용자 연결이 성공, rc=0). 내부(FK
  # constraint) trigger를 제외한 전체 목록이 허용 집합과 정확히 일치해야 한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(c.relname || '.' || tg.tgname, '; ' order by c.relname, tg.tgname), '') from pg_trigger tg join pg_class c on c.oid = tg.tgrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and not tg.tgisinternal and not exists (select 1 from (values ('users','trg_users_scrub_on_delete'),('sessions','trg_sessions_no_deleted_user'),('streaks','trg_streaks_no_deleted_user'),('user_fortunes','trg_user_fortunes_no_deleted_user'),('events','trg_events_no_deleted_user'),('events','trg_events_scrub_marker_immutable'),('purchases','trg_purchases_no_deleted_user'),('purchases','trg_purchases_user_id_immutable')) as w(tbl,tg) where w.tbl = c.relname and w.tg = tg.tgname)"; then
    echo "❌ ACL 검증(허용 외 트리거) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블에 계약 밖 트리거가 있습니다: ${_MIG_OUT} — 허용 집합(005의 계약 트리거 8개)만 존재해야 합니다. 추가 트리거는 soft-delete 계약(예: 삭제 사용자 연결 차단)을 우회할 수 있습니다 (ADR 0004). DROP TRIGGER 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i) 10라운드 P1(#7) → 12라운드 P1(#6): 정의자 role의 필수 객체 권한 —
  # has_table_privilege는 "실효" 권한이라 PUBLIC grant로도 참이 된다 (실측:
  # REVOKE UPDATE ON users FROM shaman_softdelete 후 GRANT UPDATE ON users TO
  # PUBLIC이면 rc=0 — 필수 검사가 계약 밖 경로로 통과). 005가 부여한 "직접"
  # grant(relacl/nspacl 항목)의 존재를 대조한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select 'USAGE ON SCHEMA' as v where not exists (select 1 from pg_namespace n cross join lateral aclexplode(coalesce(n.nspacl, acldefault('n', n.nspowner))) x where n.nspname = '${PGSCHEMA}' and x.grantee = (select oid from pg_roles where rolname = 'shaman_softdelete') and x.privilege_type = 'USAGE') union all select t.priv || ' ON ' || t.tbl from (values ('users','SELECT'),('users','UPDATE'),('events','SELECT'),('events','UPDATE'),('sessions','SELECT'),('sessions','UPDATE'),('sessions','DELETE'),('streaks','SELECT'),('streaks','UPDATE'),('streaks','DELETE'),('user_fortunes','SELECT'),('user_fortunes','UPDATE'),('user_fortunes','DELETE')) as t(tbl,priv) where to_regclass('\"${PGSCHEMA}\".' || t.tbl) is not null and not exists (select 1 from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x where c.oid = to_regclass('\"${PGSCHEMA}\".' || t.tbl) and x.grantee = (select oid from pg_roles where rolname = 'shaman_softdelete') and x.privilege_type = t.priv)) s"; then
    echo "❌ ACL 검증(정의자 객체 권한) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 정의자 role shaman_softdelete에 필수 '직접' grant가 없습니다: ${_MIG_OUT} — PUBLIC 등 간접 경로는 계약이 아닙니다. 005의 GRANT를 복원 후 재실행하세요 (예: GRANT UPDATE ON \"${PGSCHEMA}\".users TO shaman_softdelete;) (fail-closed)." >&2
    exit 1
  fi
  # (i-2) 11라운드 P2 → 13라운드 P1(#5): 최소권한은 "정확한" 집합이다 — 필수
  # 권한의 존재만이 아니라 초과 grant(예: users에 INSERT/DELETE/TRUNCATE)도,
  # 허용 권한이라도 WITH GRANT OPTION이 붙으면(재부여 권한 — 검증 창 밖에서
  # grant를 찍어낼 수 있다) 위반이다. aclexplode.is_grantable까지 대조한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select t.tbl || ': ' || a.privilege_type || case when a.is_grantable then ' (WITH GRANT OPTION)' else '' end as v from (values ('users','SELECT,UPDATE'),('events','SELECT,UPDATE'),('sessions','SELECT,UPDATE,DELETE'),('streaks','SELECT,UPDATE,DELETE'),('user_fortunes','SELECT,UPDATE,DELETE')) as t(tbl,allowed) cross join lateral (select x.privilege_type, x.is_grantable from pg_class c cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x where c.oid = to_regclass('\"${PGSCHEMA}\".' || t.tbl) and x.grantee = (select oid from pg_roles where rolname = 'shaman_softdelete')) a where position(',' || a.privilege_type || ',' in ',' || t.allowed || ',') = 0 or a.is_grantable) s"; then
    echo "❌ ACL 검증(정의자 초과 권한) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 정의자 role shaman_softdelete에 허용 집합 밖의 초과 권한이 있습니다: ${_MIG_OUT} — ADR 0004의 최소권한 계약 위반입니다. REVOKE로 정리 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-3) 12라운드 P1(#6): PUBLIC은 보호 테이블에서 권한 0 — PUBLIC grant는
  # 모든 role(runtime role 포함)에 상속되어 유일 진입점 계약을 무너뜨린다
  # (실측: GRANT DELETE ON users TO PUBLIC 후 임의 role의 hard-delete가 성공,
  # rc=0). 테이블(relacl)뿐 아니라 컬럼(attacl) 단위 grant까지 검사한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || ':' || x.privilege_type as v from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and x.grantee = 0 union all select c.relname || '.' || a.attname || ':' || x.privilege_type from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a on a.attrelid = c.oid and a.attnum > 0 and not a.attisdropped and a.attacl is not null cross join lateral aclexplode(a.attacl) x where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and x.grantee = 0) s"; then
    echo "❌ ACL 검증(PUBLIC 권한) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ PUBLIC에 보호 테이블 권한이 열려 있습니다: ${_MIG_OUT} — PUBLIC은 모든 role에 상속되어 유일 진입점 계약(ADR 0004)이 무너집니다. REVOKE ALL ON \"${PGSCHEMA}\".<테이블> FROM PUBLIC; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-4) 12라운드 P1(#6): 금지 권한 — hard-delete 경로인 users·purchases의
  # DELETE, 보호 테이블 전체의 TRUNCATE는 어떤 grantee에게도 허용되지 않는다
  # (실측: GRANT DELETE ON users TO <app role> 후 진입점 우회 hard-delete가
  # 성공, rc=0). 테이블 소유자의 항목만 예외다 — 소유자 권한은 ACL로 봉인할 수
  # 없는 암묵 권한의 반영이고, 소유자 신원은 별도 catalog 검사로 강제된다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || ':' || x.privilege_type || '=' || coalesce(r.rolname, 'PUBLIC') as v from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x left join pg_roles r on r.oid = x.grantee where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and x.grantee <> c.relowner and (x.privilege_type = 'TRUNCATE' or (x.privilege_type = 'DELETE' and c.relname in ('users','purchases')))) s"; then
    echo "❌ ACL 검증(금지 권한) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블에 금지된 파괴 권한이 grant되어 있습니다: ${_MIG_OUT} — users·purchases의 DELETE와 보호 테이블의 TRUNCATE는 진입점 우회 hard-delete 경로입니다 (ADR 0004 위반). REVOKE 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-4b) 13라운드 P1(#5) → 14라운드 P1(#4): 소유자 외 어떤 grantee도 보호
  # 테이블 권한을 WITH GRANT OPTION으로 보유할 수 없다 — 재부여 권한은 검증 시점
  # 밖에서 새 grant를 만들 수 있어 정확-집합 계약을 무의미하게 한다. 테이블
  # (relacl)뿐 아니라 "컬럼"(attacl) 단위 grant option까지 검사한다 (실측: 컬럼
  # 단위 grant option이 rc=0으로 승인됐다).
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || ':' || x.privilege_type || '=' || coalesce(r.rolname, 'PUBLIC') as v from pg_class c join pg_namespace n on n.oid = c.relnamespace cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) x left join pg_roles r on r.oid = x.grantee where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and x.grantee <> c.relowner and x.is_grantable union all select c.relname || '.' || a2.attname || ':' || x.privilege_type || '=' || coalesce(r.rolname, 'PUBLIC') from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_attribute a2 on a2.attrelid = c.oid and a2.attnum > 0 and not a2.attisdropped and a2.attacl is not null cross join lateral aclexplode(a2.attacl) x left join pg_roles r on r.oid = x.grantee where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and x.grantee <> c.relowner and x.is_grantable) s"; then
    echo "❌ ACL 검증(GRANT OPTION) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블 권한이 WITH GRANT OPTION으로 grant되어 있습니다: ${_MIG_OUT} — 재부여 권한은 검증 밖에서 새 grant를 만들 수 있습니다 (ADR 0004 위반). REVOKE GRANT OPTION FOR ... 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-6) 13라운드 P1(#4) → 14라운드 P1(#6): 보호 테이블 소유자 identity —
  # 소유자는 ACL·RLS와 무관하게 전권이므로 배포 identity의 일부다. 계약: 배포
  # 소유자는 "migration 실행 identity"(현재 접속 role)이며, 다른 소유자로
  # 운영하려면 MIGRATION_OWNER로 명시적으로 pin해야 한다 — 상대 비교(ledger와
  # 같기만 하면 통과)로는 ledger·테이블·helper를 일괄 이전하는 우회가 rc=0이었다
  # (실측). 절대 anchor(ledger 소유자 == 기대 identity)를 먼저 검증한 뒤, 6개
  # 테이블의 relowner가 ledger와 같고 정의자 role이 아님을 검증한다.
  _mig_expected_owner="${MIGRATION_OWNER:-$_cur}"
  case "$_mig_expected_owner" in
    ""|*[!A-Za-z0-9_]*)
      echo "❌ MIGRATION_OWNER가 유효한 식별자가 아닙니다: '${MIGRATION_OWNER:-}' (fail-closed)." >&2
      exit 2
      ;;
  esac
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce((select r.rolname from pg_class l join pg_namespace ln on ln.oid = l.relnamespace join pg_roles r on r.oid = l.relowner where ln.nspname = '${PGSCHEMA}' and l.relname = 'schema_migrations'), '')"; then
    echo "❌ ACL 검증(ledger 소유자) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ "$_MIG_OUT" != "$_mig_expected_owner" ]; then
    echo "❌ ledger(schema_migrations) 소유자가 배포 identity와 다릅니다: '${_MIG_OUT}' ≠ '${_mig_expected_owner}' — 배포 소유자 계약은 migration 실행 role(또는 MIGRATION_OWNER로 명시 pin한 role)입니다. 소유자 일괄 이전은 이 anchor가 거부합니다. 정당한 소유자 변경이면 MIGRATION_OWNER='${_MIG_OUT}'로 명시 승인 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || '=' || r.rolname as v from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_roles r on r.oid = c.relowner where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and (c.relowner is distinct from (select l.relowner from pg_class l join pg_namespace ln on ln.oid = l.relnamespace where ln.nspname = '${PGSCHEMA}' and l.relname = 'schema_migrations') or r.rolname = 'shaman_softdelete')) s"; then
    echo "❌ ACL 검증(테이블 소유자 identity) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블 소유자가 배포 identity(ledger 소유자)와 다릅니다: ${_MIG_OUT} — 소유자는 ACL과 무관하게 hard-delete가 가능하므로 소유자 이전은 계약 위반입니다 (ADR 0004). ALTER TABLE ... OWNER TO <ledger 소유자>; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-7) 13라운드 P1(#6): RLS drift — 보호 테이블에 RLS(relrowsecurity/
  # relforcerowsecurity)나 policy가 있으면 SECURITY DEFINER 진입점의 UPDATE가
  # 조용히 필터링되어 삭제가 no-op이 된다 (실측: app_soft_delete_user()가 false를
  # 반환, 상태 무변경인데 runner는 rc=0). 005 계약에 RLS는 없다 — 존재 자체가
  # 배포 identity 위반이다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select c.relname || ':' || case when c.relforcerowsecurity then 'rls-forced' else 'rls-enabled' end as v from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and (c.relrowsecurity or c.relforcerowsecurity) union all select c.relname || ':policy=' || p.polname from pg_policy p join pg_class c on c.oid = p.polrelid join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases')) s"; then
    echo "❌ ACL 검증(RLS/policy) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블에 RLS 또는 policy가 있습니다: ${_MIG_OUT} — 진입점(SECURITY DEFINER)의 UPDATE가 조용히 필터링되어 soft-delete가 no-op이 됩니다 (ADR 0004 위반). ALTER TABLE ... DISABLE ROW LEVEL SECURITY; / DROP POLICY 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (i-8) 14라운드 P1(#5): inheritance topology — 보호 테이블의 상속 child는
  # 계약 trigger를 상속받지 못해 child 행의 soft-delete가 계약 밖에서 실패하고
  # (실측: CHECK 오류), 보호 테이블이 남의 child가 되는 것도 계약 밖 경로다.
  # pg_inherits(선언적 파티션 포함)에 보호 테이블이 부모/자식 어느 쪽으로든
  # 나타나면 거부한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(v, '; ' order by v), '') from (select p.relname || ':child=' || c.relname as v from pg_inherits i join pg_class p on p.oid = i.inhparent join pg_class c on c.oid = i.inhrelid join pg_namespace n on n.oid = p.relnamespace where n.nspname = '${PGSCHEMA}' and p.relname in ('users','sessions','streaks','user_fortunes','events','purchases') union all select c.relname || ':parent=' || p.relname from pg_inherits i join pg_class c on c.oid = i.inhrelid join pg_class p on p.oid = i.inhparent join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases')) s"; then
    echo "❌ ACL 검증(inheritance) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 보호 테이블이 상속 관계(pg_inherits)에 있습니다: ${_MIG_OUT} — child 행에는 계약 trigger가 적용되지 않아 soft-delete 계약이 성립하지 않습니다 (ADR 0004 위반). ALTER TABLE ... NO INHERIT / DROP TABLE <child> 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # 허용 집합 = 요청 roles + 정의자 role — "정확한" 집합이다 (8라운드 P1 #6).
  # 실행 사용자는 @self 모드에서만 허용된다 (그때는 실행 사용자가 곧 runtime
  # role이다). 명시 role 모드에서 실행 사용자의 EXECUTE가 남아 있으면 그것도
  # 잔존 grant(위반)다 — OWNER TO 이전이 구 소유자 항목을 새 소유자로 치환하므로
  # 정상 배포 상태에 실행 사용자의 흔적은 없다.
  if [ -n "$_MIG_APP_ROLES" ]; then
    _allowed=",${_MIG_APP_ROLES},shaman_softdelete,"
  else
    _allowed=",${_cur},shaman_softdelete,"   # @self — 실행 사용자가 곧 runtime role
  fi
  # (b-2) 13라운드 P1(#5): 진입점 EXECUTE의 WITH GRANT OPTION 금지 — grantee
  # 이름만 비교하면 runtime role의 재부여 권한이 rc=0으로 승인됐다 (실측).
  # 소유자(정의자)의 암묵 항목 외에는 is_grantable이 전부 false여야 한다.
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(distinct coalesce(r.rolname, 'PUBLIC'), ','), '') from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a left join pg_roles r on r.oid = a.grantee where p.oid = '\"${PGSCHEMA}\".app_soft_delete_user(bigint)'::regprocedure and a.privilege_type = 'EXECUTE' and a.is_grantable and a.grantee <> p.proowner"; then
    echo "❌ ACL 검증(EXECUTE GRANT OPTION) query 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  if [ -n "$_MIG_OUT" ]; then
    echo "❌ 진입점 EXECUTE가 WITH GRANT OPTION으로 grant되어 있습니다(${_MIG_OUT}) — 해당 role이 검증 밖에서 임의 role에 EXECUTE를 재부여할 수 있습니다 (ADR 0004 위반). REVOKE GRANT OPTION FOR EXECUTE ON FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) FROM ${_MIG_OUT}; 후 재실행하세요 (fail-closed)." >&2
    exit 1
  fi
  # (b)+(c): EXECUTE grantee 전량 (PUBLIC은 grantee oid 0)
  if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(distinct coalesce(r.rolname, 'PUBLIC'), ','), '') from pg_proc p cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) a left join pg_roles r on r.oid = a.grantee where p.oid = '\"${PGSCHEMA}\".app_soft_delete_user(bigint)'::regprocedure and a.privilege_type = 'EXECUTE'"; then
    echo "❌ ACL grantee 조회 실패: ${_MIG_OUT}" >&2
    exit 3
  fi
  _mig_roles_ifs="$IFS"; IFS=','
  for _g in $_MIG_OUT; do
    IFS="$_mig_roles_ifs"
    [ -n "$_g" ] || { IFS=','; continue; }
    if [ "$_g" = "PUBLIC" ]; then
      echo "❌ 진입점 EXECUTE가 PUBLIC에 열려 있습니다 — ADR 0004 위반 (재부여된 것으로 보임). REVOKE ALL ON FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) FROM PUBLIC; 후 재실행하세요 (fail-closed)." >&2
      exit 1
    fi
    case "$_allowed" in
      *",${_g},"*) : ;;
      *)
        echo "❌ 허용 집합 밖의 role '${_g}'에 진입점 EXECUTE가 남아 있습니다 — ADR 0004는 'runtime app role에만 EXECUTE'를 요구합니다 (허용: ${_MIG_APP_ROLES:-${_cur}(@self)} + 정의자). 정리 후 재실행하세요: REVOKE EXECUTE ON FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) FROM ${_g}; (fail-closed)" >&2
        exit 1
        ;;
    esac
    IFS=','
  done
  IFS="$_mig_roles_ifs"
  # (d): 요청 각 role(@self는 실행 사용자)의 실효 권한
  _mig_roles_ifs="$IFS"; IFS=','
  for _r in ${_MIG_APP_ROLES:-$_cur}; do
    IFS="$_mig_roles_ifs"
    [ -n "$_r" ] || { IFS=','; continue; }
    if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select has_function_privilege('${_r}', '\"${PGSCHEMA}\".app_soft_delete_user(bigint)', 'EXECUTE') and has_schema_privilege('${_r}', '${PGSCHEMA}', 'USAGE')"; then
      echo "❌ role '${_r}' ACL 검증 실패(role 부재 가능): ${_MIG_OUT}" >&2
      exit 3
    fi
    if [ "$_MIG_OUT" != "t" ]; then
      echo "❌ role '${_r}'에 진입점 EXECUTE/schema USAGE가 구성되어 있지 않습니다 — 005는 ledger상 이미 적용되어 재실행되지 않으므로, MIGRATION_APP_ROLES 변경은 새 ACL migration 또는 수동 GRANT로 반영해야 합니다 (fail-closed):" >&2
      echo "   GRANT USAGE ON SCHEMA \"${PGSCHEMA}\" TO ${_r};" >&2
      echo "   GRANT EXECUTE ON FUNCTION \"${PGSCHEMA}\".app_soft_delete_user(bigint) TO ${_r};" >&2
      exit 1
    fi
    # (i-5a/b/c) 13라운드 P1(#4): 명시 runtime role의 escalation 경로 3종 —
    # SUPERUSER 속성, 보호 테이블 소유, 소유자 role로의 SET ROLE(MEMBER) 경로.
    # 셋 다 ACL 검사(직접·실효)에 잡히지 않은 채 hard-delete를 허용했다 (실측:
    # 전부 rc=0 false-green). @self는 실행 사용자 자신(마이그레이션 운영자)이므로
    # 검사 대상이 아니다 — 명시 role 모드에서만 검사한다.
    if [ -n "$_MIG_APP_ROLES" ]; then
      if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select rolsuper from pg_roles where rolname = '${_r}'"; then
        echo "❌ role '${_r}' 속성 조회 실패: ${_MIG_OUT}" >&2
        exit 3
      fi
      if [ "$_MIG_OUT" = "t" ]; then
        echo "❌ 명시 runtime role '${_r}'가 SUPERUSER입니다 — ACL·RLS를 전부 우회하므로 유일 진입점 계약이 성립하지 않습니다 (ADR 0004). NOSUPERUSER 전환 또는 별도 role 사용 후 재실행하세요 (fail-closed)." >&2
        exit 1
      fi
      if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(c.relname, ',' order by c.relname), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and c.relowner = (select oid from pg_roles where rolname = '${_r}')"; then
        echo "❌ role '${_r}' 소유 테이블 조회 실패: ${_MIG_OUT}" >&2
        exit 3
      fi
      if [ -n "$_MIG_OUT" ]; then
        echo "❌ 명시 runtime role '${_r}'가 보호 테이블을 소유합니다: ${_MIG_OUT} — 소유자는 ACL과 무관하게 hard-delete가 가능합니다 (ADR 0004 위반). ALTER TABLE ... OWNER TO <배포 소유자>; 후 재실행하세요 (fail-closed)." >&2
        exit 1
      fi
      # NOINHERIT member는 has_table_privilege(실효)에 잡히지 않지만 SET ROLE로
      # 소유자 전권을 얻는다. 14라운드 P2: 판정 기준은 "실제 SET ROLE 가능성"이다
      # — PG16의 GRANT ... SET FALSE membership은 전환이 불가능하므로
      # pg_has_role(..., 'SET')으로 판정한다 (INHERIT 경로의 실효 권한은 아래
      # 실효 검사가 별도로 잡는다).
      if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select coalesce(string_agg(distinct o.rolname, ','), '') from pg_class c join pg_namespace n on n.oid = c.relnamespace join pg_roles o on o.oid = c.relowner where n.nspname = '${PGSCHEMA}' and c.relname in ('users','sessions','streaks','user_fortunes','events','purchases') and pg_has_role('${_r}', c.relowner, 'SET')"; then
        echo "❌ role '${_r}' membership 조회 실패: ${_MIG_OUT}" >&2
        exit 3
      fi
      if [ -n "$_MIG_OUT" ]; then
        echo "❌ 명시 runtime role '${_r}'가 보호 테이블 소유자 role(${_MIG_OUT})로 SET ROLE 가능한 member입니다 — NOINHERIT여도 진입점을 우회해 직접 삭제할 수 있습니다 (ADR 0004 위반). REVOKE ${_MIG_OUT} FROM ${_r}; (또는 GRANT ... WITH SET FALSE) 후 재실행하세요 (fail-closed)." >&2
        exit 1
      fi
    fi
    # (i-5) 12라운드 P1(#6): runtime role의 "실효" 파괴 권한 — 직접 grant 검사
    # (i-3/i-4)로도 membership 상속 경로는 남는다. has_table_privilege(실효)로
    # users·purchases DELETE와 보호 테이블 TRUNCATE를 role별로 검사한다.
    # superuser 제외는 @self(실행 사용자 = 운영자)에만 남는 예외다 — 명시 role의
    # superuser는 위 (i-5a)가 이미 거부했다. 소유 테이블 제외도 @self 전용이다
    # (명시 role의 보호 테이블 소유는 (i-5b)가 거부).
    if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select case when (select rolsuper from pg_roles where rolname = '${_r}') then '' else coalesce((select string_agg(t.tbl || ':' || t.priv, '; ' order by t.tbl, t.priv) from (values ('users','DELETE'),('purchases','DELETE'),('users','TRUNCATE'),('sessions','TRUNCATE'),('streaks','TRUNCATE'),('user_fortunes','TRUNCATE'),('events','TRUNCATE'),('purchases','TRUNCATE')) as t(tbl,priv) where to_regclass('\"${PGSCHEMA}\".' || t.tbl) is not null and (select c.relowner from pg_class c where c.oid = to_regclass('\"${PGSCHEMA}\".' || t.tbl)) <> (select oid from pg_roles where rolname = '${_r}') and has_table_privilege('${_r}', to_regclass('\"${PGSCHEMA}\".' || t.tbl), t.priv)), '') end"; then
      echo "❌ role '${_r}' 실효 권한 검증 실패: ${_MIG_OUT}" >&2
      exit 3
    fi
    if [ -n "$_MIG_OUT" ]; then
      echo "❌ runtime role '${_r}'가 보호 테이블의 파괴 권한을 실효 보유합니다: ${_MIG_OUT} — 진입점을 우회한 hard-delete가 가능합니다 (ADR 0004 위반). 해당 grant 또는 membership을 REVOKE 후 재실행하세요 (fail-closed)." >&2
      exit 1
    fi
    IFS=','
  done
  IFS="$_mig_roles_ifs"
  return 0
}
_mig_verify_acl

# 최종 성공 보고 — ledger를 서버에서 재확인한 값으로 보고한다 (fail-closed).
#
# 재재리뷰 P1 #1: 종전의 `_final_n="$(_mig_query_bg ...)"`는 명령치환이라 부모
# bash가 subshell 종료까지 TERM trap을 미뤘다 (실측: elapsed≥5s, DB35 실패).
# _mig_psql은 부모 셸에서 실행되고 결과는 _MIG_OUT으로 받는다 — 명령치환 없음.
_mig_check_sig
if ! _mig_psql -X -v ON_ERROR_STOP=1 -tAc "select count(*) from \"${PGSCHEMA}\".schema_migrations"; then
  echo "❌ 최종 ledger 확인 실패: ${_MIG_OUT}" >&2
  exit 3
fi
_final_n="$_MIG_OUT"
_mig_check_sig
echo "✅ migrations up-to-date (${_final_n} applied; ${PGDATABASE} @ ${PGHOST}:${PGPORT}, schema: ${PGSCHEMA})"
