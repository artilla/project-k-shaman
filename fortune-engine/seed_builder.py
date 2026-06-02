"""
Seed builder: deterministic seed_hash and seed_signals from a fortune request.

DEV ONLY — default hash_fn is SHA-256 without server secret.
§3 hold: real HMAC with server secret must be injected via hash_fn in production.
"""

import hashlib

_SCORE_FIELDS = ["love", "money", "work", "relationship", "condition"]
_SCORE_LEVELS = ["high", "mid", "low"]
_DAY_THEMES = [
    "새로운 흐름이 시작되는 날",
    "관계의 온도가 따뜻해지는 날",
    "내면의 힘을 발견하는 날",
    "기운이 차곡차곡 쌓이는 날",
    "관계의 흐름이 부드러운 날",
    "변화를 준비하기 좋은 날",
    "마음의 여유가 생기는 날",
    "작은 행운이 찾아오는 날",
    "집중력이 빛나는 날",
    "감사함이 넘치는 날",
    "새로운 인연이 시작되는 날",
    "용기를 내기 좋은 날",
]


def _default_hash_fn(data):
    """Dev-only SHA-256 hash (no server secret).

    §3 hold: inject real HMAC via hash_fn parameter for production.
    """
    return hashlib.sha256(data.encode("utf-8")).hexdigest()


def _get_birth_time_bucket(birth_hour):
    """Map birth hour (0–23) to a named bucket. Exact hour is never stored."""
    if 5 <= birth_hour < 12:
        return "morning"
    if 12 <= birth_hour < 18:
        return "afternoon"
    if 18 <= birth_hour < 22:
        return "evening"
    return "night"


def _derive_birth_profile_hash(request, hash_fn):
    """Hash birth date + time bucket only — original birth data never leaves this function."""
    birth_year = request.get("birth_year")
    birth_month = request.get("birth_month")
    birth_day = request.get("birth_day")
    birth_hour = request.get("birth_hour")

    if birth_year is None or birth_month is None or birth_day is None:
        return hash_fn("anonymous")

    birth_date_str = f"{birth_year:04d}-{birth_month:02d}-{birth_day:02d}"
    bucket = _get_birth_time_bucket(birth_hour) if birth_hour is not None else "unknown"
    # Only date + bucket are hashed; exact birth_hour is never forwarded.
    return hash_fn(f"{birth_date_str}:{bucket}")


def _derive_score_bias(seed_hash):
    """Deterministically map seed_hash bytes → score_bias for each of 5 fields."""
    result = {}
    for i, field in enumerate(_SCORE_FIELDS):
        byte_val = int(seed_hash[i * 2: i * 2 + 2], 16)
        result[field] = _SCORE_LEVELS[byte_val % len(_SCORE_LEVELS)]
    return result


def _derive_day_theme(seed_hash):
    """Deterministically select a day_theme from seed_hash bytes."""
    offset = len(_SCORE_FIELDS) * 2
    byte_val = int(seed_hash[offset: offset + 2], 16)
    return _DAY_THEMES[byte_val % len(_DAY_THEMES)]


def build_seed(request, hash_fn=_default_hash_fn):
    """Build deterministic seed_hash and seed_signals from a fortune request.

    Args:
        request: dict with optional birth fields (birth_year, birth_month, birth_day,
            birth_hour) and fields date, topic, character_id, tone, locale.
        hash_fn: hash function (str → str). Default: dev SHA-256 without secret.
            §3 hold: inject real HMAC here for production use.

    Returns:
        {
            "seed_hash": str,
            "seed_signals": {
                "score_bias": {love|money|work|relationship|condition: high|mid|low},
                "day_theme": str
            }
        }

    Note: birth_year/month/day/hour never appear in the output. Only
    birth_profile_hash (derived from birth date + time bucket) flows through.
    """
    date = request.get("date", "")
    topic = request.get("topic", "")
    character_id = request.get("character_id", "hongyeon")
    tone = request.get("tone", "bright")
    locale = request.get("locale", "ko-KR")

    birth_profile_hash = _derive_birth_profile_hash(request, hash_fn)

    # Assemble seed key (Plan.md §10: birth_profile_hash:date:topic:character_id:tone:locale)
    seed_key = f"{birth_profile_hash}:{date}:{topic}:{character_id}:{tone}:{locale}"
    seed_hash = hash_fn(seed_key)

    return {
        "seed_hash": seed_hash,
        "seed_signals": {
            "score_bias": _derive_score_bias(seed_hash),
            "day_theme": _derive_day_theme(seed_hash),
        },
    }
