---
id: T010
title: Fortune API mock (계약 경계 + 결정적 스키마 유효 응답)
status: done
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T001", "T003"]
blocks: []
labels: ["sprint-2", "api", "mock", "backend"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T010 — Fortune API mock (계약 경계 + 결정적 응답)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`/api/fortune/today`의 **요청/응답 계약**을 코드로 고정하는 Python **mock**이 생긴다 — LLM·TTS 없이 `fortune-schema.v1.1` 유효 응답을 **결정적으로** 반환해, seed builder·TTS adapter·프론트 연동 티켓이 그 위에 붙는다. (docs/planning/Plan.md §6·§7·§8)

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/fortune_api_mock.py` — `get_today_fortune(request: dict) -> dict`.
  - 응답에 **유효한 `fortune-schema.v1.1` 객체**(scores·scores_line·summary[2]·advice·lucky{color,item}·avoid 등) + API 엔벨로프(`fortuneId`, mock `audioUrl`, `durationSec`).
  - **결정적**: 동일 요청 → 동일 응답 (docs/planning/Plan.md §10 "같은 seed → 재호출 없음" 캐시 전제).
  - 본문 `script`는 T003 `compose_narration` 재사용(서버 조립).
- `tests/test_fortune_api_mock.py` — 응답이 `validate_fortune`(T001) 통과 + 결정성 + 요청 필드 처리 검증.

**제외 (전부 §3 human-gate / 후속)**
- **실제 LLM 생성 호출**, **실제 TTS 합성·실제 `audioUrl`**(여기선 `mock://...` 플레이스홀더).
- **개인정보(생년월일/출생시간) 저장·실제 HMAC seed 키** — mock은 비민감 필드(topic·date·character_id)로 결정적 키를 만들고 birth 필드를 **저장/로그하지 않는다**.
- HTTP 서버·Next.js 라우트·프론트 툴체인 (T004 메모의 후속 결정).

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `get_today_fortune(req)`가 반환한 fortune 객체가 **`validate_fortune`(T001) 스키마 검증을 통과**한다.
- [ ] **결정적**: 동일 `req`에 대해 두 번 호출하면 **동일 응답**(딕셔너리 동등).
- [ ] 엔벨로프에 `fortuneId`, `audioUrl`(명백한 `mock://` 플레이스홀더), `durationSec`가 있고 `script`는 `compose_narration` 8세그먼트로 조립된다.
- [ ] **개인정보 비저장**: birth 필드는 응답·로그·파일에 평문으로 남지 않는다(테스트로 확인). 실제 HMAC은 구현하지 않는다(주석으로 §3 hold 명시).
- [ ] `./ralph/scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

```bash
pytest -q tests/test_fortune_api_mock.py
./ralph/scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm fortune-engine/fortune_api_mock.py tests/test_fortune_api_mock.py
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| mock 응답이 스키마와 미세 불일치 | M | M | `validate_fortune`를 테스트에서 먼저 태워 계약 위반을 즉시 노출 |
| 개인정보가 mock 키/로그로 새어나감 | L | H | birth 필드 미저장을 **테스트로 단언**; 키는 비민감 필드만 사용 |
| mock이 실제 LLM/TTS로 번짐 | L | H | 본 티켓은 mock 한정 — 실제 호출은 §3 hold, 별도 티켓 |

## 7. 메모 / 결정 이력

- 이 mock은 **계약(keystone)**이다. 후속: `T011 seed builder`(결정적 seed_hash 규칙), `T012 TTS adapter`(실제 합성은 §3 승인), 프론트 연동(툴체인 결정 후).
- 클라이언트 평면 응답이 필요하면 docs/planning/Plan.md §7 매핑을 후속 티켓에서; 본 mock은 `fortune-schema.v1.1` 정본 구조를 1차로 반환한다.
- 실제 HTTP/Next.js 노출은 프론트 툴체인 확정(T004 메모) 이후 implementer 티켓.
