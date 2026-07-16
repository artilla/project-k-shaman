"""HTTP와 외부 I/O에 독립적인 결정적 운세 도메인 규칙."""

from .narration import compose_narration

# 결정적 풀 — 텍스트 필드 소스 (scores_line, summary, advice, lucky, avoid, blessing)
_POOL = [
    {
        "scores_line": "연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요.",
        "summary": [
            "오늘은 마음이 먼저 움직이는 날이에요.",
            "솔직한 한마디가 관계의 온도를 한 칸 올려줘요.",
        ],
        "advice": "마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.",
        "lucky": {"color": "코랄 핑크", "item": "작은 손거울"},
        "avoid": "지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "금전운이 든든하게 올라와 있어요. 일운도 안정적이라 차근차근 정리하기 좋아요.",
        "summary": [
            "작게 모으던 것이 형태를 갖추는 날이에요.",
            "오늘의 알뜰한 선택이 다음 주의 여유가 돼요.",
        ],
        "advice": "미뤄둔 가계부나 영수증을 5분만 정리해 보세요.",
        "lucky": {"color": "금빛", "item": "단추"},
        "avoid": "기분에 휩쓸린 즉흥 결제는 오늘만 잠시 멈춰두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "일과 학업운이 아주 좋아요. 컨디션도 받쳐주니 중요한 일을 먼저 처리하기 좋아요.",
        "summary": [
            "집중력이 또렷하게 모이는 날이에요.",
            "미뤄둔 일 하나를 끝내면 흐름이 쭉 풀려요.",
        ],
        "advice": "가장 부담스러운 일을 오전 첫 30분에 먼저 손대 보세요.",
        "lucky": {"color": "먹색", "item": "메모지"},
        "avoid": "여러 일을 동시에 벌여 놓고 끝을 못 맺는 패턴은 오늘만 피하세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "인간관계운과 컨디션이 모두 좋아요. 연애운도 살짝 올라 기분 좋은 하루가 돼요.",
        "summary": [
            "분위기를 살리는 역할이 잘 어울리는 날이에요.",
            "당신이 웃으면 주변 공기가 한결 가벼워져요.",
        ],
        "advice": "오늘은 모임에서 먼저 분위기를 띄우는 한마디를 건네 보세요.",
        "lucky": {"color": "자수정 보라", "item": "작은 종"},
        "avoid": "모두를 챙기느라 정작 내 기분을 뒤로 미루지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "모든 운이 고르게 좋은 편이에요. 특별히 튀는 곳 없이 무난하고 든든한 하루예요.",
        "summary": [
            "전체적으로 균형이 잘 잡힌 안정적인 날이에요.",
            "큰 욕심 없이 흐름을 타면 하루가 매끄러워요.",
        ],
        "advice": "오늘 할 일 중 가장 쉬운 것부터 하나 끝내고 시작해 보세요.",
        "lucky": {"color": "은백", "item": "향초"},
        "avoid": "괜히 큰 결정을 서둘러 내리려 하지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
]

# score_bias(high|mid|low) → 0-100 정수 범위
_BIAS_RANGES = {
    "high": (70, 100),
    "mid": (40, 69),
    "low": (0, 39),
}
_SCORE_FIELDS = ["love", "money", "work", "relationship", "condition"]


def _apply_bias_scores(score_bias: dict, seed_hash: str) -> dict:
    """score_bias + seed_hash → 결정적 0-100 정수 scores (스키마 유효)."""
    scores = {}
    for i, field in enumerate(_SCORE_FIELDS):
        bias = score_bias.get(field, "mid")
        lo, hi = _BIAS_RANGES[bias]
        # seed_hash의 20번째 위치 이후 바이트를 사용 (앞 20자리는 pool 선택에 사용)
        byte_val = int(seed_hash[20 + i * 4 : 20 + i * 4 + 4], 16)
        scores[field] = lo + byte_val % (hi - lo + 1)
    return scores


def build_fortune(request: dict, seed_result: dict) -> dict:
    """Build fortune dict + script from seed_result (no TTS). Compute_fn for fortune cache.

    Returns {"fortune": dict, "fortune_id": str, "script": list}
    """
    seed_hash = seed_result["seed_hash"]
    seed_signals = seed_result["seed_signals"]

    pool_idx = int(seed_hash[:8], 16) % len(_POOL)
    fields = _POOL[pool_idx]
    scores = _apply_bias_scores(seed_signals["score_bias"], seed_hash)

    date = request.get("date", "2026-01-01")
    topic = request.get("topic", "total")
    character_id = request.get("character_id", "hongyeon")

    fortune = {
        "schema_version": "fortune.v1.1",
        "meta": {
            "date": date,
            "character_id": character_id,
            "topic": topic,
            "tone": "bright",
            "locale": "ko-KR",
            "seed_hash": seed_hash,
            "content_version": "prompt.v1.1",
        },
        "scores": scores,
        "scores_line": fields["scores_line"],
        "summary": fields["summary"],
        "advice": fields["advice"],
        "lucky": fields["lucky"],
        "avoid": fields["avoid"],
        "blessing": fields["blessing"],
    }

    fortune_id = f"fortune_{seed_hash[:16]}"
    script = compose_narration({**fields, "scores": scores})

    return {"fortune": fortune, "fortune_id": fortune_id, "script": script}
