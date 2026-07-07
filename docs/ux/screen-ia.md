# 모바일 PWA 화면 IA — 오늘신당

> **Sprint 1 산출물 (T004)** — 화면 구현 implementer 티켓들의 골격 기준 문서.  
> 근거: `Plan.md` §4(핵심 흐름·백로그)·§5(Analytics), `today-shindang-service-plan-v3.md` §11(재생 UX·autoplay 금지)·§12(개인정보), `fortune-engine/character-sheet-hongyeon.md` §6(아바타 상태), `fortune-engine/fortune-samples.v1.1.json`(mock 데이터).

---

## 1. 화면 인벤토리 + 전이도

### 1.1 화면 목록 (Plan.md §4 9단계 매핑)

| 화면 ID | 화면 이름 | Plan.md §4 단계 | 설명 |
|---|---|---|---|
| S0 | 온보딩 | 진입 전제 (1단계 이전) | 서비스 소개·시작 CTA |
| S1 | 무당 선택 | Step 1 — 오늘의 무당 선택 | 홍연 고정(베타 단독), 선택 확인 UI |
| S2 | 입력 | Step 2 — 닉네임·생년월일·출생시간 | 3개 입력 필드 |
| S3 | 주제 선택 | Step 3 — 관심 주제 | 총운·연애·금전·일/학업·인간관계 |
| S4 | 캐릭터 stage | Steps 4–7 — 등장·API·텍스트·오디오 | 핵심 경험 화면 |
| S5 | 결과 카드 | Step 8 — 저장·공유 + Step 9 — streak | 부적 카드 저장·공유 CTA + 재방문 유도 |
| S6 | 공유 | Step 8 — 이미지 공유 | 정적 부적 카드 이미지 생성·외부 공유 |

### 1.2 화면 전이도

```
S0 온보딩
  │ (시작 탭)                                ← fortune_start 이벤트
  ▼
S1 무당 선택  ← 홍연 1종 고정 (베타 단독)
  │ (무당 확인 탭)                           ← character_select 이벤트
  ▼
S2 입력  (닉네임 · 생년월일 · 출생시간)
  │ (다음)
  ▼
S3 주제 선택  (총운 · 연애 · 금전 · 일/학업 · 인간관계)
  │ (주제 탭 → API 요청 시작)
  ▼
S4 캐릭터 stage
  ├─ phase A: 캐릭터 등장 애니메이션     [아바타: greeting]
  ├─ phase B: API 응답 대기 (로딩)        [아바타: idle]
  ├─ phase C: 운세 텍스트 즉시 노출       [아바타: idle]   ← autoplay 없음
  └─ phase D: "듣기" 탭 → 오디오 재생    [아바타: greeting → speaking → blessing]
       │ (결과 카드 보기)
       ▼
S5 결과 카드
  ├─ (저장)        → 로컬 앨범 저장
  ├─ (공유)        → S6 공유           ← share_card_create 이벤트
  └─ (내일 알림)  → 시스템 알림 동의  ← push_permission_prompt 이벤트
       ▼
S6 공유  (정적 부적 카드 이미지 · 외부 앱 공유)  ← share_click 이벤트
```

> **불변식**: 홍연은 베타 유일 캐릭터다. S1에서 다캐릭터 선택 UI는 표시하지 않는다. (Plan.md §2, v3 §7)  
> **불변식**: 공유 포맷은 **정적 이미지**만. 동영상 공유는 후속이다. (Plan.md §2·§3)

---

## 2. 화면별 와이어프레임 수준 명세

### S0 — 온보딩

**목적**: 서비스 가치 1줄 전달 + 시작 CTA.

**핵심 요소**:
- 브랜드 로고 / 서비스명 "오늘신당"
- 슬로건: "오늘의 기운을 무대 위에서 듣다"
- CTA 버튼: "운세 보러 가기" (primary)
- 개인정보 처리 요약 링크 (footer)

**상태**:

| 상태 | 설명 |
|---|---|
| default | 슬로건 + CTA 버튼 표시 |
| loading | 없음 (정적 화면) |
| error | 없음 |

**이벤트**: `fortune_start` — CTA 버튼 탭 시

---

### S1 — 무당 선택

**목적**: 오늘의 무당 확인 (베타는 홍연 고정).

**핵심 요소**:
- 헤더: "오늘의 무당을 선택하세요"
- 홍연 캐릭터 카드 (이미지 + 이름 + 강점 소개 1줄: "연애운·자신감·대인관계")
- "선택" 버튼 (홍연 카드 고정)

**상태**:

| 상태 | 설명 |
|---|---|
| default | 홍연 카드 1종, 선택 버튼 활성 |
| loading | 없음 |
| error | 없음 |

**이벤트**: `character_select` — 선택 탭 시 (`character_id: "hongyeon"`)

> 소월·강림 카드는 베타에 표시하지 않는다. v1.1 이후 추가.

---

### S2 — 입력

**목적**: 닉네임·생년월일·출생시간 수집.

**핵심 요소**:
- 닉네임 텍스트 필드 (최대 10자, 필수)
- 생년월일 날짜 피커 (년·월·일, 필수)
- 출생시간 선택 (조·인·묘…시 또는 "모름", 선택)
- "다음" 버튼
- 개인정보 동의 배너 (하단 고정): "입력 정보는 오늘의 운세 생성에만 사용됩니다. [상세 보기]"

**개인정보 UX** (v3 §12):
- 비회원 로컬 우선: 입력 정보는 기기 로컬 스토리지에 먼저 저장 (서버 미전송).
- **원본 생년월일·출생시간은 화면·공유 카드 어디에도 노출하지 않는다**. 캐시 키는 서버 HMAC 해시만 사용.
- 동의 없는 비회원은 서버 개인화·streak·결제 비활성.

**상태**:

| 상태 | 설명 |
|---|---|
| default (빈 폼) | 플레이스홀더 표시, "다음" 버튼 비활성 |
| 입력 중 | 필수 필드 채워지면 "다음" 버튼 활성 |
| error | 닉네임 초과·유효하지 않은 날짜 → inline 오류 메시지 |

---

### S3 — 주제 선택

**목적**: 관심 주제 선택 후 API 요청 트리거.

**핵심 요소**:
- 주제 카드 5개: 총운 · 연애 · 금전 · 일/학업 · 인간관계
- 선택 시 강조 표시 (1개 고정 선택)
- "운세 보기" CTA 버튼

**상태**:

| 상태 | 설명 |
|---|---|
| default | 카드 5개 나열, 선택 없음, "운세 보기" 버튼 비활성 |
| 선택 완료 | 1개 카드 강조 + "운세 보기" 버튼 활성 |
| error | 없음 (선택 없이 탭 불가) |

**이벤트**: "운세 보기" 탭 → API 요청 시작 → S4 전환.

---

### S4 — 캐릭터 stage

**목적**: 캐릭터 등장 → 운세 텍스트 노출 → 오디오 재생. 핵심 경험 화면.

#### phase A — 등장 애니메이션

**핵심 요소**:
- 홍연 아바타 등장 애니메이션
- 배경: 무대 감성 (단청/조명 콘셉트)

**아바타 상태**: `greeting`

#### phase B — API 로딩

**핵심 요소**:
- 홍연 아바타 idle 루프
- 로딩 텍스트: "홍연이 오늘의 기운을 읽고 있어요…" (또는 스켈레톤 UI)
- 진행 인디케이터 (스피너 또는 프로그레스 바)

**아바타 상태**: `idle`

**상태**:

| 상태 | 설명 |
|---|---|
| loading | idle 아바타 + 로딩 인디케이터 |
| error | "운세를 불러오지 못했어요. 다시 시도해주세요." + 재시도 버튼 → `fortune_fail` 이벤트 |

#### phase C — 텍스트 노출 (음성 완성 대기 없이 즉시)

> **핵심 UX 규칙**: 운세 텍스트는 API 응답 즉시 표시한다. 음성 완성을 기다리지 않는다. (v3 §11.1)  
> **autoplay 금지**: 이 phase에서 오디오 자동 재생 없음. 사용자가 "듣기"를 탭해야 AudioContext가 열린다. (v3 §11.2)

**핵심 요소**:
- 운세 텍스트 카드:
  - `summary` (2문장 요약) — 상단 강조
  - `scores_line` (점수 흐름 1문장, 홍연 말투)
  - `scores` 바 그래프 (love·money·work·relationship·condition, 0–100)
  - `lucky.color` 행운 색상 표시 (색상 블록 + 텍스트)
  - `lucky.item` 행운 아이템 텍스트
  - `avoid` 피해야 할 행동 텍스트
- **"듣기" 탭 버튼** (primary, 항상 표시)
- 홍연 아바타 idle 루프

**아바타 상태**: `idle`

#### phase D — 오디오 재생

> §3 오디오 재생 UX 상세 참조.

**플레이어 상태 전이 요약**:

| 상태 | 트리거 | 아바타 동작 |
|---|---|---|
| `idle` | 텍스트 노출 완료 (phase C) | 가볍게 움직이는 루프 |
| `greeting` | "듣기" 탭 + AudioContext 오픈 | 등장·에너지 있는 동작 |
| `speaking` | presynth greeting 완료 → 본문 시작 | 음량 기반 입 모양 동기화 |
| `blessing` | 본문 완료 → blessing 세그먼트 | 축원 동작 |

**핵심 요소**:
- 플레이어 UI: 재생/일시정지 버튼, 진행바, 상태 레이블
- "다시 듣기" 버튼 (재생 실패 폴백)
- "결과 카드 보기" 버튼 (blessing 완료 후 또는 언제든 접근 가능)

**FSM 상태 ↔ 에셋 파일 매핑** (ADR-0002, T023 `docs/assets/hongyeon-promptpack.md`):

> 에셋 부재 시 현재 플레이스홀더(수정구슬)로 폴백 — 에셋은 진행을 막지 않는다 (ADR-0002 폴백 불변식, T024).

| FSM 상태 | 에셋 파일 | 비고 |
|---|---|---|
| `greeting` | `hongyeon-greeting.webp` | phase A 등장 애니메이션과 phase D 재생 시작 시 재사용 |
| `idle` | `hongyeon-idle.webp` | phase B·C 대기/텍스트 노출 구간 |
| `speaking` | `hongyeon-speaking.webp` | 음량 기반 입 모양 동기화는 근사(WebAudio AnalyserNode → 글로우/스케일 펄스) — 립싱크 아님 |
| `blessing` | `hongyeon-blessing.webp` | 본문 완료 → blessing 세그먼트 |
| (S5/S6 결과·공유 카드 전용) | `hongyeon-share-card.webp` | FSM 상태가 아닌 정적 카드 구성 요소 — §2 S5·S6 참조 |

---

### S5 — 결과 카드

**목적**: 운세 결과 전체 요약 + 저장·공유 CTA + 재방문 유도.

**핵심 요소**:
- 부적 카드 이미지 프리뷰 (정적 이미지 — MVP)
  - 구성: 날짜 · 주제 · `lucky.color` 강조색 · `lucky.item` · 홍연 캐릭터 아이콘 · "오늘신당" 워터마크
  - **닉네임은 카드 이미지에 표시 가능** (음성 본문과 달리 이미지·화면은 허용. v3 §9)
  - **원본 생년월일은 표시하지 않는다**
- "저장" 버튼 (로컬 앨범)
- "공유" 버튼 → S6
- 운세 텍스트 요약 (summary · scores · lucky · avoid)
- 재방문 유도 섹션: streak 표시 + "내일 알림 받기" CTA (v1.1 이후 완전 활성화)

**상태**:

| 상태 | 설명 |
|---|---|
| default | 카드 프리뷰 + 저장/공유 버튼 |
| loading | 카드 이미지 생성 중 스켈레톤 |
| error | "카드를 만들지 못했어요. 다시 시도해주세요." + 재시도 버튼 |

**이벤트**: `share_card_create` — 공유 버튼 탭 시

---

### S6 — 공유

**목적**: 정적 부적 카드 이미지를 외부 앱(SNS 등)으로 공유.

**핵심 요소**:
- 공유 이미지 최종 프리뷰
- 시스템 공유 시트 (Web Share API 또는 네이티브 폴백)
- "링크 복사" 버튼

**상태**:

| 상태 | 설명 |
|---|---|
| default | 공유 이미지 + 공유 버튼 |
| error | "공유에 실패했어요." + 재시도 버튼 → `share_fail` 이벤트 |

**이벤트**: `share_click` — 공유 버튼 탭 시

---

## 3. 오디오 재생 UX 상세

### 3.1 원칙 (autoplay 금지 — v3 §11.2)

1. **텍스트 먼저**: `summary`·`scores`·`scores_line`·`lucky`·`avoid`는 API 응답 즉시 화면에 표시. 음성 완성 대기 없음.
2. **사용자 제스처 필요**: "듣기" 탭으로만 AudioContext 열기 가능. 자동 재생 없음.
3. **presynth 우선**: 탭 직후 사전합성 인사(greeting) 세그먼트가 즉시 재생됨. CDN 보관 파일이므로 cache miss와 무관하게 ≤3초 보장. (v3 §11.1)
4. **본문 이어 붙이기**: 개인화 본문 음성은 cache hit 시 즉시, miss 시 background 합성 완료 후 자연스럽게 이어진다.

### 3.2 narration 세그먼트 순서 (서버 조립 — character-sheet §4)

| 순서 | 세그먼트 | 출처 | 아바타 상태 |
|---|---|---|---|
| 0 | greeting | presynth (CDN) | greeting |
| 1 | summary | LLM 생성 | speaking |
| 2 | scores_line | LLM 생성 | speaking |
| 3 | advice | LLM 생성 | speaking |
| 4 | lucky | LLM 생성 | speaking |
| 5 | avoid | LLM 생성 | speaking |
| 6 | blessing | presynth (CDN) | blessing |
| 7 | ending | presynth (CDN) | blessing |

> **닉네임 불삽입**: summary·scores_line·advice·avoid·blessing 어디에도 닉네임을 넣지 않는다. 음성에서 호칭은 "오늘의 손님"으로 고정. (character-sheet §2, v3 §9)

### 3.3 플레이어 상태 전이 (FSM)

```
[idle] ──── "듣기" 탭 + AudioContext 오픈 ────▶ [greeting]
                                                      │
                                          presynth greeting 재생 완료
                                                      │
                                                      ▼
                                                [speaking]  ←── 음량 기반 입 모양 동기화
                                                      │
                                          blessing 세그먼트 시작
                                                      │
                                                      ▼
                                                [blessing]
                                                      │
                                          ending 세그먼트 완료
                                                      │
                                                      ▼
                                               (idle 복귀 또는 종료)
```

**오류 분기**: 재생 실패(iOS 무음 정책·세션 중단 등) → 현재 상태 유지 + "다시 듣기" 버튼 표시 + `tts_play_error` 이벤트.

### 3.4 이벤트 발화 타이밍

| 이벤트 | 발화 시점 |
|---|---|
| `tts_play_start` | "듣기" 탭 직후 (AudioContext 오픈 시도 시) |
| `tts_generate_start` | cache miss 확인 후 합성 시작 시 |
| `tts_generate_complete` | 합성 완료 시 |
| `tts_play_complete` | ending 세그먼트 완료 시 |
| `tts_play_error` | 재생 실패 시 |
| `cache_hit` / `cache_miss` | API 응답 시 캐시 계층별 |

---

## 4. mock 흐름 연결 계획

`fortune-samples.v1.1.json`을 mock 데이터로 사용해 전체 화면 흐름을 연결하는 방법.

### 4.1 mock 데이터 구조 (fortune-schema.v1.1)

결과 화면이 표시할 주요 필드:

| 필드 | 타입 | 화면 표시 위치 |
|---|---|---|
| `summary` | string[] (2문장) | S4 phase C 상단 강조, S5 결과 카드 |
| `scores` | object (love·money·work·relationship·condition) | S4 phase C 바 그래프, S5 |
| `scores_line` | string (1문장) | S4 phase C 텍스트 카드 |
| `lucky.color` | string | S4 phase C, S5 카드 강조색, S6 |
| `lucky.item` | string | S4 phase C, S5 카드 |
| `avoid` | string | S4 phase C, S5 |
| `advice` | string | narration 세그먼트 3번 (오디오 전용) |
| `blessing` | string | narration 세그먼트 6번 (presynth 대체 텍스트) |

샘플 참조: `fortune-samples.v1.1.json` topic `"love"` 첫 번째 항목 (`seed_hash: "h_love_001"`).

### 4.2 mock 흐름 연결 방식

1. S0 → S1 → S2 → S3 입력 완료 후 "운세 보기" 탭 시, 실제 API 대신 mock JSON을 즉시 반환.
2. S4 phase C: mock의 `summary`·`scores`·`scores_line`·`lucky`·`avoid`를 화면에 렌더링.
3. S4 phase D ("듣기" 탭): presynth mp3가 없는 환경에서는 `greeting` 텍스트를 화면에 표시하고 상태를 `greeting → speaking → blessing` 순으로 시뮬레이션.
4. S5: mock의 `lucky.color`로 카드 강조색 결정 (character-sheet §6 팔레트 사용).
5. S6: 공유 이미지는 mock 데이터로 정적 렌더링.

> **구현 분리**: mock 스위치는 환경 변수(`MOCK_FORTUNE=true` 등)로 제어한다. 코드 분기 상세는 implementer 티켓에서 결정.

---

## 5. 분석 이벤트 매핑 (Plan.md §5 Analytics)

| 이벤트 | 발화 화면 / 액션 | 주요 속성 |
|---|---|---|
| `fortune_start` | S0 온보딩 CTA 탭 | — |
| `character_select` | S1 무당 확인 탭 | `character_id: "hongyeon"` |
| `fortune_fail` | S4 API 오류 | `error_code`, `retry_count` |
| `tts_play_start` | S4 "듣기" 탭 | `character_id`, `topic`, `cache_hit` |
| `tts_generate_start` | S4 cache miss → 합성 시작 | `character_id`, `topic` |
| `tts_generate_complete` | S4 합성 완료 | `duration_sec`, `provider` |
| `tts_play_complete` | S4 ending 완료 | `character_id`, `topic`, `duration_sec` |
| `tts_play_error` | S4 재생 실패 | `error_reason` (iOS 무음 등) |
| `share_card_create` | S5 공유 버튼 탭 | `topic`, `lucky_color` |
| `share_click` | S6 외부 앱 공유 탭 | `share_method` (web-share/copy) |
| `share_fail` | S6 공유 실패 | `error_reason` |
| `push_permission_prompt` | S5 알림 CTA 탭 | — |
| `push_permission_grant` | 시스템 알림 허용 | — |
| `cache_hit` / `cache_miss` | S4 API 응답 | `cache_layer` (text/tts) |

---

## 6. 개인정보 UX (v3 §12)

### 6.1 원칙

- **비회원 로컬 우선**: 첫 운세는 회원가입 없이 가능. 입력 정보는 기기 로컬 스토리지에 우선 저장.
- **동의 기반 서버 저장**: 개인화·streak·결제 기능 사용 시 별도 동의 후 서버 저장.
- **원본 생년월일 비노출**: 화면·공유 카드 어디에도 원본 생년월일·출생시간을 표시하지 않는다. 캐시 키는 서버 HMAC 해시만 사용.

### 6.2 화면별 처리

| 화면 | 개인정보 처리 |
|---|---|
| S2 입력 | 로컬 스토리지 우선 저장 (비회원 기본). 동의 수집 배너 표시. |
| S4 캐릭터 stage | 닉네임 화면 텍스트 표시 가능. 음성 narration에 닉네임 미삽입. |
| S5 결과 카드 | 닉네임 카드 이미지 표시 가능. **생년월일 표시 절대 없음.** |
| S6 공유 | 공유 이미지 닉네임 포함 가능. 생년월일 미포함. |

### 6.3 동의 UX 흐름

```
S2 입력 화면 하단 배너:
  "입력 정보는 오늘의 운세 생성에만 사용됩니다."
  [상세 보기] → 개인정보 처리 방침 모달

서버 저장 동의 (streak/결제 진입 시):
  "기기 정보를 서버에 저장해 개인화된 운세를 제공합니다. 동의하시겠어요?"
  [동의] [거부 — 기능 제한 안내]
```

---

## 7. 제약 사항 및 결정 이력

### 7.1 베타 확정 제약 (변경 금지)

| 제약 | 근거 |
|---|---|
| 홍연 1종 단독 — S1 다캐릭터 선택 UI 없음 | Plan.md §2, v3 §7 |
| 정적 부적 카드 — 동영상 공유 없음 | Plan.md §2·§3 |
| 닉네임 음성 본문 미삽입 — "오늘의 손님" 고정 | character-sheet §2, v3 §9 |
| autoplay 금지 — "듣기" 탭으로 AudioContext 열기 | v3 §11.2 |
| 원본 생년월일 화면·카드 비노출 | v3 §12 |

### 7.2 Sprint 1 범위 밖 (후속 티켓)

- 프론트엔드 툴체인 확정 (Next.js vs Vite + Tailwind 등)
- 코드 스캐폴딩 및 실제 화면 구현 (implementer 티켓)
- streak 완전 활성화 (v1.1)
- 내일 알림 (v1.1)
- TTS 음성 선정 (`T005-tts-voice-selection` 후보)
- 공유 카드 상세 흐름 (`T006-share-card-flow` 후보)

---

*참조: `Plan.md` §4·§5, `today-shindang-service-plan-v3.md` §11·§12, `fortune-engine/character-sheet-hongyeon.md` §4·§6, `fortune-engine/fortune-samples.v1.1.json`*
