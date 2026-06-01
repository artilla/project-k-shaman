---
id: T008
title: 엔진 통합 스모크 테스트 (+ Step 2 로깅·자율성 진단)
status: open
priority: P2
safe: true
persona: implementer
estimate: S
depends_on: ["T001", "T003", "T006"]
blocks: []
labels: ["sprint-1", "test", "smoke", "diagnostic"]
created: 2026-06-01
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T008 — 엔진 통합 스모크 테스트 (+ Step 2 로깅·자율성 진단)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

하나의 `fortune-samples.v1.1` 샘플이 **validator → narration composer → share card SVG**를 모두 무오류로 통과하는 **통합 스모크**가 고정된다. (부수 목적: T007 로그 캡처 적용 후 **첫 실제 헤드리스 사이클**로 `.ralph/logs/` 생성과 자율성 회복 여부를 진단)

## 2. 변경 범위 (Scope)

**포함**
- `tests/test_engine_smoke.py` 추가 — 동일 샘플 1건을 세 모듈에 흘려 cross-module 무오류를 단언.

**제외**
- 엔진 모듈(`validate_fortune.py`·`narration_composer.py`·`share_card.py`) **로직 변경**, 새 기능.
- 로깅/루프 스크립트 변경 (T007에서 완료).

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `tests/test_engine_smoke.py`가 `fortune-engine/fortune-samples.v1.1.json`의 유효 샘플 1건으로:
  1. `validate_fortune`(T001) — 스키마 검증 **통과**.
  2. `compose_narration`(T003) — **8세그먼트** 정상 반환(순서 정합은 T003가 이미 고정, 여기선 무오류 실행만).
  3. `share_card`(T006) — **well-formed SVG** 생성(파싱 가능).
- [ ] import는 기존 테스트 패턴 재사용(`tts-ab-kit` 경로는 `importlib`/`sys.path`).
- [ ] `./scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

```bash
pytest -q tests/test_engine_smoke.py
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm tests/test_engine_smoke.py
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| `tts-ab-kit`(하이픈) 모듈 import | M | L | T003 테스트의 `importlib`/`sys.path` 패턴 재사용 |
| 샘플 필드 계약 변동 | L | M | T001 validator를 먼저 태워 계약 위반을 명확히 노출 |

## 7. 메모 / 결정 이력 (진단 목적)

- **이 티켓은 T007(Step 2 헤드리스 로그 캡처) 적용 후 첫 실제 사이클이다.** 기대 동작:
  - `./scripts/run_loop.sh T008-engine-smoke-test` 실행 시 `.ralph/logs/T008-engine-smoke-test.log`(메타 헤더 `ticket/started_at/root/persona` 포함) 생성.
  - **자율 완료**되면 → headless 자율성 회복 확인.
  - **stall**이면 → 그 로그로 `timeout / 즉시 종료 / 행` 중 무엇인지 즉시 좁힘. §3.8 절차로 회수.
- 의도적으로 작은 task라 stall 발생 시 task 난이도가 아니라 **infra 신호**로 명확히 해석된다.
- 통과 시 T001·T003·T006이 **단일 통합 스모크**로 한 번 더 묶인다.
