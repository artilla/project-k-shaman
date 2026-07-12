-- 004_soft_delete_contract.sql — 리뷰 16차 P1(DB): 삭제 계약(ADR-0004) 반영
--
-- 주의: transaction control·ledger 기록·psql meta command를 쓰지 않는다 —
-- transaction과 version 기록은 runner(scripts/db_migrate.sh)가 소유한다.
--
-- 리뷰 16차 P1-1: 이미 공개된(remote/master) 003은 재작성하지 않는다 —
-- 같은 version의 내용 변경은 구 003을 적용한 DB가 영원히 새 계약을 받지
-- 못하게 만든다. 003은 공개본 그대로 두고, 계약 확장분은 이 파일(004)로 분리.
--
-- 확정된 삭제 계약 (2026-07-12 owner 승인 — docs/decisions/0004):
--   C1. 재가입 = 새 계정: 삭제 시 provider_subject를 복원 불가능한 익명 토큰
--       ('deleted:<uuid>')으로 대체. 같은 OAuth 계정의 재로그인은
--       UNIQUE(provider, provider_subject) 충돌 없이 새 사용자 행을 만든다.
--   C2. events: user_id 절단 + payload 스크럽('{}') — 리뷰 16차 P1-9:
--       /api/event가 임의 필드를 보존하고 payload schema 검증이 미구현이므로
--       "payload 무익명정보" 전제가 성립하지 않는다. fail-closed로 payload까지
--       스크럽한다(event_type·created_at 등 집계 축만 보존). schema 검증이
--       구현되어 전제가 성립하면 보존 완화는 후속 마이그레이션으로.
--   C3. purchases: 보존(거래기록 보존 의무) — 단, 삭제된 사용자로의 신규 행 거부.
--   C4. last_login_at: 개인 행동 흔적이므로 스크럽.
--   C5. 복구(deleted_at 재-NULL) 금지 — 재가입은 새 계정으로만 (C1과 정합).
--
-- 리뷰 16차 P1-3: 자식 유입 차단은 EXISTS 조회가 아니라 부모 행 잠금(FOR SHARE)
-- 으로 — 미커밋 삭제 UPDATE(FOR NO KEY UPDATE)와 상호 배타이므로, 삭제와 동시에
-- 들어온 자식 INSERT는 삭제 커밋을 기다렸다가 재평가되어 거부된다.
-- 리뷰 16차 P1-8: 함수는 SET search_path FROM CURRENT로 고정 — custom schema에
-- 적용된 뒤 호출자의 search_path가 달라도(예: public) 대상 테이블을 찾는다.
-- 리뷰 16차 P2: 익명 토큰 판정은 'deleted:' 접두사가 아니라 정확한 형식
-- ('deleted:' + uuid 36자) 매칭 — legacy subject가 우연히 같은 접두사여도
-- backfill·불변식이 오동작하지 않는다.

-- ── 0) 전이 스크럽 확장 — 002/003 이후의 함수 "객체"를 대체한다 (파일들은 불변).
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
    DELETE FROM sessions WHERE user_id = NEW.id;
    DELETE FROM streaks WHERE user_id = NEW.id;
    DELETE FROM user_fortunes WHERE user_id = NEW.id;
    UPDATE events SET user_id = NULL, payload = '{}'::jsonb WHERE user_id = NEW.id;
  ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'user %: soft-delete 복구는 지원하지 않습니다 — 재가입은 새 계정으로 처리됩니다 (삭제 계약 C5)', OLD.id;
  END IF;
  RETURN NEW;
END $fn$;

-- ── 1) 기존 위반 데이터 정리 (구 003까지의 스크럽 집합에 없던 필드 포함) ────────
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
       OR provider_subject !~ '^deleted:[0-9a-f-]{36}$');

DELETE FROM sessions s      USING users u WHERE s.user_id  = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM streaks st      USING users u WHERE st.user_id = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM user_fortunes f USING users u WHERE f.user_id  = u.id AND u.deleted_at IS NOT NULL;
UPDATE events e SET user_id = NULL, payload = '{}'::jsonb
  FROM users u WHERE e.user_id = u.id AND u.deleted_at IS NOT NULL;

-- ── 2) 행 불변식 확장: 003의 CHECK를 계약 필드까지 포함해 대체 ─────────────────
--       검사 집합은 위 트리거의 스크럽 집합과 정확히 동일해야 한다.
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
    AND provider_subject ~ '^deleted:[0-9a-f-]{36}$'
  )
);

-- ── 3) 자식 행 유입 차단: 삭제된 사용자를 가리키는 신규 행 거부 ─────────────────
--       부모 행을 FOR SHARE로 잠근다 — 삭제 UPDATE(FOR NO KEY UPDATE)와 배타.
--       미커밋 삭제와 동시 INSERT는 삭제 커밋 후 재평가(EvalPlanQual)로 거부되고,
--       역순(자식 먼저)이면 삭제 UPDATE가 대기 후 스크럽 트리거가 정리한다.
--       (events는 C2에 따라 user_id NULL 허용; purchases는 C3에 따라 기존 행
--       보존 + 신규 유입만 거부.)
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

DROP TRIGGER IF EXISTS trg_purchases_no_deleted_user ON purchases;
CREATE TRIGGER trg_purchases_no_deleted_user
  BEFORE INSERT OR UPDATE OF user_id ON purchases
  FOR EACH ROW EXECUTE FUNCTION reject_rows_for_deleted_user();
