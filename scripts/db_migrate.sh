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

# 접속 자체를 먼저 검증 — 이후의 모든 판정이 이 위에서만 유효하다 (fail-closed).
if ! psql -X -tAc "select 1" >/dev/null 2>&1; then
  echo "❌ DB 접속 실패: ${PGDATABASE} @ ${PGHOST}:${PGPORT} — 상태를 판정할 수 없습니다 (fail-closed)." >&2
  exit 3
fi

# 동시 runner 직렬화 키 (고정 상수 — 아래 apply 루프와 부트스트랩이 공유).
ADVISORY_KEY=721363011

# applied <version> — 0=적용됨, 1=미적용. query 실패는 즉시 중단 (pending으로 위장 금지).
applied() {
  local out
  # 리뷰 16차 P1(4차): ledger 참조는 전부 schema-qualified — migration 내용의
  # SET LOCAL search_path가 unqualified 참조를 다른 schema로 돌려도 영향 없음.
  if ! out="$(psql -X -v ON_ERROR_STOP=1 -tAc "select count(*) from \"${PGSCHEMA}\".schema_migrations where version = '$1'" 2>&1)"; then
    echo "❌ ledger 조회 실패(version=$1): $out" >&2
    exit 3
  fi
  [ "$out" = "1" ]
}

if [ "$MODE" = "status" ]; then
  # 리뷰 16차 P1: status는 읽기 전용 — 과거에는 ledger 부트스트랩(CREATE TABLE)이
  # MODE 분기보다 먼저 실행되어 --status가 DB에 "썼다". 조회 명령이 쓰기를 하면
  # 읽기 권한만 가진 계정/감사 상황에서 계약 위반이다. ledger가 없으면 만들지
  # 않고 전부 pending으로 보고한다.
  echo "── DB: ${PGDATABASE} @ ${PGHOST}:${PGPORT} (schema: ${PGSCHEMA})"
  if ! _ledger="$(psql -X -v ON_ERROR_STOP=1 -tAc "select to_regclass('\"${PGSCHEMA}\".schema_migrations') is not null" 2>&1)"; then
    echo "❌ ledger 존재 확인 실패: $_ledger" >&2
    exit 3
  fi
  [ "$_ledger" = "t" ] || echo "   (schema_migrations 없음 — 아직 한 번도 적용되지 않은 DB)"
  for f in db/migrations/*.sql; do
    v="$(basename "$f" .sql)"
    if [ "$_ledger" = "t" ] && applied "$v"; then echo "  ✓ $v (applied)"; else echo "  · $v (pending)"; fi
  done
  exit 0
fi

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

# ── 리뷰 16차 P1(7차): 신호 계약 — runner가 TERM/INT/HUP을 받으면 migration
# psql "프로세스 그룹" 전체에 신호를 전달하고, bounded reap(전달 → 대기 → KILL)
# 후 서버 쪽 backend 종료까지 확인하고 나서 종료한다. 과거에는 runner가
# rc=143으로 죽은 뒤에도 child psql이 계속 실행되어 4초 뒤 commit했고 wrapper
# temp도 남았다 (실측).
_MIG_TMPS=""
_mig_cleanup_tmps() { local _t; for _t in $_MIG_TMPS; do rm -f "$_t" 2>/dev/null || true; done; _MIG_TMPS=""; }
_MIG_SIG=""
trap '_MIG_SIG=TERM' TERM
trap '_MIG_SIG=INT'  INT
trap '_MIG_SIG=HUP'  HUP
trap '_mig_cleanup_tmps' EXIT
_mig_sig_num() { case "$1" in INT) echo 2 ;; HUP) echo 1 ;; *) echo 15 ;; esac; }

# 리뷰 16차 P1(8차): 신호가 migration psql "밖"(bootstrap·ledger 조회·wrapper
# 작성 등 foreground 단계)에서 수신되면 trap은 기록만 하고 제어는 계속 진행돼,
# 다음 migration을 통째로 적용·commit한 뒤에야 종료했다 — 신호 이후에는 어떤
# migration도 새로 시작하지 않는다. 새 작업 시작 지점마다 이 검사를 통과해야
# 한다 (통과 못 하면 temp 정리 후 즉시 종료; 진행 중이던 transaction은 없음).
_mig_check_sig() {
  [ -n "$_MIG_SIG" ] || return 0
  local _snum
  _snum="$(_mig_sig_num "$_MIG_SIG")"
  _mig_cleanup_tmps
  echo "❌ 신호(${_MIG_SIG}) 수신 — 새 migration을 시작하지 않고 중단합니다 (이미 적용된 migration은 유효, 진행 중 transaction 없음)." >&2
  exit $((128 + _snum))
}

# 서버 쪽 종료 확인: 이 runner(application_name=$PGAPPNAME)의 다른 backend가
# 사라질 때까지 bounded 대기 — 중간에 종료 요청(pg_terminate_backend)으로
# escalate하고, 끝까지 남으면 실패(호출자가 경고)를 반환한다.
_mig_server_drain() {
  local _q="select count(*) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" _n="" _i=0
  while [ "$_i" -lt 20 ]; do
    _n="$(psql -X -tAc "$_q" 2>/dev/null || echo "")"
    [ "$_n" = "0" ] && return 0
    if [ "$_i" -eq 8 ] && [ -n "$_n" ]; then
      psql -X -tAc "select pg_terminate_backend(pid) from pg_stat_activity where application_name = '${PGAPPNAME}' and pid <> pg_backend_pid()" >/dev/null 2>&1 || true
    fi
    sleep 0.25; _i=$((_i+1))
  done
  [ "$(psql -X -tAc "$_q" 2>/dev/null || echo x)" = "0" ]
}

# migration psql 실행 — job control(set -m)로 별도 프로세스 그룹에 배치.
# $1=wrapper SQL 파일, $2=출력 파일. 반환: psql rc. 신호 수신 시 전달·reap·
# 서버 확인·temp 정리 후 여기서 종료한다.
_mig_run_psql() {
  local _pid _rc _i _snum
  _mig_check_sig  # 8차: 신호가 이미 기록됐으면 psql을 아예 띄우지 않는다
  set -m
  psql -X -v ON_ERROR_STOP=1 -q --single-transaction -f "$1" > "$2" 2>&1 &
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
      echo "❌ 신호(${_MIG_SIG})로 중단됨 — migration psql 프로세스 그룹에 신호를 전달하고 서버 backend 종료를 확인했습니다 (미완료 transaction은 서버가 rollback)." >&2
      exit $((128 + _snum))
    fi
    kill -0 "$_pid" 2>/dev/null || break
  done
  return "$_rc"
}

# ledger 부트스트랩 (apply 전용 — 존재 보장, 이후 guard/INSERT가 의존).
# 리뷰 15차 P1: CREATE TABLE IF NOT EXISTS도 동시 실행에서 pg_type 충돌로 실패할 수
# 있다 — advisory lock 아래에서 수행해 부트스트랩 자체를 직렬화한다.
# 리뷰 16차 P1: schema 파라미터가 public이 아니면 스키마도 여기서 보장한다.
# 리뷰 16차 P1(4차): ledger DDL도 schema-qualified (search_path 무관).
_bootstrap_ddl="CREATE TABLE IF NOT EXISTS \"${PGSCHEMA}\".schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)"
if [ "$PGSCHEMA" = "public" ]; then
  psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
    -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
    -c "$_bootstrap_ddl" >/dev/null || { echo "❌ schema_migrations 부트스트랩 실패." >&2; exit 3; }
else
  psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
    -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
    -c "CREATE SCHEMA IF NOT EXISTS \"${PGSCHEMA}\"" \
    -c "$_bootstrap_ddl" >/dev/null || { echo "❌ schema/ledger 부트스트랩 실패." >&2; exit 3; }
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
  _content="$(cat "$_snap")"
  if [ -z "$_content" ]; then
    rm -f "$_snap"
    echo "❌ $v: 빈 마이그레이션 파일 — 적용할 수 없습니다." >&2
    exit 1
  fi
  # 리뷰 16차 P1(8차, DB16 실측 회귀): 공개본(remote/master)의 001은 이미
  # BEGIN/COMMIT이 제거된 판본이다 — 4차의 "checksum 한정 legacy strip"은 구판
  # 전제였고, 복원 후에는 변조 001에 transaction control이 없어 "서버가 거부"
  # 하던 최후 방어까지 사라져 변조본이 그대로 적용됐다 (실측). strip 경로는
  # 제거하고, 공개된 마이그레이션의 bytes를 checksum으로 직접 pin한다:
  # 커밋되었더라도 공개본과 다른 001~004는 적용하지 않는다 (fail-closed —
  # 같은 version의 내용 변경은 P1-1과 동일한 계약 위반이다). 새 마이그레이션을
  # 공개(push)할 때 그 sha256을 아래 목록에 추가한다.
  _pin=""
  case "$v" in
    001_init)                  _pin="a1296198221932cf0313dec362ef9ff5d4336ab935cdf17f9f1981b9efeb4a4b" ;;
    002_schema_contract_fixes) _pin="40965ac72a0442177abeff67bd53a0c6ec2e30be1e53bf19499f66a1aa6114c7" ;;
    003_soft_delete_invariant) _pin="b7b7a364f1dc5418097e906f122c6eac221b676741381ca06e395b33c54855cb" ;;
    004_soft_delete_contract)  _pin="94525fde054c473e87e06d060089f81e9475d65669cbe19953a12b5f591e66a4" ;;
  esac
  if [ -n "$_pin" ]; then
    _fsha="$( (shasum -a 256 "$_snap" 2>/dev/null || sha256sum "$_snap" 2>/dev/null) | awk '{print $1; exit}')"
    if [ "$_fsha" != "$_pin" ]; then
      rm -f "$_snap"
      echo "❌ $v: 공개본 checksum과 다릅니다 (expected ${_pin}, got ${_fsha:-?}) — 공개된 마이그레이션의 내용 변경은 적용하지 않습니다 (fail-closed). 변경분은 새 version(00N_*.sql)으로 작성하세요." >&2
      exit 1
    fi
  fi
  rm -f "$_snap"
  _t1=""; _t2=""
  while :; do
    _t1="do_${RANDOM}${RANDOM}${RANDOM}"
    _t2="sql_${RANDOM}${RANDOM}${RANDOM}"
    [ "$_t1" != "$_t2" ] || continue
    case "$_content" in *"\$${_t1}\$"*|*"\$${_t2}\$"*) continue ;; esac
    break
  done
  _wrap="$(mktemp "${TMPDIR:-/tmp}/dbmig.XXXXXX")" || { echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _MIG_TMPS="$_MIG_TMPS $_wrap"
  {
    printf 'SELECT pg_advisory_xact_lock(%s);\n' "$ADVISORY_KEY"
    printf 'DO $mig$ BEGIN\n'
    printf "  IF EXISTS (SELECT 1 FROM \"%s\".schema_migrations WHERE version = '%s') THEN\n" "$PGSCHEMA" "$v"
    printf "    RAISE EXCEPTION 'migration %% is already applied', '%s';\n" "$v"
    printf '  END IF;\n'
    printf 'END $mig$;\n'
    printf 'DO $%s$ BEGIN EXECUTE $%s$\n' "$_t1" "$_t2"
    printf '%s' "$_content"
    printf '\n$%s$; END $%s$;\n' "$_t2" "$_t1"
    printf "INSERT INTO \"%s\".schema_migrations (version) VALUES ('%s') ON CONFLICT (version) DO NOTHING;\n" "$PGSCHEMA" "$v"
  } > "$_wrap" || { rm -f "$_wrap"; echo "❌ 래퍼 스크립트 작성 실패." >&2; exit 3; }
  # 단일 transaction 안에서: advisory lock → applied 재확인(guard) → SQL(EXECUTE)
  # → ledger 기록. 동시 runner의 패자는 lock 대기 후 guard의 예외로 중단된다.
  _outf="$(mktemp "${TMPDIR:-/tmp}/dbmig-out.XXXXXX")" || { rm -f "$_wrap"; echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
  _MIG_TMPS="$_MIG_TMPS $_outf"
  _rc=0
  _mig_run_psql "$_wrap" "$_outf" || _rc=$?
  _out="$(cat "$_outf" 2>/dev/null || true)"
  rm -f "$_wrap" "$_outf"
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
done

echo "✅ migrations up-to-date (${PGDATABASE} @ ${PGHOST}:${PGPORT}, schema: ${PGSCHEMA})"
