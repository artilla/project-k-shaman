"""꿈 해몽 — 상징 감지·풀이 조립 (순수 함수).

원본 로직: reference/design-prototype-dream/오늘신당 꿈 해몽.dc.html (디자인 프로토타입).
서버에 두는 이유: ① 게이트(로그인 필요) 뒤에서만 생성, ② 추후 실 LLM 생성으로 교체할 지점.

프라이버시 불변식: 꿈 원문(text)은 응답 조립에만 사용하고 저장·로깅하지 않는다.
"""

from __future__ import annotations

import hashlib

SYMBOLS: dict[str, dict] = {
    "뱀": {
        "meaning": "재물과 생명력의 상징. 뱀이 다가오거나 품에 안기면 재물운·귀인운이 들어오는 길몽으로 봐요. 도망가면 기회를 놓칠 수 있다는 신호예요.",
        "tone": "good",
    },
    "물": {
        "meaning": "감정과 재물의 흐름. 맑은 물은 마음이 정돈되고 금전이 순탄히 흐를 징조, 흐린 물은 마음속 근심이 쌓였다는 뜻이에요.",
        "tone": "mixed",
    },
    "이빨 빠짐": {
        "meaning": "변화와 상실 불안의 상징. 실제 흉몽이라기보다, 곧 매듭지어야 할 일이나 관계의 변화를 마음이 미리 연습하는 꿈이에요.",
        "tone": "caution",
    },
    "추락": {
        "meaning": "통제를 놓치는 것에 대한 불안. 반대로 짐을 내려놓고 싶다는 마음의 표현이기도 해요. 착지했다면 전화위복의 암시예요.",
        "tone": "caution",
    },
    "시험": {
        "meaning": "평가받는 상황에 대한 긴장. 준비된 사람에게는 오히려 실전에서 실력이 드러난다는 예지로 풀어요.",
        "tone": "mixed",
    },
    "돈": {
        "meaning": "꿈에서 돈을 받으면 실제로는 마음의 빚, 돈을 주면 재물이 들어올 자리가 생긴다고 풀어요. 방향이 중요한 상징이에요.",
        "tone": "mixed",
    },
    "불": {
        "meaning": "왕성한 기운과 번창의 상징. 집이나 몸에 붙은 불은 사업·명예가 크게 일어날 대표적인 길몽이에요.",
        "tone": "good",
    },
    "하늘을 낢": {
        "meaning": "억눌린 마음이 풀려나는 해방의 상징. 목표를 향한 도약운이 트였다는 뜻으로, 새 시도를 시작하기 좋은 때예요.",
        "tone": "good",
    },
}

# 텍스트 자동 감지 별칭 (프로토타입 activeSymbols와 동일)
_ALIASES: dict[str, list[str]] = {
    "뱀": ["구렁이"],
    "이빨 빠짐": ["이가 빠"],
    "하늘을 낢": ["날았", "나는 꿈"],
}

BLESSING = "간밤의 꿈이 오늘의 길잡이가 되도록, 홍연이 기운을 매듭지어 드릴게요."

MAX_TEXT_LENGTH = 300
MAX_SYMBOLS = 3


def detect_symbols(text: str, selected: list[str]) -> list[str]:
    """선택 칩 + 텍스트 감지 → 상징 최대 3개, 없으면 기본 '물' (프로토타입 계약)."""
    found: list[str] = []
    for key in SYMBOLS:
        bare = key.replace(" ", "")
        hit = key in selected or (text and (key in text or bare in text))
        if not hit and text:
            hit = any(alias in text for alias in _ALIASES.get(key, []))
        if hit:
            found.append(key)
    return found[:MAX_SYMBOLS] if found else ["물"]


def build_reading(symbols: list[str]) -> dict:
    """tone 집계 → 3분기 풀이 (프로토타입 reading()과 동일 카피)."""
    tones = [SYMBOLS[k]["tone"] for k in symbols]
    good = tones.count("good")
    caution = tones.count("caution")
    joined = ", ".join(symbols)
    if good > caution:
        headline = '"귀한 기운이 들어오는 꿈이에요. 놓치지 말고 붙잡으세요."'
        overall = (
            joined
            + "의 상징이 함께 나타난 꿈은 새 기운이 손님 쪽으로 흘러들고 있다는 뜻이에요. "
            "꿈속에서 느낀 감정이 두려움보다 설렘에 가까웠다면 더욱 확실한 길몽 — 며칠 안에 오는 제안이나 연락을 가볍게 넘기지 마세요."
        )
        today = "오늘의 금전·대인 기운과 맞물려, 먼저 움직이는 쪽에 복이 붙는 날이에요."
        chip = "길몽 · 기회"
    elif caution > good:
        headline = '"마음이 미리 연습을 시킨 꿈이에요. 흉몽이 아니니 안심하세요."'
        overall = (
            joined
            + "이(가) 나오는 꿈은 대부분 실제 불운이 아니라, 다가올 변화를 마음이 먼저 리허설하는 것이에요. "
            "꿈이 대신 긴장을 풀어줬으니, 현실에서는 오히려 차분하게 매듭을 지을 수 있어요."
        )
        today = "오늘은 서두르지 말고, 미뤄둔 매듭 하나만 정리하면 기운이 풀려요."
        chip = "액땜 · 정리"
    else:
        headline = '"흐름이 바뀌는 길목의 꿈이에요. 방향은 손님이 정할 수 있어요."'
        overall = (
            joined
            + "의 상징이 섞인 꿈은 좋고 나쁨이 정해진 게 아니라, 기운이 갈림길에 서 있다는 신호예요. "
            "꿈에서 물이 맑았는지, 끝이 어땠는지 떠올려 보세요 — 끝이 편안했다면 흐름은 손님 편이에요."
        )
        today = "오늘의 총운이 무난한 날이라, 갈림길에서는 익숙한 쪽보다 마음이 끌리는 쪽을 고르세요."
        chip = "갈림길 · 선택"
    return {
        "headline": headline,
        "symbols": [{"label": k, "meaning": SYMBOLS[k]["meaning"]} for k in symbols],
        "overall": overall,
        "todayLink": today,
        "chips": [chip] + ["꿈 · " + k for k in symbols],
        "blessing": BLESSING,
    }


def build_segments(reading: dict) -> list[dict]:
    """낭독 세그먼트 — 기존 운세와 동일한 단일 오디오 + 텍스트 길이 비례 경계 방식."""
    segs = [{"text": "간밤의 꿈, 홍연이 찬찬히 풀어볼게요.", "label": "greeting"}]
    for sym in reading["symbols"]:
        segs.append(
            {
                "text": f"{sym['label']} 꿈은요. {sym['meaning']}",
                "label": "상징 · " + sym["label"],
            }
        )
    segs.append({"text": reading["overall"], "label": "전체 풀이"})
    segs.append({"text": reading["todayLink"], "label": "오늘 운세 연결"})
    segs.append({"text": reading["blessing"], "label": "축원"})
    return segs


def interpret(text: str, selected: list[str]) -> dict:
    """해몽 응답 조립. 꿈 원문은 여기서만 소비되고 응답·로그 어디에도 남지 않는다."""
    clean_text = (text or "")[:MAX_TEXT_LENGTH]
    valid_selected = [s for s in (selected or []) if s in SYMBOLS][:MAX_SYMBOLS]
    symbols = detect_symbols(clean_text, valid_selected)
    reading = build_reading(symbols)
    segments = build_segments(reading)
    # dreamId는 상징 조합 기반(원문 미포함) — 이벤트 상관용 식별자
    dream_id = (
        "dream-" + hashlib.sha256(("|".join(symbols)).encode("utf-8")).hexdigest()[:12]
    )
    return {"dreamId": dream_id, "reading": reading, "script": segments}
