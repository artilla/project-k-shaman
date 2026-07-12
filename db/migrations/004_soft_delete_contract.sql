-- 004_soft_delete_contract.sql — 리뷰 16차 P1(DB): 삭제 계약(ADR-0004) 반영
--
-- 주의: transaction control·ledger 기록·psql meta command를 쓰지 않는다 —
-- transaction과 version 기록은 runner(scripts/db_migrate.sh)가 소유한다.
--
-- 리뷰 16차 P1-1(3차): 이미 공개된(remote/master) 003은 재작성하지 않는다 —
-- 같은 version의 내용 변경은 구 003을 적용한 DB가 영원히 새 계약을 받지
-- 못하게 만든다. 003은 공개본 그대로 두고, 계약 확장분은 이 파일(004)로 분리.
--
-- 확정된 삭제 계약 (2026-07-12 owner 승인 — docs/decisions/0004):
--   C1. 재가입 = 새 계정: 삭제 시 provider_subject를 복원 불가능한 익명 토큰
--       ('deleted:<uuid>')으로 대체. 판정은 정확한 UUID 형식 매칭(4차 P1-9).
--   C2. events: user_id 절단 + payload 스크럽('{}') + scrubbed_at 마커.
--       - session으로만 귀속된 event(user_id NULL, session_id=삭제 사용자의
--         세션)도 스크럽한다 — 세션 삭제 "전"에 수행 (4차 P1-7).
--       - 스크럽은 일회성 이벤트가 아니라 영속 불변식: scrubbed_at이 설정된
--         행은 CHECK로 user_id NULL + payload '{}'가 강제되어, 삭제와 동시
--         또는 삭제 후의 payload 재기입이 거부된다 (4차 P1-8).
--   C3. purchases: 보존(거래기록 보존 의무) — 신규 유입 거부 + user_id 재배정
--       금지(거래기록 불변, 4차 P2).
--   C4. last_login_at: 스크럽.
--   C5. 복구(deleted_at 재-NULL) 금지 — 재가입은 새 계정으로만.
--
-- 리뷰 16차 P1-3(3차): 자식 유입 차단은 부모 행 잠금(FOR SHARE)으로 — 미커밋
-- 삭제 UPDATE(FOR NO KEY UPDATE)와 상호 배타.
-- 리뷰 16차 P1-8(3차): 함수는 SET search_path FROM CURRENT로 고정.

-- ── 0) events 스크럽 마커 (영속 불변식의 근거 컬럼) ─────────────────────────────
ALTER TABLE events ADD COLUMN IF NOT EXISTS scrubbed_at TIMESTAMPTZ;

-- ── 1) 전이 스크럽 확장 — 002/003 이후의 함수 "객체"를 대체한다 (파일들은 불변).
CREATE OR REPLACE FUNCTION users_scrub_on_delete() RETURNS trigger
LANGUAGE plpgsql
SET search_path FROM CURRENT
AS $fn$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    NEW.nickname := NULL;
    NEW.birth_info_enc := NULL;
    NEW.birth_profile_hash := NULL;
    NEW.last_topic := NULL;
    NEW.last_character := NULL;
    NEW.consent_personalization := FALSE;
    NEW.consented_at := NULL;
    NEW.last_login_at := NULL;
    NEW.provider_subject := 'deleted:' || gen_random_uuid();
    -- 4차 P1-7: session으로만 귀속된 event까지 — 세션 삭제 "전"에 스크럽한다
    -- (세션 삭제가 먼저면 events.session_id가 SET NULL로 끊겨 조회 불가).
    UPDATE events SET user_id = NULL, payload = '{}'::jsonb, scrubbed_at = now()
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

-- ── 2) 기존 위반 데이터 정리 (구 003까지의 계약에 없던 필드 포함) ───────────────
--       events 스크럽(세션 경유 포함)을 세션 삭제보다 먼저 수행한다.
UPDATE events e SET user_id = NULL, payload = '{}'::jsonb, scrubbed_at = now()
 WHERE e.user_id IN (SELECT id FROM users WHERE deleted_at IS NOT NULL)
    OR e.session_id IN (SELECT s.id FROM sessions s JOIN users u ON u.id = s.user_id
                        WHERE u.deleted_at IS NOT NULL);

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

-- ── 3) 행 불변식 확장: 003의 CHECK를 계약 필드까지 포함해 대체 ─────────────────
--       4차 P1-9: 익명 토큰은 정확한 UUID 형식만 인정 — 'deleted:' + 임의 36자
--       (예: 'a' 36개)는 익명화로 간주되지 않는다.
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

-- ── 4) events 스크럽 영속 불변식 (4차 P1-8) ────────────────────────────────────
--       스크럽된 행은 되돌릴 수 없다 — 삭제와 "동시"(행 잠금 대기 후 재평가) 또는
--       삭제 "후"의 payload/user_id 재기입 UPDATE는 CHECK 위반으로 거부된다.
ALTER TABLE events DROP CONSTRAINT IF EXISTS events_scrubbed_frozen;
ALTER TABLE events ADD CONSTRAINT events_scrubbed_frozen CHECK (
  scrubbed_at IS NULL
  OR (user_id IS NULL AND payload = '{}'::jsonb)
);

-- ── 5) 자식 행 유입 차단: 삭제된 사용자를 가리키는 신규 행 거부 ─────────────────
--       부모 행을 FOR SHARE로 잠근다 — 삭제 UPDATE(FOR NO KEY UPDATE)와 배타.
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

DROP TRIGGER IF EXISTS trg_sessions_no_deleted_user ON sessions;
CREATE TRIGGER trg_sessions_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON sessions
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

DROP TRIGGER IF EXISTS trg_streaks_no_deleted_user ON streaks;
CREATE TRIGGER trg_streaks_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON streaks
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

DROP TRIGGER IF EXISTS trg_user_fortunes_no_deleted_user ON user_fortunes;
CREATE TRIGGER trg_user_fortunes_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON user_fortunes
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

DROP TRIGGER IF EXISTS trg_events_no_deleted_user ON events;
CREATE TRIGGER trg_events_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON events
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();

-- purchases: 신규 유입 거부(INSERT)는 위와 동일하되, user_id "재배정"은 대상이
-- 활성 사용자라도 금지한다 — 거래기록의 귀속은 불변이다 (4차 P2).
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
