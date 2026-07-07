---
id: T025
title: Live2D 아바타 통합(L0 스파이크) — 샘플 모델 + FSM 모션/표정 + 실측 립싱크, 정지컷 폴백 유지
status: done
priority: P1
safe: true               # 로컬 정적 자산 + 프론트 — 과금·외부 전송 없음. 샘플 모델은 Free Material License(소규모 상용 가능).
persona: implementer
estimate: M
depends_on: ["T022", "T024"]
blocks: []
labels: ["feature", "frontend", "character", "live2d"]
created: 2026-07-08
spec_ref: docs/research/live2d-avatar-research.md
---

# T025 — Live2D 아바타 통합 (L0 스파이크)

## 1. 목표 (한 줄)
> 정지컷 아바타를 Live2D 실시간 아바타로 올린다 — 공식 샘플 모델(Mao)로 렌더링·FSM 모션/표정·TTS 립싱크 배선을 완성해, 홍연 전용 모델(L1)이 오면 파일 스왑(L2)만 남게 한다.

## 2. 컨텍스트

- 조사: `docs/research/live2d-avatar-research.md` — EmotiMate(운영자 기존 프로젝트)에 작동하는
  웹 통합(pixi.js 6.5.10 + pixi-live2d-display 0.4.0/cubism4 + AnalyserNode 립싱크)이 있어 이식한다.
- 샘플 모델 Mao: Idle 모션 1·TapBody 3·표정 8종·LipSync 그룹(`ParamMouthOpenY`) — S4 FSM 매핑에 충분.
  라이선스: Live2D Free Material License — 소규모 사업자 상용 가능 (연매출 1천만엔 미만).
- T024 불변식 유지: Live2D 자산/런타임이 없거나 로드 실패하면 기존 정지컷(hongyeon-*.webp) → 플레이스홀더 폴백.

## 3. 변경 범위 (Scope)

**포함**
- `web/static/live2d/` (신규, 벤더링): `live2dcubismcore.min.js`(공식 Core), `pixi.min.js`(6.5.10),
  `cubism4.min.js`(pixi-live2d-display 0.4.0), `models/Mao/` 전체, `README.md`(출처·라이선스 3종 기록).
- `web/static/live2d-avatar.js` (신규): 자기완결 모듈 `window.HongyeonLive2D` —
  ① 모델 존재 기능 감지(없으면 완전 비활성 → 폴백 체계 무간섭), ② 스크립트 순차 지연 로드,
  ③ PIXI Application + 모델 로드(자동 Idle), ④ `setState(state)`: greeting→happy 표정+TapBody,
  speaking→smile 표정, blessing→happy 표정+TapBody, idle→표정 해제, ⑤ `setMouth(v)`:
  `coreModel.setParameterValueById('ParamMouthOpenY', …)` (EmotiMate 패턴).
- `app.js`: `setPlayerState` → `HongyeonLive2D.setState`, 글로우 루프의 음량 level → `setMouth` 공급
  (기존 글로우·정지컷 로직 무변경 — Live2D 활성 시에만 캔버스가 정지컷을 가림).
- `index.html`·`styles.css`: 아바타 영역에 Live2D 캔버스 컨테이너 + 활성 시 확대 스타일.
- `server.py`: 정적 콘텐츠 타입에 `.json`/`.moc3`/`.png` 추가 (모델 서빙).
- 테스트: live2d 정적 서빙(200·타입), index/app 배선 문자열 계약, 폴백 경로 무회귀.

**제외 (Non-goals)**
- 홍연 전용 모델 제작·발주(L1, 운영자 결정), Cubism 5/공식 Web SDK 전환, 모음 감지(ParamMouthForm — 후속),
  모델 히트 인터랙션, PWA·배포(§3 hold).

## 4. 수용 기준
- [x] 페이지 로드 시 Live2D 아바타 렌더 + Idle 모션 (자산 존재 환경)
- [x] 재생 FSM 전이 시 표정/모션 변화 (greeting/speaking/blessing), 재생 음량이 입 열림에 반영
- [x] live2d 자산 제거 환경에서 기존 정지컷/플레이스홀더 폴백 그대로 (전 스위트 GREEN)
- [x] first_text_visible·first_audio_play 지연 무회귀 (Live2D 로드는 탭 경로에 선행하지 않음)
- [x] 벤더 파일 출처·라이선스 3종(Core 고유 라이선스·pixi MIT·모델 Free Material License) 기록

## 5. 롤백
`git revert <commit>` — 정적 자산 + 프론트 배선만. 서버는 콘텐츠 타입 추가뿐.

## 6. 메모 / 결정 이력
- 2026-07-08 기안: 운영자 지시 "홍연 모델 대신 live2d avatar로 구현" — L0을 즉시 실행으로 승격.
