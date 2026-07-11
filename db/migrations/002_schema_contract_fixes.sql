-- 002_schema_contract_fixes.sql — 리뷰 15차 P1(DB) 보정
--
-- 주의: BEGIN/COMMIT·ledger 기록을 쓰지 않는다 — transaction과 version 기록은
-- runner(scripts/db_migrate.sh)가 소유한다 (같은 transaction에서 적용+기록).
--
-- 보정 내용:
--   P1-6: streaks CHECK 보정 — 기존 `longest >= current OR longest >= 0`은 항상
--         참(무의미). (current=5, longest=0)이 통과했다.
--   P1-7: 동의·삭제 계약 완성 — 동의 없음 ⇒ 출생정보·hash·최근 선택·동의 시각
--         전부 NULL 강제(양방향), deleted_at 설정 시 개인 필드 스크럽 +
--         sessions/streaks/user_fortunes 정리 트리거.
--   P1-8: fortunes(캐시)와 사용자 이력의 카디널리티 분리 — cache_key는 출생
--         버킷 단위로 공유되므로 fortunes.user_id(1:1)를 제거하고 user_fortunes
--         (N:M 이력)로 이동.
--   P2  : events.payload 상한을 API 계약(EVENT_BODY_MAX_BYTES=32KiB)과 정합.

-- ── P1-6: streaks CHECK 보정 ────────────────────────────────────────────────
DO $fix$
DECLARE c TEXT;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'streaks'::regclass AND contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE streaks DROP CONSTRAINT %I', c);
  END LOOP;
END $fix$;

ALTER TABLE streaks
  ADD CONSTRAINT streaks_current_nonneg CHECK (current_streak >= 0),
  ADD CONSTRAINT streaks_longest_covers_current CHECK (longest_streak >= current_streak);

-- ── P1-8: fortunes/user_fortunes 분리 (도메인 테이블 0행 상태에서 안전) ────────
DROP INDEX IF EXISTS idx_fortunes_user;
ALTER TABLE fortunes DROP COLUMN IF EXISTS user_id;

CREATE TABLE IF NOT EXISTS user_fortunes (
  user_id     BIGINT NOT NULL REFERENCES users (id) ON DELETE CASCADE,
  fortune_id  BIGINT NOT NULL REFERENCES fortunes (id) ON DELETE CASCADE,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, fortune_id)
);
CREATE INDEX IF NOT EXISTS idx_user_fortunes_fortune ON user_fortunes (fortune_id);

-- ── P1-7: 동의 계약 (양방향) ─────────────────────────────────────────────────
ALTER TABLE users DROP CONSTRAINT IF EXISTS birth_requires_consent;
ALTER TABLE users DROP CONSTRAINT IF EXISTS personalization_requires_consent;
ALTER TABLE users ADD CONSTRAINT personalization_requires_consent CHECK (
  (consent_personalization AND consented_at IS NOT NULL)
  OR (
    NOT consent_personalization
    AND consented_at IS NULL
    AND birth_info_enc IS NULL
    AND birth_profile_hash IS NULL
    AND last_topic IS NULL
    AND last_character IS NULL
  )
);

-- ── P1-7: 삭제 요청 정리 트리거 ──────────────────────────────────────────────
-- deleted_at이 설정되는 UPDATE에서 개인 필드를 스크럽하고(§12 삭제 제공),
-- 세션·streak·운세 이력을 같은 문장에서 정리한다.
CREATE OR REPLACE FUNCTION users_scrub_on_delete() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.deleted_at IS NOT NULL AND OLD.deleted_at IS NULL THEN
    NEW.nickname := NULL;
    NEW.birth_info_enc := NULL;
    NEW.birth_profile_hash := NULL;
    NEW.last_topic := NULL;
    NEW.last_character := NULL;
    NEW.consent_personalization := FALSE;
    NEW.consented_at := NULL;
    DELETE FROM sessions WHERE user_id = NEW.id;
    DELETE FROM streaks WHERE user_id = NEW.id;
    DELETE FROM user_fortunes WHERE user_id = NEW.id;
  END IF;
  RETURN NEW;
END $fn$;

DROP TRIGGER IF EXISTS trg_users_scrub_on_delete ON users;
CREATE TRIGGER trg_users_scrub_on_delete
  BEFORE UPDATE OF deleted_at ON users
  FOR EACH ROW EXECUTE FUNCTION users_scrub_on_delete();

-- ── P2: events.payload 상한을 API 계약과 정합 (32KiB) ────────────────────────
DO $fix$
DECLARE c TEXT;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'events'::regclass AND contype = 'c'
  LOOP
    EXECUTE format('ALTER TABLE events DROP CONSTRAINT %I', c);
  END LOOP;
END $fix$;

ALTER TABLE events
  ADD CONSTRAINT events_type_length CHECK (char_length(event_type) BETWEEN 1 AND 64),
  ADD CONSTRAINT events_payload_size CHECK (pg_column_size(payload) <= 32768);
