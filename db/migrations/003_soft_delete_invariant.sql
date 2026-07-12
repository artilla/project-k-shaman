-- 003_soft_delete_invariant.sql — 리뷰 16차 P1(DB): soft-delete 상태 불변식
--
-- 주의: BEGIN/COMMIT·ledger 기록을 쓰지 않는다 — transaction과 version 기록은
-- runner(scripts/db_migrate.sh)가 소유한다. 이미 적용된 002는 수정하지 않고
-- (마이그레이션 불변 원칙), 보정은 이 파일로 "추가"한다.
--
-- 문제: 002의 스크럽 트리거는 deleted_at "전이 시점"에만 1회 동작한다(BEFORE
-- UPDATE OF deleted_at). 따라서
--   (a) 이미 삭제된 행에 개인 필드를 다시 쓰는 UPDATE — deleted_at을 건드리지
--       않으므로 트리거 미발화 — 가 통과했고,
--   (b) deleted_at이 설정된 채 개인 필드를 담은 INSERT도 통과했다.
-- 즉 "삭제된 사용자에게는 개인정보가 없다"(§12 삭제 제공)가 상태 불변식이
-- 아니라 전이 시점의 일회성 이벤트였다.
--
-- 보정: 불변식을 CHECK로 스키마 수준에서 강제한다. 검사 집합은 002 트리거의
-- 스크럽 집합과 정확히 동일하다(트리거는 BEFORE라 정상 삭제 경로의 NEW는 이미
-- 스크럽된 상태로 CHECK를 통과한다). last_login_at은 002 트리거가 스크럽하지
-- 않으므로 여기서도 요구하지 않는다 — 집합이 어긋나면 정상 삭제가 실패한다.

-- 002 이전(트리거 부재 시절)에 삭제되어 개인 필드가 남은 행 정리 — CHECK 추가
-- 전에 기존 위반 데이터를 스크럽한다. deleted_at을 변경하지 않으므로 002
-- 트리거는 발화하지 않고, 결과 상태는 personalization_requires_consent도 만족.
UPDATE users SET
  nickname                = NULL,
  birth_info_enc          = NULL,
  birth_profile_hash      = NULL,
  last_topic              = NULL,
  last_character          = NULL,
  consent_personalization = FALSE,
  consented_at            = NULL
WHERE deleted_at IS NOT NULL
  AND (nickname IS NOT NULL
       OR birth_info_enc IS NOT NULL
       OR birth_profile_hash IS NOT NULL
       OR last_topic IS NOT NULL
       OR last_character IS NOT NULL
       OR consent_personalization
       OR consented_at IS NOT NULL);

-- 같은 시절의 잔존 자식 행 정리 (002 트리거의 정리 집합과 동일).
DELETE FROM sessions s      USING users u WHERE s.user_id  = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM streaks st      USING users u WHERE st.user_id = u.id AND u.deleted_at IS NOT NULL;
DELETE FROM user_fortunes f USING users u WHERE f.user_id  = u.id AND u.deleted_at IS NOT NULL;

-- 불변식: 삭제된 행에는 개인 필드가 존재할 수 없다 (재기입 UPDATE·삭제 상태
-- INSERT 모두 스키마 수준에서 거부 — fail-closed).
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
  )
);
