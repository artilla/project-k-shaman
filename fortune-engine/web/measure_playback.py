#!/usr/bin/env python3
"""T020: state/events/playback_events.jsonl 실측 요약 — §1.6-② "탭→첫 재생 3초" 경로와
베타 임계값(캐시 히트율 70%, ≤$0.01/세션, docs/master-spec.md §1.6)을 실측치로 대조한다.

각 레코드는 server.py의 /api/event가 남긴 {"fortuneId", "events", "summary"} 한 세션분이다.
tap→first_text_visible/first_audio_play 지연은 summary에, 신규합성 비용은 events 안의
tts_generate_complete.costUsd에 이미 들어 있으므로 이 스크립트는 파일을 읽어 집계만 한다
(네트워크 호출 없음, 순수 로그 분석).

실행: python3 fortune-engine/web/measure_playback.py [--events-log <path>]
"""
import argparse
import json
from pathlib import Path

_WEB_DIR = Path(__file__).resolve().parent
_DEFAULT_EVENTS_LOG_PATH = _WEB_DIR.parent.parent / "state" / "events" / "playback_events.jsonl"

_CACHE_HIT_RATE_THRESHOLD = 0.70
_COST_PER_SESSION_THRESHOLD_USD = 0.01


def load_records(path: Path = _DEFAULT_EVENTS_LOG_PATH) -> list:
    if not path.exists():
        return []
    records = []
    with path.open("r", encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                records.append(json.loads(line))
    return records


def summarize(records: list) -> dict:
    """세션 레코드 리스트 → 지연/캐시히트율/신규합성비용 요약 dict.

    Returns:
        {
            "sessions": int,
            "avgTextLatencyMs": float|None,
            "avgAudioLatencyMs": float|None,
            "cacheHitRate": float|None,   # hit 세션 수 / (hit+miss 세션 수), mixed/unknown 제외
            "newSynthesisCount": int,     # tts_generate_complete 이벤트 총합
            "estimatedNewSynthesisCostUsd": float,
        }
    """
    text_latencies = []
    audio_latencies = []
    cache_statuses = []
    synthesis_costs = []

    for record in records:
        summary = record.get("summary", {})
        if summary.get("textLatencyMs") is not None:
            text_latencies.append(summary["textLatencyMs"])
        if summary.get("audioLatencyMs") is not None:
            audio_latencies.append(summary["audioLatencyMs"])
        if summary.get("cacheStatus") in ("hit", "miss"):
            cache_statuses.append(summary["cacheStatus"])
        for event in record.get("events", []):
            if event.get("event") == "tts_generate_complete":
                synthesis_costs.append(event.get("costUsd", 0))

    hit_count = cache_statuses.count("hit")
    cache_hit_rate = (hit_count / len(cache_statuses)) if cache_statuses else None

    return {
        "sessions": len(records),
        "avgTextLatencyMs": (sum(text_latencies) / len(text_latencies)) if text_latencies else None,
        "avgAudioLatencyMs": (sum(audio_latencies) / len(audio_latencies)) if audio_latencies else None,
        "cacheHitRate": cache_hit_rate,
        "newSynthesisCount": len(synthesis_costs),
        "estimatedNewSynthesisCostUsd": round(sum(synthesis_costs), 5),
    }


def format_report(summary: dict) -> str:
    lines = [json.dumps(summary, ensure_ascii=False, indent=2)]

    if summary["cacheHitRate"] is not None:
        verdict = "PASS" if summary["cacheHitRate"] >= _CACHE_HIT_RATE_THRESHOLD else "BELOW threshold"
        lines.append(
            f"cacheHitRate {summary['cacheHitRate']:.2%} "
            f"(threshold >= {_CACHE_HIT_RATE_THRESHOLD:.0%}): {verdict}"
        )

    if summary["sessions"]:
        cost_per_session = summary["estimatedNewSynthesisCostUsd"] / summary["sessions"]
        verdict = "PASS" if cost_per_session <= _COST_PER_SESSION_THRESHOLD_USD else "ABOVE threshold"
        lines.append(
            f"est. cost/session ${cost_per_session:.5f} "
            f"(threshold <= ${_COST_PER_SESSION_THRESHOLD_USD}): {verdict}"
        )

    return "\n".join(lines)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--events-log", type=Path, default=_DEFAULT_EVENTS_LOG_PATH)
    args = parser.parse_args()

    records = load_records(args.events_log)
    summary = summarize(records)
    print(format_report(summary))


if __name__ == "__main__":
    main()
