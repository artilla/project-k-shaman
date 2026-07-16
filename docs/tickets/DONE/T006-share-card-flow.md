---
id: T006
title: 정적 부적 공유 카드 생성·저장
status: done
priority: P1
safe: true
persona: implementer
estimate: M
depends_on: ["T001", "T002", "T004"]
blocks: []
labels: ["sprint-1", "share-card", "implementer", "mock-flow"]
created: 2026-06-01
spec_ref: docs/ux/screen-ia.md#s5--결과-카드
---

# T006 — 정적 부적 공유 카드 생성·저장

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

`fortune-schema.v1.1` 샘플 운세를 입력으로 받아 **홍연 정적 부적 공유 카드 파일**을 생성·저장하는 첫 구현이 생긴다. 이후 프론트 S5/S6, `/api/share-card`, Web Share API가 이 결과물을 기준으로 붙을 수 있다.

## 2. 변경 범위 (Scope)

**포함**
- 신규 구현 `fortune-engine/share_card.py`
  - `fortune-engine/fortune-samples.v1.1.json`의 유효 샘플 1건을 받아 정적 공유 카드 **SVG 파일**을 생성한다.
  - CLI 예시: `python fortune-engine/share_card.py --sample h_love_001 --nickname 손님 --out /tmp/h_love_001.svg`
  - 출력 파일명 기본값은 `share-{seed_hash}.svg`처럼 deterministic 해야 한다.
- 신규 테스트 `tests/test_share_card.py`
  - 샘플 기반 렌더링 스모크.
  - 카드 필수 필드 포함 검증.
  - 개인정보 비노출 검증.
  - lucky.color 팔레트 검증.
  - CLI 저장 검증.
- 공유 카드 내용은 다음 정본에 grounded:
  - `docs/ux/screen-ia.md` S5/S6, §4.1–§4.2
  - `docs/product/character-sheet-hongyeon.md` §6
  - `docs/planning/Plan.md` §7 `POST /api/share-card`, §12 Sprint 4, §13 리뷰 질문
  - `docs/planning/today-shindang-service-plan-v3.md` §16·§17

**제외**
- 프론트엔드 툴체인 도입, PWA 화면 구현, Web Share API, 로컬 앨범 저장 권한 처리.
- `/api/share-card` 서버 API, CDN/Object Storage 업로드, QR/딥링크 발급.
- PNG 래스터라이즈, 동영상 공유, 캐릭터 일러스트 생성.
- 실제 개인정보 저장·조회. 이 티켓은 mock fortune JSON과 명시 nickname 문자열만 사용한다.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] `fortune-engine/share_card.py`가 stdlib 중심으로 동작하며 네트워크·유료 API를 호출하지 않는다. 새 의존성이 정말 필요하면 `requirements.txt`와 테스트를 함께 갱신하고 근거를 남긴다.
- [ ] 카드 렌더 함수는 `fortune-schema.v1.1` 객체를 입력받아 SVG 문자열 또는 파일을 생성한다.
- [ ] SVG에는 최소 다음 정보가 포함된다:
  - 서비스명 `오늘신당`
  - 캐릭터명 `홍연`
  - 날짜 `meta.date`
  - 주제 `meta.topic`의 한국어 라벨
  - `summary` 2문장 중 최소 1문장
  - `scores_line`
  - `lucky.color`
  - `lucky.item`
  - `avoid`
  - 선택 입력된 nickname (있을 때만)
- [ ] SVG에는 원본 생년월일·출생시간·profile hash·HMAC·raw birth 관련 문자열을 표시하지 않는다. `seed_hash`는 파일명/내부 식별자 용도는 가능하지만 카드 본문 텍스트에는 표시하지 않는다.
- [ ] lucky.color는 캐릭터 시트 §6의 8개 팔레트 이름만 허용한다: `코랄 핑크`, `진홍`, `자수정 보라`, `청록`, `살구색`, `금빛`, `먹색`, `은백`. 알 수 없는 색상은 조용히 대체하지 말고 명시적으로 실패한다.
- [ ] 생성물은 모바일 공유 카드에 맞는 고정 뷰박스(예: 1080×1350 또는 1080×1920)를 갖고, `lucky.color`가 강조색으로 반영된다.
- [ ] CLI는 `--sample <seed_hash>`와 `--out <path>`를 지원하고, 성공 시 파일을 저장한 뒤 0 exit 한다.
- [ ] `tests/test_share_card.py`가 위 조건을 자동 검증하며 `./ralph/scripts/run_checks.sh`가 0 exit 한다.

## 4. 테스트 계획

```bash
pytest tests/test_share_card.py
./ralph/scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git rm fortune-engine/share_card.py tests/test_share_card.py
```

새 의존성을 추가했다면 `requirements.txt` 변경도 같은 revert에 포함한다.

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 프론트/공유 API까지 범위가 커짐 | M | M | 본 티켓은 SVG 파일 생성·저장까지만. Web Share/API/CDN은 후속 티켓 |
| 개인정보가 카드에 노출됨 | M | H | 테스트에서 birth/profile/HMAC 관련 문자열 비노출 검증 |
| lucky.color 팔레트가 시트와 어긋남 | M | M | 8개 팔레트 이름을 테스트로 고정 |
| 이미지 렌더링 품질 논쟁으로 지연 | M | L | MVP는 정적 SVG 구조·필드·팔레트 검증까지만. 시각 QA/PNG는 후속 |

## 7. 메모 / 결정 이력

- T004 IA의 S5/S6는 정적 이미지 공유를 요구하지만, 현재 프로젝트에는 프론트 툴체인이 없다. 따라서 첫 implementer 티켓은 Python 기반 SVG 생성기로 자른다.
- PNG 래스터화가 필요해지면 Pillow/Cairo/브라우저 캡처 중 하나를 별도 티켓에서 결정한다.
- 분석 이벤트 `share_card_create`, `share_click`, `share_fail`은 T004에 정의돼 있다. 본 티켓은 이벤트 송신 구현이 아니라 이벤트에 필요한 카드 생성 산출물을 제공한다.
