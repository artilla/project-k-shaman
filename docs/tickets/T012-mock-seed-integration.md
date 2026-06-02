---
id: T012
title: fortune_api_mock ↔ seed_builder 연결 (단일 계약, birth-의존 결정성)
status: open
priority: P1
safe: true
persona: implementer
estimate: S
depends_on: ["T010", "T011"]
blocks: []
labels: ["sprint-2", "api", "seed", "refactor"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T012 — fortune_api_mock ↔ seed_builder 연결

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune_api_mock`이 `build_seed`(T011)로 결정적 키·`seed_signals`를 도출하도록 연결되어, **T010 mock과 T011 seed 규칙이 하나의 계약**으로 묶인다(캐시 키가 Plan.md §10 규칙을 따름).

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/fortune_api_mock.py` 리팩토링 — 자체 `date:topic:character_id` 키 대신 `seed_builder.build_seed(request)`의 `seed_hash`·`seed_signals`를 사용.
- `tests/test_fortune_api_mock.py` 갱신 — **birth-의존 결정성** 반영, PII 비유출·스키마 유효 단언 유지.

**제외 (§3 / 후속)**
- 실제 server-secret HMAC — `build_seed` 기본 dev 해시 유지(`hash_fn` 주입점은 그대로, 실제 HMAC = §3 hold).
- 실제 LLM/TTS 호출, 개인정보 저장, HTTP/Next.js 노출.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `get_today_fortune(req)`가 `build_seed(req)`의 `seed_hash`·`seed_signals`를 사용해 응답을 도출한다(자체 키 로직 제거).
- [ ] 응답이 여전히 **`validate_fortune`(T001) 통과**하고, 엔벨로프(`fortuneId`·`mock://` `audioUrl`·`durationSec`·`compose_narration` script)를 유지한다.
- [ ] **결정적**: 동일 `req` → 동일 응답.
- [ ] **birth-의존으로 전환**: `birth_date`/`birth_time` 버킷만 다른 두 `req`는 **다른 응답**(최소 `seed_hash`/`fortuneId` 상이). 기존 "birth 무시" 단언은 이 동작으로 **갱신**한다.
- [ ] **PII 비유출 유지**: raw birth가 응답·로그·파일에 평문으로 남지 않는다(재단언).
- [ ] `./scripts/run_checks.sh` 0 exit, full `pytest` green.

## 4. 테스트 계획

```bash
pytest -q tests/test_fortune_api_mock.py tests/test_seed_builder.py
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 리팩토링 — 단일 커밋 되돌리면 T010/T011 분리 상태로 복귀
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 기존 mock 테스트 깨짐(의도된 전환) | H | L | birth-의존으로 단언 갱신 — 깨짐은 예상이며 갱신이 정답 |
| `seed_signals`→`scores` 매핑이 스키마 범위 이탈 | M | M | scores 0–100 정수·필수 필드 유지를 `validate_fortune`로 단언 |
| PII 비유출 회귀 | L | H | raw birth 비노출 단언을 통합 후에도 유지 |

## 7. 메모 / 결정 이력

- 이 통합으로 **캐시 키 = 실제 seed 규칙**(Plan.md §10). 실제 HMAC·LLM·TTS·HTTP는 여전히 후속/§3 hold.
- `score_bias`(high/mid/low)를 `scores`(0–100)로 어떻게 반영할지는 구현 재량 — **결정적이고 스키마 유효**하면 된다.
- 이후 후속: `T013` TTS adapter mock(실제 합성은 §3 승인), 프론트 툴체인 확정 → HTTP 노출.
