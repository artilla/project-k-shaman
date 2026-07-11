#!/usr/bin/env bash
# db_migrate.sh — db/migrations/*.sql 을 순서대로 멱등 적용한다.
#
# 소유권 계약 (리뷰 15차 P1):
#   - transaction: 각 마이그레이션은 runner가 --single-transaction으로 감싼다.
#     SQL 파일은 BEGIN/COMMIT을 쓰지 않는다 (001은 역사적 예외 — 중첩 BEGIN은
#     경고만 내고 무해).
#   - ledger: version 기록(INSERT INTO schema_migrations)은 runner가 같은
#     transaction에서 수행한다. SQL 파일이 marker를 빠뜨려도 재실행되지 않는다.
#   - 동시 실행: pg_advisory_xact_lock으로 직렬화. 패자는 승자 commit 후
#     applied 재확인(guard)에서 ALREADY_APPLIED로 skip한다.
#   - fail-closed: 접속/query 실패는 'pending'이 아니라 오류(rc≠0)다.
#
# 연결 정보: .env.local 의 DATABASE_URL. Prisma형 query string은 무시하고
# 구성요소를 분해해 PG* 환경변수로 전달한다 (password의 '$' 등 특수문자 안전).
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
export PGUSER PGPASSWORD PGHOST PGPORT PGDATABASE
export PGCONNECT_TIMEOUT="${PGCONNECT_TIMEOUT:-10}"
export PGOPTIONS="-c client_min_messages=warning"

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

# ledger 부트스트랩 (존재 보장 — 이후 guard/INSERT가 의존).
# 리뷰 15차 P1: CREATE TABLE IF NOT EXISTS도 동시 실행에서 pg_type 충돌로 실패할 수
# 있다 — advisory lock 아래에서 수행해 부트스트랩 자체를 직렬화한다.
psql -X -v ON_ERROR_STOP=1 -q --single-transaction   -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})"   -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  version TEXT PRIMARY KEY,
  applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
)" >/dev/null || { echo "❌ schema_migrations 부트스트랩 실패." >&2; exit 3; }

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
  echo "── DB: ${PGDATABASE} @ ${PGHOST}:${PGPORT}"
  for f in db/migrations/*.sql; do
    v="$(basename "$f" .sql)"
    if applied "$v"; then echo "  ✓ $v (applied)"; else echo "  · $v (pending)"; fi
  done
  exit 0
fi

for f in db/migrations/*.sql; do
  v="$(basename "$f" .sql)"
  if applied "$v"; then
    echo "── skip  $v (이미 적용됨)"
    continue
  fi
  echo "── apply $v"
  # 단일 transaction 안에서: advisory lock → applied 재확인(guard) → SQL → ledger 기록.
  # 동시 runner의 패자는 lock 대기 후 guard에서 ALREADY_APPLIED로 빠진다 (skip 처리).
  _guard="DO \$mig\$ BEGIN
    IF EXISTS (SELECT 1 FROM schema_migrations WHERE version = '$v') THEN
      RAISE EXCEPTION 'ALREADY_APPLIED';
    END IF;
  END \$mig\$;"
  _out=""
  _rc=0
  _out="$(psql -X -v ON_ERROR_STOP=1 -q --single-transaction \
      -c "SELECT pg_advisory_xact_lock(${ADVISORY_KEY})" \
      -c "$_guard" \
      -f "$f" \
      -c "INSERT INTO schema_migrations (version) VALUES ('$v') ON CONFLICT (version) DO NOTHING" 2>&1)" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    case "$_out" in
      *ALREADY_APPLIED*)
        echo "── skip  $v (동시 runner가 방금 적용함)"
        continue
        ;;
      *)
        echo "❌ $v 적용 실패 — transaction rollback됨 (ledger 미기록, 부분 적용 없음):" >&2
        printf '%s\n' "$_out" >&2
        exit 1
        ;;
    esac
  fi
  # 적용 후 ledger 재확인 — 기록 없이 성공으로 출력하지 않는다.
  if ! applied "$v"; then
    echo "❌ $v: SQL은 통과했으나 ledger 기록이 확인되지 않습니다 — 수동 확인 필요." >&2
    exit 1
  fi
  echo "   ✓ $v"
done

echo "✅ migrations up-to-date (${PGDATABASE} @ ${PGHOST}:${PGPORT})"
