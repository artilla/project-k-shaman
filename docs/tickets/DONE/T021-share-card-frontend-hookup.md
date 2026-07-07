---
id: T021
title: 공유 카드 프론트 연결 — 재생 후 부적 받기(/api/share-card + 다운로드/Web Share) + 공유 이벤트 계측
status: done
priority: P1
safe: true               # mock/실 운세 객체 → 기존 T006 렌더러 재사용, 과금·외부 업로드 없음.
persona: implementer
estimate: M
depends_on: ["T006", "T019"]
blocks: []
labels: ["feature", "frontend", "share-card", "metrics"]
created: 2026-07-07
spec_ref: docs/ux/screen-ia.md#s5--결과-카드
completed_at: 2026-07-07T19:48:34+09:00
started_at: 2026-07-07T19:34:38+09:00
---

# T021 — 공유 카드 프론트 연결 (E2E 베타 데모 마무리 1/2)

## 1. 목표 (한 줄)
> 재생이 끝난 사용자가 "부적 받기" 한 번으로 자기 운세의 부적 카드를 받고, 그 행동이 공유율 지표(베타 임계 8%, v3 §13)로 계측된다 — T006 정적 렌더러가 처음으로 실사용 흐름에 붙는다.

## 2. 컨텍스트

- T006: `share_card.py` — fortune 객체 → 정적 부적 SVG 렌더러 완성 (샘플 입력 기준, deterministic 파일명, 개인정보 비노출 검증 포함). 프론트/API 연결은 명시적으로 제외였다.
- T019/T020: 재생 프론트 + `/api/fortune/today` — 실제 fortune 객체가 세션에 존재한다. 공유 카드가 붙을 지점(S5 결과 카드)이 생겼다.
- v3 §17 계측: `share_initiated`(버튼 탭)·`share_completed`(다운로드/공유 성공) 이벤트가 공유율 분자다.

## 3. 변경 범위 (Scope)

**포함**
- `fortune-engine/web/server.py`: `GET /api/share-card?fortuneId=<id>` — 해당 세션에서 생성된 fortune 객체로
  T006 `render_share_card_svg`를 호출해 `image/svg+xml` 응답. fortuneId→fortune 매핑은 서버 메모리 캐시
  (T020 파이프라인 결과 재사용, 세션 범위·영속화 없음). 존재하지 않는 id는 404. 닉네임 파라미터는
  받지 않는다(개인정보 최소화 — 기본 "손님").
- `fortune-engine/web/static/`: 재생 완료(또는 텍스트 노출) 후 "부적 받기" 버튼 노출 —
  탭 시 `share_initiated` 이벤트 → SVG를 받아 다운로드(`<a download>`), `navigator.share` 지원 시
  Web Share 우선 → 성공 시 `share_completed` 이벤트. 이벤트는 기존 `/api/event` 타임라인에 합류.
- `event_timeline.py`(또는 measure_playback.py): 공유율 요약 — 세션 대비 `share_initiated`/`share_completed`
  비율을 기존 지연 요약에 추가 (베타 임계 8% 대비 표시).
- 테스트: `/api/share-card` 정상/404/SVG 필수 필드, 개인정보 비노출(생년월일 등 원문 부재),
  이벤트 스키마에 share 이벤트 추가 검증. 브라우저 의존 없는 부분만 (T019 관례).

**제외 (Non-goals)**
- PNG 래스터라이즈, CDN/Object Storage 업로드, QR/딥링크, 로컬 앨범 권한 처리(브라우저 기본 다운로드까지),
  카드 디자인 개선(T006 산출물 그대로), PWA·배포 (§3 hold).

## 4. 수용 기준 (Acceptance Criteria)
- [ ] 재생 페이지에서 운세 로드 후 "부적 받기" 버튼 → 유효한 SVG 다운로드 (mock 경로, 로컬)
- [ ] `GET /api/share-card?fortuneId=<유효>` = SVG 200, `<무효>` = 404
- [ ] SVG에 개인정보(생년월일 필드 원문) 부재, lucky.color 팔레트 규칙 유지 (T006 테스트 관례 재사용)
- [ ] `share_initiated`·`share_completed`가 이벤트 타임라인에 기록되고 요약에 공유율 산출
- [ ] `python3 -m pytest tests/` GREEN (키 없는 환경), 기존 재생 경로 무회귀

## 5. 테스트 계획

```bash
python3 -m pytest tests/                      # 키 없는 환경 GREEN
python3 fortune-engine/web/server.py          # 수동: 탭 → 재생 → 부적 받기 → SVG 확인
```

## 6. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 서버 endpoint + 정적 파일 + 요약 확장만. 엔진 모듈 무변경(호출만).
```

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| fortuneId 매핑 메모리 누수 | L | L | 세션 범위 상한(최근 N건) 두고 초과 시 오래된 것 제거 |
| SVG 다운로드 브라우저 편차 | M | L | `<a download>` 기본 + Web Share는 지원 시에만 (기능 감지) |
| 카드에 개인정보 유입 | L | H | T006 비노출 테스트를 실 fortune 경로에 재적용 |

## 8. 운영 노트 (implementer에게)

- `skills/implementer.md` §2.1 헤드리스 실행 모델을 따르라 — 특히 ① 턴=세션(백그라운드 대기·질문 종료 금지),
  ② 긴 검증은 포그라운드 분할. `state/reservations/T021.d`와 run_loop 프로세스는 당신 자신의 세션이다(③).
- 검증은 `python3 -m pytest tests/` 전체가 수 분을 넘지 않으니 포그라운드 한 번이면 된다.
