---
id: T024
title: 아바타 에셋 프론트 통합 — FSM 상태별 이미지 스왑 + 음량 글로우 + 공유카드 일러스트 임베드 (에셋 부재 폴백 유지)
status: done
priority: P1
safe: true               # 프론트 정적 파일 + SVG 임베드 — 과금·키 경로 무변경.
persona: implementer
estimate: M
depends_on: ["T022", "T023"]
blocks: []
labels: ["feature", "frontend", "character", "playback"]
created: 2026-07-07
spec_ref: docs/ux/screen-ia.md#s4--캐릭터-stage
completed_at: 2026-07-08T00:52:16+09:00
started_at: 2026-07-08T00:36:38+09:00
---

# T024 — 아바타 에셋 프론트 통합

## 1. 목표 (한 줄)
> T022의 플레이스홀더 아바타를 에셋 기반으로 올린다 — 상태 4컷 크로스페이드 + 재생 음량 글로우 펄스 + 공유카드 일러스트. 에셋이 없으면 지금 모습 그대로 동작한다(폴백 불변식).

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/web/static/`:
  - `assets/hongyeon-{greeting,idle,speaking,blessing}.webp` 존재 시 FSM 상태 전이에 맞춰
    이미지 스왑(크로스페이드 ≤300ms). **부재 시 현 플레이스홀더 유지** — 기능 감지, 404 무음 처리.
  - speaking 상태: WebAudio `AnalyserNode` 음량 → 아바타 글로우/스케일 펄스 (S4 "음량 기반 입 모양
    동기화"의 베타 근사, ADR-0002). AudioContext 재사용 — autoplay 규칙(§11.2) 무변경.
  - 에셋 preload는 첫 텍스트 노출 이후 지연 로드 — `first_text_visible`·`first_audio_play` 지연
    무회귀 (§1.6-② 예산).
- `fortune-engine/share_card.py` 또는 web 서버 조립부: 공유카드 SVG에 `hongyeon-share-card.webp`
  임베드(base64 또는 참조) — 부재 시 현 텍스트 카드 유지. 개인정보 비노출 검증 무회귀.
- 테스트: 에셋 부재 환경(기본)에서 전 스위트 GREEN·폴백 동작, 에셋 존재 시 상태→파일 매핑,
  카드 임베드 분기. 이미지 파일 자체는 커밋 전제 아님(픽스처는 1px 스텁).

**제외 (Non-goals)**
- 에셋 생성(운영자, T023 산출 사양), 립싱크/리깅, 등장 애니메이션 리치 연출, 캐릭터 2종.

## 3. 수용 기준
- [ ] 에셋 없는 기본 환경: 현 T022 동작과 완전 동일 (전 스위트 GREEN, 폴백 불변식)
- [ ] 에셋(스텁) 존재 시: FSM 상태별 스왑 + speaking 글로우 펄스 동작 (문자열/구조 수준 테스트)
- [ ] 공유카드: 일러스트 존재 시 임베드, 부재 시 기존 카드 — 개인정보 비노출 무회귀
- [ ] first_text_visible·first_audio_play 경로에 에셋 로드가 선행되지 않음 (지연 로드 단언)
- [ ] `python3 -m pytest tests/` GREEN (키 없는 환경)

## 4. 롤백
`git revert <commit>` — 프론트 + 카드 임베드 분기만.

## 5. 운영 노트 (implementer에게)
- `ralph/skills/implementer.md` §2.1 준수. 에셋 실물이 없어도 이 티켓은 완결된다 — 스텁 픽스처로 검증하라.
