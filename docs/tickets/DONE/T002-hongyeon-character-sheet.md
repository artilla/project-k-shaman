---
id: T002
title: 홍연 캐릭터 시트 작성 (제품 톤 단일 기준점)
status: done
priority: P1
safe: true
persona: planner
estimate: M
depends_on: []
blocks: []
labels: ["sprint-0", "character", "docs", "planner"]
created: 2026-06-01
spec_ref: docs/master-spec.md#1-office-hours--6가지-필수-질문
---

# T002 — 홍연 캐릭터 시트 작성 (제품 톤 단일 기준점)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

홍연 캐릭터의 **단일 기준 시트**가 생겨, 이후 프롬프트 개정·TTS 톤·공유 카드·UI가 한 문서를 참조해 일관되게 정렬된다. (Sprint 0: 홍연 캐릭터 시트 — docs/planning/Plan.md §12·§15.1, v3 §7)

## 2. 변경 범위 (Scope)

**포함**
- 신규 문서 `docs/product/character-sheet-hongyeon.md` 작성.
- 기존 출처를 **통합·확장**: `fortune-prompt-hongyeon.v1.1.md`(정체성·말투·콘텐츠 원칙·안전·lucky 풀·출력 계약), `docs/planning/Plan.md` §9, `docs/planning/today-shindang-service-plan-v3.md` §4·§7.
- 프롬프트에 **없는 공백을 보강**: 음성(TTS) 디렉션 디테일, presynth 문장 세트(인사·전환·축원·엔딩) 톤 가이드, 공유 카드·아바타 비주얼 톤.

**제외**
- `fortune-prompt-hongyeon.v1.1.md` **자체 수정** — 시트는 이를 LLM 출력 계약의 **정본으로 참조**만 한다(상충 시 프롬프트 우선).
- `fortune-schema.v1.1.json`·코드·`narration_composer.py` 변경.
- 소월·강림 등 다른 캐릭터 (v3 §7 후속).

## 3. 수용 기준 (Acceptance Criteria)

> 객관적으로 "끝났다"를 판정할 수 있는 조건.

- [ ] `docs/product/character-sheet-hongyeon.md`가 다음 **6개 섹션**을 모두 포함한다:
  1. 페르소나·세계관 (붉은 단청 K-pop 판타지 퇴마 아이돌 무당, 가상 퍼포머, 1분 공연 무대)
  2. 말투·톤 규칙 + **DO / DON'T 예시**
  3. 금지 표현·안전 기준 (공포·강매·단정·사칭·차별·미성년 부적절·닉네임 음성 삽입)
  4. 음성(TTS) 디렉션 (밝고 리듬감, 속도·감정·문장 끊기; 강점영역 연애·자신감·대인관계)
  5. presynth 문장 세트 가이드 (인사·전환·축원·엔딩 — 톤·길이·예시)
  6. 공유 카드·아바타 비주얼 톤 (팔레트는 `lucky.color` 풀과 정합)
- [ ] 기존 `fortune-prompt-hongyeon.v1.1.md`·`docs/planning/Plan.md §9` 안전 기준과 **모순 없음**(상충 시 시트가 출처를 명시하고 프롬프트를 정본으로 표기).
- [ ] 닉네임 음성 미포함, 실제 무속인 사칭 금지 등 **핵심 불변식**이 시트에 명시된다.
- [ ] `./ralph/scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

> planner(문서) 티켓이므로 코드 테스트 대신 구조·정합 검증.

```bash
# 6개 필수 섹션 헤더 존재 확인 (예시)
grep -E "페르소나|말투|안전|음성|presynth|비주얼" docs/product/character-sheet-hongyeon.md
./ralph/scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm docs/product/character-sheet-hongyeon.md   # 추가 문서만 제거
# 또는: git revert <commit>
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 프롬프트와 시트가 중복·드리프트 | M | M | 시트는 LLM 출력 규칙을 **재서술하지 않고 프롬프트를 정본으로 링크**, 보강 영역만 상세화 |
| 기획 v1.1 결정과 어긋남 | L | M | 모든 항목에 출처(§) 표기, 불일치 발견 시 시트 단독 결정 금지 → 별도 티켓 |
| 비주얼 톤이 lucky 색상 풀과 불일치 | L | L | 팔레트를 `fortune-prompt-hongyeon.v1.1.md` color 풀에 맞춤 |

## 7. 메모 / 결정 이력

- 이 시트는 이후 **프롬프트 개정·TTS 보이스 선정·공유 카드 디자인** 티켓의 참조점이다(향후 그 티켓들의 `depends_on` 후보).
- planner는 `master-spec.md`를 수정할 수 있으나, 이 티켓의 산출물은 캐릭터 시트로 한정한다.
- 캐릭터 전략의 상위 결정(홍연 1종 고정·소월 A/B)은 v3 §7이 정본 — 시트는 베타 범위(홍연)만 다룬다.
