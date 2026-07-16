# ADR-0003: 프론트엔드/백엔드 구조 분리

- 상태: 일부 대체됨 (2026-07-16, ADR-0006)
- 결정자: artilla
- 관련: docs/planning/Plan.md §2 (프론트엔드 스택 결정), docs/research/production-readiness.md §3 (서버 런타임 교체 P0)

> React/FastAPI와 same-origin 결정은 유지한다. `backend/`와 `fortune-engine/`를
> 별도 최상위 소스 트리로 두는 결정은 ADR-0006의 `src/shindang` 모듈러
> 모놀리스로 대체되었다. 아래 내용은 2026-07-08 당시의 이행 기록이다.

## 맥락

현재 구조는 `fortune-engine/web/server.py`(Python stdlib ThreadingHTTPServer)가 API와 정적 파일(vanilla JS SPA)을 함께 서빙한다. 스파이크 단계에서는 의존성 0의 단순함이 장점이었으나, 다음 조건이 겹치며 한계에 도달했다:

- `static/app.js`가 화면 6개(S0~S6) + 상태 머신을 담은 ~900줄 단일 파일로 성장 — 컴포넌트화 없이는 유지보수 비용이 계속 오른다.
- 운영 준비(P0)로 stdlib http.server → 프로덕션 런타임 교체가 어차피 필요하다.
- docs/planning/Plan.md의 MVP 스택 결정이 원래 "Vite React + TypeScript"였다 — 현 구조가 임시 형태.
- 실 LLM·DB가 들어오기 전이 마이그레이션 비용이 가장 싼 시점이다.

## 결정

리포를 `frontend/`와 `backend/`로 분리한다.

- **frontend/** — Vite + React + TypeScript SPA. v2 디자인(S0~S6)을 컴포넌트로 이식. Live2D 모듈·재생 코어(autoplay 금지, 세그먼트 타임라인)는 프레임워크 무관 모듈로 유지.
- **backend/** — FastAPI + uvicorn. 기존 핸들러를 이식하되 **엔진 로직은 `fortune-engine/`의 기존 모듈(pipeline, share_card, seed_builder, oauth 헬퍼)을 import로 재사용** — 로직 중복 금지.
- **배포는 same-origin 유지** — dev는 Vite proxy(`/api`, `/audio` → backend), prod는 backend가 `frontend/dist`를 정적 서빙(또는 reverse proxy 라우팅). 세션 쿠키(SameSite=Lax)·CORS 문제를 원천 회피한다.
- 기존 `fortune-engine/web`은 신 구조가 패리티에 도달할 때까지 유지(병행), 패리티 확인 후 제거한다.
  → **2026-07-09 제거 완료**: server.py·vanilla UI 삭제, 헬퍼는 `backend/core.py`로 승격,
  고유 테스트 커버리지는 `tests/test_backend_app.py`로 이관. `pipeline.py`·`event_timeline.py`·
  공용 에셋(`static/assets`, `static/live2d`)은 엔진 계층으로 잔류.

## 대안 검토

- **현 구조 유지 + 런타임만 교체**: 마이그레이션 2회(런타임, 이후 FE) 발생. 기각.
- **Next.js(SSR)**: 운세 SPA는 SSR 이득이 없고(개인화가 클라이언트 로컬 데이터 기반), 정적 빌드 + CDN이 더 단순. Vite SPA 채택.
- **FE/BE 도메인 분리 배포**: CORS + 쿠키 SameSite=None(Secure) 강제 — 복잡도만 증가. same-origin 채택.

## 결과 (트레이드오프)

- (+) FE 정적 산출물 CDN 배포, BE 독립 스케일·배포 주기 분리, 타입 안정성, 컴포넌트 테스트.
- (−) 기존 문자열 수준 마크업 계약 테스트(test_web_server.py 일부)는 신 구조에서 컴포넌트/E2E 테스트로 대체 필요.
- (−) 빌드 파이프라인(node) 의존성 추가.
- 불변식 유지: autoplay 금지·텍스트 먼저·프로필 로컬 우선·재생/부적 로그인 게이트(서버 401 포함)·이벤트 스키마.
