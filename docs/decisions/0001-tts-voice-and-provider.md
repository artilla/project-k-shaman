---
id: ADR-0001
title: TTS 보이스·프로바이더 선정 (베타)
status: accepted
date: 2026-06-01
deciders: ["이훈"]
ticket: T005
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
depends_on: ["T002"]
---

# ADR-0001 — TTS 보이스·프로바이더 선정 (베타)

> **범위 명확화**: 본 ADR은 "어떤 TTS 프로바이더와 음색으로 합성할지"를 결정한다.  
> narration 조립 순서(greeting → summary → scores_line → … → ending)는  
> `fortune-engine/tts-ab-kit/listening-decision-report.md`에서 **"scores_line 중간안"으로 이미 결정 완료**됐다.  
> 두 결정은 독립이며 혼동하지 않는다.

---

## 1. 컨텍스트

오늘신당 베타는 홍연 캐릭터의 운세를 **45–60초 음성(TTS)으로 전달**하는 것이 핵심 차별점이다.  
TTS 프로바이더·음색을 선정하지 않으면 어댑터 구현·presynth 합성·단위 경제 확정 모두 진행할 수 없다.

### 결정 제약 조건

| 조건 | 기준 | 출처 |
|---|---|---|
| 한국어 품질 | 홍연 캐릭터 시트 §4 톤 부합 — 밝고 리듬감, 신비롭지만 무섭지 않게 | character-sheet-hongyeon.md §4 |
| 원가 | cache miss 신규합성 기여분 ≤ $0.01/세션 목표 | v3 §13, Plan.md §10 |
| 지연 | 45–60초 narration 합성 속도 수용 가능 | Plan.md §2, v3 §11.1 |
| 라이선스 | 상업적 서비스 운영 허용 | 공개 ToS |
| 커스터마이즈 | 베타: 기본 제공 음색만 사용. 커스텀 보이스 계약은 베타 지표 이후 | Plan.md §2·§3 |

### 홍연 음성 디렉션 — 톤 적합성 평가 기준 (캐릭터 시트 §4)

| 파라미터 | 홍연 요구사항 |
|---|---|
| 기본 톤 | 밝고 리듬감 있는. 신비롭지만 무섭지 않게. 화려하지만 과하지 않게. |
| 감정 | `bright` 기본. 강점 영역(연애운·자신감·대인관계) → `bright + energetic`. |
| 속도 | 1.0x 기준. 강조 구간 약간 느리게. |
| 목표 길이 | 45–60초 |
| 호칭 제약 | 닉네임 음성 삽입 금지 → 닉네임 없이도 몰입감 있는 음색 필요 |

---

## 2. 후보 비교

> **기준**: 공식 공개 자료 확인일 2026-06-01, 사내 실측일 2026-05-22.  
> 불확실값은 `(확인 필요)` 표기. 가격 확정은 provider usage 로그 기반 실제 청구액으로 교체 필요 (v3 §13 TBD).  
> 참고 공식 자료: [OpenAI gpt-4o-mini-tts 모델 가격](https://developers.openai.com/api/docs/models/gpt-4o-mini-tts), [OpenAI Text to speech guide](https://developers.openai.com/api/docs/guides/text-to-speech), [OpenAI Terms of Use](https://openai.com/policies/terms-of-use/), [Google Cloud TTS pricing](https://cloud.google.com/text-to-speech/pricing), [ElevenLabs pricing](https://elevenlabs.io/pricing), [ElevenLabs models](https://elevenlabs.io/docs/models/).

| 항목 | OpenAI gpt-4o-mini-tts | Google Cloud TTS Neural2 | ElevenLabs Multilingual v2 |
|---|---|---|---|
| **한국어 품질** | 양호 — 다국어 TTS + 5샘플 실청 완료. 단, OpenAI 가이드는 built-in voice가 영어 최적화라고 명시 → 한국어 QA 필요 | 양호 — ko-KR Neural2 전용 모델 | 양호 — 한국어 Multilingual v2 지원 |
| **음색 후보** | coral · sage · nova · alloy 등 | ko-KR-Neural2-A~D 등 복수 | (확인 필요) |
| **원가 (공개가)** | 공식: text input $0.60/1M tokens + audio output $12.00/1M audio tokens. 기존 문서의 `$0.015/min`은 이 토큰 단가의 내부 환산/추정 | Neural2 약 $16/1M자 | 구독/credit 모델. Starter: 30k credits/mo + Commercial License, V2 Multilingual은 1자=1 credit. 세션 원가 별도 환산 필요 |
| **세션 원가 (cache miss 신규합성)** | $0.0078/세션 **사내 추정 실측** (31초, coral, `$0.015/min` 환산). 실제 청구액 재확인 필요 | 약 $0.005–$0.010/세션 (500자 추정) | (확인 필요) |
| **지연** | 스트리밍 지원, 양호 | 저지연, 스트리밍 지원 | 스트리밍 지원 (확인 필요) |
| **라이선스·상업 사용** | Terms of Use 준수 전제 출력물 사용. 합성음 고지 필요 | Google Cloud ToS — 상업 사용 허용 | Starter 이상 Commercial License. 보이스 클로닝은 동의 문서화 필수 |
| **커스텀 가능성** | 고정 음색 세트; 커스텀 보이스 별도 계약 | Custom Voice (엔터프라이즈·샘플 필요) | Instant/Professional 보이스 클로닝 — 성우 동의 필수 |
| **사내 실측 근거** | `tts-ab-results-report.md`, `synthesize_tts.py` (coral 5샘플) | 없음 | 없음 |

---

## 3. 결정

**베타 선정: OpenAI `gpt-4o-mini-tts` + `coral` 음색**

### 선정 근거

1. **실측 데이터 유일**: `synthesize_tts.py`로 coral 음색 5샘플을 합성·청취 완료.  
   31초 신규합성 기준 **$0.0078/miss 실측** — 타 프로바이더는 추정치만 존재 (`tts-ab-results-report.md`).

2. **홍연 톤 적합성 (캐릭터 시트 §4 기준)**:
   - `coral` 음색은 따뜻하고 에너지 있는 특성으로 **"밝고 리듬감 있는"** §4 기본 방향에 부합한다.
   - `bright + energetic` 감정 파라미터를 TTS 호출 파라미터로 매핑 가능하다.
   - 닉네임 없이 "오늘의 손님" 호칭만으로도 몰입감 있는 음색 가능함을 청취에서 확인했다.

3. **원가 투명성**: 공식 가격은 text input $0.60/1M tokens + audio output $12.00/1M audio tokens이고,  
   기존 단위 경제 시뮬레이터는 이를 약 `$0.015/min`으로 환산해 반영했다 (v3 §13).  
   cache hit율 30% 베타 목표 달성 시 블렌디드 원가 허용 범위 유지. 단, 실제 청구액으로 재보정 필요.

4. **합성음 고지 경계 명확**: OpenAI TTS 가이드는 end user에게 AI-generated voice임을 명확히 고지해야 한다고 명시한다.  
   합성음 고지(v3 §18)는 UI에서 별도 표시한다.

5. **어댑터 최소 변경**: `synthesize_tts.py`가 이미 어댑터 패턴으로 구조화되어 있어  
   일반화 비용 낮음. 프로바이더 교체 시 파라미터만 변경하면 된다.

### 베타 범위 명시

> **기본 TTS 음색(`coral`) + 홍연 말투 (fortune-prompt-hongyeon.v1.1.md 지시)**  
>
> 커스텀 보이스 계약(성우 동의·음성권·2차 활용 문서화)은  
> **베타 지표(청취 완료율 ≥60%, DAU 목표) 확인 이후** 판단한다.  
> (Plan.md §2·§3, v3 §10, character-sheet-hongyeon.md §5)

---

## 4. 대안과 기각 이유

### Google Cloud TTS Neural2

- **장점**: 한국어 전용 Neural2 음색 다수 (ko-KR-Neural2-A~D), 안정적 대규모 인프라, 저지연.
- **기각 이유**:
  - 사내 실청 데이터 없음. 홍연 §4 톤 적합성(밝고 리듬감·energetic) 검증 미완료.
  - 음색 선정을 위한 별도 청취 QA 사이클 필요 → 베타 일정 내 추가 작업 발생.
  - 원가 추정치($0.005–$0.010/세션)가 OpenAI와 유의미하게 다르지 않아 교체 유인 낮음.
  - 단위 경제 시뮬레이터가 OpenAI 실측값 기반 → 전환 시 재보정 필요.

### ElevenLabs Multilingual v2

- **장점**: 보이스 클로닝으로 홍연 커스텀 음색 제작 가능, 감정 표현·억양 조절 풍부.
- **기각 이유**:
  - 베타 원가 `(확인 필요)` 상태 — 플랜별 자 수 제한 구조가 DAU 증가 시 예측 어려움.
  - 보이스 클로닝(Instant/Professional)은 성우 동의·계약 필수 → 베타 범위 초과.
  - v3 §10에서 "원가 높음 → 프리미엄/시즌 한정" 후보로 이미 분류됨.
  - 커스텀 보이스 없이 기본 음색만 사용하면 OpenAI 대비 차별점 없음.

---

## 5. 후속 영향

### 즉각 적용 사항

- TTS 어댑터 구현 티켓(후속 implementer)은 `gpt-4o-mini-tts` + `coral`을 **기본값**으로 구현한다.
- `synthesize_tts.py`를 일반화해 provider·model·voice를 파라미터로 받도록 한다 (교체 대비).
- presynth 세그먼트(인사·전환·축원·엔딩)는 `coral` 음색으로 사전 합성·CDN 보관한다.
- TTS 캐시 키 형식 `tts:v1:{provider}:{voice_id}:{script_hash}:{speed}:{emotion}` 그대로 적용 (v3 §11.3).

### 인간 승인 필수 경계 (master-spec §3 hold)

다음 항목은 **본 ADR 결정 범위 밖**이며 master-spec §3에 따라 인간 승인 없이 자율 실행 금지:

| 항목 | 이유 |
|---|---|
| 실제 유료 TTS API 호출·합성 | 비용 발생, 가역성 없음 |
| provider·모델·음색 변경 | 단위 경제·품질 재검증 필요 |
| 커스텀 보이스 계약 (성우 동의·음성권) | 법적 의무 발생 |
| 합성음 고지 UI 내용 변경 | 법무·소비자 보호 영향 |

### 후속 검토 시점

- 베타 지표(청취 완료율 ≥60%, TTS 비용/사용자, DAU) 확인 후 **커스텀 보이스 계약 여부** 재검토.
- provider usage 로그 기반 실제 청구액 확인 후 단위 경제 시뮬레이터 업데이트 (v3 §13 TBD 항목).
- `synthesize_tts.py`의 `TTS_PER_MIN = 0.015`는 공식 과금 단위가 아니라 토큰 단가 기반 내부 환산값임을 후속 구현에서 주석/계산식으로 분리한다.
- 최종 홍연 음색 확정 후 길이·청취 인상도 재측정 필요 (`tts-ab-results-report.md` §5 한계 참조).

### 합성음 고지 의무

v3 §18: AI/TTS 합성음 고지를 서비스 화면 UI에 명시해야 한다. 구현은 별도 티켓.
