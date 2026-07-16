---
id: T005
title: TTS 보이스·프로바이더 선정 결정 (ADR)
status: done
priority: P2
safe: true
persona: planner
estimate: M
depends_on: ["T002"]
blocks: []
labels: ["sprint-1", "tts", "decision", "planner"]
created: 2026-06-01
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T005 — TTS 보이스·프로바이더 선정 결정 (ADR)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

베타용 **TTS 프로바이더와 홍연 보이스**를 비교·선정한 **결정 기록(ADR)**이 생겨, 이후 TTS 어댑터 구현·합성이 한 기준 위에서 진행된다. (docs/planning/Plan.md §3·§12·§15.4 "TTS provider 후보 비용/한국어 품질 확인")

## 2. 변경 범위 (Scope)

**포함**
- 신규 ADR `docs/decisions/0001-tts-voice-and-provider.md` 작성 (형식: 컨텍스트 / 결정 / 대안과 기각 이유 / 후속 영향).
- 후보 비교: 한국어 품질, **원가**(공개 가격·문자/초당), 지연, 라이선스·상업 사용, 보이스 커스터마이즈 가능성.
- 홍연 톤 적합성 기준은 캐릭터 시트 §4(밝고 리듬감·speed/emotion)에 grounded.
- 근거: `docs/planning/Plan.md` §2·§3(보이스 결정: 기본 TTS 음색+말투, 커스텀 계약은 지표 이후)·§13(단위 경제), `docs/planning/today-shindang-service-plan-v3.md` §10·§13·§18, 기존 `fortune-engine/tts-ab-kit/synthesize_tts.py`(현재 어댑터 가정).

**제외 (중요)**
- **실제 유료 TTS API 호출·합성·계약 체결** — master-spec §3에서 **인간 승인 필수**. 본 티켓은 결정 문서까지만.
- TTS 어댑터 **구현 코드** (후속 implementer 티켓).
- narration 조립 전략 — 이미 `docs/reports/tts/listening-decision-report.md`에서 "scores_line 중간안"으로 **결정 완료**(보이스 선정과 별개, 혼동 금지).

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `docs/decisions/0001-tts-voice-and-provider.md`가 ADR 4부(컨텍스트/결정/대안·기각/후속)를 갖춘다.
- [ ] **후보 비교표**: 최소 2~3개 프로바이더 × (한국어 품질·원가·지연·라이선스·커스텀 가능성). 수치는 **공개 자료/기존 샘플 기반**, 실시간 유료 호출 없이 — 불확실값은 `(확인 필요)` 표기.
- [ ] **권고안 1개 + 근거**, 그리고 베타 범위 = "기본 TTS 음색 + 홍연 말투, 커스텀 보이스 계약은 베타 지표 이후"(Plan §2)를 명시.
- [ ] 홍연 톤 적합성 평가 기준(시트 §4)이 선정 근거에 반영된다.
- [ ] **인간 승인 경계 명시**: 실제 합성/유료 계약은 master-spec §3 hold 항목임을 ADR 후속에 적는다.
- [ ] 기존 narration A/B 결정과 **혼동하지 않음**(보이스 선정 ≠ 조립 전략).
- [ ] `./ralph/scripts/run_checks.sh` 0 exit (ADR도 `lint_external_docs` 대상 — git 명령 컨텍스트에 base 브랜치 하드코딩 금지).

## 4. 테스트 계획

```bash
# ADR 4부 구성 + 비교표 존재 확인 (예시)
grep -E "컨텍스트|결정|대안|후속|한국어|원가|지연|라이선스" docs/decisions/0001-tts-voice-and-provider.md
./ralph/scripts/run_checks.sh   # lint_external_docs가 docs/decisions/ 를 검사
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm docs/decisions/0001-tts-voice-and-provider.md
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 공개 가격·보이스 가용성 변동 | H | M | 수치에 측정일·출처 명기, 불확실은 `(확인 필요)`; 최종 확정은 실측 후속 |
| 실제 TTS 비용 발생 호출로 번짐 | L | H | 본 티켓은 결정 문서까지만 — 합성/계약은 human-gate(master-spec §3) |
| 한국어 보이스 라이선스·상업 제약 누락 | M | H | 비교표에 라이선스·상업 사용 열을 필수로 |

## 7. 메모 / 결정 이력

- ADR이 서면, 후속 **implementer 티켓**이 선정 프로바이더로 TTS 어댑터(`synthesize_tts.py` 일반화)를 구현하고, 그 시점에 **실제 소량 합성 spot check**(listening-decision-report §5 후속)는 인간 승인하에 진행한다.
- 이 결정은 `T006-share-card-flow`와 독립이며 병렬 가능.
- 가격·품질의 1차 자료는 공개 문서. 본 루프 환경에서 외부 유료 API를 호출하지 않는다.
