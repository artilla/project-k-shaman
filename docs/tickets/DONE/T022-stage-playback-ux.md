---
id: T022
title: S4 무대 재생 UX 최소판 — 구조화 운세 카드(점수 바·행운) + 플레이어 FSM(듣기/진행/상태) + 무대 스타일
status: done
priority: P1
safe: true               # 프론트 정적 파일 + 서버 응답 필드 노출만 — 과금·키 경로 무변경.
persona: implementer
estimate: M
depends_on: ["T019", "T020", "T021"]
blocks: []
labels: ["feature", "frontend", "playback", "ux"]
created: 2026-07-07
spec_ref: docs/ux/screen-ia.md#s4--캐릭터-stage
---

# T022 — S4 무대 재생 UX 최소판 (E2E 베타 데모 마무리 2/2)

## 1. 목표 (한 줄)
> T019 스켈레톤의 "텍스트 나열 + 재생 중 한 줄"을 screen-ia S4 명세의 최소 구현으로 올린다 — 구조화된 운세 카드, 듣기 플레이어 FSM, 무대 감성 스타일. 1분 공연 데모가 "화면"이 된다.

## 2. 컨텍스트

- T019/T020/T021로 파이프라인·실오디오·공유카드는 완성. 남은 것은 **핵심 경험 화면(S4)의 격차**:
  현재 페이지는 세그먼트 텍스트를 `<p>`로 나열하고 status 한 줄("재생 중")뿐이다.
- 정본: `docs/ux/screen-ia.md` §2 S4 (phase C 텍스트 카드 요소, phase D 플레이어 상태 전이),
  §3 오디오 재생 UX(FSM: idle→greeting→speaking→blessing), `fortune-engine/character-sheet-hongyeon.md`(말투·팔레트).
- **캐릭터 모션/일러스트 에셋은 없다** — 아바타는 정적 플레이스홀더(이모지/도형) + 상태 레이블 +
  CSS 수준 애니메이션까지만. 리치 모션은 후속(§1.5 non-goal 경계 준수).

## 3. 변경 범위 (Scope)

**포함**
- `fortune-engine/web/static/` (index.html·app.js·styles.css):
  - **phase C 텍스트 카드**: `summary` 상단 강조, `scores_line`, `scores` 5종 바 그래프(0–100),
    `lucky.color` 색상 블록+텍스트, `lucky.item`, `avoid` — API 응답의 fortune 객체 필드 사용.
  - **플레이어 FSM**: idle → greeting("듣기" 탭, AudioContext 오픈) → speaking(세그먼트 재생) →
    blessing(마지막 세그먼트) 상태를 상태 레이블 + 아바타 플레이스홀더 CSS 상태로 표현.
    재생/일시정지 버튼, 진행바(오디오 currentTime 기반), "다시 듣기" 폴백 유지.
  - **무대 스타일**: 어두운 무대 배경 + 단청/조명 감성 그라디언트, 홍연 팔레트(character-sheet §6)
    — CSS만, 이미지 에셋 신규 도입 없음.
  - 기존 계약 유지: 텍스트 먼저(v3 §11.1), autoplay 금지(§11.2), 이벤트 훅(first_text_visible·
    first_audio_play)·부적 받기(T021) 무회귀.
- `fortune-engine/web/server.py`: `/api/fortune/today` 응답에 카드에 필요한 필드(scores·scores_line·
  lucky·avoid·summary)가 없다면 노출 (fortune 객체에 이미 존재 — 통과만).
- 테스트: 서버 응답 필드 계약, 정적 파일에 카드 요소/플레이어 요소 존재(문자열 수준),
  이벤트 무회귀. 브라우저 렌더링 자체는 수동 확인 (T019 관례).

**제외 (Non-goals)**
- 캐릭터 일러스트/모션 에셋 제작, 립싱크(음량 기반 입 모양), S0–S3 온보딩/입력 화면,
  PWA·푸시·배포(§3 hold), 세그먼트별 오디오 분할 재생(현재 단일 오디오 유지).

## 4. 수용 기준 (Acceptance Criteria)
- [ ] 탭 → 텍스트 카드: summary 강조 + 점수 바 5종 + lucky 색상/아이템 + avoid 표시 (mock 경로, 로컬)
- [ ] "듣기" 재생 중 상태 전이 표시: greeting→speaking→blessing (레이블 or 아바타 상태 클래스), 진행바 동작
- [ ] 재생/일시정지·다시 듣기 동작, 부적 받기(T021)·이벤트 훅 무회귀
- [ ] `/api/fortune/today` 응답에 카드 필드 존재 (테스트로 계약 고정)
- [ ] `python3 -m pytest tests/` GREEN (키 없는 환경)

## 5. 테스트 계획

```bash
python3 -m pytest tests/                      # 키 없는 환경 GREEN
python3 fortune-engine/web/server.py          # 수동: 탭 → 카드 → 듣기 → 상태 전이/진행바 확인
```

## 6. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 정적 파일 + 서버 필드 노출만. 엔진 무변경.
```

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| FSM 전이가 실제 오디오 타이밍과 어긋남 | M | L | 세그먼트 타이밍은 근사(재생 진행률 기반), 데모 수준 허용 |
| 카드 필드 누락 fortune 변형 | L | M | 서버 응답 계약 테스트로 고정 |
| 스타일 변경이 기존 훅 셀렉터 파괴 | L | M | 기존 id/이벤트 경로 유지 단언 테스트 |

## 8. 운영 노트 (implementer에게)

- `skills/implementer.md` §2.1 헤드리스 실행 모델 준수 — 턴=세션(백그라운드 대기·질문 종료 금지),
  긴 검증은 포그라운드 분할. `state/reservations/T022.d`·run_loop 프로세스는 당신 자신의 세션.
- 디자인 판단이 갈리면 screen-ia.md S4를 정본으로, 그 밖은 가장 보수적인 선택으로 진행하고 메모에 남겨라.
