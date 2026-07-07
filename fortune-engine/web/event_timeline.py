"""T019: 재생 이벤트 타임라인 스키마 — 3초 경로 실측 훅 (master-spec §1.6-②).

전체 세션 타임라인 = 서버 이벤트(tts_generate_start/complete, cache_hit/miss — pipeline.py가
get_today_fortune 호출 중 캡처) + 클라이언트 이벤트(first_text_visible, first_audio_play —
브라우저가 /api/event로 보고).

이 모듈은 코드가 아니라 이벤트 dict 리스트만 다루므로 브라우저 없이 완전히 단위 테스트 가능하다.
"""
import json
import logging

_logger = logging.getLogger("fortune_engine.web.event_timeline")

CLIENT_EVENT_TYPES = ("first_text_visible", "first_audio_play")
_CACHE_EVENT_TYPES = ("cache_hit", "cache_miss")


def validate_timeline(events: list) -> list:
    """타임라인이 최소 요구 이벤트를 포함하는지 검사한다.

    Returns:
        결측 이벤트 이름 리스트. 비어 있으면 요구 조건을 모두 만족한다는 뜻.
        cache_hit/cache_miss는 방문 종류(신규 vs 재방문)에 따라 둘 중 하나만 있으면 되므로
        "cache_hit|cache_miss" 하나로 묶어 보고한다.
    """
    seen = {e.get("event") for e in events}
    missing = []
    for required in CLIENT_EVENT_TYPES:
        if required not in seen:
            missing.append(required)
    if not any(t in seen for t in _CACHE_EVENT_TYPES):
        missing.append("cache_hit|cache_miss")
    return missing


def _first_client_ts(events: list, event_name: str):
    for e in events:
        if e.get("event") == event_name:
            return e.get("clientTs")
    return None


def summarize_latency(events: list, *, session_start_ms: float) -> dict:
    """세션 이벤트 타임라인에서 지연 요약을 계산하고 구조화 로그로 남긴다.

    Args:
        events: 서버 이벤트 + 클라이언트 이벤트를 합친 리스트.
        session_start_ms: 사용자가 탭한 시각(클라이언트 Date.now() 기준 epoch ms).

    Returns:
        {
            "textLatencyMs": float|None,   # session_start_ms → first_text_visible
            "audioLatencyMs": float|None,  # session_start_ms → first_audio_play
            "cacheStatus": "hit"|"miss"|"mixed"|"unknown",
        }
    """
    text_ts = _first_client_ts(events, "first_text_visible")
    audio_ts = _first_client_ts(events, "first_audio_play")

    text_latency = (text_ts - session_start_ms) if text_ts is not None else None
    audio_latency = (audio_ts - session_start_ms) if audio_ts is not None else None

    cache_events = [e["event"] for e in events if e.get("event") in _CACHE_EVENT_TYPES]
    if not cache_events:
        cache_status = "unknown"
    elif all(e == "cache_hit" for e in cache_events):
        cache_status = "hit"
    elif all(e == "cache_miss" for e in cache_events):
        cache_status = "miss"
    else:
        cache_status = "mixed"

    summary = {
        "textLatencyMs": text_latency,
        "audioLatencyMs": audio_latency,
        "cacheStatus": cache_status,
    }
    _logger.info(json.dumps({"event": "playback_timeline_summary", **summary}, ensure_ascii=False))
    return summary
