#!/usr/bin/env bash
# db_migrate.sh — db/migrations/*.sql 을 순서대로 멱등 적용한다.
#
# 소유권 계약 (리뷰 15차 P1 + 16차 P1):
#   - transaction: 각 마이그레이션은 runner가 --single-transaction으로 감싼다.
#     SQL 파일은 BEGIN/COMMIT을 쓰지 않는다. 파일 내 최상위 BEGIN/COMMIT/ROLLBACK은
#     단일 transaction을 중도 종결시켜 부분 commit을 만들 수 있으므로(16차 P1)
#     runner가 중화(제거)하고 경고를 남긴다 — 001의 역사적 BEGIN/COMMIT 포함.
#   - ledger: version 기록(INSERT INTO schema_migrations)은 runner가 같은
#     transaction에서 수행한다. SQL 파일이 marker를 빠뜨려도 재실행되지 않는다.
#   - 동시 실행: pg_advisory_xact_lock으로 직렬화. 패자는 승자 commit 후 guard
#     예외로 중단되고, 실패 후 ledger 재조회로 skip을 판정한다(16차 P1: 출력
#     문자열 매칭 판정 금지).
#   - --status: 읽기 전용 — 어떤 쓰기도 하지 않는다 (16차 P1).
#   - fail-closed: 접속/query 실패는 'pending'이 아니라 오류(rc≠0)다.
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

DB_URL="$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE" | head -1 | tr -d '"' | tr -d "'")"
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
  _sch="$(printf '%s' "$_query" | tr '&' '\n' | sed -n 's/^schema=//p' | head -1)"
  if [ -n "$_sch" ]; then
    case "$_sch" in
      [A-Za-z_]*) ;;
      *) echo "❌ DATABASE_URL schema 파라미터가 유효한 식별자가 아닙니다: '$_sch'" >&2; exit 2 ;;
    esac
    case "$_sch" in
      *[!A-Za-z0-9_]*) echo "❌ DATABASE_URL schema 파라미터가 유효한 식별자가 아닙니다: '$_sch'" >&2; exit 2 ;;
    esac
    PGSCHEMA="$_sch"
  fi
fi

export PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c client_min_messages=warning -c search_path=${PGSCHEMA}"

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
  if ! out="$(psql -X -v ON_ERROR_STOP=1 -tAc "select count(*) from schema_migrations where version = '$1'" 2>&1)"; then
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
  if ! _ledger="$(psql -X -v ON_ERROR_STOP=1 -tAc "select to_regclass('schema_migrations') is not null" 2>&1)"; then
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

# ledger 부트스트랩 (apply 전용 — 존재 보장, 이후 guard/INSERT가 의존).
# 리뷰 15차 P1: CREATE TABLE IF NOT EXISTS도 동시 실행에서 pg_type 충돌로 실패할 수
# 있다 — advisory lock 아래에서 수행해 부트스트랩 자체를 직렬화한다.
# 리뷰 16차 P1: schema 파라미터가 public이 아니면 스키마도 여기서 보장한다.
_bootstrap_ddl="CREATE TABLE IF NOT EXISTS schema_migrations (
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
    -c "CREATE SCHEMA IF NOT EXISTS ${PGSCHEMA}" \
    -c "$_bootstrap_ddl" >/dev/null || { echo "❌ schema/ledger 부트스트랩 실패." >&2; exit 3; }
fi

for f in db/migrations/*.sql; do
  v="$(basename "$f" .sql)"
  if applied "$v"; then
    echo "── skip  $v (이미 적용됨)"
    continue
  fi
  echo "── apply $v"
  # 리뷰 16차 P1(부분 commit): SQL 파일 내부의 최상위 BEGIN/COMMIT/ROLLBACK은
  # --single-transaction을 중도 종결시킨다 — 내부 COMMIT 시점에 그때까지의 변경이
  # 실제로 commit되고 advisory xact lock도 풀려, 이후 문장이 실패하면 "부분 적용
  # + ledger 미기록 + 직렬화 붕괴"가 된다 (001의 역사적 BEGIN/COMMIT이 그 사례).
  # 계약대로 transaction은 runner가 소유한다 — 독립 라인의 txn 제어문을 중화하고
  # 경고를 남긴다 (파일은 무수정 보존).
  _sql_src="$f"
  _tmp_sql=""
  if grep -Eiq '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK)[[:space:]]*;[[:space:]]*$' "$f"; then
    echo "   ⚠️  $v: 파일 내 최상위 BEGIN/COMMIT/ROLLBACK 감지 — transaction은 runner 소유이므로 중화하고 단일 transaction으로 적용합니다."
    _tmp_sql="$(mktemp "${TMPDIR:-/tmp}/dbmig.XXXXXX")" || { echo "❌ 임시 파일 생성 실패." >&2; exit 3; }
    grep -Eiv '^[[:space:]]*(BEGIN|COMMIT|ROLLBACK)[[:space:]]*;[[:space:]]*$' "$f" > "$_tmp_sql" \
      || { rm -f "$_tmp_sql"; echo "❌ $v: txn 제어문 중화 실패." >&2; exit 3; }
    _sql_src="$_tmp_sql"
  fi
  # 단일 transaction 안에서: advisory lock → applied 재확인(guard) → SQL → ledger 기록.
  # 동시 runner의 패자는 lock 대기 후 guard의 예외로 transaction이 중단된다.
  _guard="DO \$mig\$ BEGIN
    IF EXISTS (SELECT 1 FROM schema_migrations WHERE version = '$v') THEN
      RAISE EXCEPTION 'migration % is already applied', '$v';
    END IF;
  END \$mig\$;"
  _out=""
  _rc=0
  _out="$(psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
      -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
      -c "$_guard" \
      -f "$_sql_src" \
      -c "INSERT INTO schema_migrations (version) VALUES ('$v') ON CONFLICT (version) DO NOTHING" 2>&1)" || _rc=$?
  [ -n "$_tmp_sql" ] && rm -f "$_tmp_sql"
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
