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
  # 리뷰 16차 P1(7차): runner의 실행 원본은 "HEAD에 커밋된 blob"뿐이다 —
  # fixture도 git repo여야 하고, 테스트가 migration 파일을 쓰거나 바꾸면
  # _commit_migs로 커밋해야 적용 대상이 된다 (미커밋 변경은 fail-closed 거부).
  TROOT="$PGT/root_${BATS_TEST_NUMBER}"
  mkdir -p "$TROOT/scripts" "$TROOT/db"
  cp "$REPO_ROOT/scripts/db_migrate.sh" "$TROOT/scripts/db_migrate.sh"
  cp -R "$REPO_ROOT/db/migrations" "$TROOT/db/migrations"
  # 리뷰 16차 8라운드 후속 P1: 여기서 chmod +x를 하지 않는다 — 과거 이 chmod가
  # 커밋된 mode 소실(100755→100644, rc=126)을 숨겼다. cp는 원본 권한을 보존하므로
  # 실제 checkout의 실행 권한이 그대로 검증된다 (실행 불가면 모든 테스트가 실패).
  [ -x "$TROOT/scripts/db_migrate.sh" ] || {
    echo "scripts/db_migrate.sh 가 checkout에서 실행 가능하지 않습니다 (git mode 100755 필요)" >&2
    return 1
  }
  git -C "$TROOT" init -q
  git -C "$TROOT" config user.email "db@test"
  git -C "$TROOT" config user.name "dbtest"
  git -C "$TROOT" add -A
  git -C "$TROOT" commit -qm "fixture"
  RUNNER="$TROOT/scripts/db_migrate.sh"
}

# 테스트가 만든/바꾼 migration을 커밋 — 커밋된 blob만 실행되는 계약(7차 P1-2).
_commit_migs() {
  git -C "$TROOT" add -A db/migrations
  git -C "$TROOT" commit -qm "migs: $BATS_TEST_NUMBER" >/dev/null
}

teardown() {
  [ -n "${TROOT:-}" ] && rm -rf "$TROOT" 2>/dev/null || true
}

_psql() {
  PGOPTIONS='-c client_min_messages=warning' \
    "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" -tAc "$1"
}

# _deploy_upto <version…> — "그 시점까지만 배포된 live DB"를 재현한다.
# 리뷰 16차 P1(8차 2회, #1): 이제 runner는 공개 manifest 전량(001~005)이 커밋에
# 존재할 것을 요구하므로, 구버전 상태를 "파일 삭제"로 흉내낼 수 없다(그 자체가
# 거부 대상이다 — DB27 참조). 실제 live DB가 그렇듯 "파일은 전부 있고 ledger만
# 앞선 version까지"인 상태를 만든다: 해당 SQL을 직접 적용하고 ledger에 기록한다.
_deploy_upto() {
  local v
  "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
    -c "CREATE TABLE IF NOT EXISTS schema_migrations (version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now())" >/dev/null
  for v in "$@"; do
    PGOPTIONS='-c client_min_messages=warning' \
      "$PGBIN/psql" -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -f "$TROOT/db/migrations/${v}.sql" >/dev/null
    _psql "insert into schema_migrations (version) values ('${v}') on conflict (version) do nothing" >/dev/null
  done
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
  _commit_migs
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
  _psql "select app_soft_delete_user(1)"
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

@test "DB7: embedded transaction control is refused by the server itself - full rollback, no partial commit" {
  # 리뷰 16차 P1 재재수정: 원자성 경계는 수제 파서가 아니라 서버다. 파일 내용은
  # DO 블록의 EXECUTE(SPI)로 실행되고, `COMMIT; -- comment` 같은 어떤 변형이든
  # 서버가 원자 컨텍스트에서 거부한다 → 앞선 문장까지 전부 rollback.
  cat > "$TROOT/db/migrations/998_txn_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS partial_a (id INT);
COMMIT; -- innocuous-looking comment
CREATE TABLE IF NOT EXISTS partial_b (id INT);
SELECT 1/0;
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"transaction"* ]]
  # 부분 commit 불가능 — 내부 COMMIT "앞"의 객체도 남지 않는다 (전체 rollback)
  [ "$(_psql "select count(*) from information_schema.tables where table_name in ('partial_a','partial_b')")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '998%'")" = "0" ]

  # 변형: `commit ;` (공백) — 동일하게 거부
  cat > "$TROOT/db/migrations/998_txn_zz_test.sql" <<'SQL'
commit ;
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [ "$(_psql "select count(*) from schema_migrations where version like '998%'")" = "0" ]
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
  # 리뷰 16차 P1-8: custom schema에 설치된 삭제 트리거는 호출자의 search_path가
  # 달라도(기본 public) 동작해야 한다 — 함수가 SET search_path FROM CURRENT로 고정됨.
  _psql "insert into \"AppData\".users (provider, provider_subject, nickname) values ('kakao','sub1','nick')"
  _psql "select \"AppData\".app_soft_delete_user(1)"
  [ "$(_psql "select (nickname is null and provider_subject like 'deleted:%') from \"AppData\".users where id=1")" = "t" ]
  # 위험 식별자는 거부 (fail-closed)
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=app;drop" > "$ENVF"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 2 ]
  # 리뷰 16차 P2: 63자 초과 schema는 서버가 잘라 다른 이름이 된다 — 명시 거부
  _long="s$(printf 'a%.0s' $(seq 1 70))"
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB}?schema=${_long}" > "$ENVF"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 2 ]
  [[ "$output" == *"63자"* ]]
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
  _psql "insert into events (event_type, user_id, payload) values ('visit', 1, '{\"pii\":\"maybe\"}'::jsonb)"
  _psql "insert into purchases (user_id, product_code, amount_krw) values (1, 'p1', 1000)"
  _psql "select app_soft_delete_user(1)"
  # C1: provider_subject 익명화 / C4: last_login_at 스크럽 (+ 기존 스크럽 집합)
  [ "$(_psql "select (provider_subject like 'deleted:%' and last_login_at is null and nickname is null and birth_profile_hash is null and not consent_personalization) from users where id=1")" = "t" ]
  # C2(강화): events는 user_id 절단 + payload 스크럽 — 행(집계 축)은 유지
  [ "$(_psql "select count(*) from events where event_type='visit'")" = "1" ]
  [ "$(_psql "select count(*) from events where user_id=1")" = "0" ]
  [ "$(_psql "select payload::text from events where event_type='visit'")" = "{}" ]
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
  _commit_migs
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
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  # 함수 본문이 원본 그대로 적용됐다 (수정 실행 없음)
  [ "$(_psql "select zz_probe() like 'COMMIT;%'")" = "t" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_name='zz_ok'")" = "1" ]
}

@test "DB13: psql meta-commands and COPY FROM STDIN in a migration cannot execute - refused server-side" {
  # 리뷰 16차 P1: \i 외부 파일 포함·\! 셸 실행은 scanner가 못 보는 경로로
  # transaction control을 반입했다. 이제 파일 내용이 dollar-quote 리터럴로
  # 서버에 전달되므로 psql이 meta command를 해석할 기회 자체가 없다.
  cat > "$TROOT/evil-include.sql" <<'SQL'
COMMIT;
CREATE TABLE smuggled (id INT);
SQL
  cat > "$TROOT/db/migrations/995_meta_zz_test.sql" <<SQL
CREATE TABLE IF NOT EXISTS meta_a (id INT);
\i $TROOT/evil-include.sql
\! touch $TROOT/pwned
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  # 셸 실행·외부 포함이 일어나지 않았고, 부분 적용도 없다
  [ ! -f "$TROOT/pwned" ]
  [ "$(_psql "select count(*) from information_schema.tables where table_name in ('meta_a','smuggled')")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '995%'")" = "0" ]
  rm -f "$TROOT/db/migrations/995_meta_zz_test.sql"

  # COPY FROM STDIN — 서버가 PL/pgSQL 컨텍스트에서 거부
  cat > "$TROOT/db/migrations/995_copy_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS copy_a (id INT);
COPY copy_a FROM STDIN;
1
\.
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [ "$(_psql "select count(*) from information_schema.tables where table_name='copy_a'")" = "0" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '995%'")" = "0" ]
}

@test "DB14: concurrent soft-delete and child INSERT serialize on the parent row - no orphan links survive" {
  # 리뷰 16차 P1-3: EXISTS 조회는 부모 행을 잠그지 않아, 미커밋 삭제 UPDATE 동안
  # 자식 INSERT가 이전 active 스냅숏을 보고 통과했다 — FOR SHARE 잠금으로 삭제
  # 커밋을 기다렸다가 재평가되어 거부된다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  # 세션 A: 삭제 UPDATE를 열고 2초간 미커밋 유지
  ( PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -c "BEGIN; SELECT app_soft_delete_user(1); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 ) &
  local killer=$!
  sleep 0.7
  # 세션 B: 삭제 미커밋 동안 자식 INSERT — FOR SHARE 대기 후 재평가로 거부돼야 한다
  run _psql "insert into sessions (user_id) values (1)"
  [ "$status" -ne 0 ]
  run _psql "insert into events (event_type, user_id) values ('visit', 1)"
  [ "$status" -ne 0 ]
  wait "$killer" 2>/dev/null || true
  # 삭제 완료 후 어떤 연결도 남지 않았다
  [ "$(_psql "select count(*) from sessions where user_id=1")" = "0" ]
  [ "$(_psql "select count(*) from events where user_id=1")" = "0" ]
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
}

@test "DB15: migration-issued SET LOCAL search_path cannot divert the ledger - runner refs are schema-qualified" {
  # 리뷰 16차 P1(4차): migration이 SET LOCAL search_path=other를 실행하면
  # unqualified ledger INSERT가 other.schema_migrations로 갔다 — guard·INSERT·
  # 조회 전부 schema-qualified라 이제 영향받지 않는다.
  cat > "$TROOT/db/migrations/994_hijack_zz_test.sql" <<'SQL'
CREATE SCHEMA IF NOT EXISTS sneaky;
CREATE TABLE IF NOT EXISTS sneaky.schema_migrations (
  version TEXT PRIMARY KEY, applied_at TIMESTAMPTZ NOT NULL DEFAULT now()
);
SET LOCAL search_path = sneaky;
CREATE TABLE hijack_probe (id INT);
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  # ledger는 public에 기록됐고, sneaky 쪽 위장 ledger에는 기록되지 않았다
  [ "$(_psql "select count(*) from public.schema_migrations where version='994_hijack_zz_test'")" = "1" ]
  [ "$(_psql "select count(*) from sneaky.schema_migrations")" = "0" ]
  # 재실행도 정확히 skip (조회 역시 qualified)
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip  994_hijack_zz_test"* ]]
}

@test "DB16: published migrations are checksum-pinned - committed tamper of 001 is refused even without txn control" {
  # 리뷰 16차 P1(8차 실측 회귀): 공개본 001에는 BEGIN/COMMIT이 없어 "서버의
  # transaction control 거부"가 변조를 잡아주지 않는다 — runner가 공개본
  # sha256 pin으로 직접 거부해야 한다 (커밋 여부와 무관, fail-closed).
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from schema_migrations where version='001_init'")" = "1" ]

  # 변조된 001 (무해한 주석 한 줄 추가, 커밋까지) → fresh DB에서 pin 불일치 거부
  TEST_DB2="${TEST_DB}b"
  _as_pg "'$PGBIN/createdb' -h 127.0.0.1 -p $PGT_PORT -U postgres $TEST_DB2"
  echo "DATABASE_URL=postgres://postgres:x@127.0.0.1:${PGT_PORT}/${TEST_DB2}?schema=public" > "$ENVF"
  printf -- '-- tampered\n' >> "$TROOT/db/migrations/001_init.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"공개본 checksum"* ]]
  # 8라운드 후속: manifest preflight는 bootstrap "전"에 거부한다 — 계약은
  # "manifest 실패 시 DB에 아무것도 쓰지 않는다"이다. ledger 자체가 없어야 한다
  # (과거 assertion은 테이블을 직접 조회해 빈 출력에서 실패했다).
  [ "$(PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB2" -tAc \
    "select to_regclass('public.schema_migrations') is null")" = "t" ]
}

@test "DB17: session-only events are scrubbed, scrub is a frozen invariant, anonymized token is exact-UUID" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into sessions (user_id) values (1)"
  # 리뷰 16차 P1-7(4차): user_id 없이 session으로만 귀속된 event
  _psql "insert into events (event_type, session_id, payload) select 'visit', id, '{\"pii\":\"session\"}'::jsonb from sessions where user_id=1"
  _psql "select app_soft_delete_user(1)"
  # session-only event도 스크럽됐다 (세션 삭제 전에 수행)
  [ "$(_psql "select payload::text from events where event_type='visit'")" = "{}" ]
  [ "$(_psql "select (scrubbed_at is not null) from events where event_type='visit'")" = "t" ]
  # 리뷰 16차 P1-8(4차): 스크럽은 영속 불변식 — 삭제 후 payload 재기입 거부
  run _psql "update events set payload='{\"pii\":\"late\"}'::jsonb where event_type='visit'"
  [ "$status" -ne 0 ]
  run _psql "update events set user_id=1 where event_type='visit'"
  [ "$status" -ne 0 ]
  # 리뷰 16차 P1-9(4차): 'deleted:' + 임의 36자는 익명 토큰으로 인정되지 않는다
  run _psql "insert into users (provider, provider_subject, deleted_at) values ('kakao', 'deleted:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', now())"
  [ "$status" -ne 0 ]
  # 정상 삭제 경로의 토큰은 정확한 UUID 형식이다
  [ "$(_psql "select provider_subject ~ '^deleted:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\$' from users where id=1")" = "t" ]
  # 리뷰 16차 P2(4차): purchases.user_id 재배정 금지 (활성 사용자로도)
  _psql "insert into users (provider, provider_subject) values ('kakao','u2')"
  _psql "insert into purchases (user_id, product_code, amount_krw) values (3, 'p1', 1000)"
  _psql "insert into users (provider, provider_subject) values ('kakao','u3')"
  run _psql "update purchases set user_id=4 where user_id=3"
  [ "$status" -ne 0 ]
}

@test "DB18: scrub marker cannot be cleared, session-only INSERT races serialize, scrubbed events cannot be re-linked" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into events (event_type, user_id, payload) values ('visit', 1, '{\"pii\":\"x\"}'::jsonb)"
  _psql "select app_soft_delete_user(1)"
  # 5차 P1-2: scrubbed_at 해제(NULL 전이)로 frozen CHECK를 우회할 수 없다
  run _psql "update events set scrubbed_at=NULL, payload='{\"pii\":\"restored\"}'::jsonb where event_type='visit'"
  [ "$status" -ne 0 ]
  run _psql "update events set scrubbed_at=NULL where event_type='visit'"
  [ "$status" -ne 0 ]
  # 5차 P1-5: scrubbed event를 활성 세션에 재연결할 수 없다 (session_id 절단 불변)
  _psql "insert into users (provider, provider_subject) values ('kakao','u2')"
  _psql "insert into sessions (user_id) values (2)"
  run _psql "update events set session_id=(select id from sessions where user_id=2) where event_type='visit'"
  [ "$status" -ne 0 ]
  # 5차 P1-3: 미커밋 삭제 중 session-only INSERT — 세션 소유자 행 잠금으로 직렬화
  _psql "insert into sessions (user_id) values (2)"
  ( PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -c "BEGIN; SELECT app_soft_delete_user(2); SELECT pg_sleep(2); COMMIT;" >/dev/null 2>&1 ) &
  local deleter=$!
  sleep 0.7
  run _psql "insert into events (event_type, session_id, payload) select 'raced', id, '{\"pii\":\"raced\"}'::jsonb from sessions where user_id=2 limit 1"
  [ "$status" -ne 0 ]
  wait "$deleter" 2>/dev/null || true
  # 삭제 완료 후 pii payload를 가진 orphan은 존재하지 않는다
  [ "$(_psql "select count(*) from events where payload::text like '%raced%'")" = "0" ]
  # 익명 세션 경유 INSERT는 계속 허용
  _psql "insert into sessions (user_id) values (NULL)"
  _psql "insert into events (event_type, session_id) select 'anon', id from sessions where user_id is null limit 1"
}

@test "DB19: the manifest covers every published version including 005 - any committed tamper is refused before any write" {
  # 리뷰 16차 8라운드 후속 P1: (a) "004 checksum 실패 전에 001~003이 적용된다"는
  # 전제 제거 — 새 manifest 계약은 DB에 어떤 쓰기도 하기 "전에" 전체를 거부한다.
  # (b) "unpublished 005 stays editable" 전제 제거 — 005도 공개본이며 변조는
  # 반드시 거부된다 (001~005 전 항목 동일 규칙, 예외 없음).
  cat >> "$TROOT/db/migrations/004_soft_delete_contract.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS evil_004 (id INT);
SQL
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"공개본 checksum"* ]]
  [[ "$output" == *"004_soft_delete_contract"* ]]
  # 아무것도 적용되지 않았다 — bootstrap 전 거부라 ledger 자체가 없다
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  [ "$(_psql "select to_regclass('evil_004') is null")" = "t" ]

  # 004 원복 + 005 변조(무해한 주석 한 줄, 커밋) → 005도 같은 규칙으로 거부
  git -C "$TROOT" show HEAD~1:db/migrations/004_soft_delete_contract.sql \
    > "$TROOT/db/migrations/004_soft_delete_contract.sql"
  printf -- '-- tampered 005\n' >> "$TROOT/db/migrations/005_ownership_repair_and_lock_contract.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"공개본 checksum"* ]]
  [[ "$output" == *"005_ownership_repair_and_lock_contract"* ]]
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]

  # --status도 같은 계약으로 거부한다
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 1 ]
  [[ "$output" != *"pending"* ]]

  # 005 원복(직전 커밋의 원본) → 전부 정상 적용
  git -C "$TROOT" show HEAD~1:db/migrations/005_ownership_repair_and_lock_contract.sql \
    > "$TROOT/db/migrations/005_ownership_repair_and_lock_contract.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from schema_migrations")" = "5" ]
}

@test "DB20: legacy orphan events (002-era deletes) are scrubbed by the 005 backfill - explicit fail-closed policy" {
  # 002까지만 배포된 live DB의 삭제는 sessions를 먼저 지워 session-only event가
  # orphan으로 남았다 — 005는 소유 증거가 없는 이중 orphan payload를 전부 스크럽.
  # (8차 2회 #1: 구버전 상태는 파일 삭제가 아니라 ledger 상태로 재현한다.)
  _deploy_upto 001_init 002_schema_contract_fixes
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into events (event_type, session_id, payload) select 'visit', id, '{\"pii\":\"legacy\"}'::jsonb from sessions where user_id=1"
  # 002-era 삭제: 진입점 계약이 아직 없으므로 직접 UPDATE — 트리거가 세션을 지워
  # event가 orphan(session_id NULL)이 된다
  _psql "update users set deleted_at=now() where id=1"
  [ "$(_psql "select (session_id is null and payload::text like '%legacy%') from events where event_type='visit'")" = "t" ]
  # 003·004·005 적용 — legacy 정책이 orphan payload를 스크럽한다
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip  001_init"* ]]
  [[ "$output" == *"✓ 005_ownership_repair_and_lock_contract"* ]]
  [ "$(_psql "select payload::text from events where event_type='visit'")" = "{}" ]
  [ "$(_psql "select (scrubbed_at is not null) from events where event_type='visit'")" = "t" ]
}

@test "DB21: session owner reassignment is banned (anon bind allowed), cross-owned events rejected" {
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"   # id 1
  _psql "insert into users (provider, provider_subject) values ('kakao','u2')"   # id 2
  _psql "insert into sessions (user_id) values (1)"
  local S1 SB SD
  S1="$(_psql "select id from sessions where user_id=1")"
  # 6차 P1-2: 소유자 재배정 금지 — 다른 사용자로도, NULL로도 (삭제 스캔 우회 차단)
  run _psql "update sessions set user_id=2 where id='$S1'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"재배정"* ]]
  run _psql "update sessions set user_id=NULL where id='$S1'"
  [ "$status" -ne 0 ]
  [ "$(_psql "select user_id from sessions where id='$S1'")" = "1" ]
  # 익명 세션의 로그인 바인딩(NULL→user)은 허용
  _psql "insert into sessions (user_id) values (NULL)"
  SB="$(_psql "select id from sessions where user_id is null")"
  _psql "update sessions set user_id=2 where id='$SB'"
  [ "$(_psql "select user_id from sessions where id='$SB'")" = "2" ]
  # 삭제된 사용자로의 바인딩은 거부
  _psql "insert into users (provider, provider_subject) values ('kakao','u3')"   # id 3
  _psql "select app_soft_delete_user(3)"
  _psql "insert into sessions (user_id) values (NULL)"
  SD="$(_psql "select id from sessions where user_id is null")"
  run _psql "update sessions set user_id=3 where id='$SD'"
  [ "$status" -ne 0 ]
  # 6차 P1-3: user와 session 소유자가 다른 event는 거부 (교차 귀속 = 삭제 스캔 사각)
  run _psql "insert into events (event_type, user_id, session_id) values ('x', 2, '$S1')"
  [ "$status" -ne 0 ]
  [[ "$output" == *"교차 귀속"* ]]
  # 익명 세션(소유자 NULL)에 특정 user 귀속도 거부 — 먼저 세션을 바인딩해야 한다
  run _psql "insert into events (event_type, user_id, session_id) values ('x', 1, '$SD')"
  [ "$status" -ne 0 ]
  [ "$(_psql "select count(*) from events where event_type='x'")" = "0" ]
  # 정합 귀속은 허용: 소유자 본인 귀속, user_id 없는 세션 귀속
  _psql "insert into events (event_type, user_id, session_id) values ('ok', 1, '$S1')"
  _psql "insert into events (event_type, session_id) values ('ok2', '$S1')"
  [ "$(_psql "select count(*) from events where event_type in ('ok','ok2')")" = "2" ]
}

@test "DB22: working-tree divergence from HEAD is refused up front - torn/in-place mutation has no execution path" {
  # 6차 P1-1→7차 P1-2: 이중 읽기+cmp는 같은 mutable inode를 두 번 읽을 뿐이라
  # 동일한 torn 내용을 두 번 읽으면 통과했다 (실측). 이제 실행 원본은 커밋된
  # blob"만"이고, 작업트리가 HEAD와 다르면(미커밋 수정) 어떤 것도 적용하기 전에
  # 거부한다 — torn 내용이 실행될 경로 자체가 없다 (fail-closed).
  printf 'CREATE TABLE torn_write (id INT);\n' >> "$TROOT/db/migrations/002_schema_contract_fixes.sql"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"커밋되"* ]]
  # 아무것도 적용되지 않았다 — 전체 집합 무결성 (ledger 자체가 없다)
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  [ "$(_psql "select to_regclass('torn_write') is null")" = "t" ]

  # 미추적 *.sql(집합 불일치)도 거부된다
  git -C "$TROOT" checkout -- db/migrations/002_schema_contract_fixes.sql
  printf 'CREATE TABLE stray (id INT);\n' > "$TROOT/db/migrations/993_stray_zz_test.sql"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"목록"* ]]
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  rm -f "$TROOT/db/migrations/993_stray_zz_test.sql"

  # 정리 후에는 정상 적용된다
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from schema_migrations where version='001_init'")" = "1" ]
}

@test "DB23: pre-existing cross-attributed events are repaired by 005 - guest-bind then delete cannot scrub third-party payload" {
  # 리뷰 16차 P1-4(7차): 001~004 시절의 교차 귀속 행(event.user_id=B /
  # session.owner=A, event.user_id=B / guest session)은 004 적용 후에도 남았고,
  # guest 세션을 A에 바인딩한 뒤 A를 삭제하면 B 귀속 payload까지 스크럽됐다.
  # 005의 repair는 불일치 행의 session 링크를 절단한다 (귀속·payload 보존).
  # 004까지 배포된 live DB (8차 2회 #1: 파일 삭제가 아니라 ledger 상태로 재현)
  _deploy_upto 001_init 002_schema_contract_fixes 003_soft_delete_invariant 004_soft_delete_contract
  _psql "insert into users (provider, provider_subject) values ('kakao','A')"   # id 1
  _psql "insert into users (provider, provider_subject) values ('kakao','B')"   # id 2
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into sessions (user_id) values (NULL)"
  local SA SG
  SA="$(_psql "select id from sessions where user_id=1")"
  SG="$(_psql "select id from sessions where user_id is null")"
  # 구 004에는 교차 귀속 거부가 없다 — 두 행 모두 통과한다
  _psql "insert into events (event_type, user_id, session_id, payload) values ('x', 2, '$SA', '{\"keep\":\"a\"}'::jsonb)"
  _psql "insert into events (event_type, user_id, session_id, payload) values ('y', 2, '$SG', '{\"keep\":\"g\"}'::jsonb)"
  # 005 적용 — repair가 session 링크를 절단한다
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from events where user_id=2 and session_id is null and event_type in ('x','y')")" = "2" ]
  # 재현 경로: guest 세션을 A에 바인딩 후 A 삭제 — B의 payload는 스크럽되지 않는다
  _psql "update sessions set user_id=1 where id='$SG'"
  [ "$(_psql "select app_soft_delete_user(1)")" = "t" ]
  [ "$(_psql "select payload::text from events where event_type='x'")" = '{"keep": "a"}' ]
  [ "$(_psql "select payload::text from events where event_type='y'")" = '{"keep": "g"}' ]
  [ "$(_psql "select count(*) from events where scrubbed_at is not null and event_type in ('x','y')")" = "0" ]
}

@test "DB24: one global lock order (child->users) - writer holding child locks and the deleter contend in the danger window without deadlock" {
  # 리뷰 16차 8라운드 후속 P1: 구 app_lock_user_rows(users-first)는 child→users인
  # 삭제 경로와 정면 상충해, helper를 따른 writer가 deadlock victim이 됐다 (실측).
  # 전역 순서는 child→users 하나다 — users-first helper는 제거됐고, writer는
  # 사전 잠금 없이 child DML만으로 구조적으로 순서를 따른다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  # users-first helper가 더 이상 존재하지 않는다
  [ "$(_psql "select count(*) from pg_proc where proname='app_lock_user_rows'")" = "0" ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into events (event_type, user_id, payload) values ('e', 1, '{\"p\":1}'::jsonb)"
  _psql "insert into streaks (user_id, current_streak, longest_streak) values (1, 1, 1)"
  # writer: 여러 child 테이블의 행 잠금(트리거 발화 컬럼 포함)을 쥔 채 지연 커밋
  ( PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -c "BEGIN; UPDATE events SET user_id=user_id WHERE user_id=1; UPDATE sessions SET user_id=user_id WHERE user_id=1; UPDATE streaks SET user_id=user_id WHERE user_id=1; SELECT pg_sleep(1.5); COMMIT;" > "$PGT/w24.log" 2>&1; echo $? > "$PGT/w24.rc" ) &
  local writer=$!
  sleep 0.5
  # 삭제: 위험 창(writer 미커밋, child 행 잠금 보유) 한가운데서 진입 —
  # deadlock이 아니라 "대기 후 성공"이어야 한다. 실제 경합을 timing으로 증명한다.
  local t0 t1 waited
  t0="$(_psql "select extract(epoch from clock_timestamp())")"
  run _psql "select app_soft_delete_user(1)"
  t1="$(_psql "select extract(epoch from clock_timestamp())")"
  [ "$status" -eq 0 ]
  [[ "$output" == *"t"* ]]
  waited="$(awk -v a="$t0" -v b="$t1" 'BEGIN { print (b - a >= 0.8) ? "y" : "n" }')"
  [ "$waited" = "y" ]
  wait "$writer" 2>/dev/null || true
  # 어느 쪽도 deadlock victim이 되지 않았다
  [ "$(cat "$PGT/w24.rc")" -eq 0 ]
  ! grep -qi "deadlock" "$PGT/w24.log"
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
  # 이미 삭제된 사용자 재호출은 false (멱등 신호)
  [ "$(_psql "select app_soft_delete_user(1)")" = "f" ]
  # 스크럽 결과는 기존 계약과 동일
  [ "$(_psql "select count(*) from sessions where user_id=1")" = "0" ]
  [ "$(_psql "select payload::text from events where event_type='e'")" = "{}" ]

  # 역방향 위험 창: 삭제가 child 잠금을 쥔 채 미커밋인 동안 writer의 child
  # UPDATE — deadlock이 아니라 "대기 후 guard 거부"로 직렬화된다.
  _psql "insert into users (provider, provider_subject) values ('kakao','u2')"
  _psql "insert into events (event_type, user_id, payload) values ('e2', 2, '{\"p\":2}'::jsonb)"
  ( PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -c "BEGIN; SELECT app_soft_delete_user(2); SELECT pg_sleep(1.5); COMMIT;" > "$PGT/d24.log" 2>&1; echo $? > "$PGT/d24.rc" ) &
  local deleter=$!
  sleep 0.5
  # 삭제가 스크럽한 행을 다시 사용자에 귀속하려는 UPDATE — 행 잠금 대기 후
  # 재평가되어 guard/frozen CHECK가 거부한다 (deadlock 아님)
  run _psql "update events set user_id=2 where event_type='e2'"
  [ "$status" -ne 0 ]
  [[ "$output" != *"deadlock"* ]]
  wait "$deleter" 2>/dev/null || true
  [ "$(cat "$PGT/d24.rc")" -eq 0 ]
  ! grep -qi "deadlock" "$PGT/d24.log"
  [ "$(_psql "select payload::text from events where event_type='e2'")" = "{}" ]
}

@test "DB25: TERM to the runner kills the migration psql process group - no late commit, temps cleaned, no lingering backend" {
  # 리뷰 16차 P1-3(7차): 과거에는 runner가 rc=143으로 죽은 뒤에도 child psql이
  # 계속 실행되어 몇 초 뒤 테이블·ledger를 commit했고 wrapper temp도 남았다.
  # 이제 psql은 별도 프로세스 그룹 — 신호 전달·bounded reap·서버 backend 종료
  # 확인 후 runner가 종료한다.
  cat > "$TROOT/db/migrations/990_slow_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS slow_probe (id INT);
SELECT pg_sleep(15);
SQL
  _commit_migs
  mkdir -p "$TROOT/tmp"
  env ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" "$RUNNER" > "$PGT/sig_${BATS_TEST_NUMBER}.log" 2>&1 &
  local rpid=$! i=0 rc=0
  # 990 적용(pg_sleep) 단계 진입 대기
  while [ "$i" -lt 60 ]; do
    if grep -q "apply 990_slow_zz_test" "$PGT/sig_${BATS_TEST_NUMBER}.log" 2>/dev/null \
       && [ "$(_psql "select count(*) from pg_stat_activity where application_name like 'db_migrate.%' and query like '%pg_sleep%'")" != "0" ]; then
      break
    fi
    sleep 0.25; i=$((i+1))
  done
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  [ "$rc" -eq 143 ]
  # child psql이 이어서 commit하지 못했다 — 시간이 지나도 결과가 없다
  sleep 3
  [ "$(_psql "select count(*) from schema_migrations where version like '990%'")" = "0" ]
  [ "$(_psql "select to_regclass('slow_probe') is null")" = "t" ]
  # wrapper/snapshot/출력 temp가 남지 않았다
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]
  # 서버에 이 runner의 잔존 backend가 없다 (transaction 종료 확인)
  [ "$(_psql "select count(*) from pg_stat_activity where application_name like 'db_migrate.%'")" = "0" ]
}

@test "DB26: signal received outside the migration psql - no NEW migration is started afterwards" {
  # 리뷰 16차 P1(8차): 신호가 migration psql "밖"(ledger 조회 등 foreground
  # 단계)에서 오면 trap은 기록만 하고 제어가 계속 진행돼, 다음 migration을
  # 통째로 적용·commit한 뒤에야 rc=143으로 끝났다 — 신호 이후에는 어떤
  # migration도 새로 시작하지 않아야 한다.
  cat > "$TROOT/db/migrations/990_first_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS first_ok (id INT);
SQL
  cat > "$TROOT/db/migrations/991_second_zz_test.sql" <<'SQL'
CREATE TABLE IF NOT EXISTS must_not_start (id INT);
SQL
  _commit_migs
  # 991의 ledger 조회(applied)만 지연시키는 psql shim — 그 구간에 TERM을 넣는다
  mkdir -p "$PGT/sigbin_${BATS_TEST_NUMBER}" "$TROOT/tmp"
  cat > "$PGT/sigbin_${BATS_TEST_NUMBER}/psql" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"version = '991_second_zz_test'"*) sleep 4 ;;
esac
exec "$PGBIN/psql" "\$@"
SHIM
  chmod +x "$PGT/sigbin_${BATS_TEST_NUMBER}/psql"
  env PATH="$PGT/sigbin_${BATS_TEST_NUMBER}:$PATH" ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" \
    "$RUNNER" > "$PGT/sig26_${BATS_TEST_NUMBER}.log" 2>&1 &
  local rpid=$! i=0 rc=0
  # 990 적용 완료(✓) 후 991의 지연된 ledger 조회 창에서 TERM
  while [ "$i" -lt 80 ]; do
    grep -q "✓ 990_first_zz_test" "$PGT/sig26_${BATS_TEST_NUMBER}.log" 2>/dev/null && break
    sleep 0.1; i=$((i+1))
  done
  sleep 0.5
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  [ "$rc" -eq 143 ]
  # 990은 적용됐고(신호 전 완료), 991은 시작조차 되지 않았다
  [ "$(_psql "select count(*) from schema_migrations where version like '990%'")" = "1" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '991%'")" = "0" ]
  [ "$(_psql "select to_regclass('must_not_start') is null")" = "t" ]
  # temp 정리 + 잔존 backend 없음
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]
  [ "$(_psql "select count(*) from pg_stat_activity where application_name like 'db_migrate.%'")" = "0" ]
}

@test "DB27: the manifest is complete - deleting a published migration is refused (fresh DB stays empty)" {
  # 8차 2회 P1(#1): pin이 "존재하는 파일"만 검사해, 커밋에서 004를 삭제하면
  # 001·002·003·005만 적용하고 rc=0 / up-to-date로 끝났다 (실측). manifest는
  # 공개된 전 version의 전량 목록이다 — 하나라도 없으면 아무것도 적용하지 않는다.
  git -C "$TROOT" rm -q db/migrations/004_soft_delete_contract.sql
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"004_soft_delete_contract.sql 이 커밋"* ]]
  [[ "$output" != *"up-to-date"* ]]
  # 부분 적용조차 없다 — ledger 자체가 생기지 않았다
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  # --status도 같은 계약으로 거부한다 (apply와 같은 inventory·manifest)
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 1 ]
  [[ "$output" != *"pending"* ]]
}

@test "DB28: already-applied published migrations are re-verified - tampering a deployed 003 is refused" {
  # 8차 2회 P1(#1): 이미 적용된 version은 apply 루프의 skip 분기에서 pin 검사를
  # 건너뛰어, 배포된 DB에 대해 공개본 변조가 무검증 통과했다. manifest 검증은
  # 적용 여부와 무관하게 "시작 전"에 수행된다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  printf -- '-- tampered after deploy\n' >> "$TROOT/db/migrations/003_soft_delete_invariant.sql"
  _commit_migs
  # 전부 applied라 apply 루프는 아무 일도 하지 않지만, manifest 검증이 잡는다
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"공개본 checksum"* ]]
  [[ "$output" == *"003_soft_delete_invariant"* ]]
  [[ "$output" != *"up-to-date"* ]]
}

@test "DB29: executed bytes are exactly the verified blob - a NUL byte is refused, trailing newlines are preserved" {
  # 8차 2회 P1(#2): _content="$(cat ...)"의 command substitution이 NUL을 버리고
  # 후행 개행을 제거해, "검증한 blob"과 "실제 실행 SQL"이 달랐다 — <유효 SQL><NUL>
  # migration이 변형된 채 적용되고 ledger에도 기록됐다 (실측).
  printf 'CREATE TABLE nul_probe (id INT);\n\000' > "$TROOT/db/migrations/989_nul_zz_test.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"NUL"* ]]
  # 변형 실행도, ledger 기록도 없다
  [ "$(_psql "select to_regclass('nul_probe') is null")" = "t" ]
  [ "$(_psql "select count(*) from schema_migrations where version like '989%'")" = "0" ]
  git -C "$TROOT" rm -q db/migrations/989_nul_zz_test.sql
  # 후행 개행이 여러 개인 SQL은 bytes 그대로 정상 적용된다 (변형 없음)
  printf 'CREATE TABLE tail_probe (id INT);\n\n\n\n' > "$TROOT/db/migrations/989_tail_zz_test.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select to_regclass('tail_probe') is not null")" = "t" ]
  # 8라운드 후속 P2: 개행 "없이" 끝나는(마지막 줄이 주석) 파일도 그대로 적용된다.
  # 서버가 실행 직전 octet_length+md5로 "EXECUTE 문자열 == 검증 blob"을 강제하므로
  # runner가 한 byte라도 추가/제거하면(과거: suffix \n) 이 apply는 실패한다 —
  # 성공 자체가 byte-identity의 증거다.
  printf 'CREATE TABLE nonl_probe (id INT);\n-- trailing comment, no newline' \
    > "$TROOT/db/migrations/988_nonl_zz_test.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select to_regclass('nonl_probe') is not null")" = "t" ]
}

@test "DB30: soft-delete entrypoint is enforced by the schema - direct UPDATE is refused, no lock-order reversal remains" {
  # 8차 2회 P1(#9): write contract가 helper 제공에 그쳐 직접 UPDATE를 막지 못했고,
  # 비준수 writer와 삭제가 경합하면 다른 writer가 deadlock victim이 됐다.
  # 이제 스크럽 트리거가 진입점 통과 증거를 요구한다 — 직접 UPDATE는 거부되고,
  # 진입점은 child→users 순서로 잠가 직접 child UPDATE 경로와 순서가 일치한다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into sessions (user_id) values (1)"
  _psql "insert into events (event_type, user_id, payload) values ('e', 1, '{\"p\":1}'::jsonb)"
  # 직접 UPDATE(비준수 writer)는 스키마가 거부한다 — 계약이 규약이 아니다
  run _psql "update users set deleted_at=now() where id=1"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app_soft_delete_user"* ]]
  [ "$(_psql "select (deleted_at is null) from users where id=1")" = "t" ]
  # GUC를 수동으로 흉내내도 통과하지 못한다 — 틀린 값(999)뿐 아니라
  # "정확한 대상 ID(1)"로 위조해도 거부된다 (8라운드 후속 P1: GUC는 더 이상
  # 증거가 아니다 — 증거는 role 정체성뿐이다)
  run _psql "begin; select set_config('app.soft_delete_user','999',true); update users set deleted_at=now() where id=1; commit;"
  [ "$status" -ne 0 ]
  [ "$(_psql "select (deleted_at is null) from users where id=1")" = "t" ]
  run _psql "begin; select set_config('app.soft_delete_user','1',true); update users set deleted_at=now() where id=1; commit;"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app_soft_delete_user"* ]]
  [ "$(_psql "select (deleted_at is null) from users where id=1")" = "t" ]

  # 역전 경로 재현: child row lock을 먼저 쥔 writer와 삭제가 경합해도 deadlock이
  # 아니라 직렬화된다 (진입점이 child→users로 잠그므로 순서가 일치한다).
  ( PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U postgres -d "$TEST_DB" \
      -c "BEGIN; UPDATE events SET user_id=user_id WHERE user_id=1; SELECT pg_sleep(1.5); COMMIT;" > "$PGT/w30.log" 2>&1; echo $? > "$PGT/w30.rc" ) &
  local writer=$!
  sleep 0.5
  run _psql "select app_soft_delete_user(1)"
  [ "$status" -eq 0 ]
  wait "$writer" 2>/dev/null || true
  # 어느 쪽도 deadlock victim이 되지 않았다
  [ "$(cat "$PGT/w30.rc")" -eq 0 ]
  ! grep -qi "deadlock" "$PGT/w30.log"
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
  [ "$(_psql "select payload::text from events where event_type='e'")" = "{}" ]
}

@test "DB31: a signal during the final post-apply ledger check is not lost (no rc=0 'up-to-date' lie)" {
  # 8차 2회 P1(#3): 마지막 migration의 post-apply ledger 재확인 중에 온 TERM이
  # 루프 상단 검사에 닿지 못하고 사라져, 4초 뒤 rc=0 / migrations up-to-date로
  # 끝났다 (실측). 이제 매 iteration 끝과 최종 보고 직전에도 신호를 확인한다.
  mkdir -p "$PGT/lastbin_${BATS_TEST_NUMBER}" "$TROOT/tmp"
  # 005의 ledger 조회는 두 번 일어난다: (1) 루프 상단 applied? (2) 적용 후 재확인.
  # 두 번째 호출만 지연시켜 그 창에 TERM을 넣는다.
  cat > "$PGT/lastbin_${BATS_TEST_NUMBER}/psql" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"version = '005_ownership_repair_and_lock_contract'"*)
    n=0
    [ -f "$TROOT/tmp/n005" ] && n=\$(cat "$TROOT/tmp/n005")
    n=\$((n+1)); echo "\$n" > "$TROOT/tmp/n005"
    if [ "\$n" -ge 2 ]; then touch "$TROOT/tmp/postapply"; sleep 5; fi
    ;;
esac
exec "$PGBIN/psql" "\$@"
SHIM
  chmod +x "$PGT/lastbin_${BATS_TEST_NUMBER}/psql"
  env PATH="$PGT/lastbin_${BATS_TEST_NUMBER}:$PATH" ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" \
    "$RUNNER" > "$PGT/sig31.log" 2>&1 &
  local rpid=$! i=0 rc=0
  while [ "$i" -lt 150 ]; do
    [ -f "$TROOT/tmp/postapply" ] && break
    sleep 0.1; i=$((i+1))
  done
  sleep 0.3
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  # 신호가 rc=0 성공으로 위장되지 않는다
  [ "$rc" -eq 143 ]
  ! grep -q "up-to-date" "$PGT/sig31.log"
  # 적용된 migration 자체는 유효하다 (transaction은 이미 commit됨)
  [ "$(_psql "select count(*) from schema_migrations")" = "5" ]
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]
}

@test "DB32: manifest existence is an exact filename-set comparison - a superstring name cannot stand in for a published file" {
  # 8라운드 후속 P1: substring 매칭은 공개 이름을 "포함하는" 다른 파일을 존재로
  # 오판했다. 공개 005를 개명해 상위 이름 안에 숨겨도 정확 집합 대조가 거부한다.
  git -C "$TROOT" mv db/migrations/005_ownership_repair_and_lock_contract.sql \
    db/migrations/990_zz005_ownership_repair_and_lock_contract.sql
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"005_ownership_repair_and_lock_contract.sql 이 커밋"* ]]
  [[ "$output" != *"up-to-date"* ]]
  # 아무것도 적용되지 않았다
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
}

@test "DB33: migration names must be fixed-width numeric (NNN_) with a safe charset - malformed names are refused up front" {
  # 8라운드 후속 P1: 비정형 이름은 정렬·공개 대역 비교·SQL literal 어디서도
  # 신뢰할 수 없다 — 시작 전에 거부한다 (fail-closed).
  printf 'CREATE TABLE bad_name (id INT);\n' > "$TROOT/db/migrations/05_short_zz_test.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"고정 폭 3자리 숫자 형식"* ]]
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  git -C "$TROOT" rm -q db/migrations/05_short_zz_test.sql
  # 허용 밖 문자(-)도 거부
  printf 'CREATE TABLE bad_name2 (id INT);\n' > "$TROOT/db/migrations/991_bad-dash_zz_test.sql"
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"허용되지 않는 문자"* ]]
  [ "$(_psql "select to_regclass('public.schema_migrations') is null")" = "t" ]
  git -C "$TROOT" rm -q db/migrations/991_bad-dash_zz_test.sql
  _commit_migs
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
}

@test "DB34: the runner is committed with the executable bit - a real checkout runs without any chmod" {
  # 8라운드 후속 P1: tracked mode가 100755→100644로 떨어져 실제 checkout에서
  # rc=126(Permission denied)이었고, 테스트 setup의 chmod +x가 이를 숨겼다.
  # 저장소의 커밋된 mode 자체를 검증한다 (setup은 더 이상 chmod하지 않는다).
  run git -C "$REPO_ROOT" ls-tree HEAD -- scripts/db_migrate.sh
  [ "$status" -eq 0 ]
  [[ "$output" == 100755* ]]
  # fixture(cp로 권한 보존된 checkout 사본)가 chmod 없이 그대로 실행된다
  run env ENV_FILE="$ENVF" "$RUNNER" --status
  [ "$status" -eq 0 ]
}

@test "DB36: a plain app role cannot forge entrypoint evidence - delete completes only through the SECURITY DEFINER entrypoint" {
  # 8라운드 후속 P1: 과거 GUC 증거는 일반 app role이 정확한 ID로 set_config해
  # 우회할 수 있었다 (실측 rc=0). 이제 증거는 role 정체성 — 일반 role로 재현한다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"   # id 1
  _psql "insert into users (provider, provider_subject) values ('kakao','u2')"   # id 2
  _psql "insert into events (event_type, user_id, payload) values ('e', 1, '{\"p\":1}'::jsonb)"
  # 일반 app role — users에 대한 (테이블 수준) UPDATE 권한까지 있는 최악 조건.
  # 재리뷰 #3: 진입점 EXECUTE는 PUBLIC에서 회수됐다 — app role에 "명시적으로" 부여한다.
  _psql "create role zz_app36 login"
  _psql "grant select, update on users to zz_app36"
  _psql "grant execute on function app_soft_delete_user(bigint) to zz_app36"
  _approle() {
    PGOPTIONS='-c client_min_messages=warning' \
      "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U zz_app36 -d "$TEST_DB" -tAc "$1"
  }
  # 정확한 대상 ID로 GUC를 위조 + 직접 UPDATE — role 경계가 거부한다
  run _approle "begin; select set_config('app.soft_delete_user','1',true); update users set deleted_at=now() where id=1; commit;"
  [ "$status" -ne 0 ]
  [[ "$output" == *"app_soft_delete_user"* ]]
  [ "$(_psql "select (deleted_at is null) from users where id=1")" = "t" ]
  # membership이 없으므로 정의자 role을 사칭(SET ROLE)할 수 없다
  run _approle "set role shaman_softdelete"
  [ "$status" -ne 0 ]
  # 유일 경로: SECURITY DEFINER 진입점 — 일반 role로도 삭제·스크럽이 완결된다
  [ "$(_approle "select app_soft_delete_user(1)")" = "t" ]
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
  [ "$(_psql "select payload::text from events where event_type='e'")" = "{}" ]
  # 배포 계약(컬럼 목록 grant): deleted_at이 grant에 없으면 권한층이 먼저 거부한다
  _psql "create role zz_app36col login"
  _psql "grant select on users to zz_app36col"
  _psql "grant update (nickname, last_topic) on users to zz_app36col"
  run env PGOPTIONS='-c client_min_messages=warning' \
    "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U zz_app36col -d "$TEST_DB" -tAc \
    "update users set deleted_at=now() where id=2"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
  [ "$(_psql "select (deleted_at is null) from users where id=2")" = "t" ]
}

@test "DB37: the entrypoint is not executable by PUBLIC - an unprivileged CONNECT role cannot delete" {
  # 재리뷰 P1(#3): 함수 ACL이 기본값이라 EXECUTE가 PUBLIC에 열려 있었다 — 아무 테이블
  # 권한도 없는 신규 CONNECT role이 app_soft_delete_user(1)을 호출해 사용자를 삭제할
  # 수 있었다 (SECURITY DEFINER가 정의자 권한으로 전부 수행하므로, 실측).
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  # 테이블 권한이 전혀 없는 신규 role (CONNECT만)
  _psql "create role zz_nobody login"
  _psql "grant connect on database ${TEST_DB} to zz_nobody"
  run env PGOPTIONS='-c client_min_messages=warning' \
    "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U zz_nobody -d "$TEST_DB" -tAc \
    "select app_soft_delete_user(1)"
  [ "$status" -ne 0 ]
  [[ "$output" == *"permission denied"* ]]
  [ "$(_psql "select (deleted_at is null) from users where id=1")" = "t" ]
  # PUBLIC에는 EXECUTE가 없다 (ACL로 직접 확인)
  [ "$(_psql "select coalesce(has_function_privilege('public','app_soft_delete_user(bigint)','EXECUTE'), false)")" = "f" ]
  # 명시적으로 부여하면 정상 동작한다 (배포 계약: app role에만 GRANT)
  _psql "grant execute on function app_soft_delete_user(bigint) to zz_nobody"
  [ "$(PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" -U zz_nobody -d "$TEST_DB" -tAc "select app_soft_delete_user(1)")" = "t" ]
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
}

@test "DB38: a caller's pg_temp table cannot shadow the scrub target - search_path is pinned with pg_temp last" {
  # 재리뷰 P1(#2): `SET search_path FROM CURRENT`가 캡처하는 값에는 pg_temp가 없고,
  # PostgreSQL은 명시되지 않은 pg_temp를 가장 먼저 탐색한다 — 호출자가 만든
  # pg_temp.events가 permanent table보다 먼저 해석되어, 사용자는 삭제됐지만 실제
  # events payload는 스크럽되지 않았다 (실측). search_path를
  # pg_catalog, <schema>, pg_temp로 고정해 임시 객체가 가릴 수 없게 한다.
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  _psql "insert into users (provider, provider_subject) values ('kakao','u1')"
  _psql "insert into events (event_type, user_id, payload) values ('e', 1, '{\"pii\":\"real\"}'::jsonb)"
  _psql "create role zz_temp38 login"
  _psql "grant select, insert, update, delete on users, events, sessions, streaks, user_fortunes to zz_temp38"
  _psql "grant usage on schema public to zz_temp38"
  _psql "grant temporary on database ${TEST_DB} to zz_temp38"
  _psql "grant execute on function app_soft_delete_user(bigint) to zz_temp38"
  # 같은 세션에서 pg_temp.events를 만든 뒤 진입점을 호출한다
  PGOPTIONS='-c client_min_messages=warning' "$PGBIN/psql" -X -h 127.0.0.1 -p "$PGT_PORT" \
    -U zz_temp38 -d "$TEST_DB" -v ON_ERROR_STOP=1 -tAc \
    "create temp table events (id bigint, user_id bigint, session_id bigint, payload jsonb, scrubbed_at timestamptz);
     select app_soft_delete_user(1);" >/dev/null
  # 삭제가 수행됐고, "진짜" events가 스크럽됐다 (pg_temp가 가리지 못했다)
  [ "$(_psql "select (deleted_at is not null) from users where id=1")" = "t" ]
  [ "$(_psql "select payload::text from public.events where event_type='e'")" = "{}" ]
  [ "$(_psql "select (scrubbed_at is not null) from public.events where event_type='e'")" = "t" ]
}

@test "DB39: a pre-existing shaman_softdelete role with LOGIN or members is refused (no blind trust)" {
  # 재리뷰 P1(#4): 같은 이름의 LOGIN role과 membership이 미리 존재해도 migration이
  # 그대로 받아들였다 — 이후 member가 SET ROLE로 진입점을 우회해 직접 삭제할 수
  # 있었다. role 속성(NOLOGIN)과 membership(비어 있음)을 검증하고 위반이면 거부한다.
  # role은 클러스터 전역이라 앞선 테스트의 migration이 이미 만들었을 수 있다 —
  # 존재하면 LOGIN으로 바꾸고, 없으면 LOGIN으로 만든다 (둘 다 "위반 상태" 재현).
  _psql "do \$\$ begin
           if exists (select 1 from pg_roles where rolname='shaman_softdelete') then
             alter role shaman_softdelete login;
           else
             create role shaman_softdelete login;
           end if;
         end \$\$"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"LOGIN"* ]]
  # 005가 적용되지 않았다 (진입점도 설치되지 않았다)
  [ "$(_psql "select count(*) from schema_migrations where version like '005%'")" = "0" ]

  # NOLOGIN으로 고쳐도 member가 있으면 여전히 거부 (SET ROLE 우회 가능)
  _psql "alter role shaman_softdelete nologin"
  _psql "create role zz_member39 login"
  _psql "grant shaman_softdelete to zz_member39"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 1 ]
  [[ "$output" == *"member"* ]]
  [ "$(_psql "select count(*) from schema_migrations where version like '005%'")" = "0" ]

  # membership을 정리하면 정상 적용된다
  _psql "revoke shaman_softdelete from zz_member39"
  run env ENV_FILE="$ENVF" "$RUNNER"
  [ "$status" -eq 0 ]
  [ "$(_psql "select count(*) from schema_migrations")" = "5" ]
}

@test "DB35: TERM in the final success-report window is not reported as rc=0 (phase-aware trap)" {
  # 8라운드 후속 P1: 마지막 checkpoint(_mig_check_sig) "이후" 최종 성공 보고
  # 창에 온 TERM이 flag만 기록되고 rc=0 + '✅ up-to-date'로 위장됐다 (실측).
  # 이제 최종 보고는 ledger 재확인 query를 거치고, phase=run 구간의 신호는
  # trap이 즉시 128+N으로 종료한다 — 그 창의 TERM은 성공이 될 수 없다.
  mkdir -p "$PGT/finbin_${BATS_TEST_NUMBER}" "$TROOT/tmp"
  cat > "$PGT/finbin_${BATS_TEST_NUMBER}/psql" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"where version ="*) : ;;
  *'count(*) from "public".schema_migrations'*) touch "$TROOT/tmp/final"; sleep 5 ;;
esac
exec "$PGBIN/psql" "\$@"
SHIM
  chmod +x "$PGT/finbin_${BATS_TEST_NUMBER}/psql"
  env PATH="$PGT/finbin_${BATS_TEST_NUMBER}:$PATH" ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" \
    "$RUNNER" > "$PGT/sig35.log" 2>&1 &
  local rpid=$! i=0 rc=0
  while [ "$i" -lt 200 ]; do
    [ -f "$TROOT/tmp/final" ] && break
    sleep 0.1; i=$((i+1))
  done
  [ -f "$TROOT/tmp/final" ]
  sleep 0.3
  local t0 t1
  t0="$(date +%s)"
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  t1="$(date +%s)"
  # 신호가 rc=0 성공으로 위장되지 않고, 성공 문구도 출력되지 않는다
  [ "$rc" -eq 143 ]
  ! grep -q "up-to-date" "$PGT/sig35.log"
  # 재리뷰(추가사항): "즉시 종료" 계약 — 포그라운드 psql의 5초 sleep을 끝까지
  # 기다리지 않는다. 조회는 별도 프로세스 그룹의 background job이고 wait는 trap에
  # 의해 즉시 깨어나므로, 신호 직후 psql 그룹을 종료하고 빠져나온다.
  [ $(( t1 - t0 )) -lt 3 ]
  # 적용 자체는 전부 완료된 상태였다 (신호는 보고 창에만 개입했다)
  [ "$(_psql "select count(*) from schema_migrations")" = "5" ]
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]
}

@test "DB40: TERM during the initial connect probe / applied() query exits immediately (no foreground/command-substitution wait)" {
  # 재재리뷰 P1(#1): 최종 보고 창(DB35)뿐 아니라 초기 접속·bootstrap·applied()에도
  # foreground psql·명령치환 대기 구조가 남아 TERM 처리가 psql 종료까지 밀렸다
  # (실측: elapsed≥5s). 이제 모든 psql이 단일 helper(_mig_psql: 별도 프로세스 그룹
  # background + wait)를 거치므로 어느 창의 신호든 즉시 전달·reap된다.
  mkdir -p "$PGT/connbin_${BATS_TEST_NUMBER}" "$TROOT/tmp"
  cat > "$PGT/connbin_${BATS_TEST_NUMBER}/psql" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"select 1"*) touch "$TROOT/tmp/conn"; sleep 5 ;;
esac
exec "$PGBIN/psql" "\$@"
SHIM
  chmod +x "$PGT/connbin_${BATS_TEST_NUMBER}/psql"
  env PATH="$PGT/connbin_${BATS_TEST_NUMBER}:$PATH" ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" \
    "$RUNNER" > "$PGT/sig40.log" 2>&1 &
  local rpid=$! i=0 rc=0
  while [ "$i" -lt 200 ]; do
    [ -f "$TROOT/tmp/conn" ] && break
    sleep 0.1; i=$((i+1))
  done
  [ -f "$TROOT/tmp/conn" ]
  sleep 0.3
  local t0 t1
  t0="$(date +%s)"
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  t1="$(date +%s)"
  [ "$rc" -eq 143 ]
  ! grep -q "up-to-date" "$PGT/sig40.log"
  [ $(( t1 - t0 )) -lt 3 ]
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]

  # applied() 창 — ledger 조회(where version =)가 느려도 TERM은 즉시 처리된다
  mkdir -p "$PGT/appbin_${BATS_TEST_NUMBER}"
  cat > "$PGT/appbin_${BATS_TEST_NUMBER}/psql" <<SHIM
#!/usr/bin/env bash
case "\$*" in
  *"where version ="*) touch "$TROOT/tmp/appl"; sleep 5 ;;
esac
exec "$PGBIN/psql" "\$@"
SHIM
  chmod +x "$PGT/appbin_${BATS_TEST_NUMBER}/psql"
  rc=0
  env PATH="$PGT/appbin_${BATS_TEST_NUMBER}:$PATH" ENV_FILE="$ENVF" TMPDIR="$TROOT/tmp" \
    "$RUNNER" > "$PGT/sig40b.log" 2>&1 &
  rpid=$!; i=0
  while [ "$i" -lt 200 ]; do
    [ -f "$TROOT/tmp/appl" ] && break
    sleep 0.1; i=$((i+1))
  done
  [ -f "$TROOT/tmp/appl" ]
  sleep 0.3
  t0="$(date +%s)"
  kill -TERM "$rpid"
  wait "$rpid" || rc=$?
  t1="$(date +%s)"
  [ "$rc" -eq 143 ]
  ! grep -q "up-to-date" "$PGT/sig40b.log"
  [ $(( t1 - t0 )) -lt 3 ]
  [ -z "$(ls "$TROOT/tmp"/dbmig* 2>/dev/null || true)" ]
}
