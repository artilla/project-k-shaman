---
id: T016
title: fortune_api_mock에 Text/TTS cache_layer 배선 (end-to-end dedup)
status: open
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T014", "T015"]
blocks: []
labels: ["sprint-2", "cache", "api", "integration"]
created: 2026-06-04
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T016 — fortune_api_mock에 Text/TTS cache_layer 배선

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune_api_mock`이 T015 `cache_layer`를 사용해 동일 요청의 fortune/text 계산과 TTS 합성을 **각각 1회만 수행**한다 — 같은 seed/script의 두 번째 요청은 fortune cache(`fortune:v1:{seed_hash}`)와 TTS cache(`tts:v1:...`)에서 반환되어 compute 재호출 0회가 된다. (Plan.md §10 "같은 seed → 재호출 없음")

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/fortune_api_mock.py`
  - T015 `get_or_compute`, `InMemoryCacheStore`, `fortune_cache_key`를 사용해 fortune/text 단계와 TTS 단계에 **2단 캐시**를 배선한다.
  - 기본 store는 네트워크 없는 in-memory mock이어야 한다. 테스트에서는 fresh store를 주입할 수 있어야 한다.
  - 테스트가 spy할 수 있도록 fortune build 단계와 TTS synthesize 단계에 **주입형 compute/backend 훅**을 둔다. 구현 형태는 로컬 패턴에 맞춰 선택하되, 기존 `get_today_fortune(req)` 호출은 계속 동작해야 한다.
  - fortune/text 캐시 키는 `fortune_cache_key(seed_hash) == "fortune:v1:{seed_hash}"`를 사용한다.
  - TTS 캐시 키는 `tts_adapter.synthesize(script)`가 반환한 `cacheKey`를 **그대로** 사용한다.
- `tests/test_fortune_api_mock.py` 또는 신규 테스트 파일
  - 동일 request 2회 호출 시 fortune build spy와 TTS synthesize spy가 모두 **추가 호출 0회**임을 단언한다.
  - 응답 바이트/딕셔너리 동등, fortune schema 유효, raw birth 비유출을 유지한다.

**제외 (§3 / 후속)**
- 실제 Redis/Memcached, S3/object storage, CDN 백엔드. 실 백엔드는 §3 hold, 주입점만 유지.
- TTL, 만료, LRU 등 eviction 정책.
- 실제 LLM 생성, 실제 OpenAI TTS 호출, HMAC server secret, HTTP/Next.js 노출.
- nullable/`None` 값을 캐시하는 sentinel 설계. 이번 캐시 대상은 fortune dict와 TTS dict처럼 non-None 값으로 한정한다.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `get_today_fortune(req)` 기존 호출 방식은 유지되며, 기본 store는 in-memory/file mock 범위에서 네트워크 0이다.
- [ ] 동일 request를 같은 store로 2회 호출하면 응답이 완전히 동일하다.
- [ ] 동일 request 2회차에서 fortune/text build compute가 **추가 호출 0회**임을 spy/카운터로 단언한다.
- [ ] 동일 request 2회차에서 TTS synthesize compute가 **추가 호출 0회**임을 spy/카운터로 단언한다.
- [ ] fortune/text 캐시 키는 `fortune:v1:{seed_hash}`이며 T015 `fortune_cache_key`를 사용한다.
- [ ] TTS 캐시 키는 T013 adapter의 `tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion}` 값을 변형 없이 사용한다.
- [ ] 유지: fortune 객체는 `fortune-schema.v1.1` 검증을 통과하고, 동일 요청 결정성·birth bucket 결정성·raw PII 비유출 테스트가 계속 통과한다.
- [ ] 실 LLM/TTS/Redis/S3/CDN 호출은 없다. 실제 백엔드는 §3 hold 주석 또는 주입점으로만 존재한다.
- [ ] `./scripts/run_checks.sh` 0 exit, full `pytest` green.

## 4. 테스트 계획

```bash
pytest -q tests/test_fortune_api_mock.py tests/test_cache_layer.py tests/test_tts_adapter.py
./scripts/run_checks.sh
```

검증 포인트:
- fresh cache store 주입 → 첫 요청 miss에서 fortune/TTS compute 각각 1회.
- 같은 store + 같은 request 재호출 → fortune/TTS compute 호출 수 그대로 유지.
- 다른 request(예: 다른 date/topic/birth bucket)는 독립 key로 miss가 발생한다.
- 캐시 hit 응답도 `validate_fortune` 통과, raw birth 필드명/값 비노출.

## 5. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 단일 커밋 되돌리면 T014의 비캐시 API mock 상태로 복귀
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 전역 default store가 테스트 간 상태를 오염 | M | M | 테스트는 fresh store 주입, 기본 store 동작은 기존 호출 호환용으로 한정 |
| 캐시 배선이 seed/birth 결정성을 깨뜨림 | L | H | seed_hash 기반 `fortune:v1:` key와 기존 birth bucket 테스트 유지 |
| hit인데 compute가 재호출되어 dedup 실패 | M | M | fortune build spy + TTS synthesize spy를 각각 카운터로 단언 |
| TTS key를 재계산하다 adapter 계약과 어긋남 | M | M | adapter 출력 `cacheKey` verbatim 재사용을 테스트로 고정 |
| 실제 Redis/S3/TTS 호출로 번짐 | L | H | 기본 mock store + mock adapter 한정, 실 백엔드/실 TTS는 §3 hold 주석 유지 |
| `None` 캐시값이 영구 miss가 됨 | L | L | 본 티켓 캐시 대상은 non-None dict만. nullable 캐시는 sentinel 후속으로 분리 |

## 7. 메모 / 결정 이력

- T015 리뷰 메모: `get_or_compute`는 `cached is not None`으로 hit를 판정하므로 nullable 캐시값은 후속 sentinel 설계가 필요하다. T016 대상 값은 fortune dict와 TTS result dict라 안전하다.
- 본 티켓이 끝나면 mock backend 파이프라인은 요청 → seed → fortune cache → narration → TTS cache → 응답까지 dedup된다.
- 실 Redis/S3/CDN 배선과 eviction/TTL 정책은 비용·운영 경계가 있으므로 §3 인간 승인 이후 별도 티켓/ADR로 다룬다.
