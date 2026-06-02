---
id: T013
title: TTS adapter mock (결정적 캐시 키·mock audioUrl; 실제 합성은 §3 hold)
status: done
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T003", "T005"]
blocks: []
labels: ["sprint-2", "tts", "adapter", "mock"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T013 — TTS adapter mock

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`script` + 보이스 설정에서 **결정적 TTS 캐시 키와 `mock://` audioUrl·duration·metadata**를 만드는 adapter가 생긴다 — 실제 TTS를 끼울 **단일 교체점**이 마련된다. (Plan.md §10 TTS 캐시 키, §2 길이, ADR-0001 권고값)

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/tts_adapter.py` — `synthesize(script, *, provider, voice, speed, emotion, backend=<mock>) -> dict`.
  - **결정적 캐시 키**: `tts:v1:{provider}:{voice_id}:{script_hash}:{speed}:{emotion}` (Plan.md §10 형태).
  - 반환: `{ audioUrl: "mock://...", durationSec, cacheKey, metadata }`.
  - **기본값 = ADR-0001**: `provider=openai`, `voice=coral`, `model=gpt-4o-mini-tts`.
  - `durationSec`는 script 길이 기반 결정적 추정(45–60초 밴드, Plan.md §2).
  - **주입형 backend 인터페이스만** 개방(기본은 mock backend — 호출/네트워크/비용 없음).
- `tests/test_tts_adapter.py` — 결정성·캐시 키 형태·mock url·기본값·duration·주입형 backend 검증.

**제외 (전부 §3 hold)**
- **실제 TTS 합성·비용 발생 API 호출**, object storage 업로드/CDN, 프로바이더 **계약·API 키 관리**.
- 실제 `audioUrl`(여기선 `mock://` 플레이스홀더).

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `synthesize(script, ...)`가 `{ audioUrl, durationSec, cacheKey, metadata }`를 반환.
- [ ] `cacheKey` == `tts:v1:{provider}:{voice_id}:{script_hash}:{speed}:{emotion}` (Plan.md §10 형태).
- [ ] **결정적**: 동일 `script`+설정 → 동일 `audioUrl`·`cacheKey`·`durationSec`.
- [ ] 기본값이 **ADR-0001**(`gpt-4o-mini-tts`, `coral`)을 따른다.
- [ ] **실제 합성 미구현**: 기본 backend는 mock(`mock://`, 네트워크/비용 0). 주입형 backend가 호출됨을 테스트로 확인. 실제 호출 = §3 hold(주석 명시).
- [ ] `durationSec`가 script 길이에서 결정적으로 나오고 합리적 밴드 안.
- [ ] `./scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

```bash
pytest -q tests/test_tts_adapter.py
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm fortune-engine/tts_adapter.py tests/test_tts_adapter.py
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| mock이 실제 TTS/비용으로 번짐 | L | H | 기본 backend는 mock 한정, 실제 호출은 §3 hold·주입점으로만 — 테스트로 네트워크 0 확인 |
| 캐시 키가 Plan §10 형태와 어긋남 | M | M | 키 문자열을 테스트로 고정(`tts:v1:...` 토큰 순서) |
| duration 추정이 비결정적/비현실적 | L | L | 글자수·고정 발화속도 기반 결정적 추정, 밴드 단언 |

## 7. 메모 / 결정 이력

- 이 adapter는 **실제 TTS 교체점**이다. 후속: 실제 OpenAI `gpt-4o-mini-tts` 백엔드 구현 + 소량 합성 spot check는 **§3 인간 승인**하에(ADR-0001 §후속, listening-decision-report §5).
- `fortune_api_mock`이 이 adapter로 `audioUrl`/`durationSec`을 받도록 연결하는 건 별도 후속 티켓.
- script는 `compose_narration`(T003) 조립 결과를 입력으로 가정한다.
