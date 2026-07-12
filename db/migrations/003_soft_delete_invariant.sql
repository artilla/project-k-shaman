-- 003_soft_delete_invariant.sql — 리뷰 16차 P1(DB): soft-delete 상태 불변식 + 삭제 계약
--
-- 주의: transaction control·ledger 기록을 쓰지 않는다 — transaction과 version
-- 기록은 runner(scripts/db_migrate.sh)가 소유한다. 이미 적용된 002는 수정하지
-- 않고(마이그레이션 불변 원칙), 보정은 이 파일로 "추가"한다.
--
-- 확정된 삭제 계약 (2026-07-12 owner 승인 — docs/decisions 참조):
--   C1. 재가입 = 새 계정: 삭제 시 provider_subject를 복원 불가능한 익명 토큰
--       ('deleted:<uuid>')으로 대체한다. 같은 OAuth 계정의 재로그인은
--       UNIQUE(provider, provider_subject) 충돌 없이 새 사용자 행을 만든다.
--   C2. events: user_id 절단(NULL) — 익명 집계 데이터만 남고 사용자 연결은 끊는다.
--       payload는 유지(개인정보 미포함 계약: 크기 제한·스키마 검증).
--   C3. purchases: 보존 — 거래기록 보존 의무(전자상거래법상 대금결제 기록).
--       단, 삭제된 사용자로의 "신규" 행 유입은 거부한다.
--   C4. last_login_at: 개인 행동 흔적이므로 스크럽.
--   C5. 복구(deleted_at 재-NULL) 금지 — 재가입은 새 계정으로만 (C1과 정합).
--
-- 문제(16차 P1-7): 002의 스크럽 트리거는 deleted_at "전이 시점"에만 1회 동작한다.
--   (a) 삭제된 행에 개인 필드를 다시 쓰는 UPDATE(트리거 미발화)가 통과했고,
--   (b) deleted_at이 설정된 채 개인 필드를 담은 INSERT도 통과했으며,
--   (c) 삭제된 사용자에게 sessions/streaks/user_fortunes를 다시 INSERT하는 세
--       경로가 모두 성공했다 — "삭제"가 상태 불변식이 아니라 일회성 이벤트였다.
-- 보정: 전이 스크럽(트리거 확장) + 행 불변식(CHECK) + 자식 행 유입 차단(트리거).

-- ── 0) 전이 스크럽 확장 — 002가 만든 함수 "객체"를 대체한다 (002 파일은 불변).
--       스크럽 집합에 last_login_at(C4)·provider_subject 익명화(C1)·events 절단(C2)
--       추가, 복구 금지(C5) 추가.
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
    NEW.last_login_at := NULL;
    NEW.provider_subject := 'deleted:' || gen_random_uuid();
    DELETE FROM sessions WHERE user_id = NEW.id;
    DELETE FROM streaks WHERE user_id = NEW.id;
    DELETE FROM user_fortunes WHERE user_id = NEW.id;
    UPDATE events SET user_id = NULL WHERE user_id = NEW.id;
  ELSIF NEW.deleted_at IS NULL AND OLD.deleted_at IS NOT NULL THEN
    RAISE EXCEPTION 'user %: soft-delete 복구는 지원하지 않습니다 — 재가입은 새 계정으로 처리됩니다 (삭제 계약 C5)', OLD.id;
  END IF;
  RETURN NEW;
END $fn$;

-- ── 1) 기존 위반 데이터 정리 (002 이전에 삭제된, 트리거 부재 시절의 행) ─────────
--       deleted_at을 변경하지 않으므로 위 트리거는 발화하지 않고, 결과 상태는
--       personalization_requires_consent(002)도 만족한다.
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
       OR provider_subject NOT LIKE 'deleted:%');

DELETE FROM sessions s      USING users u WHERE s.user_id  = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM streaks st      USING users u WHERE st.user_id = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM user_fortunes f USING users u WHERE f.user_id  = u.id AND u.deleted_at IS NOT NULL;
UPDATE events e SET user_id = NULL FROM users u WHERE e.user_id = u.id AND u.deleted_at IS NOT NULL;

-- ── 2) 행 불변식: 삭제된 행에는 개인 필드가 존재할 수 없다 ─────────────────────
--       재기입 UPDATE·삭제 상태 INSERT 모두 스키마 수준에서 거부 (fail-closed).
--       검사 집합은 위 트리거의 스크럽 집합과 정확히 동일해야 한다 — 어긋나면
--       정상 삭제 경로가 CHECK에 걸린다.
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
    AND provider_subject LIKE 'deleted:%'
  )
);

-- ── 3) 자식 행 유입 차단: 삭제된 사용자를 가리키는 신규 행 거부 ─────────────────
--       migration 시점 1회 정리가 아니라 상태 불변식으로 — INSERT와 user_id
--       변경 UPDATE 모두 검사한다. (events는 C2에 따라 user_id NULL은 허용;
--       purchases는 C3에 따라 기존 행 보존 + 신규 유입만 거부.)
CREATE OR REPLACE FUNCTION reject_rows_for_deleted_user() RETURNS trigger
LANGUAGE plpgsql AS $fn$
BEGIN
  IF NEW.user_id IS NOT NULL
     AND EXISTS (SELECT 1 FROM users WHERE id = NEW.user_id AND deleted_at IS NOT NULL) THEN
    RAISE EXCEPTION '%.user_id=%: 삭제된 사용자입니다 — 신규 연결을 거부합니다 (soft-delete 불변식)', TG_TABLE_NAME, NEW.user_id;
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
