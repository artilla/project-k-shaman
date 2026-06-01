---
id: T003
title: narration_composer ↔ 시트/스키마 정합 회귀 테스트
status: done
priority: P2
safe: true
persona: implementer
estimate: S
depends_on: ["T001", "T002"]
blocks: []
labels: ["sprint-2", "tts", "test", "consistency"]
created: 2026-06-01
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T003 — narration_composer ↔ 시트/스키마 정합 회귀 테스트

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune-engine/tts-ab-kit/narration_composer.py`의 **조립 순서·세그먼트·타이핑**이 캐릭터 시트 §4 / `fortune-prompt-hongyeon.v1.1.md`가 정의한 정본과 일치함을 pytest로 **고정**하여, 이후 변경이 정합을 깨면 즉시 잡힌다.

## 2. 변경 범위 (Scope)

**포함**
- `tests/test_narration_composer.py` 추가 — `compose_narration()` 출력의 순서·세그먼트·타입을 단언.
- `fortune-samples.v1.1.json`의 유효 샘플 1건을 `compose_narration`에 통과시켜 스모크 검증.
- (선택) `narration_composer.py`에 **동작 변경 없이** 정본 출처(시트 §4) 링크 주석 보강.

**제외**
- 조립 **순서/로직 변경**, presynth 풀 단일→다중 확장, `transition` 세그먼트 추가 — 이는 product/planner 결정 (시트 §5의 "(선택) 전환" 및 Plan.md §10 풀 분리).
- `fortune-schema.v1.1.json`·캐릭터 시트·프롬프트 **수정**.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `compose_narration(f)`가 정확히 **8개 세그먼트**를 **이 순서로** 반환한다: `greeting → summary → scores → advice → lucky → avoid → blessing → ending`. (프롬프트 v1.1 §변경요약, 시트 §4)
- [ ] presynth 세그먼트(`greeting`/`blessing`/`ending`)는 `type == "presynth"`이고 `PRESYNTH` 풀에서 나온다; 개인화(`summary`/`scores`/`advice`/`avoid`)는 LLM 필드에서; `lucky`는 `type == "semi"`(템플릿).
- [ ] `fortune-samples.v1.1.json`의 유효 샘플을 통과시키면 모든 세그먼트 `text`가 **비어 있지 않다**.
- [ ] **알려진 허용 편차**(transition 미포함=선택, presynth 단일 문자열=MVP)는 테스트에서 **실패로 취급하지 않는다**(주석으로 의도 명시).
- [ ] `./scripts/run_checks.sh` 0 exit (pytest 포함).

## 4. 테스트 계획

```bash
pytest -q tests/test_narration_composer.py
./scripts/run_checks.sh
```

> `narration_composer.py`는 `fortune-engine/tts-ab-kit/` 하위이므로, 테스트에서 해당 경로를 `sys.path`에 추가하거나 `importlib`로 로드한다(경로 상수는 테스트 상단에).

## 5. 롤백 방법 (Reversibility)

```bash
git rm tests/test_narration_composer.py
# narration_composer.py 주석을 보강한 경우 함께 되돌린다.
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| import 경로(`tts-ab-kit` 하이픈·하위 디렉터리) | M | L | 테스트가 `sys.path.insert` 또는 `importlib.util.spec_from_file_location`로 절대경로 로드 |
| composer가 실제로 시트와 불일치 발견 | L | M | **이 티켓에서 composer를 임의 수정 금지** — 불일치는 ADR/planner 티켓으로 승격(시트 §4가 순서 정본) |
| 샘플 필드와 composer 입력 계약 불일치 | L | M | 테스트는 `summary[2]`·`lucky{color,item}`·`avoid`·`advice` 존재를 전제로 하고, 누락 시 명확히 실패 메시지 |

## 7. 메모 / 결정 이력

- 정합이 깨지면 **무엇이 정본인가**: 순서·세그먼트는 캐릭터 시트 §4(= 프롬프트 v1.1)가 정본. composer가 어긋나면 composer를 고치는 별도 티켓으로, 시트를 고치면 planner 티켓으로 승격.
- presynth **풀 확장**(단일 문자열 → 변형 세트)과 **transition 세그먼트**는 Sprint 후속 product 결정 → 본 티켓 범위 밖.
- 이 테스트가 통과하면 T001(스키마)·T002(시트)·조립기 코드가 한 회귀 그물로 묶인다.
