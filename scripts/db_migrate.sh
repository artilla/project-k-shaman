#!/usr/bin/env bash
# db_migrate.sh — db/migrations/*.sql 을 순서대로 멱등 적용한다.
#
# 연결 정보: .env.local 의 DATABASE_URL 을 읽는다. Prisma 형식 URL의
# query string(?schema=...&connection_limit=...)은 psql이 거부하므로
# 구성요소를 분해해 PG* 환경변수로 전달한다 (password의 '$' 등 특수문자 안전).
#
# 사용:
#   ./scripts/db_migrate.sh            # 미적용 마이그레이션 전부 적용
#   ./scripts/db_migrate.sh --status   # 적용 상태만 출력
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

ENV_FILE="${ENV_FILE:-.env.local}"
[ -f "$ENV_FILE" ] || { echo "❌ ${ENV_FILE} 이 없습니다." >&2; exit 2; }

DB_URL="$(sed -n 's/^DATABASE_URL=//p' "$ENV_FILE" | head -1 | tr -d '"' | tr -d "'")"
[ -n "$DB_URL" ] || { echo "❌ ${ENV_FILE} 에 DATABASE_URL 이 없습니다." >&2; exit 2; }

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

command -v psql >/dev/null 2>&1 || { echo "❌ psql 이 PATH에 없습니다 (brew install libpq 후 PATH 추가)." >&2; exit 2; }

applied() {
  psql -tAc "select 1 from information_schema.tables where table_schema='public' and table_name='schema_migrations'" \
    | grep -q 1 || return 1
  psql -tAc "select 1 from schema_migrations where version = '$1'" | grep -q 1
}

if [ "${1:-}" = "--status" ]; then
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
  psql -v ON_ERROR_STOP=1 -q -f "$f"
  echo "   ✓ $v"
done

echo "✅ migrations up-to-date (${PGDATABASE} @ ${PGHOST}:${PGPORT})"
