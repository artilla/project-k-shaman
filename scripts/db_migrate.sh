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
DB_URL="$(awk '!f && sub(/^DATABASE_URL=/, "") { v = $0; f = 1 } END { if (f) print v }' "$ENV_FILE" | tr -d '"' | tr -d "'")"
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
_MIG_APP_ROLES="${MIGRATION_APP_ROLES:-$(awk '!f && sub(/^MIGRATION_APP_ROLES=/, "") { v = $0; f = 1 } END { if (f) print v }' "$ENV_FILE" | tr -d '"' | tr -d "'")}"
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
_MIG_TMPS=""
_mig_cleanup_tmps() { local _t; for _t in $_MIG_TMPS; do rm -f "$_t" 2>/dev/null || true; done; _MIG_TMPS=""; }
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
_mig_probe() {  # $1=SQL, $2=제한(0.25s 스텝 수) → 결과는 $_MIG_PROBE_OUT, rc≠0=실패/시간초과
  local _f _pid _i=0 _rc=0
  _MIG_PROBE_OUT=""
  _f="$(mktemp "${TMPDIR:-/tmp}/dbmig-probe.XXXXXX")" || return 1
  set -m
  psql -X -tAc "$1" > "$_f" 2>/dev/null &
  _pid=$!
  set +m
  while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt "$2" ]; do sleep 0.25; _i=$((_i+1)); done
  if kill -0 "$_pid" 2>/dev/null; then
    kill -TERM -- "-${_pid}" 2>/dev/null || true
    sleep 0.25
    kill -0 "$_pid" 2>/dev/null && kill -KILL -- "-${_pid}" 2>/dev/null
    wait "$_pid" 2>/dev/null || true
    rm -f "$_f"
    return 1
  fi
  wait "$_pid" 2>/dev/null || _rc=$?
  _MIG_PROBE_OUT="$(cat "$_f" 2>/dev/null || true)"
  rm -f "$_f"
  return "$_rc"
}
_mig_server_drain() {
  local _q="select count(*) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" _i=0
  # 전체 예산: probe(응답 상한 0.5s, 시간초과 시 TERM→KILL 포함 ≈0.8s) × 3회 +
  # terminate 1회 + 최종 probe — 최악 ≈ 4s 상한. 예산 초과는 포기·실패 반환
  # (호출자가 경고 후 즉시 종료 — 신호 처리 전체가 unbounded가 되지 않는다).
  while [ "$_i" -lt 3 ]; do
    if _mig_probe "$_q" 2 && [ "$_MIG_PROBE_OUT" = "0" ]; then return 0; fi
    if [ "$_i" -eq 1 ]; then
      _mig_probe "select pg_terminate_backend(pid) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" 2 || true
    fi
    _i=$((_i+1))
  done
  _mig_probe "$_q" 2 && [ "$_MIG_PROBE_OUT" = "0" ]
}

# 유일한 psql 실행 경로 — job control(set -m)로 별도 프로세스 그룹에 배치.
# 인수는 psql에 그대로 전달, stdout+stderr는 $_MIG_OUT에 담긴다. 반환: psql rc.
# 신호 수신 시 전달·bounded reap·서버 drain·temp 정리 후 여기서 128+N으로 종료한다.
_MIG_OUT=""
_mig_psql() {
  local _qout _pid _rc _i _snum
  _mig_check_sig  # 신호가 이미 기록됐으면 psql을 아예 띄우지 않는다
  _qout="$(mktemp "${TMPDIR:-/tmp}/dbmig-q.XXXXXX")" || { echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _MIG_TMPS="$_MIG_TMPS $_qout"
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
      kill -s "$_MIG_SIG" -- "-${_pid}" 2>/dev/null || true
      _i=0
      while kill -0 "$_pid" 2>/dev/null && [ "$_i" -lt 20 ]; do sleep 0.25; _i=$((_i+1)); done
      if kill -0 "$_pid" 2>/dev/null; then
        kill -KILL -- "-${_pid}" 2>/dev/null || true
      fi
      wait "$_pid" 2>/dev/null || true
      if ! _mig_server_drain; then
        echo "⚠️  서버에 이 runner의 backend가 아직 남아 있을 수 있습니다 — pg_stat_activity(application_name=${PGAPPNAME})를 확인하세요." >&2
      fi
      _snum="$(_mig_sig_num "$_MIG_SIG")"
      _mig_cleanup_tmps
      echo "❌ 신호(${_MIG_SIG})로 중단됨 — psql 프로세스 그룹에 신호를 전달하고 서버 backend 종료를 확인했습니다 (미완료 transaction은 서버가 rollback)." >&2
      exit $((128 + _snum))
    fi
    kill -0 "$_pid" 2>/dev/null || break
  done
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
005_ownership_repair_and_lock_contract 5278471dabfa05c4e380e74fcd0ab451667543026614cb3a194cdab52e77f7b6"
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
  exit 0
fi

# 신호 계약·psql 실행 경로(_mig_psql)는 위(접속 검증 앞)에서 정의됐다 —
# 재재리뷰 P1 #1: apply 경로도 같은 helper 하나만 쓴다.

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
  _MIG_TMPS="$_MIG_TMPS $_snap"
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
  _MIG_TMPS="$_MIG_TMPS $_pre $_post $_wrap"
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
    printf 'DO $%s$ DECLARE _mig_sql text := $%s$' "$_t1" "$_t2"
  } > "$_pre" || { rm -f "$_snap" "$_pre" "$_post" "$_wrap"; echo "❌ 래퍼 작성 실패." >&2; exit 3; }
  {
    printf '$%s$;\nBEGIN\n' "$_t2"
    printf "  IF octet_length(_mig_sql) <> %s OR md5(_mig_sql) <> '%s' THEN\n" "$_raw_sz" "$_mig_md5"
    printf "    RAISE EXCEPTION 'migration %s: EXECUTE string differs from the verified blob (fail-closed)';\n" "$v"
    printf '  END IF;\n'
    printf '  EXECUTE _mig_sql;\n'
    printf 'END $%s$;\n' "$_t1"
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
  _MIG_TMPS="$_MIG_TMPS $_cut"
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
