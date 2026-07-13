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
    -- 8차 2회 P1(#9) → 8라운드 후속 P1: soft-delete의 "유일 진입점"을 DB가
    -- 강제한다. 직접 UPDATE users는 users 행을 먼저 잠가 users→child 순서가
    -- 되는데, 직접 child UPDATE는 PG가 child 행을 먼저 잠근 뒤 guard 트리거가
    -- users를 잠가 child→users 순서다 — 역전이 남는다. app_soft_delete_user()는
    -- child를 먼저 잠그고 users를 나중에 잠가 순서를 일치시킨다.
    -- 진입점 증거: 과거의 transaction-local GUC는 일반 app role도 정확한 ID로
    -- set_config할 수 있어 위조 가능했다 (8라운드 후속 실측: rc=0 삭제 성공).
    -- 이제 증거는 "role 정체성"이다 — 진입점은 shaman_softdelete 소유의
    -- SECURITY DEFINER 함수뿐이고, 그 안에서만 current_user가 이 role이 된다.
    -- membership 없는 role은 SET ROLE로 사칭할 수 없다 (DB 권한 경계).
    IF current_user <> 'shaman_softdelete' THEN
      RAISE EXCEPTION 'users.id=%: soft-delete는 app_soft_delete_user(%)로만 수행할 수 있습니다 — 진입점 밖의 deleted_at 전이는 role 경계가 거부합니다 (write contract)', OLD.id, OLD.id;
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
-- P1-3·5). 교차 귀속(user_id ≠ session 소유자)은 거부한다 (6차 P1-3).
-- 잠금 순서 (8라운드 후속 P1): 과거의 "무잠금 선독 → users → sessions → 재검증"
-- 순서는 삭제 경로(children→users)와 역전을 만들었다 — 전역 순서는 child→users
-- 하나다. session 행을 FOR SHARE로 "먼저" 잠그면 소유자가 검사 중 바뀔 수 없어
-- 재검증도 불필요하다: 대상 event 행(암묵) → sessions → users, 삭제 경로의
-- events → sessions → … → users와 정확히 같은 순서다.
CREATE OR REPLACE FUNCTION events_guard() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
DECLARE
  _owner BIGINT;
  _check_user BIGINT;
BEGIN
  IF NEW.session_id IS NOT NULL THEN
    SELECT s.user_id INTO _owner FROM sessions s WHERE s.id = NEW.session_id FOR SHARE OF s;
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

-- ── 8) 잠금 순서 write contract — 규약이 아니라 스키마 강제 (7차 P1-5 → 8차 #9
--       → 8라운드 후속 P1) ─────────────────────────────────────────────────────
-- 문제(실측, PG16): PostgreSQL은 child row를 잠근 "뒤" BEFORE UPDATE 트리거를
-- 실행한다. 따라서 직접 child UPDATE 경로는 항상 child→users 순서다(바꿀 수
-- 없다 — 잠금이 트리거보다 먼저다).
--
-- 전역 잠금 순서는 "하나"다 (8라운드 후속 P1 — 과거 app_lock_user_rows는
-- users→children을 요구해 child→users인 삭제 경로와 정면 상충했고, helper를
-- 따른 writer가 deadlock victim이 됐다. 실측):
--
--     events → sessions → streaks → user_fortunes → users   (child→users)
--
--   - 직접 child DML: PG가 child 행을 먼저 잠그고 guard 트리거가 users를
--     FOR SHARE — 구조적으로 이 순서다 (사전 잠금 helper가 필요 없다).
--   - events_guard: 대상 event 행(암묵) → sessions FOR SHARE → users FOR SHARE
--     — 같은 순서 (위 6절).
--   - 삭제 진입점: 아래 app_soft_delete_user()가 같은 순서로 잠근다.
--   - users를 "먼저" 잠그는 helper는 제거한다 — users-first 경로가 남아 있는 한
--     역전은 사라지지 않는다. 여러 child 행을 갱신하는 writer는 위 테이블
--     순서와 id 오름차순을 따른다 (ADR 0004).
DROP FUNCTION IF EXISTS app_lock_user_rows(BIGINT[]);

-- 진입점의 권한 경계 (8라운드 후속 P1): 증거는 GUC가 아니라 role 정체성이다.
--   - shaman_softdelete: NOLOGIN 정의자 role. 스크럽 트리거는 deleted_at 전이
--     시점의 current_user가 이 role일 것을 요구한다 (위 1절).
--   - app_soft_delete_user()는 이 role 소유의 SECURITY DEFINER 함수 — 함수 안
--     에서만 current_user가 shaman_softdelete가 된다. membership이 없는 role은
--     SET ROLE로 사칭할 수 없다.
--   - app role에는 users.deleted_at UPDATE 권한을 주지 않는 것이 배포 계약이다
--     (컬럼 목록 grant — ADR 0004). 트리거 경계는 그 위의 스키마 강제층이다.
DO $role$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'shaman_softdelete') THEN
    BEGIN
      CREATE ROLE shaman_softdelete NOLOGIN;
    EXCEPTION WHEN duplicate_object THEN
      NULL;  -- 동시 생성 경합 — 존재하면 충분하다
    END;
  END IF;
END $role$;

-- 정의자 role이 진입점·스크럽 트리거(SECURITY INVOKER — 정의자 컨텍스트에서
-- 실행됨)가 필요로 하는 최소 권한: 잠금(FOR NO KEY UPDATE/SHARE)은 UPDATE
-- 권한을, 자식 정리는 DELETE 권한을 요구한다.
GRANT SELECT, UPDATE ON users, events TO shaman_softdelete;
GRANT SELECT, UPDATE, DELETE ON sessions, streaks, user_fortunes TO shaman_softdelete;

-- soft-delete의 유일 진입점 (스크럽 트리거가 role 경계로 강제한다).
-- 반환: TRUE=이번 호출로 삭제됨, FALSE=이미 삭제된 사용자(멱등).
-- SECURITY DEFINER + 생성 시점 고정 search_path (SET search_path FROM CURRENT
-- — runner가 스키마를 search_path로 고정한 상태에서 생성된다).
CREATE OR REPLACE FUNCTION app_soft_delete_user(p_user BIGINT) RETURNS boolean
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path FROM CURRENT
AS $fn$
DECLARE
  _try INT := 0;
  _hit BOOLEAN;
BEGIN
  LOOP
    BEGIN
      -- 전역 잠금 순서(child→users) — 직접 child DML 경로와 동일하다.
      PERFORM 1 FROM events e
        WHERE e.user_id = p_user
           OR e.session_id IN (SELECT s.id FROM sessions s WHERE s.user_id = p_user)
        ORDER BY e.id
        FOR NO KEY UPDATE;
      PERFORM 1 FROM sessions s WHERE s.user_id = p_user ORDER BY s.id FOR NO KEY UPDATE;
      PERFORM 1 FROM streaks st WHERE st.user_id = p_user ORDER BY st.user_id FOR NO KEY UPDATE;
      PERFORM 1 FROM user_fortunes f WHERE f.user_id = p_user ORDER BY f.user_id FOR NO KEY UPDATE;
      -- 삭제 전이 — 스크럽 트리거는 current_user = shaman_softdelete(이 함수의
      -- 정의자 컨텍스트)를 확인한다. GUC 증거는 더 이상 존재하지 않는다.
      UPDATE users SET deleted_at = now() WHERE id = p_user AND deleted_at IS NULL;
      _hit := FOUND;
      RETURN _hit;
    EXCEPTION WHEN deadlock_detected THEN
      -- subtransaction rollback으로 이 시도의 잠금은 해제됨 — bounded 재시도.
      -- 순서가 일치하면 발생하지 않지만, 외부 도구가 임의 순서로 여러 행을
      -- 잠그는 경우에 대한 최후 흡수 계층이다.
      _try := _try + 1;
      IF _try >= 5 THEN
        RAISE;
      END IF;
      PERFORM pg_sleep(0.05 * _try);
    END;
  END LOOP;
END $fn$;

-- 소유권 이전은 함수 생성 "후" — SECURITY DEFINER의 정의자 = 소유자.
ALTER FUNCTION app_soft_delete_user(BIGINT) OWNER TO shaman_softdelete;
