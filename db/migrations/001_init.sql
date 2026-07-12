-- 001_init.sql — 오늘신당(shindang) 초기 스키마
--
-- 근거:
--   - today-shindang-service-plan-v3.md §12 (확정: 서버 저장 동의 기반)
--     · 원본 생년월일/출생시간: 암호화 저장(동의 시), 보관기간·삭제 제공
--     · birth_profile_hash: 서버 secret HMAC — 캐시 키에는 해시만 사용
--     · 최근 선택 기록(주제·캐릭터·streak): 사용자 레코드
--     · 닉네임: 화면 표시용
--   - docs/research/production-readiness.md: 세션·동의 기반 프로필·streak·구매(추후)
--     Postgres 1개, /api/event 크기 제한 필요
--
-- 원칙: 수집 최소화(IP/UA 미저장), 삭제 요청 지원(users.deleted_at), 멱등 적용
-- (IF NOT EXISTS — 재실행 안전). PostgreSQL 13+ (gen_random_uuid 내장) 가정.

BEGIN;

CREATE TABLE IF NOT EXISTS schema_migrations (
  version     TEXT PRIMARY KEY,
  applied_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

-- ── 사용자 (OAuth 계정: kakao/google — backend/core.py extract_profile와 정합) ──
CREATE TABLE IF NOT EXISTS users (
  id                      BIGSERIAL PRIMARY KEY,
  provider                TEXT NOT NULL CHECK (provider IN ('kakao', 'google')),
  provider_subject        TEXT NOT NULL,
  nickname                TEXT,                    -- 화면 표시용, 캐시 키 미사용
  -- §12: 원본 출생정보는 "동의 시"에만, 애플리케이션 레벨 암호화 후 저장
  birth_info_enc          BYTEA,
  birth_profile_hash      TEXT,                    -- 서버 secret HMAC — 캐시 키 전용
  consent_personalization BOOLEAN NOT NULL DEFAULT FALSE,
  consented_at            TIMESTAMPTZ,
  -- 최근 선택 기록 (§12 "사용자 레코드")
  last_topic              TEXT,
  last_character          TEXT,
  created_at              TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_login_at           TIMESTAMPTZ,
  deleted_at              TIMESTAMPTZ,             -- 삭제 요청(soft delete) 지원
  UNIQUE (provider, provider_subject),
  -- 동의 없이 출생정보가 저장되는 상태를 스키마 수준에서 차단
  CONSTRAINT birth_requires_consent
    CHECK (birth_info_enc IS NULL OR consent_personalization)
);

CREATE INDEX IF NOT EXISTS idx_users_birth_profile_hash
  ON users (birth_profile_hash) WHERE birth_profile_hash IS NOT NULL;

-- ── 세션 (비로그인 세션 허용: user_id NULL — backend cookie 세션의 서버 영속화) ──
CREATE TABLE IF NOT EXISTS sessions (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id       BIGINT REFERENCES users (id) ON DELETE CASCADE,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  last_seen_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  expires_at    TIMESTAMPTZ NOT NULL DEFAULT now() + interval '24 hours'  -- JWT_EXPIRATION 24h와 정합
);

CREATE INDEX IF NOT EXISTS idx_sessions_user ON sessions (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_sessions_expires ON sessions (expires_at);

-- ── streak (재방문 유도 §9/§15 — 계정 식별 후 활성화) ──
CREATE TABLE IF NOT EXISTS streaks (
  user_id         BIGINT PRIMARY KEY REFERENCES users (id) ON DELETE CASCADE,
  current_streak  INTEGER NOT NULL DEFAULT 0 CHECK (current_streak >= 0),
  longest_streak  INTEGER NOT NULL DEFAULT 0 CHECK (longest_streak >= current_streak OR longest_streak >= 0),
  last_visit_date DATE
);

-- ── 운세 결과 (캐시/공유카드 재조회 — 키는 birth_profile_hash 기반, 원본 미포함) ──
CREATE TABLE IF NOT EXISTS fortunes (
  id          BIGSERIAL PRIMARY KEY,
  cache_key   TEXT NOT NULL UNIQUE,               -- HMAC 기반 seed 키 (원본 생년월일 미사용)
  user_id     BIGINT REFERENCES users (id) ON DELETE SET NULL,  -- 익명 조회 허용
  character   TEXT NOT NULL DEFAULT 'hongyeon',   -- 홍연·소월·강림
  topic       TEXT,
  payload     JSONB NOT NULL,                     -- fortune-schema.v1.1.json 준수 본문
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_fortunes_user ON fortunes (user_id) WHERE user_id IS NOT NULL;
CREATE INDEX IF NOT EXISTS idx_fortunes_created ON fortunes (created_at);

-- ── 이벤트 (state/events/playback_events.jsonl의 서버 영속화 대상) ──
-- production-readiness: /api/event는 크기 제한·스키마 검증 필요 → payload 8KiB 상한.
CREATE TABLE IF NOT EXISTS events (
  id          BIGSERIAL PRIMARY KEY,
  session_id  UUID REFERENCES sessions (id) ON DELETE SET NULL,
  user_id     BIGINT REFERENCES users (id) ON DELETE SET NULL,
  event_type  TEXT NOT NULL CHECK (char_length(event_type) BETWEEN 1 AND 64),
  payload     JSONB NOT NULL DEFAULT '{}'::jsonb
              CHECK (pg_column_size(payload) <= 8192),
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_events_type_created ON events (event_type, created_at);
CREATE INDEX IF NOT EXISTS idx_events_session ON events (session_id) WHERE session_id IS NOT NULL;

-- ── 구매 (추후 — production-readiness 예약. 결제 연동 시 마이그레이션으로 확장) ──
CREATE TABLE IF NOT EXISTS purchases (
  id            BIGSERIAL PRIMARY KEY,
  user_id       BIGINT NOT NULL REFERENCES users (id) ON DELETE RESTRICT,
  product_code  TEXT NOT NULL,
  amount_krw    INTEGER NOT NULL CHECK (amount_krw >= 0),
  status        TEXT NOT NULL DEFAULT 'pending'
                CHECK (status IN ('pending', 'paid', 'cancelled', 'refunded')),
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS idx_purchases_user ON purchases (user_id);

INSERT INTO schema_migrations (version) VALUES ('001_init')
ON CONFLICT (version) DO NOTHING;

COMMIT;
