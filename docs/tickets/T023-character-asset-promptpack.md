---
id: T023
title: 홍연 에셋 프롬프트 팩 + 선정 킷 — 상태 4컷·공유카드 1컷 생성 사양 정본화 (ADR-0002)
status: open
priority: P1
safe: true               # 문서/사양만 — 생성·과금은 운영자 세션에서 별도 수행.
persona: planner
estimate: S
depends_on: []
blocks: ["T024"]
labels: ["character", "assets", "docs"]
created: 2026-07-07
spec_ref: docs/decisions/0002-character-asset-pipeline.md
---

# T023 — 홍연 에셋 프롬프트 팩 + 선정 킷

## 1. 목표 (한 줄)
> 누가 어떤 도구로 생성하든 같은 홍연이 나오도록, 캐릭터 시트 §6을 재현 가능한 생성 사양(프롬프트 팩 + 수용 기준 + 선정 절차)으로 정본화한다.

## 2. 변경 범위 (Scope)

**포함**
- `docs/assets/hongyeon-promptpack.md` (신규):
  - **캐릭터 지문** (모든 컷 공통): 외형 고정 요소 — 붉은 단청 팔레트 무대 의상, 헤어, 시그니처
    소품(방울·부적 등 시트 §6 기반), 화풍(K-pop 무대 감성 + 한국 전통 미감, 밝고 에너지),
    금지(실존 인물 유사, 공포, 과다 노출).
  - **상태 변주 5컷 사양**: greeting(등장 포즈·에너지) / idle(정면 안정) / speaking(발화 제스처) /
    blessing(축원 포즈) / share-card(공유카드용 상반신·장식 프레임 친화).
  - **기술 규격**: 투명 배경, 1024×1024, WebP 변환 후 장당 ≤150KB, 파일명 규칙
    (`hongyeon-{state}.webp`), `fortune-engine/web/static/assets/` 배치, `assets-manifest.md`
    (도구·모델·생성일·프롬프트·라이선스 근거 기록).
  - **선정 절차**: 도구 2종 이상 × 세트 후보 → 운영자 1회 선정(사람 게이트) → 선정 세트만 커밋.
    일관성 체크리스트(의상·머리·소품 5항목 일치)를 선정 기준으로 명문화.
- `docs/ux/screen-ia.md` S4와의 상태 매핑 표 (FSM 상태 ↔ 에셋 파일).

**제외 (Non-goals)**
- 실제 이미지 생성·과금(운영자 세션), 프론트 통합(T024), 립싱크/리깅(ADR-0002 v1.1 재평가).

## 3. 수용 기준
- [ ] 프롬프트 팩만 보고 제3자가 동일 조건의 후보 세트를 생성할 수 있다 (지문+변주+규격 완비)
- [ ] 캐릭터 시트 §6·screen-ia S4와 상호 참조 정합 (팔레트·상태명 일치)
- [ ] 선정 절차·일관성 체크리스트·매니페스트 양식 포함
- [ ] run_checks --fast GREEN (외부 문서 린트 포함)

## 4. 롤백
`git revert <commit>` — 문서만.

## 5. 운영 노트 (implementer/planner에게)
- `skills/implementer.md` §2.1 헤드리스 실행 모델 준수 (턴=세션, 질문 종료 금지 — 판단 갈리면 시트 §6을 정본으로 보수적 선택 후 메모).
