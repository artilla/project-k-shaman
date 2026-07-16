# 홍연 에셋 프롬프트 팩 — 상태 4컷 + 공유카드 1컷 생성 사양 (정본)

> **역할**: 이 문서만 보고 제3자가(사람이든 다른 AI 도구든) 동일 조건의 홍연 후보 세트를 생성할 수 있도록 하는 재현 가능한 생성 사양이다.
> **상위 정본**: `docs/product/character-sheet-hongyeon.md` §6 (비주얼 톤 — 상충 시 그쪽이 우선하며, 이 문서는 §6을 이미지 생성 프롬프트로 구체화한 하위 문서다).
> **결정 근거**: `docs/decisions/0002-character-asset-pipeline.md` (베타 = AI 정지컷 + CSS 연출, 리깅 없음).
> **소비처**: `docs/ux/screen-ia.md` S4 (FSM 상태 ↔ 에셋 매핑), T024 (프론트 통합 — 이 문서의 파일명 규칙을 그대로 소비).
> **범위**: 이 문서는 문서/사양만 정의한다. 실제 이미지 생성·과금 실행은 운영자 세션에서 별도로 수행한다 (T023 §2 Non-goals).

---

## 1. 캐릭터 지문 (모든 컷 공통 — 고정 요소)

아래 요소는 5컷(greeting/idle/speaking/blessing/share-card) 전부에서 **동일하게 유지**되어야 한다. 도구·세션이 바뀌어도 이 문단을 프롬프트 앞부분에 그대로 포함한다.

### 1.1 외형 고정 프롬프트 (영문, 생성 도구 입력용)

```
A young Korean female pop-idol-style shaman character named "Hongyeon" (홍연),
performing on a stage. Fixed identity across all shots:

- Outfit: modern K-pop stage costume reinterpreting traditional Korean
  dancheong (단청) red-and-gold color motifs — NOT a literal hanbok replica,
  NOT any existing idol group's uniform. Deep crimson base with gold trim
  and small dancheong-pattern accents on sleeves/collar.
- Hair: dark hair with a bold crimson/coral streak or ribbon accent,
  styled for stage performance (half-up or ponytail with ornament).
- Signature prop: a small ceremonial bell (방울) tied with red/coral thread,
  worn at the wrist or held — OR a stylized paper talisman (부적) motif as
  an accessory. Pick ONE and keep it consistent across all 5 shots.
- Palette: crimson/dancheong-red as base, accented with ONLY colors from
  this fixed pool — coral pink, deep crimson, amethyst purple, teal,
  apricot, gold, ink black, silver white (character-sheet §6 lucky.color
  pool). Do not introduce colors outside this pool for costume/props.
- Art style: bright, energetic K-pop stage illustration blended with
  Korean traditional aesthetics ("퇴마 판타지" fantasy exorcist-performer,
  NOT literal shamanic ritual imagery). Clean cel-shaded or semi-realistic
  illustration, NOT photorealistic, NOT 3D render.
- Mood: mystical but NOT scary, glamorous but NOT excessive exposure.
  Warm, welcoming stage-performer energy.
```

### 1.2 금지 사항 (모든 컷 공통)

| 금지 | 이유 |
|---|---|
| 실존 아이돌/그룹/특정 IP(KPop Demon Hunters 등)와 유사한 캐릭터명·로고·의상·고유 설정 | 캐릭터 시트 §1 IP 원칙 |
| 실존 인물과 닮은 얼굴·특정 연예인 재현 | 초상권/사칭 리스크 |
| 공포·괴기 연출(뒤틀린 표정, 어두운 배경, 유혈 등) | "무섭지 않게" (시트 §6) |
| 과다 노출·선정적 의상 | 브랜드 톤·안전 기준 |
| 실제 무속 의식 도구를 사실적으로 재현(사칭 인상) | 시트 §1 "가상 퍼포머" 원칙 |

---

## 2. 상태 변주 5컷 사양

공통 지문(§1)에 아래 상태별 포즈·표정·구도 지시를 이어 붙인다. 5컷은 **같은 생성 세션/시드 계열**에서 연속 생성하여 일관성을 높인다 (ADR-0002 §결과).

| 상태 | 파일명 | 포즈/에너지 지시 | 구도 |
|---|---|---|---|
| **greeting** | `hongyeon-greeting.webp` | 등장 포즈. 팔을 살짝 벌리거나 인사하는 동작, 밝은 미소, 무대 등장의 기대감. 시트 §4 "무대 등장 느낌" | 전신 또는 상반신, 정면~약간 측면 |
| **idle** | `hongyeon-idle.webp` | 정면 안정 포즈. 자연스러운 스탠딩, 부드러운 미소, 대기 상태의 편안함 | 상반신 중심, 정면 |
| **speaking** | `hongyeon-speaking.webp` | 발화 제스처. 한 손을 살짝 들어 말하는 듯한 동작, 생기 있는 표정, 입은 살짝 열림(립싱크 목적 아님 — 정지컷) | 상반신, 정면~약간 측면 |
| **blessing** | `hongyeon-blessing.webp` | 축원 포즈. 두 손을 모으거나 소품(방울/부적)을 들어올리는 동작, 따뜻하고 진심 어린 표정 | 상반신 또는 전신, 정면 |
| **share-card** | `hongyeon-share-card.webp` | 공유카드용 상반신. 카드 프레임 안에 장식적으로 배치되기 좋은 정적 포즈(정면, 여백 있는 구도), 표정은 밝고 확신에 찬 느낌 | 상반신, 정면, 좌우 여백 확보(텍스트 오버레이 고려) |

각 상태 프롬프트는 `§1.1 고정 프롬프트 + 위 지시` 형태로 조합한다. 예시(greeting):

```
[§1.1 고정 프롬프트 전문]
Pose: greeting gesture, arms slightly open in welcome, bright warm smile,
anticipation of a stage entrance. Composition: full body or upper body,
front-facing to slight angle. Transparent background.
```

---

## 3. 기술 규격

| 항목 | 값 |
|---|---|
| 배경 | 투명 (PNG 생성 후 WebP 변환 시 알파 채널 유지) |
| 해상도 | 1024×1024 |
| 최종 포맷 | WebP, 장당 ≤150KB |
| 파일명 규칙 | `hongyeon-{state}.webp` (`state` ∈ `greeting`\|`idle`\|`speaking`\|`blessing`\|`share-card`) |
| 배치 경로 | `frontend/public/static/assets/` |
| 매니페스트 | `docs/assets/hongyeon-assets-manifest.md` — 아래 §5 양식 |

변환 순서: 생성 도구 원본(PNG 등) → 투명 배경 확인 → 1024×1024 크롭/리사이즈 → WebP 변환(품질 조정으로 ≤150KB 충족) → 파일명 규칙 적용 → 배치.

---

## 4. 선정 절차 (사람 게이트)

1. **후보 생성**: 상업적 이용이 가능한 생성 도구 **2종 이상**으로 각각 5컷 세트(greeting/idle/speaking/blessing/share-card)를 생성한다. 도구당 최소 1세트, 여러 시드로 복수 후보 세트 생성 가능.
2. **일관성 체크리스트 적용**: 각 후보 세트에 대해 아래 5항목을 채점한다. 5컷 모두 일치해야 해당 세트가 선정 후보로 유효하다.

   | # | 체크 항목 | 기준 |
   |---|---|---|
   | 1 | 의상 | 크림슨/골드 단청 모티프 색상·패턴이 5컷 모두 동일 |
   | 2 | 머리 | 헤어스타일·색상·포인트(리본/스트리크)가 5컷 모두 동일 |
   | 3 | 소품 | 방울 또는 부적(§1.1에서 택1한 것) 형태가 5컷 모두 동일 |
   | 4 | 팔레트 | 강조색이 시트 §6 `lucky.color` 풀 안에서만 사용됨 |
   | 5 | 화풍 | 채색 스타일(셀셰이딩/반실사 등)이 5컷 모두 동일 톤 |

3. **운영자 1회 선정**: 유효 후보 세트 중 운영자가 **1세트를 최종 선정**한다 (사람 게이트 — 자동 루프가 대신하지 않는다).
4. **커밋**: 선정된 세트만 `frontend/public/static/assets/`에 배치하고 커밋한다. 미선정 후보는 저장소에 포함하지 않는다.

---

## 5. 에셋 매니페스트 양식 (`assets-manifest.md`)

선정 세트를 배치할 때 아래 표를 `docs/assets/hongyeon-assets-manifest.md`에 기록한다.

```markdown
# Hongyeon Asset Manifest

| 파일 | 도구 | 모델 | 생성일 | 프롬프트 요약 | 라이선스 근거 |
|---|---|---|---|---|---|
| hongyeon-greeting.webp | (도구명) | (모델명/버전) | YYYY-MM-DD | (§2 표의 상태 지시 요약) | (상업 이용 가능 근거 — 도구 ToS 링크 또는 플랜명) |
| hongyeon-idle.webp | ... | ... | ... | ... | ... |
| hongyeon-speaking.webp | ... | ... | ... | ... | ... |
| hongyeon-blessing.webp | ... | ... | ... | ... | ... |
| hongyeon-share-card.webp | ... | ... | ... | ... | ... |
```

---

## 6. FSM 상태 ↔ 에셋 매핑

`docs/ux/screen-ia.md` §2 S4·§3.3 FSM 정의와의 매핑은 `docs/ux/screen-ia.md` S4 섹션의 표를 정본으로 한다 (본 문서 §2와 상태명 일치 확인됨: greeting/idle/speaking/blessing + share-card는 S5/S6 결과 카드 전용).

---

## 메타 정보

| 항목 | 값 |
|---|---|
| 대상 캐릭터 | 홍연 (베타 단독) |
| 상위 정본 | `docs/product/character-sheet-hongyeon.md` §6 |
| 결정 근거 | `docs/decisions/0002-character-asset-pipeline.md` |
| 소비 티켓 | T024 (프론트 통합) |
| 작성 티켓 | T023 |
| 작성일 | 2026-07-08 |
