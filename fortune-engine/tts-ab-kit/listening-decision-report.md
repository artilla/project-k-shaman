# TTS A/B 청취 결정 리포트

작성일: 2026-05-22  
입력 파일: `listening-scores-2026-05-22.json`  
평가 대상: A=LLM narration, B=서버 조립 narration  
결정: **`scores_line` 중간안 채택**

## 1. 점수 요약

| 버전 | 자연스러움 | 연결 | scores | 캐릭터성 | 전체 |
| --- | ---: | ---: | ---: | ---: | ---: |
| A: LLM narration | 2.8 | 3.2 | 3.0 | 3.0 | 3.0 |
| B: 서버 조립 narration | 3.2 | 3.0 | 3.0 | 3.0 | 3.6 |

사전 합격 기준:

- B의 scores 평균 >= 4.0 그리고 연결 평균 >= 4.0: 서버 조립 전면 채택
- 둘 중 하나라도 < 3.5: `scores_line` 중간안
- B 전반 < 3.0: 현행 유지

B는 scores 3.0, 연결 3.0이므로 전면 서버 조립 기준을 통과하지 못했다. 다만 전체 평균은 3.6으로 현행 유지까지 갈 수준은 아니므로, 사전에 정의한 **`scores_line` 중간안**을 채택한다.

## 2. 채택안

LLM 출력:

- `scores`
- `scores_line`
- `summary`
- `advice`
- `lucky`
- `avoid`
- `blessing`

LLM 출력에서 제거:

- `narration`

서버 조립:

```text
greeting(presynth)
→ summary(LLM summary 2문장 연결)
→ scores(LLM scores_line)
→ advice(LLM advice)
→ lucky(서버 템플릿)
→ avoid(LLM avoid)
→ blessing(presynth)
→ ending(presynth)
```

## 3. 이유

템플릿 기반 B의 약점은 `scores` 문장이었다. "최고/최저 점수 기반 템플릿"은 비용상 유리하지만, topic·summary 흐름과 자연스럽게 붙는 감각이 부족했다.

`scores_line` 중간안은 다음 균형점이다.

- scores 문장 자연스러움은 LLM이 유지한다.
- 긴 `narration` 배열은 제거해 출력 토큰을 줄인다.
- 서버는 presynth/lucky/순서 조립을 책임져 캐싱 구조를 단순화한다.

## 4. 반영 산출물

- `fortune-schema.v1.1.json`: `narration` 제거, `scores_line` 추가
- `fortune-prompt-hongyeon.v1.1.md`: v1.1 출력 계약 반영
- `fortune-samples.v1.1.json`: 기존 샘플 15개를 v1.1 구조로 변환
- `narration_composer.py`: `scores_line`이 있으면 우선 사용, 없으면 템플릿 fallback

## 5. 후속

- Gemini 공식 `count_tokens`로 v1.1 출력 토큰을 재측정한다.
- v1.1 샘플로 2차 TTS 소량 합성을 실행해 `scores_line` 조립 결과가 A와 동일하게 들리는지 spot check한다.
- production에서는 `scores_line` 누락 시 템플릿 fallback을 사용하되, 품질 이벤트로 기록한다.
