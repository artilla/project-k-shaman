-- 005_ownership_repair_and_lock_contract.sql — 리뷰 16차 7라운드 P1(DB) 반영
--
-- 주의: transaction control·ledger 기록·psql meta command를 쓰지 않는다 —
-- transaction과 version 기록은 runner(scripts/db_migrate.sh)가 소유한다.
--
-- 7차 P1-1: 이미 공개된(remote/master) 004는 재작성하지 않는다 — 같은 version의
-- 내용 변경은 구 004를 적용한 DB가 skip으로 새 계약(sessions_guard·교차 귀속
-- 거부·scrubbed_at 등)을 영원히 받지 못하게 만들었다 (실측: session 재배정·교차
-- 귀속 삽입이 모두 성공). 004는 공개본 그대로 복원하고, 4~6차 라운드에서 004에
-- 얹었던 계약 전부 + 7차 신규 계약(P1-4 repair, P1-5 잠금 계약)을 이 파일로 옮긴다.
-- 이 파일은 "공개 004까지 적용된 DB"와 "변형 004가 적용됐던 개발 DB" 모두에서
-- 동일 결과로 수렴하도록 전부 멱등(CREATE OR REPLACE / DROP IF EXISTS / 조건부
-- UPDATE)으로 작성한다.
--
-- 확정된 삭제 계약 (2026-07-12 owner 승인 — docs/decisions/0004):
--   C1. 재가입 = 새 계정: provider_subject → 'deleted:<uuid>' (정확 UUID 매칭).
--   C2. events: user_id·session_id 절단 + payload 스크럽('{}') + scrubbed_at 마커
--       (영속 불변식 — CHECK + 마커 비가역 트리거).
--   C3. purchases: 보존 — 신규 유입 거부 + user_id 재배정 금지.
--   C4. last_login_at: 스크럽.  C5. 복구 금지.

-- ── 0) events 스크럽 마커 (영속 불변식의 근거 컬럼) ─────────────────────────────
ALTER TABLE events ADD COLUMN IF NOT EXISTS scrubbed_at TIMESTAMPTZ;

-- ── 1) 전이 스크럽 확장 — 004까지의 함수 "객체"를 대체한다 (파일들은 불변).
--       session 귀속 event를 세션 삭제 "전"에 스크럽하고(4차 P1-7), session 링크도
--       절단해(5차 P1-5) frozen CHECK가 재연결을 거부하게 한다.
CREATE OR REPLACE FUNCTION users_scrub_on_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    -- 8차 2회 P1(#9): soft-delete의 "유일 진입점"을 DB가 강제한다.
    -- 직접 UPDATE users는 users 행을 먼저 잠근 뒤 이 트리거가 child를 갱신해
    -- users→child 순서가 되는데, 직접 child UPDATE는 PG가 child 행을 먼저 잠근
    -- 뒤 guard 트리거가 users를 잠가 child→users 순서다 — 역전이 남는다.
    -- app_soft_delete_user()는 child를 먼저 잠그고 users를 나중에 잠가 두 경로의
    -- 순서를 일치시킨다. 그 진입점을 통과했다는 증거(transaction-local GUC)가
    -- 없으면 삭제 전이를 거부한다 — 계약이 규약이 아니라 스키마 강제가 된다.
    IF current_setting('app.soft_delete_user', true) IS DISTINCT FROM OLD.id::text THEN
      RAISE EXCEPTION 'users.id=%: soft-delete는 app_soft_delete_user(%)로만 수행할 수 있습니다 — 직접 UPDATE는 잠금 순서 계약(child→users)을 깨 deadlock을 유발합니다 (write contract)', OLD.id, OLD.id;
    END IF;
    NEW.nickname := NULL;
    NEW.birth_info_enc := NULL;
    NEW.birth_profile_hash := NULL;
    NEW.last_topic := NULL;
    NEW.last_character := NULL;
    NEW.consent_personalization := FALSE;
    NEW.consented_at := NULL;
    NEW.last_login_at := NULL;
    NEW.provider_subject := 'deleted:' || gen_random_uuid();
    UPDATE events SET user_id = NULL, session_id = NULL, payload = '{}'::jsonb, scrubbed_at = now()
     WHERE user_id = NEW.id
        OR session_id IN (SELECT id FROM sessions WHERE user_id = NEW.id);
    DELETE FROM sessions WHERE user_id = NEW.id;
    DELETE FROM streaks WHERE user_id = NEW.id;
    DELETE FROM user_fortunes WHERE user_id = NEW.id;
  ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'user %: soft-delete 복구는 지원하지 않습니다 — 재가입은 새 계정으로 처리됩니다 (삭제 계약 C5)', OLD.id;
  END IF;
  RETURN NEW;
END $fn$;

-- ── 2) 기존 교차 귀속 데이터 repair (7차 P1-4) ─────────────────────────────────
-- 001~004 시절에는 event.user_id와 session 소유자의 불일치(교차 귀속)를 막는
-- 계약이 없었다: `event.user_id=B / session.owner=A`, `event.user_id=B /
-- guest session` 행이 남아 있으면 — guest 세션이 이후 A에게 바인딩된 뒤 A를
-- 삭제할 때 세션 스캔이 B 귀속 payload까지 스크럽했다 (실측).
-- repair 정책: 명시적 user_id가 귀속의 근거다 — 불일치 행은 session 링크를
-- 절단해 교차 스크럽의 사각을 제거하고 B의 귀속·payload는 보존한다.
-- 이 UPDATE는 아래 백필·CHECK·트리거 설치보다 "먼저" 수행해야 한다: 삭제된
-- 소유자의 세션에 걸린 활성 사용자 event가 백필 스캔에 걸려 스크럽되는 것을
-- 막는다. (scrubbed 행은 이미 session_id NULL이라 영향 없음.)
UPDATE events e SET session_id = NULL
 WHERE e.session_id IS NOT NULL
   AND e.user_id IS NOT NULL
   AND (SELECT s.user_id FROM sessions s WHERE s.id = e.session_id) IS DISTINCT FROM e.user_id;

-- ── 3) 기존 위반 데이터 정리 (구 004까지의 계약에 없던 필드 포함) ───────────────
--       events 스크럽(세션 경유 포함)을 세션 삭제보다 먼저 수행한다.
UPDATE events e SET user_id = NULL, session_id = NULL, payload = '{}'::jsonb, scrubbed_at = now()
 WHERE e.user_id IN (SELECT id FROM users WHERE deleted_at IS NOT NULL)
    OR e.session_id IN (SELECT s.id FROM sessions s JOIN users u ON u.id = s.user_id
                        WHERE u.deleted_at IS NOT NULL);

-- 5차 P1-4(legacy 정책): 002 시절의 삭제는 sessions를 먼저 지워 session-only
-- event의 소유 연결 증거(session_id)가 이미 끊겼다 — fail-closed: 소유 증거가
-- 없는 이중 orphan(user_id·session_id 모두 NULL) event의 payload는 전부
-- 스크럽한다 (집계 축 event_type·created_at은 보존; docs/decisions/0004).
UPDATE events SET payload = '{}'::jsonb, scrubbed_at = now()
 WHERE user_id IS NULL AND session_id IS NULL AND scrubbed_at IS NULL;

UPDATE users SET
  nickname                = NULL,
  birth_info_enc          = NULL,
  birth_profile_hash      = NULL,
  last_topic              = NULL,
  last_character          = NULL,
  consent_personalization = FALSE,
  consented_at            = NULL,
  last_login_at           = NULL,
  provider_subject        = 'deleted:' || gen_random_uuid()
WHERE deleted_at IS NOT NULL
  AND (nickname IS NOT NULL
       OR birth_info_enc IS NOT NULL
       OR birth_profile_hash IS NOT NULL
       OR last_topic IS NOT NULL
       OR last_character IS NOT NULL
       OR consent_personalization
       OR consented_at IS NOT NULL
       OR last_login_at IS NOT NULL
       OR provider_subject !~ '^deleted:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$');

DELETE FROM sessions s      USING users u WHERE s.user_id  = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM streaks st      USING users u WHERE st.user_id = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM user_fortunes f USING users u WHERE f.user_id  = u.id AND u.deleted_at IS NOT NULL;

-- ── 4) 행 불변식 확장: 004의 CHECK를 정확 UUID 매칭으로 대체 (4차 P1-9) ────────
ALTER TABLE users DROP CONSTRAINT IF EXISTS deleted_users_are_scrubbed;
ALTER TABLE users ADD CONSTRAINT deleted_users_are_scrubbed CHECK (
  deleted_at IS NULL
  OR (
    nickname IS NULL
    AND birth_info_enc IS NULL
    AND birth_profile_hash IS NULL
    AND last_topic IS NULL
    AND last_character IS NULL
    AND NOT consent_personalization
    AND consented_at IS NULL
    AND last_login_at IS NULL
    AND provider_subject ~ '^deleted:[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
  )
);

-- ── 5) events 스크럽 영속 불변식 (4차 P1-8) + 마커 비가역 (5차 P1-2) ───────────
ALTER TABLE events DROP CONSTRAINT IF EXISTS events_scrubbed_frozen;
ALTER TABLE events ADD CONSTRAINT events_scrubbed_frozen CHECK (
  scrubbed_at IS NULL
  OR (user_id IS NULL AND session_id IS NULL AND payload = '{}'::jsonb)
);

CREATE OR REPLACE FUNCTION events_scrub_marker_immutable() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF OLD.scrubbed_at IS NOT NULL AND NEW.scrubbed_at IS NULL THEN
    RAISE EXCEPTION 'events.id=%: scrubbed_at 해제는 허용되지 않습니다 — 스크럽은 비가역입니다 (삭제 계약 C2)', OLD.id;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_events_scrub_marker_immutable ON events;
CREATE TRIGGER trg_events_scrub_marker_immutable
  BEFORE UPDATE OF scrubbed_at ON events
  FOR EACH ROW EXECUTE FUNCTION events_scrub_marker_immutable();

-- ── 6) 자식 행 유입 차단 — 부모 행 FOR SHARE (3차 P1-3, 함수 객체는 004와 동일) ──
CREATE OR REPLACE FUNCTION reject_rows_for_deleted_user() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF NEW.user_id IS NOT NULL THEN
    PERFORM 1 FROM users WHERE id = NEW.user_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION '%.user_id=%: 삭제되었거나 존재하지 않는 사용자입니다 — 신규 연결을 거부합니다 (soft-delete 불변식)', TG_TABLE_NAME, NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

-- sessions: 삭제 사용자 검사에 더해 소유자 "재배정"을 금지한다 (6차 P1-2).
-- 허용되는 전이는 익명 세션의 로그인 바인딩(NULL→user, 삭제 사용자 검사 포함)뿐.
CREATE OR REPLACE FUNCTION sessions_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF TG_OP = 'UPDATE' AND OLD.user_id IS NOT NULL
     AND NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'sessions.id=%: 소유자 재배정(%->%)은 허용되지 않습니다 — 삭제 스크럽 우회 방지 (soft-delete 불변식)', OLD.id, OLD.user_id, NEW.user_id;
  END IF;
  IF NEW.user_id IS NOT NULL THEN
    PERFORM 1 FROM users WHERE id = NEW.user_id AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'sessions.user_id=%: 삭제되었거나 존재하지 않는 사용자입니다 — 신규 연결을 거부합니다 (soft-delete 불변식)', NEW.user_id;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_sessions_no_deleted_user ON sessions;
CREATE TRIGGER trg_sessions_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON sessions
  FOR EACH ROW EXECUTE FUNCTION sessions_guard();

DROP TRIGGER IF EXISTS trg_streaks_no_deleted_user ON streaks;
CREATE TRIGGER trg_streaks_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON streaks
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

DROP TRIGGER IF EXISTS trg_user_fortunes_no_deleted_user ON user_fortunes;
CREATE TRIGGER trg_user_fortunes_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON user_fortunes
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

-- events: user_id뿐 아니라 session_id의 "소유 사용자"도 잠그고 검증한다 (5차
-- P1-3·5). 교차 귀속(user_id ≠ session 소유자)은 거부한다 (6차 P1-3). 잠금
-- 순서는 항상 users → sessions (6차 P1-3; UPDATE 경로의 child→users 역전은
-- 아래 8)의 write contract가 소유한다 — 7차 P1-5).
CREATE OR REPLACE FUNCTION events_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
DECLARE
  _owner BIGINT;
  _owner2 BIGINT;
  _check_user BIGINT;
BEGIN
  IF NEW.session_id IS NOT NULL THEN
    SELECT s.user_id INTO _owner FROM sessions s WHERE s.id = NEW.session_id;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'events.session_id=%: 존재하지 않는 세션입니다 — 연결을 거부합니다', NEW.session_id;
    END IF;
    IF NEW.user_id IS NOT NULL AND _owner IS DISTINCT FROM NEW.user_id THEN
      RAISE EXCEPTION 'events: user_id=%와 session 소유자=%가 다릅니다 — 교차 귀속을 거부합니다 (soft-delete 불변식)', NEW.user_id, _owner;
    END IF;
    _check_user := COALESCE(NEW.user_id, _owner);
  ELSE
    _check_user := NEW.user_id;
  END IF;
  IF _check_user IS NOT NULL THEN
    PERFORM 1 FROM users WHERE id = _check_user AND deleted_at IS NULL FOR SHARE;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'events: user %는 삭제되었거나(삭제 중이거나) 존재하지 않습니다 — 연결을 거부합니다 (soft-delete 불변식)', _check_user;
    END IF;
  END IF;
  IF NEW.session_id IS NOT NULL THEN
    SELECT s.user_id INTO _owner2 FROM sessions s WHERE s.id = NEW.session_id FOR SHARE OF s;
    IF NOT FOUND THEN
      RAISE EXCEPTION 'events.session_id=%: 세션이 사라졌습니다 — 연결을 거부합니다', NEW.session_id;
    END IF;
    IF _owner2 IS DISTINCT FROM _owner THEN
      RAISE EXCEPTION 'events.session_id=%: 검사 중 세션 소유자가 바뀌었습니다(%->%) — 연결을 거부합니다 (fail-closed)', NEW.session_id, _owner, _owner2;
    END IF;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_events_no_deleted_user ON events;
CREATE TRIGGER trg_events_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id, session_id ON events
  FOR EACH ROW EXECUTE FUNCTION events_guard();

-- ── 7) purchases: 신규 유입 거부(INSERT) + user_id 재배정 금지 (4차 P2) ────────
CREATE OR REPLACE FUNCTION purchases_user_id_immutable() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF NEW.user_id IS DISTINCT FROM OLD.user_id THEN
    RAISE EXCEPTION 'purchases.id=%: user_id 재배정(%->%)은 허용되지 않습니다 — 거래기록 귀속 불변 (삭제 계약 C3)', OLD.id, OLD.user_id, NEW.user_id;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_purchases_no_deleted_user ON purchases;
CREATE TRIGGER trg_purchases_no_deleted_user
  BEFORE INSERT ON purchases
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

DROP TRIGGER IF EXISTS trg_purchases_user_id_immutable ON purchases;
CREATE TRIGGER trg_purchases_user_id_immutable
  BEFORE UPDATE OF user_id ON purchases
  FOR EACH ROW EXECUTE FUNCTION purchases_user_id_immutable();

-- ── 8) 잠금 순서 write contract — 규약이 아니라 스키마 강제 (7차 P1-5 → 8차 #9) ──
-- 문제(실측, PG16): PostgreSQL은 child row를 잠근 "뒤" BEFORE UPDATE 트리거를
-- 실행한다. 따라서 직접 child UPDATE 경로는 항상 child→users 순서다(바꿀 수
-- 없다 — 잠금이 트리거보다 먼저다). 반면 직접 `UPDATE users SET deleted_at`은
-- users 행을 먼저 잠근 뒤 스크럽 트리거가 child를 갱신해 users→child 순서가
-- 되어 역전 deadlock이 남았다.
--
-- 7차의 helper-only 계약은 "비준수 writer가 있으면 여전히 deadlock"이라 계약이
-- 강제되지 않았다 (8차 #9). 해결은 두 축이다:
--   (a) 삭제 경로를 child→users로 "뒤집는다": app_soft_delete_user()가 대상
--       사용자의 child 행(events·sessions·streaks·user_fortunes)을 결정적 순서
--       (id 오름차순)로 먼저 잠그고, 그 다음에 users 행을 잠근다 — 직접 child
--       UPDATE 경로와 동일한 순서가 되어 역전 자체가 사라진다.
--   (b) 그 진입점을 "유일"하게 만든다: 스크럽 트리거가 transaction-local 증거
--       (GUC app.soft_delete_user)를 요구하므로, 직접 UPDATE로는 삭제 전이가
--       아예 불가능하다 (위 1절). 이제 비준수 writer가 존재할 수 없다.
-- bounded deadlock retry는 남겨 둔다 — 순서가 일치하면 발생하지 않지만, 외부
-- 도구가 임의 순서로 여러 행을 잠그는 경우에 대한 최후 흡수 계층이다.
--
-- app_lock_user_rows: child 행을 "여러 사용자"에 걸쳐 갱신하는 writer용 보조 —
-- 사용자 행을 id 오름차순으로 먼저 잠가 writer 간 상호 deadlock을 막는다.
-- (삭제와의 순서 정합은 (a)가 이미 보장하므로 필수는 아니다.)
CREATE OR REPLACE FUNCTION app_lock_user_rows(VARIADIC p_users BIGINT[]) RETURNS void
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
DECLARE
  _u BIGINT;
BEGIN
  FOR _u IN SELECT DISTINCT t.u FROM unnest(p_users) AS t(u) WHERE t.u IS NOT NULL ORDER BY t.u LOOP
    PERFORM 1 FROM users WHERE id = _u FOR SHARE;
  END LOOP;
END $fn$;

-- soft-delete의 유일 진입점 (스크럽 트리거가 이 함수를 통과했음을 요구한다).
-- 반환: TRUE=이번 호출로 삭제됨, FALSE=이미 삭제된 사용자(멱등).
CREATE OR REPLACE FUNCTION app_soft_delete_user(p_user BIGINT) RETURNS boolean
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
DECLARE
  _try INT := 0;
  _hit BOOLEAN;
BEGIN
  LOOP
    BEGIN
      -- (a) child-first 잠금 — 직접 child UPDATE 경로와 동일한 순서.
      PERFORM 1 FROM events e
        WHERE e.user_id = p_user
           OR e.session_id IN (SELECT s.id FROM sessions s WHERE s.user_id = p_user)
        ORDER BY e.id
        FOR NO KEY UPDATE;
      PERFORM 1 FROM sessions s WHERE s.user_id = p_user ORDER BY s.id FOR NO KEY UPDATE;
      PERFORM 1 FROM streaks st WHERE st.user_id = p_user ORDER BY st.user_id FOR NO KEY UPDATE;
      PERFORM 1 FROM user_fortunes f WHERE f.user_id = p_user ORDER BY f.user_id FOR NO KEY UPDATE;
      -- (b) 진입점 증거 — transaction-local. 트리거가 이 값을 검사한다.
      PERFORM set_config('app.soft_delete_user', p_user::text, true);
      UPDATE users SET deleted_at = now() WHERE id = p_user AND deleted_at IS NULL;
      _hit := FOUND;
      -- 증거는 이 삭제에만 유효하게 — 같은 transaction의 이후 직접 UPDATE가
      -- 남은 GUC로 트리거를 통과하지 못하도록 즉시 해제한다.
      PERFORM set_config('app.soft_delete_user', '', true);
      RETURN _hit;
    EXCEPTION WHEN deadlock_detected THEN
      -- subtransaction rollback으로 이 시도의 잠금은 해제됨 — bounded 재시도.
      _try := _try + 1;
      IF _try >= 5 THEN
        RAISE;
      END IF;
      PERFORM pg_sleep(0.05 * _try);
    END;
  END LOOP;
END $fn$;
