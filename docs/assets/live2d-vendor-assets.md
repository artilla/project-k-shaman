# Live2D 벤더 자산 (T025 L0 스파이크)

출처·라이선스 — 상세 조사: `docs/research/live2d-avatar-research.md`

| 파일/디렉터리 | 출처 | 버전 | 라이선스 |
|---|---|---|---|
| `live2dcubismcore.min.js` | Live2D Cubism Core (공식 배포) | Cubism 4 계열 | Live2D Proprietary Software License — SDK 출시 라이선스는 연매출 1천만엔 미만 소규모 사업자 면제 |
| `pixi.min.js` | pixi.js (npm) | 6.5.10 | MIT |
| `cubism4.min.js` | pixi-live2d-display (npm, cubism4 번들) | 0.4.0 | MIT |
| `models/Mao/` | Live2D 공식 샘플 모델 (Mao Niziiro) | Cubism 4 | Live2D Free Material License — 소규모 사업자 상용 이용 가능. **홍연 전용 모델(L1) 도착 시 교체 예정** |

- 벤더링 경로: EmotiMate(운영자 기존 프로젝트) public/live2d 및 node_modules에서 복사 (2026-07-08).
- Cubism 5 모델은 이 조합(0.4.0)에서 비호환 — 홍연 모델 발주 시 "Cubism 4 호환 출력" 명시 (research §5).
