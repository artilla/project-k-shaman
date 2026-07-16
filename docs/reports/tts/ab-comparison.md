# TTS A/B 비교: LLM narration vs 서버 조립 narration

생성일: 2026-05-22 / 합성 전 텍스트·예측 비교 (실제 오디오 아님)

대상: 주제별 1개씩 5개 샘플. A=현재 LLM 출력 narration, B=`narration_composer.py` 서버 조립.

> 핵심: **TTS 오디오 길이/요금은 두 버전이 거의 같다**(아래 예측표). 비용 이득은 LLM **출력 토큰** 절감(별도 리포트)에서 나온다. 이 A/B는 **자연스러움(특히 scores 문장과 연결)** 이 유지되는지를 귀로 판정하기 위한 것이다.

## 예측 오디오 길이 (4.5음절/초 + 세그먼트 0.4초 휴지)

| 샘플 | 주제 | A 전체(초) | B 전체(초) | A 신규합성(초) | B 신규합성(초) |
| --- | --- | --- | --- | --- | --- |
| h_love_001 | love | 50.8 | 48.3 | 32.2 | 29.8 |
| h_money_001 | money | 46.8 | 45.2 | 28.2 | 26.7 |
| h_work_001 | work | 47.9 | 46.3 | 29.3 | 27.8 |
| h_rel_001 | relationship | 47.4 | 46.8 | 28.9 | 28.2 |
| h_total_001 | total | 47.4 | 45.9 | 28.9 | 27.3 |

TTS 신규합성 평균: A 29.5초(≈$0.0074/건), B 28.0초(≈$0.0070/건). 차이는 미미 → **TTS 원가는 사실상 동일**.

## 스크립트 대조 (A=LLM / B=서버 조립)

### h_love_001 (love)

**A. LLM narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 오늘은 마음이 먼저 움직이는 날이에요. 솔직한 한마디가 관계의 온도를 한 칸 올려줘요.
  - [personalized] scores: 연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요.
  - [personalized] advice: 마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.
  - [semi] lucky: 오늘의 행운 색은 코랄 핑크, 행운 아이템은 작은 손거울이에요.
  - [personalized] avoid: 지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

**B. 서버 조립 narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 오늘은 마음이 먼저 움직이는 날이에요. 솔직한 한마디가 관계의 온도를 한 칸 올려줘요.
  - [personalized] scores: 연애운이 아주 좋고, 컨디션은 조금 낮으니 무리하진 마세요.
  - [personalized] advice: 마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.
  - [semi] lucky: 오늘의 행운 색은 코랄 핑크, 행운 아이템은 작은 손거울이에요.
  - [personalized] avoid: 지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

> scores 차이 → A: "연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요."  /  B: "연애운이 아주 좋고, 컨디션은 조금 낮으니 무리하진 마세요."

### h_money_001 (money)

**A. LLM narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 작게 모으던 것이 형태를 갖추는 날이에요. 오늘의 알뜰한 선택이 다음 주의 여유가 돼요.
  - [personalized] scores: 금전운이 든든하게 올라와 있어요. 일운도 안정적이라 차근차근 정리하기 좋아요.
  - [personalized] advice: 미뤄둔 가계부나 영수증을 5분만 정리해 보세요.
  - [semi] lucky: 오늘의 행운 색은 금빛, 행운 아이템은 단추예요.
  - [personalized] avoid: 기분에 휩쓸린 즉흥 결제는 오늘만 잠시 멈춰두세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

**B. 서버 조립 narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 작게 모으던 것이 형태를 갖추는 날이에요. 오늘의 알뜰한 선택이 다음 주의 여유가 돼요.
  - [personalized] scores: 금전운이 아주 좋고, 인간관계운은 조금 낮으니 무리하진 마세요.
  - [personalized] advice: 미뤄둔 가계부나 영수증을 5분만 정리해 보세요.
  - [semi] lucky: 오늘의 행운 색은 금빛, 행운 아이템은 단추예요.
  - [personalized] avoid: 기분에 휩쓸린 즉흥 결제는 오늘만 잠시 멈춰두세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

> scores 차이 → A: "금전운이 든든하게 올라와 있어요. 일운도 안정적이라 차근차근 정리하기 좋아요."  /  B: "금전운이 아주 좋고, 인간관계운은 조금 낮으니 무리하진 마세요."

### h_work_001 (work)

**A. LLM narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 집중력이 또렷하게 모이는 날이에요. 미뤄둔 일 하나를 끝내면 흐름이 쭉 풀려요.
  - [personalized] scores: 일과 학업운이 아주 좋아요. 컨디션도 받쳐주니 중요한 일을 먼저 처리하기 좋아요.
  - [personalized] advice: 가장 부담스러운 일을 오전 첫 30분에 먼저 손대 보세요.
  - [semi] lucky: 오늘의 행운 색은 먹색, 행운 아이템은 메모지예요.
  - [personalized] avoid: 여러 일을 동시에 벌여 놓고 끝을 못 맺는 패턴은 오늘만 피하세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

**B. 서버 조립 narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 집중력이 또렷하게 모이는 날이에요. 미뤄둔 일 하나를 끝내면 흐름이 쭉 풀려요.
  - [personalized] scores: 일과 학업운이 아주 좋고, 연애운은 조금 낮으니 무리하진 마세요.
  - [personalized] advice: 가장 부담스러운 일을 오전 첫 30분에 먼저 손대 보세요.
  - [semi] lucky: 오늘의 행운 색은 먹색, 행운 아이템은 메모지예요.
  - [personalized] avoid: 여러 일을 동시에 벌여 놓고 끝을 못 맺는 패턴은 오늘만 피하세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

> scores 차이 → A: "일과 학업운이 아주 좋아요. 컨디션도 받쳐주니 중요한 일을 먼저 처리하기 좋아요."  /  B: "일과 학업운이 아주 좋고, 연애운은 조금 낮으니 무리하진 마세요."

### h_rel_001 (relationship)

**A. LLM narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 오래 못 본 사람과 연이 닿기 좋은 날이에요. 당신의 한마디가 누군가에게 큰 위로가 돼요.
  - [personalized] scores: 인간관계운이 활짝 열렸어요. 연애운도 잔잔히 좋고 컨디션도 무난해요.
  - [personalized] advice: 문득 떠오른 사람에게 안부 메시지를 가볍게 남겨 보세요.
  - [semi] lucky: 오늘의 행운 색은 살구색, 행운 아이템은 손수건이에요.
  - [personalized] avoid: 사소한 오해를 키워서 마음속에 담아두지는 마세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

**B. 서버 조립 narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 오래 못 본 사람과 연이 닿기 좋은 날이에요. 당신의 한마디가 누군가에게 큰 위로가 돼요.
  - [personalized] scores: 인간관계운이 아주 좋고, 금전운은 조금 낮으니 무리하진 마세요.
  - [personalized] advice: 문득 떠오른 사람에게 안부 메시지를 가볍게 남겨 보세요.
  - [semi] lucky: 오늘의 행운 색은 살구색, 행운 아이템은 손수건이에요.
  - [personalized] avoid: 사소한 오해를 키워서 마음속에 담아두지는 마세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

> scores 차이 → A: "인간관계운이 활짝 열렸어요. 연애운도 잔잔히 좋고 컨디션도 무난해요."  /  B: "인간관계운이 아주 좋고, 금전운은 조금 낮으니 무리하진 마세요."

### h_total_001 (total)

**A. LLM narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 전체적으로 균형이 잘 잡힌 안정적인 날이에요. 큰 욕심 없이 흐름을 타면 하루가 매끄러워요.
  - [personalized] scores: 모든 운이 고르게 좋은 편이에요. 특별히 튀는 곳 없이 무난하고 든든한 하루예요.
  - [personalized] advice: 오늘 할 일 중 가장 쉬운 것부터 하나 끝내고 시작해 보세요.
  - [semi] lucky: 오늘의 행운 색은 금빛, 행운 아이템은 메모지예요.
  - [personalized] avoid: 괜히 큰 결정을 서둘러 내리려 하지는 마세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

**B. 서버 조립 narration**

  - [presynth] greeting: 오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요.
  - [personalized] summary: 전체적으로 균형이 잘 잡힌 안정적인 날이에요. 큰 욕심 없이 흐름을 타면 하루가 매끄러워요.
  - [personalized] scores: 인간관계운이 좋은 편이고, 전반적으로 고르게 안정적이에요.
  - [personalized] advice: 오늘 할 일 중 가장 쉬운 것부터 하나 끝내고 시작해 보세요.
  - [semi] lucky: 오늘의 행운 색은 금빛, 행운 아이템은 메모지예요.
  - [personalized] avoid: 괜히 큰 결정을 서둘러 내리려 하지는 마세요.
  - [presynth] blessing: 오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.
  - [presynth] ending: 내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요.

> scores 차이 → A: "모든 운이 고르게 좋은 편이에요. 특별히 튀는 곳 없이 무난하고 든든한 하루예요."  /  B: "인간관계운이 좋은 편이고, 전반적으로 고르게 안정적이에요."

## 관찰 (텍스트 단계, 합성 전)

- greeting/blessing/ending/lucky: A·B 동일(풀·템플릿). 차이 없음.

- summary/advice/avoid: B는 LLM 필드를 그대로 재사용 → 텍스트 동일.

- **scores 세그먼트만 실질 차이**: A는 LLM이 문맥에 맞춰 쓴 문장, B는 최고/최저 점수 기반 템플릿. 청취 QA의 핵심 포인트.

- 따라서 v1.1 결정은 사실상 "scores 문장을 템플릿으로 대체해도 자연스러운가"로 좁혀진다. 중간안: scores만 LLM이 짧은 한 문장(`scores_line`) 출력(출력 토큰 소폭 증가, 자연스러움 보존).
