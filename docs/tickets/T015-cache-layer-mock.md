---
id: T015
title: Text/TTS 캐시 레이어 mock (get-or-compute dedup; 실 Redis/S3/CDN은 §3 hold)
status: open
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T011", "T013"]
blocks: []
labels: ["sprint-2", "cache", "mock", "performance"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T015 — Text/TTS 캐시 레이어 mock

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

**기존 키 계약**(`seed_hash`→fortune, `tts:v1:…`→audio)을 그대로 재사용하는 **get-or-compute 캐시 레이어**가 생긴다 — 같은 키의 두 번째 요청은 **compute(LLM/TTS) 재호출 없이** 캐시에서 돌려준다(dedup). 실제 Redis/S3/CDN을 끼울 **단일 교체점**이 마련된다. (master-spec §2 흐름의 "Text/TTS 캐시" 노드, Plan.md §10 "같은 seed → 재호출 없음")

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/cache_layer.py`
  - `get_or_compute(store, key, compute_fn) -> value`
    - **hit**: `key`가 store에 있으면 캐시 값을 반환하고 **`compute_fn`을 호출하지 않는다**(핵심 dedup 불변식).
    - **miss**: `compute_fn()`을 **정확히 1회** 호출 → 결과를 store에 저장 → 반환.
  - **주입형 store 인터페이스**(duck-typed: `get(key)`/`set(key, value)` + `hits`/`misses` 카운터). 기본 구현 2종, 둘 다 네트워크/비용 0:
    - `InMemoryCacheStore` — dict 기반.
    - `FileCacheStore(base_dir)` — JSON 파일 백업(결정적, 네트워크 없음). 새 인스턴스로도 같은 `base_dir`이면 값이 보존됨.
  - **키 형태 재사용(재발명 금지)**:
    - fortune/text 측: `fortune_cache_key(seed_hash) -> "fortune:v1:{seed_hash}"` 헬퍼(`seed_builder.build_seed`의 `seed_hash` 입력).
    - tts/audio 측: `tts_adapter`가 이미 만드는 `cacheKey`(`tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion}`)를 **그대로** 키로 사용(어댑터 결과 재사용, 새 키 계산 안 함).
- `tests/test_cache_layer.py` — 아래 수용 기준을 spy/카운터로 검증.

**제외 (전부 §3 hold 또는 후속)**
- **실제 Redis/Memcached, S3/object storage, CDN** 백엔드(주입점만 개방, 실 백엔드 = §3 hold).
- TTL·만료·LRU 등 **eviction 정책**(이번엔 무한 보존 mock; eviction은 후속).
- `fortune_api_mock`에 캐시를 **배선**해 반복 요청 시 재계산을 건너뛰게 하는 통합(별도 후속 티켓 — T013→T014 분리 패턴과 동일).
- HTTP/Next.js 노출, 개인정보 저장.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `get_or_compute(store, key, compute_fn)`가 miss 시 `compute_fn`을 **정확히 1회** 호출하고 값을 store에 저장한다.
- [ ] **dedup 핵심 불변식**: 같은 `key`로 두 번째 호출 시 `compute_fn` **추가 호출 0회**(spy/카운터로 단언) — 캐시 값을 반환.
- [ ] `InMemoryCacheStore`·`FileCacheStore` 둘 다 `get`/`set`과 `hits`/`misses` 카운터를 제공하고, hit/miss가 카운터에 반영된다.
- [ ] `FileCacheStore`는 **같은 `base_dir`의 새 인스턴스**에서도 저장된 값을 읽어온다(파일 백업 보존). 기본 동작에 **네트워크 호출 0**.
- [ ] `fortune_cache_key(seed_hash) == "fortune:v1:{seed_hash}"`, tts 측은 어댑터의 `tts:v1:…` 키를 변형 없이 키로 쓴다(키 형태 유지).
- [ ] **결정성**: 같은 `key` → 같은 캐시 값. 다른 `key` → 서로 영향 없음.
- [ ] **PII 비유출**: 캐시 키·값은 이미 파생된 해시(`seed_hash`/`script_hash`)만 담고 raw birth(생년월일/출생시간)는 담지 않는다.
- [ ] **실 백엔드 미구현**: 기본 store는 in-memory/file mock(네트워크/비용 0), 실제 Redis/S3/CDN = §3 hold(주석 명시·주입점으로만).
- [ ] `./scripts/run_checks.sh` 0 exit, full `pytest` green.

## 4. 테스트 계획

```bash
pytest -q tests/test_cache_layer.py
./scripts/run_checks.sh
```

검증 포인트(필수):
- compute 호출 카운터: miss 1회 → 동일 키 재호출 시 **0회 추가**.
- `FileCacheStore`: 인스턴스 A로 `set` → 인스턴스 B(`base_dir` 동일)로 `get` 시 동일 값.
- 키 형태: `fortune:v1:…` prefix, tts 키는 어댑터 출력과 바이트 동일.

## 5. 롤백 방법 (Reversibility)

```bash
git rm fortune-engine/cache_layer.py tests/test_cache_layer.py
# 또는 단일 커밋 revert — 신규 모듈이라 기존 파이프라인 동작에 영향 없음
git revert <commit>
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| mock 캐시가 실제 Redis/S3/CDN 호출로 번짐 | L | H | 기본 store는 in-memory/file 한정, 실 백엔드 = §3 hold·주입점으로만 — 네트워크 0 테스트 |
| dedup 불변식이 깨져 hit인데 compute 재호출 | M | M | compute spy/카운터로 "두 번째 호출 0회"를 직접 단언 |
| 캐시 키 형태가 기존 계약(`fortune:v1:`/`tts:v1:`)과 어긋남 | M | M | 키 문자열을 테스트로 고정, tts는 어댑터 출력 재사용(재계산 금지) |
| 캐시 값에 raw PII가 섞임 | L | H | 키·값은 파생 해시만 — raw birth 비포함을 테스트로 단언 |
| FileCache 동시쓰기 경쟁 | L | L | mock 범위는 단일 프로세스 — 동시성은 실 백엔드(§3)에서 다룸, 주석 명시 |

## 7. 메모 / 결정 이력

- 이 캐시는 **실 Redis/S3/CDN 교체점**이다. 후속: 실 백엔드 + eviction/TTL 정책은 **§3 인간 승인**하에(master-spec §3 "실제 TTS 비용 발생 호출/운영 배포" 인접).
- 캐시를 `fortune_api_mock`에 배선해 **반복 요청 dedup**(같은 seed/script → 0 재계산)을 실증하는 건 별도 후속 티켓(T016 후보) — 본 티켓은 레이어+계약 고정까지.
- 키 계약 출처: fortune 측 `seed_hash`는 T011(`build_seed`), tts 측 `tts:v1:…`는 T013(`tts_adapter.synthesize`). 본 티켓은 **재사용만** 하고 새 키 의미를 만들지 않는다.
