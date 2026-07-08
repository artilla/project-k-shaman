# 오늘신당 프로토타입 구현 조사

> 조사일: 2026-07-08 · 대상: claude.ai 디자인 프로젝트 "오늘신당 프로토타입.dc.html"
> 원본 사본: `reference/design-prototype/` (dc.html 2종, support.js, ios-frame.jsx, assets 5종)

## 1. 프로토타입 구조

프로토타입은 디자인 툴 전용 선언적 포맷(.dc.html)으로, `<sc-if>`/`<sc-for>` 템플릿 + `DCLogic` 컴포넌트 클래스(상태·핸들러) 한 쌍으로 구성된다. `support.js`와 `ios-frame.jsx`는 디자인 툴 런타임이므로 **구현에 가져올 필요 없음**. 실제 구현에 필요한 것은 템플릿 구조(마크업·스타일)와 컴포넌트 로직(상태 머신·데이터)이며, 현재 스택(vanilla JS `app.js` + `styles.css`)으로 이식 가능하다.

상태 머신 핵심: `screen`(s0~s5) · `phase`(loading→text, S4 진입 후 1.6s) · `player`(idle→playing→done) · `segIdx`(재생 세그먼트 인덱스) · `sheetOpen` · `toast` · `streak`.

## 2. 화면 플로우 (S0→S6)

| 화면 | 내용 | 핵심 요소 |
|---|---|---|
| S0 온보딩 | 풀블리드 홍연(greeting) + 타이틀 | "운세 보러 가기" 주 CTA, Google/카카오 보조 버튼, "가입 없이 게스트로" 안내문 |
| S1 무당 확인 | 홍연 카드 (idle + breathe 애니메이션) | "베타 단독" 뱃지, 캐릭터 소개 한 줄, 단계 표시 "1 / 4" |
| S2 입력 | 닉네임(≤10자)·생년월일·출생시간(12시진, 선택) | 유효성: 닉네임+생년월일 필수 시 버튼 활성, 개인정보 로컬 우선 문구 |
| S3 주제 선택 | 5주제 리스트 (총운/연애/금전/일·학업/인간관계) | 선택 시 금색 보더 하이라이트, 주제별 설명 문구 |
| S4 스테이지 | 원형 아바타(200px, 글로우+브리드) → 로딩 1.6s → 텍스트 카드 → 플레이어 | 아바타 4상태 크로스페이드, 점수 바 5종, 행운 색/아이템, 피하면 좋아요, 세그먼트 라벨 |
| S5 부적 카드 | 공유용 카드 (share-card 에셋 + 행운색 보더) | 이미지 저장, 공유하기, streak("N일 연속 방문"), "내일 알림 받기" |
| S6 공유 시트 | 바텀 시트 (글래스 blur) | 카카오톡/인스타/X/더보기 + 링크 복사, 토스트 피드백 |

단계 인디케이터는 S1~S3에 "n / 4 · 라벨" 형식으로 존재.

## 3. 디자인 시스템

- **팔레트**: 배경 `#0F0A14`, 서피스 `#16101E`, 주색(진홍) `#C9184A`, 강조(금빛) `#F2B705`, 텍스트 `#F5EEFC`, 보라 포인트 `#7B2CBF`. 현재 구현의 연보라(`#e6a0ff`) 버튼 체계를 전면 교체.
- **폰트**: 제목 `Song Myung`(serif), 본문 `Noto Sans KR` — Google Fonts 외부 로드. (오프라인/프라이버시 고려 시 self-host 결정 필요)
- **무대 조명**: radial-gradient 3겹 오버레이 (진홍 상단, 금빛 좌측, 보라 우측) — 토글 가능한 연출.
- **애니메이션 5종**: `ts-breathe`(아바타 3.2s), `ts-glow`(글로우 2.4s), `ts-in`(화면 진입 0.4s), `ts-sheet`(바텀시트 0.3s), `ts-toast`(1.8s).
- **글래스모피즘**: 플레이어 카드와 바텀 시트에만 `backdrop-filter: blur` 절제 적용 (v3 규칙).

## 4. 핵심 인터랙션 상세

**TTS 8세그먼트** — `segments()`가 주제 데이터로 생성:
`greeting(presynth)` → `summary` → `scores_line` → `advice` → `lucky` → `avoid` → `blessing(presynth)` → `ending(presynth)`.
아바타 매핑: greeting→greeting, 본문 4개→speaking, blessing/ending→blessing. 재생 완료 시 blessing 유지 + "결과 카드 보기" 버튼 노출. **presynth 라벨 3개는 서버 사전합성 캐시 대상과 일치** — 현재 서버의 presynth 전략과 정합.

프로토타입은 기기 `speechSynthesis`(ko-KR, rate 1.05, pitch 1.12)를 쓰고 onend 미발화 대비 `text.length*180+3000ms` 안전 타이머, 실패 시 `text.length*95ms` 시뮬레이션 폴백을 둔다. **실서비스는 서버 TTS이므로 이 부분은 기존 `pipeline.build_playback_response`의 세그먼트 타임라인으로 대체**하면 되고, 안전 타이머·폴백 패턴만 차용하면 된다.

**진행률**: `done`이면 100, 아니면 `(segIdx/segCount)*100 + 6`.

**Streak**: `ts_proto_streak` localStorage `{count, lastDate}` — 당일 재방문 유지, 하루 차이 +1, 그 외 1로 리셋. 서버 불필요.

**토스트**: 저장/공유/링크복사/알림 예약의 유일한 피드백 채널. 1.9s 자동 소멸.

**공유**: 프로토타입은 전부 목업(토스트만). 실구현 시 링크 복사는 Clipboard API, "더보기"는 Web Share API, 이미지 저장은 기존 `share_card.py` 활용 가능.

## 5. 데이터 계약

- `DATA` 5주제(total/love/money/work/rel)의 스키마: `name, scores{love,money,work,relationship,condition}, scores_line, summary[2], advice, lucky{color,item}, avoid` — **서버 `fortune-samples.v1.1.json`/`fortune-schema.v1.1.json`과 동일 계열**. 서버는 이미 `/api/fortune?topic=` 파라미터를 받는다(`_DEFAULT_TOPIC="total"`). 프론트에 주제 선택 UI만 없다.
- `LUCKY_HEX` 8색 매핑: 코랄 핑크 `#FF7B9C`, 진홍 `#E0355F`, 자수정 보라 `#A46BE0`, 청록 `#2BC4B8`, 살구색 `#FFB88A`, 금빛 `#F2B705`, 먹색 `#8E8496`, 은백 `#E8E6EF`. 행운색 시각화(원형 스와치, 카드 보더 색)에 사용.
- 고정 축원문 `BLESSING`: "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요."
- 프로필 저장 키: `ts_proto_profile` {nickname, birthDate, birthHour} — 현재 구현의 `shindang.profile`과 동일 컨셉(키 이름만 다름).

## 6. 현재 구현과의 갭

**이미 있는 것** (재사용):
아바타 4상태 webp 에셋 (`static/assets/hongyeon-*.webp` — 프로토타입과 동일 파일), 아바타 상태 전환 로직(app.js), S2 입력 폼(12시진 select 동일), 운세 카드(점수/행운/피하기), 세그먼트 플레이어 + 진행 바, 서버 topic 파라미터, share_card.py, 게스트 우선 + 소셜 로그인 스캐폴드, 이벤트 로깅.

**없는 것** (신규 구현):

1. 새 팔레트·폰트·무대 조명 (styles.css 전면 개편)
2. S0 리뉴얼 — 풀블리드 캐릭터 + 그라데이션 오버레이 레이아웃
3. S1 무당 확인 화면 (신규)
4. S3 주제 선택 화면 (신규) + `?topic=` API 연동
5. S4 스테이지형 레이아웃 — 원형 아바타 + 글로우/브리드, 로딩 페이즈, 세그먼트 라벨 노출
6. 단계 인디케이터 (1/4~3/4)
7. S5 부적 카드 + streak + 이미지 저장
8. S6 공유 바텀 시트 + 토스트 시스템
9. "내일 알림 받기" — 프로토타입도 목업. 웹 푸시는 서버 작업 필요라 **범위 보류 권장**

현재 구현은 "프로필 있으면 S0~S3 전부 스킵" 구조인데, 프로토타입은 매 방문 S0부터 시작한다. **재방문 UX 결정 필요**: 프로필 보유 시 S3(주제 선택)로 바로 진입하는 절충안이 자연스럽다 (S1·S2 스킵, 주제는 매일 선택).

## 7. 제안 구현 순서

1. **P1 디자인 시스템** — 팔레트/폰트/조명/애니메이션 키프레임 교체. 기존 화면 그대로 새 옷.
2. **P2 플로우 확장** — S1, S3 신규 + 화면 상태 머신(`screen`) 도입, topic API 연동, 단계 인디케이터.
3. **P3 S4 스테이지** — 원형 아바타 크로스페이드(기존 로직 이식), 로딩 페이즈, 플레이어 개편(세그먼트 라벨·정지·다시 듣기·결과 카드 버튼).
4. **P4 S5 부적 카드** — 카드 UI, LUCKY_HEX, streak(localStorage), 이미지 저장(share_card.py 연동 또는 canvas).
5. **P5 S6 공유** — 바텀 시트, 토스트, 링크 복사(Clipboard), Web Share API.
6. **보류** — 웹 푸시 알림, 다캐릭터(소월·강림) S1 선택 화면(v1.1).

## 8. 리스크·결정 사항

- Google Fonts 의존 (Song Myung) — self-host 여부.
- 매 방문 시작 화면 정책 (위 6절).
- 이미지 저장의 실제 구현 방식: 서버 share_card vs 클라이언트 canvas 렌더.
- 푸시 알림은 목업 유지 여부 (프로토타입도 토스트만 띄움).
- autoplay 금지·텍스트 먼저 원칙은 프로토타입·현재 구현 모두 준수 — 유지.
