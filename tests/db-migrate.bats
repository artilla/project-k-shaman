#!/usr/bin/env bats
# tests/db-migrate.bats — scripts/db_migrate.sh 회귀 (리뷰 15차 P1: DB runner 계약)
#
# disposable PostgreSQL 클러스터(초기화→기동→폐기)에서 실행한다.
# 서버 바이너리(initdb/pg_ctl)가 없으면 전체 skip — 게이트를 막지 않는다.
# root로 실행되면(컨테이너 CI) postgres 시스템 사용자로 클러스터를 돌린다.

_pg_bin() {
  local d
  for d in /usr/lib/postgresql/*/bin /opt/homebrew/opt/postgresql@*/bin \
           /usr/local/opt/postgresql@*/bin /usr/local/bin /opt/homebrew/bin; do
    [ -x "$d/initdb" ] && [ -x "$d/pg_ctl" ] && { echo "$d"; return 0; }
  done
  return 1
}

# root면 postgres 사용자로, 아니면 현재 사용자로 실행
_as_pg() {
  if [ "$(id -u)" = "0" ]; then
    su postgres -c "$*"
  else
    bash -c "$*"
  fi
}

setup_file() {
  # macOS: 로케일이 비어 있으면 postmaster가 기동 중 멀티쓰레드가 되어 시작 자체가
  # 실패한다 (CoreFoundation 로케일 초기화) — 비대화형/자동화 환경에서 재현.
  # C 로케일로 고정한다 (Linux에는 무해).
  export LC_ALL="${LC_ALL:-C}"
  PGBIN="$(_pg_bin)" || skip "PostgreSQL 서버 바이너리 없음 — migration 회귀 skip"
  if [ "$(id -u)" = "0" ] && ! id postgres >/dev/null 2>&1; then
    skip "root인데 postgres 사용자 없음 — skip"
  fi
  export PGBIN
  export PGT="$(mktemp -d)"
  export PGT_PORT=$(( 54400 + RANDOM % 100 ))
  chmod 777 "$PGT"
  [ "$(id -u)" = "0" ] && chown postgres "$PGT"
  _as_pg "'$PGBIN/initdb' -D '$PGT/data' -A trust -U postgres" > "$PGT/initdb.log" 2>&1 \
    || skip "initdb 실패 — skip"
  _as_pg "'$PGBIN/pg_ctl' -D '$PGT/data' -l '$PGT/pg.log' -o '-p $PGT_PORT -c listen_addresses=127.0.0.1 -k $PGT' start" >/dev/null \
    || skip "pg_ctl start 실패 — skip"
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
}

teardown_file() {
  [ -n "${PGT:-}" ] || return 0
  _as_pg "'$PGBIN/pg_ctl' -D '$PGT/data' stop -m immediate" >/dev/null 2>&1 || true
  rm -rf "$PGT" 2>/dev/null || true
}

setup() {
  [ -n "${PGT:-}" ] || skip "클러스터 없음"
  TEST_DB="t$$_${BATS_TEST_NUMBER}"
  _as_pg "'$PGBIN/createdb' -h 127.0.0.1 -p $PGT_PORT -U postgres $TEST_DB"
  ENVF="$PGT/${TEST_DB}.env"
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=public" > "$ENVF"
}

_psql() {
  PGOPTIONS='-c client_min_messages=warning' \
    "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" -tAc "$1"
}

@test "DB1: fresh apply installs all migrations, ledger owned by runner" {
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  # 002는 자체 marker INSERT가 없다 — ledger 기록은 runner 소유임을 증명
  [ "$(_psql "select count(*) from schema_migrations where version='002_schema_contract_fixes'")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='public' and table_name='user_fortunes'")" = "1" ]
}

@test "DB2: re-run is a no-op (idempotent), typo option is a usage error" {
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh" --statsu
  [ "$status" -eq 2 ]
  [[ "$output" == *"알 수 없는 인수"* ]]
}

@test "DB3: failing migration rolls back atomically - no partial objects, no ledger entry" {
  local bad="$REPO_ROOT/db/migrations/999_bad_zz_test.sql"
  cat > "$bad" <<'SQL'
CREATE TABLE IF NOT EXISTS should_not_survive (id INT);
SELECT 1/0;
SQL
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  rm -f "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rollback"* ]]
  [ "$(_psql "select count(*) from information_schema.tables where table_name='should_not_survive'")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '999%'")" = "0" ]
}

@test "DB4: unreachable DB is fail-closed for both --status and apply (no 'pending' lie)" {
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:1/${TEST_DB}?schema=public" > "$ENVF"
  run env ENV_FILE="$ENVF" PGCONNECT_TIMEOUT=3 "$REPO_ROOT/scripts/db_migrate.sh" --status
  [ "$status" -ne 0 ]
  [[ "$output" == *"접속 실패"* ]]
  [[ "$output" != *"pending"* ]]
  run env ENV_FILE="$ENVF" PGCONNECT_TIMEOUT=3 "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -ne 0 ]
}

@test "DB5: concurrent runners serialize - each migration applied exactly once, both rc=0" {
  ( ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh" > "$PGT/c1.log" 2>&1; echo $? > "$PGT/c1.rc" ) &
  ( ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh" > "$PGT/c2.log" 2>&1; echo $? > "$PGT/c2.rc" ) &
  wait
  [ "$(cat "$PGT/c1.rc")" -eq 0 ]
  [ "$(cat "$PGT/c2.rc")" -eq 0 ]
  ! grep -q "ERROR" "$PGT/c1.log" "$PGT/c2.log"
  [ "$(_psql "select count(*) from schema_migrations")" = "$(ls "$REPO_ROOT"/db/migrations/*.sql | wc -l | tr -d ' ')" ]
}

@test "DB6: deployed contract - bad streak rejected, consent bidirectional, delete scrubs, events 32KiB" {
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  # P1-6: (current=5, longest=0) 거부
  run _psql "insert into streaks (user_id, current_streak, longest_streak) values (1, 5, 0)"
  [ "$status" -ne 0 ]
  # P1-7: 동의 없이 hash 저장 거부 / 동의 시각 없는 동의 거부
  run _psql "update users set birth_profile_hash='h' where id=1"
  [ "$status" -ne 0 ]
  run _psql "update users set consent_personalization=true where id=1"
  [ "$status" -ne 0 ]
  _psql "update users set consent_personalization=true, consented_at=now(), birth_profile_hash='h', last_topic='love' where id=1"
  # P1-7: 삭제 스크럽 + 자식 정리
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into fortunes (cache_key, payload) values ('ck','{}')"
  _psql "insert into user_fortunes (user_id, fortune_id) values (1,1)"
  _psql "update users set deleted_at=now() where id=1"
  [ "$(_psql "select (birth_profile_hash is null and last_topic is null and not consent_personalization) from users where id=1")" = "t" ]
  [ "$(_psql "select count(*) from sessions where user_id=1")" = "0" ]
  [ "$(_psql "select count(*) from user_fortunes where user_id=1")" = "0" ]
  # P1-8: 캐시는 사용자와 분리되어 남는다 / fortunes.user_id 컬럼 부재
  [ "$(_psql "select count(*) from fortunes")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.columns where table_name='fortunes' and column_name='user_id'")" = "0" ]
  # P2: events 32KiB 계약 (20KB 허용, 33KB 거부)
  _psql "insert into events (event_type, payload) values ('t', ('{\"d\":\"' || repeat('a',20000) || '\"}')::jsonb)"
  run _psql "insert into events (event_type, payload) values ('t', ('{\"d\":\"' || repeat('a',33000) || '\"}')::jsonb)"
  [ "$status" -ne 0 ]
}

# ── 리뷰 16차 P1 회귀 ──────────────────────────────────────────────────────────

@test "DB7: embedded top-level COMMIT cannot break atomicity - no partial commit, lock not released mid-file" {
  # 내부 COMMIT은 --single-transaction을 중도 종결시켜, 이후 문장이 실패하면
  # 앞부분만 commit된 채 남았다 (001의 역사적 BEGIN/COMMIT과 같은 패턴).
  local bad="$REPO_ROOT/db/migrations/998_txn_zz_test.sql"
  cat > "$bad" <<'SQL'
CREATE TABLE IF NOT EXISTS partial_a (id INT);
COMMIT;
CREATE TABLE IF NOT EXISTS partial_b (id INT);
SELECT 1/0;
SQL
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  rm -f "$bad"
  [ "$status" -eq 1 ]
  [[ "$output" == *"중화"* ]]
  # 부분 commit 없음 — 내부 COMMIT 앞의 객체도 남지 않는다
  [ "$(_psql "select count(*) from information_schema.tables where table_name in ('partial_a','partial_b')")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '998%'")" = "0" ]
}

@test "DB8: --status is strictly read-only - no ledger bootstrap on a fresh DB" {
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"pending"* ]]
  # status가 schema_migrations를 만들지 않았다
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  # apply 후에는 applied로 보고
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"001_init (applied)"* ]]
}

@test "DB9: DATABASE_URL schema parameter is honored - objects and ledger land in that schema" {
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=appdata&connection_limit=20" > "$ENVF"
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='appdata' and table_name='users'")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='appdata' and table_name='schema_migrations'")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='public' and table_name='users'")" = "0" ]
  # 위험 식별자는 거부 (fail-closed)
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=app;drop" > "$ENVF"
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 2 ]
}

@test "DB10: soft-delete is a state invariant - re-writing personal fields or inserting deleted rows is rejected" {
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "update users set consent_personalization=true, consented_at=now(), birth_profile_hash='h', nickname='n' where id=1"
  _psql "update users set deleted_at=now() where id=1"
  # 정상 삭제 경로: 트리거 스크럽 후 불변식 통과
  [ "$(_psql "select (nickname is null and birth_profile_hash is null and not consent_personalization) from users where id=1")" = "t" ]
  # (a) 삭제된 행에 개인 필드 재기입 — 거부
  run _psql "update users set last_topic='love' where id=1"
  [ "$status" -ne 0 ]
  run _psql "update users set nickname='back' where id=1"
  [ "$status" -ne 0 ]
  # (b) deleted_at이 설정된 채 개인 필드를 담은 INSERT — 거부
  run _psql "insert into users (provider, provider_subject, nickname, deleted_at) values ('kakao','u2','n2',now())"
  [ "$status" -ne 0 ]
  # 개인 필드 없는 삭제 상태 INSERT는 허용 (불변식 위반 아님)
  _psql "insert into users (provider, provider_subject, deleted_at) values ('kakao','u3',now())"
}

@test "DB11: a failing migration whose error text contains 'ALREADY_APPLIED' is a failure, not a skip" {
  local bad="$REPO_ROOT/db/migrations/997_lie_zz_test.sql"
  cat > "$bad" <<'SQL'
DO $x$ BEGIN RAISE EXCEPTION 'ALREADY_APPLIED impostor'; END $x$;
SQL
  run env ENV_FILE="$ENVF" "$REPO_ROOT/scripts/db_migrate.sh"
  rm -f "$bad"
  # 과거: 출력 문자열 매칭으로 skip 처리되어 rc=0으로 위장 — 지금은 실패(rc=1)
  [ "$status" -eq 1 ]
  [[ "$output" != *"skip  997"* ]]
  [ "$(_psql "select count(*) from schema_migrations where version like '997%'")" = "0" ]
}
