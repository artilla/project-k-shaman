---
id: T019
title: 재생 프론트 스켈레톤 — 탭 오디오 컨텍스트·텍스트 먼저·presynth 재생 + 3초 경로 실측 훅
status: done
priority: P1
safe: true               # 프론트 스켈레톤 + mock 파이프라인 — 과금·개인정보 경로 없음.
persona: implementer
estimate: M
depends_on: ["T018"]
blocks: []
labels: ["feature", "frontend", "playback", "metrics"]
created: 2026-07-07
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T019 — 재생 프론트 스켈레톤 (E2E 베타 데모 1단계)

## 1. 목표 (한 줄)
> 홍연 운세 1회를 모바일 웹에서 "탭 → 텍스트 먼저 → 음성 재생"으로 끝까지 체험할 수 있는 최소 페이지를 만든다 — master-spec §1.6-③의 E2E 데모 골격이자 §1.6-② 3초 실측의 측정 지점.

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/web/` (신규): 정적 모바일 웹 페이지 + 최소 로컬 서버(또는 기존 파이썬으로 서빙).
  - **자동 재생 금지 전제** (v3 §11.2): 첫 재생은 사용자 탭으로 오디오 컨텍스트를 연다.
  - **텍스트 먼저** (v3 §11.1): fortune 텍스트를 즉시 노출하고, 오디오는 준비되는 대로 재생.
  - 파이프라인 연결: seed_builder → fortune_api(mock) → narration composer → tts_adapter(mock 기본,
    `OPENAI_API_KEY` 있으면 실백엔드 선택 가능) → cache_layer.
- **3초 경로 실측 훅** (§1.6-②): `tts_generate_start/complete`·`cache_hit/miss`에 더해
  `first_text_visible`·`first_audio_play` 타임스탬프를 계측해 세션당 지연 요약을 로그로 남긴다.
- 테스트: 파이프라인 조립 함수 단위 테스트(브라우저 없이 검증 가능한 부분), 이벤트 타임라인 스키마.

**제외 (Non-goals)**
- 캐릭터 모션/무대 연출, 공유 카드 UI 통합(T006 산출물 연결은 후속), PWA 매니페스트·푸시,
  배포(§3 hold), 디자인 폴리시(스켈레톤 수준).

## 3. 수용 기준
- [ ] 모바일 뷰포트에서: 탭 1회 → 텍스트 즉시 노출 → 음성 재생 시작 (mock 경로, 로컬)
- [ ] 이벤트 타임라인 로그: `first_text_visible`·`tts_generate_*`·`cache_hit/miss`·`first_audio_play` 기록
- [ ] 같은 seed 재방문 시 cache_hit 경로로 재생 (신규합성 0회)
- [ ] `python3 -m pytest tests/` GREEN (신규 테스트 포함), 키 없는 환경 무영향
- [ ] 실행 방법 1줄이 README 또는 티켓 완료 노트에 기록

## 4. 롤백
`git revert <commit>` — 신규 디렉터리 중심, 기존 엔진 모듈 무변경(호출만).
