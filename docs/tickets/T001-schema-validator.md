---
id: T001
title: 운세 스키마 validator 연결 (fortune-schema.v1.1)
status: open
priority: P1
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: ["sprint-0", "schema", "test"]
created: 2026-06-01
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T001 — 운세 스키마 validator 연결 (fortune-schema.v1.1)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune-engine/fortune-samples.v1.1.json`이 정본 스키마 `fortune-engine/fortune-schema.v1.1.json`(JSON Schema Draft 2020-12)을 만족하는지 **자동 검증**되고, 회귀 테스트로 고정된다. (Sprint 0: "운세 JSON schema validator 연결" — Plan.md §12·§15.2)

## 2. 변경 범위 (Scope)

**포함**
- 스키마 검증 스크립트 추가 (예: `fortune-engine/validate_fortune.py`) — `jsonschema`로 샘플을 스키마에 대해 검증.
- pytest 테스트 추가 (`tests/test_fortune_schema.py`): 유효 샘플 통과 + 의도적 무효 샘플 거부.
- (필요 시) `requirements.txt`에 `jsonschema` 명시 → `run_checks.local.sh` python 경로가 자동 인식.

**제외**
- `fortune-schema.v1.1.json` **스키마 자체 변경** (정본이므로 손대지 않음).
- LLM 운세 생성·`narration_composer.py`·TTS 로직.
- 클라이언트 평면 응답(§7 API) 매핑.

## 3. 수용 기준 (Acceptance Criteria)

> AI가 "끝났다"고 판단할 수 있는 객관적 조건.

- [ ] `fortune-samples.v1.1.json`의 모든 유효 샘플이 스키마 검증을 **통과**한다.
- [ ] 필수 필드(`schema_version`, `meta`, `scores`, `scores_line`, `summary`(정확히 2문장), `advice`, `lucky.{color,item}`, `avoid`, `blessing`) 누락/형식 위반 샘플은 **거부**된다(테스트로 1건 이상 검증).
- [ ] `scores`의 5개 항목(love/money/work/relationship/condition)이 0–100 정수 범위를 벗어나면 거부된다.
- [ ] `pytest`가 통과하고 `./scripts/run_checks.sh` 가 **0 exit**.

## 4. 테스트 계획

> `scripts/run_checks.sh`가 이 명령들을 호출 가능해야 함.

```bash
pytest -q tests/test_fortune_schema.py
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

> 추가만 하는 작업이라 파일 삭제로 원복 가능.

```bash
rm -f fortune-engine/validate_fortune.py tests/test_fortune_schema.py
# requirements.txt를 새로 만든 경우 함께 되돌린다.
# git 사용 중이면: git revert <commit> / git checkout -- <files>
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 샘플/스키마 경로·파일명 변동(v1.0 잔존) | L | M | 정본은 `*.v1.1.json`만 대상으로 고정, 경로를 테스트 상단 상수로 |
| `jsonschema` 미설치 | M | L | `requirements.txt` 명시 + `run_checks.local.sh`가 미설치 시 graceful skip |
| 스키마와 샘플 불일치(기획 진행 중) | M | M | 불일치 발견 시 스키마 변경 금지 — 별도 planner 티켓으로 승격 |

## 7. 메모 / 결정 이력

- `run_checks.local.sh`(python)는 `tests/`에 `test_*.py`가 있을 때만 pytest를 실행한다 — 이 티켓이 첫 pytest 대상이 된다.
- 스키마 자체 정합성(기획 v1.1 결정) 문제는 이 implementer 티켓 범위 밖 → `docs/decisions/`로 ADR 승격 후보.
