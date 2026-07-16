---
id: T026
title: 온보딩·로그인·입력 화면 — 게스트 우선 + 소셜 로그인 스캐폴드 + S2(닉네임·생년월일·시진) → seed 반영
status: done
priority: P1
safe: true               # 로컬 세션·로컬 스토리지 우선, 소셜은 env 키 있을 때만 활성 — 과금·외부 전송 기본 없음.
persona: implementer
estimate: L
depends_on: ["T019", "T022"]
blocks: []
labels: ["feature", "frontend", "auth", "onboarding"]
created: 2026-07-08
spec_ref: docs/ux/screen-ia.md#s2--입력
---

# T026 — 온보딩·로그인·입력 화면

## 1. 목표 (한 줄)
> 사용자가 시작 화면에서 게스트 또는 소셜 계정으로 들어와, 닉네임·생년월일·출생시간(12시진)을 입력하면 그 정보가 개인화된 운세 seed(birth_*)로 이어진다 — screen-ia S0→S2→S4 흐름의 앞단 완성.

## 2. 컨텍스트 (정본 준수 사항)

- screen-ia S2: 닉네임(≤10자 필수)·생년월일 피커(필수)·출생시간(자~해 12시진 또는 "모름", 선택)·
  "다음" 버튼·개인정보 동의 배너. 상태: 빈 폼(다음 비활성)/입력 중(활성)/inline 오류.
- v3 §12 개인정보 UX (**불변식**): 비회원 로컬 우선 — 입력값은 **localStorage에만** 저장,
  운세 요청 시 기존 `/api/fortune/today?birth_year=…` 쿼리로만 전달(이미 T019가 지원, seed_builder가
  HMAC 해시). **원본 생년월일·출생시간을 화면·공유카드에 재노출하지 않는다** (입력 화면 제외).
- docs/planning/Plan.md §계정: 첫 운세는 비회원 가능 — 게스트가 기본 경로, 계정은 부가.

## 3. 변경 범위 (Scope)

**포함**
- **S0 시작/로그인 화면** (`static/` 확장): 기존 "탭하여 보기" 앞에 온보딩 스텝 —
  ① "게스트로 시작"(기본, 즉시 진행) ② "Google로 계속" ③ "카카오로 계속".
  소셜 버튼은 서버 `/api/auth/providers` 응답(키 존재 여부)로 활성/비활성 — 비활성 시
  "관리자 설정 필요" 툴팁. 로그인 상태면 닉네임 표시 + "로그아웃".
- **소셜 로그인 스캐폴드** (`server.py`): OAuth 2.0 인가 코드 흐름 —
  `GET /api/auth/login/{google|kakao}`(리다이렉트), `GET /api/auth/callback/{provider}`(코드 교환→
  프로필 조회→세션 쿠키), `GET /api/auth/me`, `POST /api/auth/logout`.
  키는 env(`GOOGLE_CLIENT_ID/SECRET`, `KAKAO_REST_API_KEY`)만, 코드/로그에 원문 금지 (runbook §4).
  세션은 **서명 쿠키 + 서버 메모리**(DB 없음 — §3 hold), 재시작 시 소멸 명시.
  표준 라이브러리만 사용(urllib) — 신규 의존성 금지.
- **S2 입력 화면**: 닉네임(≤10자)·생년월일(년/월/일 select 또는 date input)·출생시간
  (12시진 라디오/select + "모름")·개인정보 배너·"다음"(빈 필수 필드 시 비활성)·inline 오류.
  저장은 localStorage(`shindang.profile`), "다음" 후 기존 탭 화면으로 — 이후 fortune 요청에
  `birth_year/month/day/hour` 쿼리 자동 첨부 (시진→대표 시각 매핑, "모름"이면 미첨부).
  재방문 시 저장된 프로필로 S2 스킵(변경 링크 제공).
- 계측: `onboarding_started`·`profile_saved`(값 아닌 존재 여부만)·`login_{provider}` 이벤트 —
  기존 `/api/event` 합류. **이벤트에 생년월일 원문 금지.**
- 테스트: providers 응답(키 없는 환경 = 전부 비활성), 게스트 흐름 무회귀, 프로필→쿼리 매핑
  (시진→시각), 세션 쿠키 발급/조회/로그아웃, 원문 비노출(이벤트·카드), 전 스위트 GREEN.

**제외 (Non-goals)**
- DB/영속 계정·streak·결제(docs/planning/Plan.md 후속), 이메일/비밀번호 가입(소셜+게스트만), Apple 로그인,
  실 소셜 키 발급(운영자가 콘솔에서 발급해 .env.local에 넣는 것 — 안내 문구만), PWA·배포(§3 hold).

## 4. 수용 기준 (Acceptance Criteria)
- [x] 키 없는 환경(기본): 게스트로 시작 → S2 입력 → 탭 → 재생까지 기존 흐름 무회귀, 소셜 버튼 비활성+안내
- [x] S2 유효성: 닉네임 10자 초과·미래 날짜 등 inline 오류, 필수 미입력 시 "다음" 비활성
- [x] 입력 후 fortune 요청에 birth_* 쿼리 자동 첨부 → 같은 생년월일 재방문 시 동일 fortuneId(결정성 유지), "모름"이면 birth_hour 미첨부
- [x] localStorage 프로필 저장·재방문 스킵·변경 가능, 원본 생년월일이 이벤트 로그·공유카드에 부재
- [x] (env 키 주입 시) OAuth 리다이렉트 URL 생성·콜백 코드 교환 경로가 계약 테스트로 고정 (실 호출은 mock/skip)
- [x] `python3 -m pytest tests/` GREEN (키 없는 환경)

## 5. 테스트 계획

```bash
python3 -m pytest tests/
python3 fortune-engine/web/server.py   # 수동: 게스트 → S2 → 탭 → 재생 → 부적
```

## 6. 롤백
`git revert <commit>` — 프론트 + 서버 auth 라우트만. 엔진 무변경. 세션은 메모리라 잔존물 없음.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 온보딩이 기존 데모 흐름을 가림 | M | M | 게스트 기본 + 저장 프로필 스킵으로 탭까지 2탭 이내 유지 |
| 생년월일 원문 유출 | L | H | 이벤트/카드 비노출 테스트로 고정 (v3 §12) |
| OAuth 구현이 키 없이 검증 불가 | M | M | 리다이렉트 URL·콜백 파싱을 순수 함수로 분리해 단위 테스트 |

## 8. 운영 노트 (implementer에게)
- `ralph/skills/implementer.md` §2.1 헤드리스 실행 모델 준수 — 턴=세션, 긴 검증 포그라운드 분할,
  `state/reservations/T026.d`·run_loop은 당신 자신의 세션.
- 판단 갈리면 screen-ia S2·v3 §12가 정본. 소셜 흐름의 "실동작"은 키가 없어 검증 불가 —
  순수 함수 계약 테스트까지가 이 티켓의 완결이다. 질문으로 턴을 끝내지 마라.

## 9. 메모 / 결정 이력
- 2026-07-08 완료 확정 (runbook §3.7 분기 1): 에이전트가 구현·검증·커밋·DONE 이동(ab70daf, 스위트
  309 GREEN·ruff 클린)까지 전부 완료했으나, run_checks의 bats 2건(headless_idle_watchdog 70·74 —
  idle-exit 아티팩트 보존)이 실패해 사이클 판정만 checks-failed로 남음. 격리 재실행 8/8 통과 —
  세션 부하 중 1초 idle 창의 타이밍 플레이크로 판정 (T026 범위 무관, 하네스 테스트).
  후속 후보: 해당 bats의 타이밍 여유 상향 (Hephaestus와 동기).
