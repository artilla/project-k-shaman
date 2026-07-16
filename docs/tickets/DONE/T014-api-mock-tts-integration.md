---
id: T014
title: fortune_api_mock ↔ tts_adapter 연결 (audioUrl·duration·tts metadata)
status: done
priority: P1
safe: true
persona: implementer
estimate: S
depends_on: ["T010", "T013"]
blocks: []
labels: ["sprint-2", "api", "tts", "refactor"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T014 — fortune_api_mock ↔ tts_adapter 연결

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune_api_mock`의 placeholder `audioUrl`/고정 `durationSec`이 **`tts_adapter.synthesize(script, …)`의 결정적 출력**으로 교체되고, 응답 엔벨로프에 `tts` metadata가 붙는다 — mock 파이프라인이 **요청→응답 end-to-end**로 완성된다. (Plan.md §7 응답, §10 TTS 캐시 키)

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/fortune_api_mock.py` 리팩토링 — `compose_narration`(T003)로 만든 script를 `tts_adapter.synthesize(script, ...)`에 넘겨 `audioUrl`·`durationSec`을 받고, `tts` metadata(cacheKey·provider·voice 등)를 엔벨로프에 추가. 보이스 설정은 ADR-0001 기본값.
- `tests/test_fortune_api_mock.py` 갱신 — **고정값 단언만** adapter-도출값으로, `tts` metadata 단언 추가.

**제외 (§3 / 후속)**
- 실제 TTS 합성·비용 발생 호출(adapter mock backend 유지, 실제 = §3 hold).
- object storage/CDN 업로드, HTTP/Next.js 노출, 개인정보 저장.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `get_today_fortune(req)`의 `audioUrl`·`durationSec`이 **`tts_adapter.synthesize()` 출력에서** 온다(placeholder/고정값 제거).
- [ ] 응답 엔벨로프에 `tts` metadata(최소 `cacheKey`·`provider`·`voice`)가 포함된다.
- [ ] **유지**: fortune 객체 `validate_fortune`(T001) 통과 · 결정성(동일 req→동일 응답) · **PII 비유출**(raw birth 비노출).
- [ ] **실제 TTS 미호출**: adapter mock backend 사용(네트워크/비용 0), 실제 호출은 §3 hold(주석).
- [ ] 기존 placeholder/고정 duration 단언은 adapter-도출값으로 **갱신**. `./ralph/scripts/run_checks.sh` 0 exit, full `pytest` green.

## 4. 테스트 계획

```bash
pytest -q tests/test_fortune_api_mock.py tests/test_tts_adapter.py
./ralph/scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 리팩토링 — 단일 커밋 되돌리면 T010 placeholder 상태로 복귀
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 기존 mock 테스트 깨짐(의도된 교체) | H | L | 고정값 단언만 adapter-도출값으로 갱신 — 예상된 전환 |
| 엔벨로프 변경이 스키마 fortune 객체를 오염 | L | M | `tts`는 **엔벨로프 레벨**에만, fortune 객체는 `validate_fortune` 그대로 통과 |
| 실제 TTS/비용으로 번짐 | L | H | mock backend 한정, 실제 = §3 hold — 네트워크 0 테스트 |

## 7. 메모 / 결정 이력

- 이 연결로 **mock 백엔드 계약이 end-to-end**(seed→fortune→narration→TTS-mock→응답)로 닫힌다.
- 이후 후속: 실제 OpenAI TTS backend·LLM 생성·HTTP 노출은 전부 §3/프론트 툴체인 결정 이후.
- `audioUrl`/`durationSec`은 이제 `tts:v1:...` 캐시 키(Plan.md §10)와 정합한 결정적 값이다.
