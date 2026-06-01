---
id: T004
title: Sprint 1 UX 골격 — 화면 IA·와이어프레임 명세
status: open
priority: P1
safe: true
persona: planner
estimate: M
depends_on: ["T002"]
blocks: []
labels: ["sprint-1", "ux", "docs", "planner"]
created: 2026-06-01
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T004 — Sprint 1 UX 골격 (화면 IA·와이어프레임 명세)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

모바일 PWA의 **화면 정보구조(IA)와 화면별 와이어프레임 수준 명세**가 한 문서로 서서, 이후 화면 구현 implementer 티켓들이 이 골격을 기준으로 붙는다. (Sprint 1: "모바일 화면 IA 작성" — Plan.md §12·§15.3)

## 2. 변경 범위 (Scope)

**포함**
- 신규 문서 `docs/ux/screen-ia.md` 작성 — 화면 인벤토리·전이·화면별 요소/상태·이벤트 매핑.
- 기존 결정에 grounded: `Plan.md` §4(핵심 흐름)·§5(Frontend 백로그)·§5(Analytics 이벤트), `today-shindang-service-plan-v3.md` §11(재생 UX·autoplay 금지), §12(개인정보 UX), 캐릭터 시트 §6(아바타 상태).
- `fortune-samples.v1.1.json` mock으로 결과 화면이 표시할 필드(summary·scores·scores_line·lucky·avoid)를 명시.

**제외**
- 실제 프론트엔드 **코드/스캐폴딩** 및 툴체인 확정(Next.js vs Vite) — 별도 implementer 티켓·결정으로 분리(메모 참조).
- 백엔드 API·TTS·운세 생성 로직.
- 고해상도 비주얼 디자인(색·타이포 최종) — 비주얼 톤 방향은 시트 §6 참조만.

## 3. 수용 기준 (Acceptance Criteria)

> `docs/ux/screen-ia.md`가 다음을 포함한다.

- [ ] **화면 인벤토리 + 전이도**: 온보딩 → 무당 선택(홍연 고정) → 입력(닉네임·생년월일·출생시간) → 주제 선택 → 캐릭터 stage → 결과 카드 → 공유. (Plan.md §4 9단계와 1:1 매핑)
- [ ] **화면별 와이어프레임 수준 요소·상태**: 각 화면의 핵심 요소, 빈/로딩/에러 상태.
- [ ] **오디오 재생 UX**: 텍스트 **먼저** 노출 → '듣기' 탭으로 AudioContext 오픈(**autoplay 금지**) → presynth 인사 즉시 → 개인화 본문. 플레이어 상태 `idle/greeting/speaking/blessing` 전이. (v3 §11.1–11.2, 시트 §6)
- [ ] **mock 흐름 연결 계획**: `fortune-samples.v1.1.json`을 mock으로 전체 화면 흐름을 연결하는 방법 명시.
- [ ] **분석 이벤트 매핑**: 화면/액션 → 이벤트(`fortune_start`·`character_select`·`tts_play_start/complete`·`share_card_create` 등, Plan.md §5).
- [ ] **개인정보 UX**: 비회원 로컬 우선·동의 기반 저장 표기(원본 생년월일 비노출). (v3 §12)
- [ ] 기존 결정과 **모순 없음**(홍연 1종·정적 부적 카드·닉네임 음성 미포함). `./scripts/run_checks.sh` 0 exit.

## 4. 테스트 계획

```bash
# 핵심 화면·상태가 문서에 존재하는지 (예시)
grep -E "온보딩|무당 선택|입력|주제|stage|결과 카드|공유|idle|greeting|speaking|blessing" docs/ux/screen-ia.md
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm -r docs/ux/screen-ia.md   # 추가 문서만 제거
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| IA가 구현 가능 범위를 넘어 과설계 | M | M | "Sprint 1 = 화면 골격 + mock 흐름"으로 범위 고정, 백엔드 연동은 명세 밖 |
| 재생 UX가 v3 §11(autoplay 금지) 결정과 어긋남 | L | H | 텍스트-먼저·탭-후-AudioContext를 수용 기준에 박음 |
| 개인정보 UX 누락 | L | H | 비회원 로컬 우선·원본 미노출을 필수 항목으로 |

## 7. 메모 / 결정 이력

- **프론트엔드 툴체인 확정**(Next.js vs Vite + Tailwind 등)과 화면 **코드 스캐폴딩**은 본 티켓 밖 → 후속 implementer 티켓에서 결정(그때 `run_checks.local.sh`에 node 검증 추가 고려).
- 이 IA가 서면 `T005-tts-voice-selection`·`T006-share-card-flow`가 이 화면 골격 위에 자연스럽게 붙는다(향후 `depends_on` 후보).
- planner는 `master-spec.md`를 수정할 수 있으나, 본 티켓 산출물은 UX IA 문서로 한정한다.
