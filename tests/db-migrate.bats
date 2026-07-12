#!/usr/bin/env bats
# tests/db-migrate.bats — scripts/db_migrate.sh 회귀 (리뷰 15차~16차 P1: DB runner 계약)
#
# disposable PostgreSQL 클러스터(초기화→기동→폐기)에서 실행한다.
# 서버 바이너리(initdb/pg_ctl)가 없으면 전체 skip — 게이트를 막지 않는다.
# root로 실행되면(컨테이너 CI) postgres 시스템 사용자로 클러스터를 돌린다.
#
# 리뷰 16차 P2: fixture 격리 — 테스트는 실제 db/migrations/를 절대 만지지 않는다.
# 각 테스트는 runner+migrations를 temp ROOT로 복사해 그 안에서 실행한다
# (병렬 실행·중단이 저장소와 다른 테스트를 오염시키지 않음).

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
  # fixture 격리: runner + migrations를 temp ROOT로 복사 (실제 저장소 무변조)
  TROOT="$PGT/root_${BATS_TEST_NUMBER}"
  mkdir -p "$TROOT/scripts" "$TROOT/db"
  cp "$REPO_ROOT/scripts/db_migrate.sh" "$TROOT/scripts/db_migrate.sh"
  cp -R "$REPO_ROOT/db/migrations" "$TROOT/db/migrations"
  chmod +x "$TROOT/scripts/db_migrate.sh"
  RUNNER="$TROOT/scripts/db_migrate.sh"
}

teardown() {
  [ -n "${TROOT:-}" ] && rm -rf "$TROOT" 2>/dev/null || true
}

_psql() {
  PGOPTIONS='-c client_min_messages=warning' \
    "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" -tAc "$1"
}

@test "DB1: fresh apply installs all migrations, ledger owned by runner" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  # 002는 자체 marker INSERT가 없다 — ledger 기록은 runner 소유임을 증명
  [ "$(_psql "select count(*) from schema_migrations where version='002_schema_contract_fixes'")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='public' and table_name='user_fortunes'")" = "1" ]
}

@test "DB2: re-run is a no-op (idempotent), typo option is a usage error" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  run env ENV_FILE="$ENVF" "$RUNNER" --statsu
  [ "$status" -eq 2 ]
  [[ "$output" == *"알 수 없는 인수"* ]]
}

@test "DB3: failing migration rolls back atomically - no partial objects, no ledger entry" {
  cat > "$TROOT/db/migrations/999_bad_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS should_not_survive (id INT);
SELECT 1/0;
SQL
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"rollback"* ]]
  [ "$(_psql "select count(*) from information_schema.tables where table_name='should_not_survive'")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '999%'")" = "0" ]
}

@test "DB4: unreachable DB is fail-closed for both --status and apply (no 'pending' lie)" {
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:1/${TEST_DB}?schema=public" > "$ENVF"
  run env ENV_FILE="$ENVF" PGCONNECT_TIMEOUT=3 "$RUNNER" --status
  [ "$status" -ne 0 ]
  [[ "$output" == *"접속 실패"* ]]
  [[ "$output" != *"pending"* ]]
  run env ENV_FILE="$ENVF" PGCONNECT_TIMEOUT=3 "$RUNNER"
  [ "$status" -ne 0 ]
}

@test "DB5: concurrent runners serialize - each migration applied exactly once, both rc=0" {
  ( ENV_FILE="$ENVF" "$RUNNER" > "$PGT/c1.log" 2>&1; echo $? > "$PGT/c1.rc" ) &
  ( ENV_FILE="$ENVF" "$RUNNER" > "$PGT/c2.log" 2>&1; echo $? > "$PGT/c2.rc" ) &
  wait
  [ "$(cat "$PGT/c1.rc")" -eq 0 ]
  [ "$(cat "$PGT/c2.rc")" -eq 0 ]
  ! grep -q "ERROR" "$PGT/c1.log" "$PGT/c2.log"
  [ "$(_psql "select count(*) from schema_migrations")" = "$(ls "$TROOT"/db/migrations/*.sql | wc -l | tr -d ' ')" ]
}

@test "DB6: deployed contract - bad streak rejected, consent bidirectional, delete scrubs, events 32KiB" {
  run env ENV_FILE="$ENVF" "$RUNNER"
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

@test "DB7: top-level transaction control is rejected before execution - comment variants included, nothing runs" {
  # 리뷰 16차 P1 재수정: `COMMIT; -- comment`는 독립 행 정규식을 우회해
  # rc=1이면서도 앞뒤 테이블이 실제로 남는 부분 commit을 만들었다.
  # 이제 문맥 인지 스캐너가 실행 "전"에 정확히 검출해 거부한다 — 아무것도 실행 안 함.
  cat > "$TROOT/db/migrations/998_txn_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS partial_a (id INT);
COMMIT; -- innocuous-looking comment
CREATE TABLE IF NOT EXISTS partial_b (id INT);
SELECT 1/0;
SQL
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"transaction control"* ]]
  # 실행 자체가 거부되므로 어떤 객체도 생기지 않는다 (부분 commit 불가능)
  [ "$(_psql "select count(*) from information_schema.tables where table_name in ('partial_a','partial_b')")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '998%'")" = "0" ]

  # 변형: `commit ;` (공백) — 동일하게 거부
  cat > "$TROOT/db/migrations/998_txn_zz_test.sql" <<'SQL'
commit ;
SQL
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"transaction control"* ]]
}

@test "DB8: --status is strictly read-only - no ledger bootstrap on a fresh DB" {
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"pending"* ]]
  # status가 schema_migrations를 만들지 않았다
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  # apply 후에는 applied로 보고
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 0 ]
  [[ "$output" == *"001_init (applied)"* ]]
}

@test "DB9: schema parameter is honored with exact case (quoted identifier), unsafe values rejected" {
  # 리뷰 16차 P1: unquoted 식별자는 소문자로 접혀 schema=AppData가 appdata에
  # 적용되면서 로그만 AppData로 표시됐다 — quoting으로 대소문자 그대로 사용.
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=AppData&connection_limit=20" > "$ENVF"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"schema: AppData"* ]]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='AppData' and table_name='users'")" = "1" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='AppData' and table_name='schema_migrations'")" = "1" ]
  # 소문자 스키마가 대신 만들어지지 않았고, public에도 없다
  [ "$(_psql "select count(*) from information_schema.schemata where schema_name='appdata'")" = "0" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_schema='public' and table_name='users'")" = "0" ]
  # 위험 식별자는 거부 (fail-closed)
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=app;drop" > "$ENVF"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 2 ]
  # 긴 중복 파라미터도 무진단 종료(SIGPIPE rc=141) 없이 첫 값으로 처리된다
  {
    printf 'DATABASE_URL=postgres://postgres:x@127.0.0.1:%s/%s?schema=public' "$PGT_PORT" "$TEST_DB"
    for i in $(seq 1 2000); do printf '&schema=dup%s' "$i"; done
    printf '\n'
  } > "$ENVF"
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 0 ]
}

@test "DB10: soft-delete contract - anonymized identity, severed events, preserved purchases, no resurrection" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject, last_login_at) values ('kakao','u1', now())"
  _psql "update users set consent_personalization=true, consented_at=now(), birth_profile_hash='h', nickname='n' where id=1"
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into events (event_type, user_id) values ('visit', 1)"
  _psql "insert into purchases (user_id, product_code, amount_krw) values (1, 'p1', 1000)"
  _psql "update users set deleted_at=now() where id=1"
  # C1: provider_subject 익명화 / C4: last_login_at 스크럽 (+ 기존 스크럽 집합)
  [ "$(_psql "select (provider_subject like 'deleted:%' and last_login_at is null and nickname is null and birth_profile_hash is null and not consent_personalization) from users where id=1")" = "t" ]
  # C2: events는 user_id 절단, payload(행)는 유지
  [ "$(_psql "select count(*) from events where event_type='visit'")" = "1" ]
  [ "$(_psql "select count(*) from events where user_id=1")" = "0" ]
  # C3: purchases는 연결 유지한 채 보존
  [ "$(_psql "select count(*) from purchases where user_id=1")" = "1" ]
  # (a) 삭제된 행에 개인 필드 재기입 — 거부 (CHECK 불변식)
  run _psql "update users set last_topic='love' where id=1"
  [ "$status" -ne 0 ]
  run _psql "update users set nickname='back' where id=1"
  [ "$status" -ne 0 ]
  # (b) deleted_at이 설정된 채 개인 필드를 담은 INSERT — 거부
  run _psql "insert into users (provider, provider_subject, nickname, deleted_at) values ('kakao','u2','n2',now())"
  [ "$status" -ne 0 ]
  # (c) 삭제된 사용자로의 자식 행 재유입 — 세 경로 + events/purchases 모두 거부
  run _psql "insert into sessions (user_id) values (1)"
  [ "$status" -ne 0 ]
  run _psql "insert into streaks (user_id, current_streak, longest_streak) values (1, 0, 0)"
  [ "$status" -ne 0 ]
  _psql "insert into fortunes (cache_key, payload) values ('ck2','{}')"
  run _psql "insert into user_fortunes (user_id, fortune_id) values (1, 1)"
  [ "$status" -ne 0 ]
  run _psql "insert into events (event_type, user_id) values ('visit', 1)"
  [ "$status" -ne 0 ]
  run _psql "insert into purchases (user_id, product_code, amount_krw) values (1, 'p2', 1000)"
  [ "$status" -ne 0 ]
  # 익명 세션/이벤트(user_id NULL)는 계속 허용
  _psql "insert into sessions (user_id) values (NULL)"
  _psql "insert into events (event_type) values ('visit')"
  # C5: 복구(deleted_at 재-NULL) 금지
  run _psql "update users set deleted_at=NULL where id=1"
  [ "$status" -ne 0 ]
  # C1: 같은 OAuth 계정 재가입 = 새 행 (UNIQUE 충돌 없음)
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  [ "$(_psql "select count(*) from users where provider_subject='u1'")" = "1" ]
  [ "$(_psql "select count(*) from users")" = "2" ]
}

@test "DB11: a failing migration whose error text contains 'ALREADY_APPLIED' is a failure, not a skip" {
  cat > "$TROOT/db/migrations/997_lie_zz_test.sql" <<'SQL'
DO $x$ BEGIN RAISE EXCEPTION 'ALREADY_APPLIED impostor'; END $x$;
SQL
  run env ENV_FILE="$ENVF" "$RUNNER"
  # 과거: 출력 문자열 매칭으로 skip 처리되어 rc=0으로 위장 — 지금은 실패(rc=1)
  [ "$status" -eq 1 ]
  [[ "$output" != *"skip  997"* ]]
  [ "$(_psql "select count(*) from schema_migrations where version like '997%'")" = "0" ]
}

@test "DB12: transaction-control keywords inside dollar-quotes, strings and comments are NOT rejected, SQL runs verbatim" {
  # 리뷰 16차 P1: SQL을 수정해 실행하는 방식은 procedure/function 본문의 독립
  # COMMIT;도 문맥 없이 삭제해 원본과 다른 SQL을 적용했다 — 수정 실행 금지.
  # 문맥상 안전한 위치의 키워드는 오탐 없이 그대로 적용되어야 한다.
  cat > "$TROOT/db/migrations/996_dollar_zz_test.sql" <<'SQL'
-- COMMIT; (주석 — 무시)
/* BEGIN; /* 중첩 주석 */ ROLLBACK; */
CREATE OR REPLACE FUNCTION zz_probe() RETURNS text
LANGUAGE plpgsql AS $body$
BEGIN
  -- 본문 안의 독립 행 COMMIT; 텍스트가 삭제되면 안 된다:
  RETURN 'COMMIT;
END';
END $body$;
CREATE TABLE IF NOT EXISTS zz_ok (note TEXT DEFAULT 'ROLLBACK; -- in string');
SQL
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  # 함수 본문이 원본 그대로 적용됐다 (수정 실행 없음)
  [ "$(_psql "select zz_probe() like 'COMMIT;%'")" = "t" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_name='zz_ok'")" = "1" ]
}
