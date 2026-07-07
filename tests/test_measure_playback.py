"""T020: fortune-engine/web/measure_playback.py — playback_events.jsonl 실측 요약 로직 검증.

네트워크·서버 구동 없이, 기록된 세션 레코드 리스트에 대한 순수 집계만 검증한다.
"""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).parent.parent
MOD_PATH = ROOT / "fortune-engine" / "web" / "measure_playback.py"

_spec = importlib.util.spec_from_file_location("t020_measure_playback", MOD_PATH)
measure_playback = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(measure_playback)

load_records = measure_playback.load_records
summarize = measure_playback.summarize
format_report = measure_playback.format_report


def _record(text_latency, audio_latency, cache_status, synthesis_costs=()):
    return {
        "fortuneId": "mock_x",
        "events": [
            {"event": "tts_generate_start"},
            *({"event": "tts_generate_complete", "costUsd": cost} for cost in synthesis_costs),
        ],
        "summary": {
            "textLatencyMs": text_latency,
            "audioLatencyMs": audio_latency,
            "cacheStatus": cache_status,
        },
    }


def _share_record(*, share_initiated=False, share_completed=False, text_latency=100):
    events = []
    if share_initiated:
        events.append({"event": "share_initiated"})
    if share_completed:
        events.append({"event": "share_completed"})
    return {
        "fortuneId": "mock_x",
        "events": events,
        "summary": {"textLatencyMs": text_latency, "audioLatencyMs": text_latency + 200, "cacheStatus": "hit"},
    }


class TestLoadRecords:
    def test_missing_file_returns_empty_list(self, tmp_path):
        assert load_records(tmp_path / "does-not-exist.jsonl") == []

    def test_loads_jsonl_lines(self, tmp_path):
        path = tmp_path / "events.jsonl"
        path.write_text(
            '{"fortuneId": "a", "events": [], "summary": {}}\n'
            '{"fortuneId": "b", "events": [], "summary": {}}\n',
            encoding="utf-8",
        )
        records = load_records(path)
        assert len(records) == 2
        assert records[0]["fortuneId"] == "a"

    def test_skips_blank_lines(self, tmp_path):
        path = tmp_path / "events.jsonl"
        path.write_text('{"fortuneId": "a", "events": [], "summary": {}}\n\n', encoding="utf-8")
        assert len(load_records(path)) == 1


class TestSummarize:
    def test_empty_records(self):
        summary = summarize([])
        assert summary["sessions"] == 0
        assert summary["avgTextLatencyMs"] is None
        assert summary["avgAudioLatencyMs"] is None
        assert summary["cacheHitRate"] is None
        assert summary["newSynthesisCount"] == 0
        assert summary["estimatedNewSynthesisCostUsd"] == 0

    def test_averages_latencies(self):
        records = [_record(100, 300, "hit"), _record(200, 500, "hit")]
        summary = summarize(records)
        assert summary["avgTextLatencyMs"] == 150
        assert summary["avgAudioLatencyMs"] == 400

    def test_cache_hit_rate_all_hits(self):
        records = [_record(100, 300, "hit"), _record(120, 320, "hit")]
        summary = summarize(records)
        assert summary["cacheHitRate"] == 1.0

    def test_cache_hit_rate_mixed(self):
        records = [_record(100, 300, "hit"), _record(150, 1200, "miss", synthesis_costs=[0.0078])]
        summary = summarize(records)
        assert summary["cacheHitRate"] == 0.5

    def test_new_synthesis_count_and_cost(self):
        records = [
            _record(150, 1200, "miss", synthesis_costs=[0.0078]),
            _record(150, 1250, "miss", synthesis_costs=[0.0082]),
            _record(100, 300, "hit"),
        ]
        summary = summarize(records)
        assert summary["newSynthesisCount"] == 2
        assert summary["estimatedNewSynthesisCostUsd"] == round(0.0078 + 0.0082, 5)

    def test_sessions_counts_all_records_including_unknown_cache_status(self):
        records = [_record(None, None, "unknown")]
        summary = summarize(records)
        assert summary["sessions"] == 1
        assert summary["cacheHitRate"] is None  # unknown은 hit/miss 분모에서 제외


class TestShareRate:
    """T021: share_initiated/share_completed → 공유율(베타 임계 8%, v3 §13) 집계."""

    def test_share_rates_none_when_no_eligible_sessions(self):
        summary = summarize([])
        assert summary["shareInitiatedRate"] is None
        assert summary["shareCompletedRate"] is None

    def test_share_rates_computed_over_eligible_sessions(self):
        records = [
            _share_record(share_initiated=True, share_completed=True),
            _share_record(share_initiated=True, share_completed=False),
            _share_record(share_initiated=False, share_completed=False),
            _share_record(share_initiated=False, share_completed=False),
        ]
        summary = summarize(records)
        assert summary["shareInitiatedRate"] == 0.5
        assert summary["shareCompletedRate"] == 0.25

    def test_share_completed_reported_via_separate_record_still_counted(self):
        """부적 받기는 재생 리포트와 별도 /api/event 호출로 도착할 수 있다 —
        textLatencyMs가 없는 그 레코드는 분모(eligible_sessions)엔 안 들어가지만
        분자(share 카운트)에는 반영되어야 한다."""
        records = [
            _record(100, 300, "hit"),
            {
                "fortuneId": "mock_x",
                "events": [{"event": "share_completed"}],
                "summary": {"textLatencyMs": None, "audioLatencyMs": None, "cacheStatus": "unknown"},
            },
        ]
        summary = summarize(records)
        assert summary["shareCompletedRate"] == 1.0


class TestFormatReport:
    def test_reports_pass_when_thresholds_met(self):
        records = [_record(100, 300, "hit") for _ in range(10)]
        report = format_report(summarize(records))
        assert "PASS" in report
        assert "cacheHitRate" in report

    def test_reports_below_threshold_when_hit_rate_low(self):
        records = [_record(150, 1200, "miss", synthesis_costs=[0.0078]) for _ in range(10)]
        report = format_report(summarize(records))
        assert "BELOW threshold" in report

    def test_no_threshold_lines_when_empty(self):
        """세션이 0개면 임계값 대조 문구(PASS/BELOW/cost per session) 자체를 만들지 않는다."""
        report = format_report(summarize([]))
        assert "threshold" not in report
        assert "cost/session" not in report

    def test_reports_pass_when_share_completed_rate_meets_threshold(self):
        records = [_share_record(share_initiated=True, share_completed=True) for _ in range(10)]
        report = format_report(summarize(records))
        assert "shareCompletedRate" in report
        assert "PASS" in report

    def test_reports_below_threshold_when_share_completed_rate_low(self):
        records = [_share_record(share_initiated=False, share_completed=False) for _ in range(10)]
        report = format_report(summarize(records))
        assert "BELOW threshold" in report
