# Live2D 아바타 도입 조사 — EmotiMate 레퍼런스 + 라이선스/제작 파이프라인

- 날짜: 2026-07-08
- 관련: ADR-0002(캐릭터 에셋 파이프라인 — "리깅은 v1.1 지표 조건부"의 구체화), screen-ia S4(아바타 FSM·립싱크), T024(현 정지컷 통합)
- 레퍼런스 코드: `~/Dev/workspace/web/EmotiMate` (동일 운영자의 기존 프로젝트 — 작동하는 Live2D 웹 통합 보유)

## 1. 결론 요약

**기술 리스크는 사실상 없다** — EmotiMate에 홍연 S4가 요구하는 것(웹 렌더링·TTS 립싱크·표정/모션 전환)의
작동하는 구현이 이미 있고 상당 부분 이식 가능하다. **진짜 병목은 에셋**: 홍연 전용 Live2D 모델(파츠 분해
일러스트 + 리깅)이 없으며, 이것은 외주 2주~2개월/20~50만원 또는 직접 리깅 학습 비용이다. 라이선스는
연매출 1천만엔 미만 소규모 사업자 면제라 베타 단계 비용 0원.

## 2. EmotiMate 구현 분석 (이식 가능 자산)

| 자산 | 위치 | 내용 |
|---|---|---|
| 웹 렌더러 | `emotimate-fe/src/components/live2d/Live2DCanvas.web.tsx` (806줄) | PixiJS + `pixi-live2d-display@0.4.0`(cubism4). Cubism Core를 로컬→jsdelivr→공식 CDN 순 폴백 로드 |
| 립싱크 | `src/hooks/useLipSync.ts` | TTS 오디오 → `AnalyserNode.getByteFrequencyData` → `mouthOpenValue`(0–1) 스토어 → `ParamMouthOpenY` 주입, 진폭 증폭·블렌드 가중치·모음 감지(`ParamMouthForm`) 옵션까지 구현 |
| 상태/모션 | 동일 캔버스 | `model.motion('TapBody')`, `exp3.json` 표정 전환 (Mao 모델 기준 표정 13종) |
| 모델 번들 | `public/live2d/models/` | 공식 샘플 13종 (Haru·Hiyori·Mao·Shizuku 등) — moc3/model3.json/physics/motions/expressions 구조 참고용 |
| 디버그 | `LipSyncDebugOverlay` | 립싱크 파라미터 실시간 관측 |

**홍연 접점**: T020/T024의 재생 경로가 이미 단일 오디오 + `AudioContext`라, useLipSync의 Analyser 신호를
현 "글로우 펄스" 대신 `ParamMouthOpenY`로 꽂으면 S4 명세의 "음량 기반 입 모양 동기화"가 근사가 아닌
실물이 된다. FSM(greeting/speaking/blessing)은 표정(exp3)/모션 트리거로 1:1 매핑된다.

## 3. 라이선스 (2026-07 확인)

| 항목 | 내용 |
|---|---|
| SDK 출시 라이선스 | 배포 시 Publication License 계약 필요하나, **연매출 1,000만엔 미만 소규모 사업자·개인은 면제(무료)** |
| 플랫폼 | 동일 콘텐츠의 iOS/Android/**Web** 병행 배포에 추가 라이선스비 없음 |
| 초과 시 | 매출 규모·과금 모델(일시구매/러닝 로열티)별 플랜 — 유료 전환 시점에 재계약 |
| 공식 샘플 모델 | Free Material License 동의 시 소규모 사업자 **상용 이용 가능** (단 Unity-chan·하츠네 미쿠 제외) — 기술 검증용으로 합법 |
| Cubism Core (웹 런타임) | 공식 배포 채널로 로드 (EmotiMate 폴백 체인 방식) |

## 4. 모델 제작 파이프라인 (병목)

1. **일러스트**: 전신/상반신 1장 — 단 Live2D용은 **PSD 레이어 파츠 분해**(눈·입·머리·팔 분리) 필수.
   현 gpt-image-1 정지컷은 단일 레이어라 그대로 못 쓴다 → 파츠 분해 재작업 또는 분해 전제 재생성 필요.
2. **리깅**: Cubism Editor(FREE 제한판/PRO)에서 메쉬·디포머·물리 설정.
   - 국내 외주 시세: 상반신 기준 **약 20만~50만원**, 기간 **2주~2개월** (크몽 등).
   - 관찰: 단일 이미지에서 파츠 자동 분리하는 "Image2Live2D" 오픈소스 공개 예고(2026) — 성숙 시 비용 급감 후보.
3. **산출물**: `모델.moc3 + model3.json + 텍스처 + physics3/motions/expressions` → 웹 정적 서빙 (수 MB —
   §1.6-② 3초 경로 예산상 **지연 로드 필수**, 정지컷 폴백 유지).

## 5. 기술 선택 주의점

- `pixi-live2d-display@0.4.0`(EmotiMate 사용판)은 **Cubism 4까지** — 리깅 외주 시 "Cubism 4 호환 출력" 명시 필요.
  Cubism 5 모델을 쓰려면 공식 Web SDK 직접 사용 또는 PixiJS v8 계열 엔진(untitled-pixi-live2d-engine 등)으로.
  립싱크 패치 포크(`pixi-live2d-display-lipsyncpatch`)도 존재하나 EmotiMate는 자체 useLipSync로 해결 — 그 방식 권장.
- 현 스켈레톤은 프레임워크 없는 바닐라 JS — PixiJS 도입은 번들 증가. 아바타 영역만 독립 캔버스로 격리하고
  기능 감지 + 정지컷 폴백(T024 불변식)을 유지할 것.

## 6. 홍연 적용 로드맵 제안 (ADR-0002 v1.1 경로 구체화)

| 단계 | 내용 | 비용/기간 | 게이트 |
|---|---|---|---|
| L0 기술 스파이크 | EmotiMate 패턴 이식 + **공식 샘플 모델**로 S4 연결 검증 (FSM→표정/모션, TTS 립싱크) | 0원 / 티켓 1개 | 없음 (safe:true) |
| L1 홍연 모델 발주 | promptpack 기반 파츠 분해 일러스트 + Cubism 4 리깅 외주 | 20~50만원 / 2주+ | **운영자 결정** (베타 지표: 청취 완료율 60%) |
| L2 교체 | 샘플 → 홍연 모델 스왑 (구조 동일, 파일 교체 수준) | 0원 | L1 완료 |

베타(7/20)는 현 정지컷 체계로 가고, L0 스파이크는 병행 가능. L1 발주는 지표 확인 후가 ADR-0002 취지에 부합.

## 출처

- Live2D SDK 출시 라이선스: https://www.live2d.com/en/sdk/license/ · 소규모 판정: https://help.live2d.com/en/sdk/sdk_007/ · 계약 필요 시점: https://help.live2d.com/en/sdk/sdk_001/
- 샘플 모델 약관: https://www.live2d.com/en/learn/sample/model-terms/ · 상용 가능 여부: https://help.live2d.com/en/other/other_16/
- pixi-live2d-display: https://github.com/guansss/pixi-live2d-display · 립싱크 패치: https://www.npmjs.com/package/pixi-live2d-display-lipsyncpatch · PixiJS v8/Cubism5 계열: https://github.com/Untitled-Story/untitled-pixi-live2d-engine
- 공식 립싱크 매뉴얼: https://docs.live2d.com/en/cubism-sdk-manual/lipsync/
- 국내 외주 시세: https://kmong.com/gig/497998 · https://m.dcinside.com/mini/vtuberknowhow/35 · Image2Live2D 예고: https://www.threads.com/@choi.openai/post/DWcB7R6gtvG
