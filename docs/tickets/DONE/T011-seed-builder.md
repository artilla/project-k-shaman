---
id: T011
title: Seed builder (결정적 seed_hash·seed_signals; 실제 HMAC은 §3 hold)
status: done
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T010"]
blocks: []
labels: ["sprint-2", "backend", "seed", "privacy"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T011 — Seed builder (결정적 seed_hash·seed_signals)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

요청에서 **결정적 `seed_hash`와 파생 `seed_signals`(score_bias·day_theme)**를 만드는 seed builder가 생긴다 — 캐시 키와 LLM 입력의 단일 규칙이 되어, TTS adapter·HTTP 노출·실제 LLM 연결이 그 위에 안정적으로 붙는다. (Plan.md §10 캐시 키, §11 `birth_profile_hash`/`birth_time_bucket`, 프롬프트 §개인화 입력)

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/seed_builder.py` — `build_seed(request: dict, hash_fn=<dev default>) -> dict`.
  - 반환: `{ "seed_hash": str, "seed_signals": { "score_bias": {love,money,work,relationship,condition ∈ high|mid|low}, "day_theme": str } }`.
  - `seed_hash`는 `birth_profile_hash : date : topic : character_id : tone : locale` 형태(Plan.md §10)로 조립.
  - `birth_profile_hash`는 **birth_date + birth_time_bucket**(정확 시각 아님, Plan.md §11)에서 파생.
  - **결정적**: 동일 입력 → 동일 `seed_hash`/`seed_signals`.
- `tests/test_seed_builder.py` — 결정성·구조·PII 비유출·버킷화·`hash_fn` 주입 검증.

**제외 (§3 human-gate / 후속)**
- **실제 server-secret HMAC seed 키** — 본 티켓은 **비밀키 없는 dev 해시**(예: 정규화 후 SHA-256)를 기본값으로 쓰고, 진짜 HMAC은 `hash_fn` 주입점으로만 남긴다(주석에 §3 hold 명시). 실제 HMAC 키 도입은 인간 승인.
- 개인정보 **저장**(DB/파일), 동의 플로우, fortune_api_mock·LLM·TTS **연결**(후속 티켓).

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `build_seed(req)`가 `seed_hash`(문자열)와 `seed_signals`(`score_bias` 5필드 ∈ high|mid|low + `day_theme` 문자열)를 반환.
- [ ] **결정적**: 동일 `req` 두 번 호출 시 동일 결과.
- [ ] **PII 비유출**: 원본 `birthDate`/정확 `birthTime`가 `seed_hash`·`seed_signals`·반환값·로그·파일에 **평문으로 남지 않는다**(테스트로 단언). birth는 **버킷+해시**로만 흐른다.
- [ ] **실제 HMAC 미구현**: 기본 해시는 비밀키 없는 dev 해시이며, `hash_fn` 주입으로 실제 HMAC을 나중에 끼울 수 있음(주석에 §3 hold). 주입형이 동작함을 테스트로 확인.
- [ ] `./scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

```bash
pytest -q tests/test_seed_builder.py
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm fortune-engine/seed_builder.py tests/test_seed_builder.py
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 원본 birth가 seed/로그로 누출 | L | H | 버킷화 + 해시만 출력, **PII 비유출을 테스트로 단언** |
| dev 해시를 production HMAC으로 오인 | M | M | 기본 해시·주입점에 "dev only, real HMAC = §3 hold" 주석·docstring |
| seed_signals 분포가 비결정적 | L | M | 해시 기반 결정적 매핑, seed 고정 테스트 |

## 7. 메모 / 결정 이력

- **이 모듈은 캐시/개인화의 단일 규칙**이다. 후속: `fortune_api_mock`이 `build_seed`를 사용하도록 연결(별도 티켓 — 그때 mock 결정성 테스트 무회귀 확인), 실제 LLM/TTS 호출(§3 승인), HTTP 노출(프론트 툴체인 후).
- 실제 HMAC 키·server secret 관리는 **§3 hold** — 본 티켓은 인터페이스(`hash_fn`)와 결정적 규칙까지만.
- `birth_time_bucket`(아침/오후/저녁/밤 등) 정의는 Plan.md §11을 따른다(정확 시각 비저장으로 PII 최소화).
