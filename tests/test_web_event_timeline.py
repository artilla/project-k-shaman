"""재생 이벤트 타임라인의 필수 이벤트와 3초 경로 지연 요약 테스트.
3초 경로 지연 요약 테스트."""

import logging

from shindang.application.telemetry import summarize_latency, validate_timeline

_FULL_TIMELINE = [
    {"event": "tts_generate_start"},
    {"event": "tts_generate_complete"},
    {"event": "cache_miss", "layer": "tts"},
    {"event": "first_text_visible", "clientTs": 1000},
    {"event": "first_audio_play", "clientTs": 1500},
]


class TestValidateTimeline:
    def test_complete_timeline_has_no_missing(self):
        assert validate_timeline(_FULL_TIMELINE) == []

    def test_missing_first_text_visible_detected(self):
        events = [e for e in _FULL_TIMELINE if e["event"] != "first_text_visible"]
        assert "first_text_visible" in validate_timeline(events)

    def test_missing_first_audio_play_detected(self):
        events = [e for e in _FULL_TIMELINE if e["event"] != "first_audio_play"]
        assert "first_audio_play" in validate_timeline(events)

    def test_missing_cache_event_detected(self):
        events = [
            e for e in _FULL_TIMELINE if e["event"] not in ("cache_hit", "cache_miss")
        ]
        assert "cache_hit|cache_miss" in validate_timeline(events)

    def test_cache_hit_alone_satisfies_requirement(self):
        events = [e for e in _FULL_TIMELINE if e["event"] != "cache_miss"]
        events.append({"event": "cache_hit", "layer": "tts"})
        assert validate_timeline(events) == []

    def test_empty_timeline_reports_all_missing(self):
        missing = validate_timeline([])
        assert set(missing) == {
            "first_text_visible",
            "first_audio_play",
            "cache_hit|cache_miss",
        }


class TestSummarizeLatency:
    def test_computes_text_and_audio_latency(self):
        summary = summarize_latency(_FULL_TIMELINE, session_start_ms=500)
        assert summary["textLatencyMs"] == 500
        assert summary["audioLatencyMs"] == 1000

    def test_cache_status_miss(self):
        summary = summarize_latency(_FULL_TIMELINE, session_start_ms=0)
        assert summary["cacheStatus"] == "miss"

    def test_cache_status_hit(self):
        events = [e for e in _FULL_TIMELINE if e["event"] != "cache_miss"]
        events.append({"event": "cache_hit"})
        summary = summarize_latency(events, session_start_ms=0)
        assert summary["cacheStatus"] == "hit"

    def test_cache_status_mixed(self):
        events = [*_FULL_TIMELINE, {"event": "cache_hit"}]
        summary = summarize_latency(events, session_start_ms=0)
        assert summary["cacheStatus"] == "mixed"

    def test_cache_status_unknown_when_absent(self):
        events = [
            e for e in _FULL_TIMELINE if e["event"] not in ("cache_miss", "cache_hit")
        ]
        summary = summarize_latency(events, session_start_ms=0)
        assert summary["cacheStatus"] == "unknown"

    def test_latency_none_when_client_event_absent(self):
        events = [e for e in _FULL_TIMELINE if e["event"] != "first_audio_play"]
        summary = summarize_latency(events, session_start_ms=0)
        assert summary["audioLatencyMs"] is None

    def test_logs_summary_event(self, caplog):
        with caplog.at_level(logging.INFO, logger="shindang.application.telemetry"):
            summarize_latency(_FULL_TIMELINE, session_start_ms=0)
        assert any("playback_timeline_summary" in r.message for r in caplog.records)
