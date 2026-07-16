# LLM 입력/출력 토큰 최적화 리포트 v1

측정일: 2026-05-22
대상: `docs/prompts/fortune-prompt-hongyeon.v1.md`, `contracts/fortune/fortune-samples.v1.json` 15개
방법: 실제 API 호출 없이 `o200k_base` 프록시 토크나이저로 토큰 측정 + 공개 단가 적용
단가(Gemini 2.5 Flash, 공개가): 입력 $0.30/1M · 출력 $2.50/1M · **캐시 읽기 $0.03/1M**(기본 입력의 10%) · 캐시 스토리지 $1.00/1M·시간

## 0. 요약 (TL;DR)

1. **컨텍스트 캐시가 가장 큰 즉효 레버다.** few-shot 개수와 무관하게 LLM 비용/건이 약 **$0.00213 → $0.0015**(약 27%↓)로 수렴한다. system+few-shot 프리픽스가 캐시되어 10% 단가로 청구되기 때문이다.
2. **캐시를 켜면 few-shot 트리밍의 추가 효과는 미미하다.** 캐시 적용 후 비용은 거의 전부 **출력 토큰**이 좌우한다(출력 580 tok × $2.5/1M = $0.00145가 사실상 바닥).
3. **다음 레버는 출력 토큰이다.** narration 배열은 summary/advice/scores/lucky/avoid(이미 구조화된 필드)와 고정 presynth 문구를 중복한다. **LLM이 narration을 출력하지 않고 서버가 조립**하면 출력 토큰이 **580 → 239(59%↓)**.
4. **캐시 + narration 서버 조립을 합치면 LLM 비용/건 $0.00213 → $0.00068 (약 68%↓).**

## 1. 측정된 토큰 구성

| 영역 | 토큰(프록시) | 비고 |
| --- | --- | --- |
| system prompt | 983 | 캐시 가능(프리픽스) |
| few-shot 2개(현재) | 1,181 | 캐시 가능(프리픽스) |
| few-shot 1개 | 604 | 캐시 가능 |
| few-shot 1개(narration 제거) | 250 | 캐시 가능 |
| user 입력(seed_hash+signals) | 104 | 매 요청 가변 |
| 출력 JSON(narration 포함) | 580 | 평균 |
| 출력 JSON(narration 제거) | 239 | 평균 |

## 2. few-shot 구성별 LLM 비용/건

| 구성 | 입력 합(tok) | 비용/건(無캐시) | 비용/건(캐시) | vs 현재 |
| --- | --- | --- | --- | --- |
| A. 2-shot (현재) | 2,268 | $0.00213 | $0.00155 | -27% |
| B. 1-shot | 1,691 | $0.00196 | $0.00153 | -28% |
| C. 0-shot (system만) | 1,087 | $0.00178 | $0.00151 | -29% |
| D. 1-shot (narration 제거 예시) | 1,337 | $0.00185 | $0.00152 | -29% |

해석: **無캐시**에서는 few-shot을 줄이면 $0.00213 → $0.00178(0-shot)로 약 16% 절감된다. 그러나 **캐시 적용** 시 네 구성 모두 ~$0.0015로 수렴해, few-shot 트리밍의 한계 효용이 사라진다. 즉 캐시를 켜는 것이 트리밍보다 우선이며, 품질을 위해 few-shot은 1-2개 유지해도 비용 손해가 거의 없다.

## 3. 출력 토큰 레버 (narration 서버 조립)

narration 배열의 각 세그먼트 text는 다음과 같이 이미 다른 곳에 존재한다.

- greeting/blessing/ending → 캐릭터 고정 presynth 문구(서버 보유)
- summary/advice → 동명 구조화 필드 그대로
- scores → scores 객체에서 문장 생성 가능
- lucky → "오늘의 행운 색은 {color}, 행운 아이템은 {item}이에요." 템플릿
- avoid → 동명 구조화 필드

따라서 **LLM은 구조화 필드만 출력하고, 서버가 presynth 풀 + 템플릿으로 narration을 조립**하면 출력 토큰 341개(59%)를 제거할 수 있다.

| 시나리오(캐시 ON, 1-shot 프리픽스) | 출력 tok | LLM 비용/건 | vs 현재($0.00213) |
| --- | --- | --- | --- |
| narration 포함(현재) | 580 | $0.00153 | -28% |
| narration 서버 조립 | 239 | **$0.00068** | **-68%** |

## 4. 전체 건당 원가에서의 위치

LLM은 cache miss 건당 원가($0.0096)의 약 22%다. 따라서 LLM을 68% 줄여도 전체 miss 원가는 다음과 같이 약 15% 감소한다.

| 항목 | 현재 | 최적화(캐시+narration 서버조립) |
| --- | --- | --- |
| LLM | $0.0021 | $0.0007 |
| TTS(miss, 28초) | $0.0070 | $0.0070 |
| 인프라 | $0.0005 | $0.0005 |
| **cache miss 원가/건** | **$0.0096** | **$0.0082** |

요약: LLM 토큰 최적화는 비용 효율이 분명하지만(특히 캐시), **전체 원가의 지배 요인은 여전히 TTS**다. 큰 폭의 추가 절감은 TTS 캐시 히트율·무료 TTS 길이에서 나온다(→ 다음 단계 TTS 실측).

## 5. 권장 사항

1. **컨텍스트 캐시를 기본으로 적용한다.** system prompt + few-shot을 캐시 프리픽스로 고정(전사 공유 1개). 스토리지 비용은 프리픽스 2,164 tok × $1/1M/h × 24h = 약 $0.05/일로, 요청 수에 분산되면 무시 가능.
2. **few-shot은 품질을 위해 1-2개 유지한다.** 캐시 적용 시 비용 차이가 거의 없으므로 무리하게 0-shot으로 줄이지 않는다.
3. **청취 QA 결과에 따라 `scores_line` 중간안을 채택한다.** LLM 출력에서 `narration` 배열은 제거하되, scores 문장 자연스러움을 위해 `scores_line` 한 문장은 LLM이 생성한다.

## 6. 반영 결정 (2026-05-22)

- **즉시 반영**: 컨텍스트 캐시를 단위 경제 baseline으로 승격했다. `unit-economics-simulator.xlsx` v1.1은 캐시 프리픽스 2,164 tok, 가변 입력 104 tok, 출력 580 tok을 기본값으로 사용한다.
- **청취 QA 후 결정**: narration 서버 조립 전면 채택은 보류하고, `scores_line` 중간안을 채택한다. LLM은 `narration` 배열 대신 `scores_line` 한 문장과 구조화 필드만 출력한다.
- **문서 반영**: `docs/planning/today-shindang-service-plan-v3.md` §13의 baseline을 context cache ON 기준으로 갱신했다.

## 7. 한계와 후속

- 토큰은 `o200k_base` 프록시다. 상대 비교(트리밍/캐시 효과)에는 충분하나, 절대 비용은 Gemini 공식 `count_tokens`로 0단계에서 재측정해야 한다.
- 컨텍스트 캐시의 최소 토큰 요건·TTL·실제 청구 방식은 provider 문서/실측으로 확정한다.
- `scores_line` 중간안의 실제 Gemini 출력 토큰은 `contracts/fortune/fortune-schema.v1.1.json`/`docs/prompts/fortune-prompt-hongyeon.v1.1.md` 기준으로 재측정한다.
