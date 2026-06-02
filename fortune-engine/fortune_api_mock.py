#!/usr/bin/env python3
"""T010: /api/fortune/today mock — fortune-schema.v1.1 준수, 결정적 응답.

비민감 요청 필드(topic, date, character_id)로 결정적 키를 만들어
사전 정의 풀에서 유효한 응답을 반환한다.

§3 hold: 실제 HMAC seed 키, 실제 LLM 생성, 실제 TTS 합성은 구현하지 않는다 — 후속 티켓.
birth 필드는 키·응답·로그 어디에도 평문으로 남기지 않는다.
"""
import hashlib
import importlib.util
from pathlib import Path

# T003 compose_narration 재사용 (서버 조립)
_COMPOSER_PATH = Path(__file__).parent / "tts-ab-kit" / "narration_composer.py"
_spec = importlib.util.spec_from_file_location("narration_composer", _COMPOSER_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
_compose_narration = _mod.compose_narration

# 결정적 풀 — fortune-schema.v1.1 유효 필드 세트
_POOL = [
    {
        "scores": {"love": 88, "money": 61, "work": 55, "relationship": 79, "condition": 48},
        "scores_line": "연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요.",
        "summary": ["오늘은 마음이 먼저 움직이는 날이에요.", "솔직한 한마디가 관계의 온도를 한 칸 올려줘요."],
        "advice": "마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.",
        "lucky": {"color": "코랄 핑크", "item": "작은 손거울"},
        "avoid": "지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores": {"love": 52, "money": 84, "work": 70, "relationship": 49, "condition": 63},
        "scores_line": "금전운이 든든하게 올라와 있어요. 일운도 안정적이라 차근차근 정리하기 좋아요.",
        "summary": ["작게 모으던 것이 형태를 갖추는 날이에요.", "오늘의 알뜰한 선택이 다음 주의 여유가 돼요."],
        "advice": "미뤄둔 가계부나 영수증을 5분만 정리해 보세요.",
        "lucky": {"color": "금빛", "item": "단추"},
        "avoid": "기분에 휩쓸린 즉흥 결제는 오늘만 잠시 멈춰두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores": {"love": 45, "money": 57, "work": 86, "relationship": 62, "condition": 71},
        "scores_line": "일과 학업운이 아주 좋아요. 컨디션도 받쳐주니 중요한 일을 먼저 처리하기 좋아요.",
        "summary": ["집중력이 또렷하게 모이는 날이에요.", "미뤄둔 일 하나를 끝내면 흐름이 쭉 풀려요."],
        "advice": "가장 부담스러운 일을 오전 첫 30분에 먼저 손대 보세요.",
        "lucky": {"color": "먹색", "item": "메모지"},
        "avoid": "여러 일을 동시에 벌여 놓고 끝을 못 맺는 패턴은 오늘만 피하세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores": {"love": 67, "money": 45, "work": 55, "relationship": 82, "condition": 75},
        "scores_line": "인간관계운과 컨디션이 모두 좋아요. 연애운도 살짝 올라 기분 좋은 하루가 돼요.",
        "summary": ["분위기를 살리는 역할이 잘 어울리는 날이에요.", "당신이 웃으면 주변 공기가 한결 가벼워져요."],
        "advice": "오늘은 모임에서 먼저 분위기를 띄우는 한마디를 건네 보세요.",
        "lucky": {"color": "자수정 보라", "item": "작은 종"},
        "avoid": "모두를 챙기느라 정작 내 기분을 뒤로 미루지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores": {"love": 70, "money": 65, "work": 68, "relationship": 72, "condition": 69},
        "scores_line": "모든 운이 고르게 좋은 편이에요. 특별히 튀는 곳 없이 무난하고 든든한 하루예요.",
        "summary": ["전체적으로 균형이 잘 잡힌 안정적인 날이에요.", "큰 욕심 없이 흐름을 타면 하루가 매끄러워요."],
        "advice": "오늘 할 일 중 가장 쉬운 것부터 하나 끝내고 시작해 보세요.",
        "lucky": {"color": "은백", "item": "향초"},
        "avoid": "괜히 큰 결정을 서둘러 내리려 하지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
]


def get_today_fortune(request: dict) -> dict:
    """결정적 fortune 응답을 반환한다.

    비민감 필드(date, topic, character_id)만으로 결정적 키를 생성한다.
    birth 필드는 수신 가능하지만 키·응답·파일에 남기지 않는다(§3 hold: 실제 HMAC은 미구현).
    """
    date = request.get("date", "2026-01-01")
    topic = request.get("topic", "total")
    character_id = request.get("character_id", "hongyeon")

    # 결정적 키: 비민감 필드만 사용 (birth 제외)
    key = f"{date}:{topic}:{character_id}"
    seed_hash = hashlib.sha256(key.encode()).hexdigest()[:16]

    fields = _POOL[int(seed_hash[:8], 16) % len(_POOL)]

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
        "scores": fields["scores"],
        "scores_line": fields["scores_line"],
        "summary": fields["summary"],
        "advice": fields["advice"],
        "lucky": fields["lucky"],
        "avoid": fields["avoid"],
        "blessing": fields["blessing"],
    }

    fortune_id = f"mock_{seed_hash}"
    script = _compose_narration(fields)

    return {
        "fortuneId": fortune_id,
        "audioUrl": f"mock://audio/{fortune_id}.mp3",
        "durationSec": 60,
        "script": script,
        "fortune": fortune,
    }
