# Hongyeon Asset Manifest

생성 사양: `docs/assets/hongyeon-promptpack.md` (T023) · 결정: `docs/decisions/0002-character-asset-pipeline.md`

| 파일 | 도구 | 모델 | 생성일 | 프롬프트 요약 | 라이선스 근거 |
|---|---|---|---|---|---|
| hongyeon-greeting.webp | OpenAI Images API | gpt-image-1 (quality=medium) | 2026-07-08 | §1.1 지문 + greeting(환영 포즈·팔 벌림·밝은 미소) | OpenAI 서비스 약관 — API 생성물 상업 이용 가능(출력물 권리 사용자 귀속) |
| hongyeon-idle.webp | OpenAI Images API | gpt-image-1 (quality=medium) | 2026-07-08 | §1.1 지문 + idle(정면 안정·부드러운 미소) | 상동 |
| hongyeon-speaking.webp | OpenAI Images API | gpt-image-1 (quality=medium) | 2026-07-08 | §1.1 지문 + speaking(발화 제스처·입 살짝 열림) | 상동 |
| hongyeon-blessing.webp | OpenAI Images API | gpt-image-1 (quality=medium) | 2026-07-08 | §1.1 지문 + blessing(축원 포즈·방울) | 상동 |
| hongyeon-share-card.webp | OpenAI Images API | gpt-image-1 (quality=medium) | 2026-07-08 | §1.1 지문 + share-card(정면 확신 포즈·여백) | 상동 |

## 생성·선정 기록 (2026-07-08)

- 파이프라인: gpt-image-1 → 그린 스크린(#00FF00) 프롬프트 → PIL 크로마키+디스필 → 1024 WebP
  (스크립트: `state/assets-gen/{gen,key}.py`, gitignore 영역 — 프롬프트 원문은 promptpack §1.1과 스크립트에 동일 유지).
- 시행착오: ① transparent 파라미터 단독으로는 배경 글로우를 그림 → 플랫 단색 지시로 전환,
  ② 마젠타 지정 시 크림슨으로 이탈 → 순녹 배경 + 캐릭터 녹색/청록 금지로 확정,
  ③ greeting 1차본에 글자 아티팩트 → "NO text" 지문 추가 후 재생성.
- 일관성 체크리스트(promptpack §4): 의상 톤·머리(리본+크림슨 스트리크)·소품(방울)·팔레트·화풍 5/5 —
  트림 패턴의 컷별 미세 변주는 200px 아바타 표시 크기에서 허용 판정.
- 편차 기록: blessing·speaking 파일이 규격(≤150KB)을 13~20KB 초과 (q=34에서도 경계 복잡도로 미달성) —
  로컬 데모 영향 없음, 배포 전 재압축 후보.
- 선정: 운영자 위임("알아서 생성") 하에 Claude가 체크리스트 기준 선정, 스크린샷 검수 이력은 세션 기록 참조.
- 비용: 이미지 8회 생성(시행착오 포함) × quality medium ≈ $0.3 내외 — T018/T020 승인 한도 관행(≤$1) 내.
