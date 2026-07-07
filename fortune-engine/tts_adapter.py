"""TTS Adapter — deterministic cache key and mock/real audioUrl (ADR-0001).

Default backend is mock (no network, no cost). `openai_backend` performs the
real OpenAI gpt-4o-mini-tts + coral synthesis (T018, approved:
docs/approvals/T018.md) and is only invoked when explicitly injected via the
`backend` parameter — it requires OPENAI_API_KEY and makes a real, billed
network call. The module default stays mock either way.
"""
import hashlib
import json
import logging
import os
import time
from pathlib import Path

_ROOT = Path(__file__).parent.parent
_TTS_CACHE_DIR = _ROOT / "state" / "tts_cache"
_logger = logging.getLogger("fortune_engine.tts_adapter")

DEFAULT_PROVIDER = "openai"
DEFAULT_VOICE = "coral"          # ADR-0001: coral voice
DEFAULT_MODEL = "gpt-4o-mini-tts"  # ADR-0001
DEFAULT_SPEED = 1.0
DEFAULT_EMOTION = "bright"

# Korean speech rate: ~4.5 chars/sec (270 chars/min, includes pauses)
_CHARS_PER_SEC = 4.5
_DURATION_MIN_SEC = 45  # Plan.md §2 band
_DURATION_MAX_SEC = 60  # Plan.md §2 band

# ADR-0001 §3: internal $/min conversion derived from the official per-token
# price, not an official per-minute billing unit. Used only to log a cost
# estimate alongside each synthesis event (v3 §17 "TTS 비용/사용자" KPI).
_COST_PER_MIN_USD = 0.015


def _compute_script_hash(script) -> str:
    serialized = json.dumps(script, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def _estimate_duration(script) -> float:
    """Deterministic duration estimate from script text length, clamped to 45–60s."""
    total_chars = 0
    if isinstance(script, list):
        for segment in script:
            total_chars += len(segment.get("text", ""))
    elif isinstance(script, str):
        total_chars = len(script)
    raw = total_chars / _CHARS_PER_SEC
    return max(_DURATION_MIN_SEC, min(_DURATION_MAX_SEC, raw))


def _mock_backend(script, cache_key, metadata):
    """Mock backend — no network, no cost. §3 hold: replace with real backend."""
    return {"audioUrl": f"mock://{cache_key}"}


def _full_text(script) -> str:
    """Join narration segments into one synthesis input string."""
    if isinstance(script, list):
        return " ".join(segment.get("text", "") for segment in script)
    return str(script)


def _default_event_sink(event: dict) -> None:
    """Structured log line for beta instrumentation hooks (v3 §17)."""
    _logger.info(json.dumps(event, ensure_ascii=False))


def openai_backend(script, cache_key, metadata):
    """Real OpenAI gpt-4o-mini-tts + coral synthesis backend (ADR-0001, T018).

    Requires OPENAI_API_KEY (env var only — the value is never read into a
    variable here; the OpenAI SDK picks it up itself, so it can't leak into
    logs/fixtures per runbook §4). Performs a real, billed network call — only
    reached when explicitly injected via synthesize(..., backend=openai_backend).

    Output is cached to state/tts_cache/ (gitignored) keyed by a hash of
    cache_key, as a defense-in-depth guard against re-billing the same
    synthesis outside of cache_layer's own dedup (T015).
    """
    if not os.getenv("OPENAI_API_KEY"):
        raise RuntimeError(
            "OPENAI_API_KEY is not set — openai_backend requires a real API key"
        )

    from openai import OpenAI

    _TTS_CACHE_DIR.mkdir(parents=True, exist_ok=True)
    file_name = hashlib.sha256(cache_key.encode("utf-8")).hexdigest() + ".mp3"
    out_path = _TTS_CACHE_DIR / file_name

    if not out_path.exists():
        client = OpenAI()
        with client.audio.speech.with_streaming_response.create(
            model=metadata["model"], voice=metadata["voice"], input=_full_text(script),
        ) as resp:
            resp.stream_to_file(str(out_path))

    return {"audioUrl": f"file://{out_path}"}


def synthesize(
    script,
    *,
    provider=DEFAULT_PROVIDER,
    voice=DEFAULT_VOICE,
    speed=DEFAULT_SPEED,
    emotion=DEFAULT_EMOTION,
    backend=None,
    event_sink=None,
) -> dict:
    """Return deterministic TTS result dict.

    Args:
        script: narration from compose_narration (list of segment dicts) or str.
        provider: TTS provider. Default: "openai" (ADR-0001).
        voice: voice ID. Default: "coral" (ADR-0001).
        speed: speech speed multiplier. Default: 1.0.
        emotion: emotion tag. Default: "bright".
        backend: callable(script, cache_key, metadata) → {"audioUrl": str}.
                 Default: mock backend (no network, no cost).
                 Inject `openai_backend` for real production synthesis.
        event_sink: callable(event: dict) for tts_generate_start/complete (v3 §17).
                    Default: structured log line via the standard logging module.

    Returns:
        {"audioUrl": str, "durationSec": float, "cacheKey": str, "metadata": dict}
    """
    if backend is None:
        backend = _mock_backend
    if event_sink is None:
        event_sink = _default_event_sink

    script_hash = _compute_script_hash(script)
    cache_key = f"tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion}"

    metadata = {
        "provider": provider,
        "voice": voice,
        "model": DEFAULT_MODEL,
        "speed": speed,
        "emotion": emotion,
        "script_hash": script_hash,
    }

    event_sink({"event": "tts_generate_start", "cacheKey": cache_key,
                "provider": provider, "voice": voice, "model": DEFAULT_MODEL})
    started = time.monotonic()
    backend_result = backend(script, cache_key, metadata)
    latency_ms = round((time.monotonic() - started) * 1000, 1)
    duration_sec = _estimate_duration(script)
    cost_usd = round(duration_sec / 60 * _COST_PER_MIN_USD, 5)
    event_sink({"event": "tts_generate_complete", "cacheKey": cache_key,
                "provider": provider, "voice": voice, "model": DEFAULT_MODEL,
                "latencyMs": latency_ms, "costUsd": cost_usd})

    return {
        "audioUrl": backend_result["audioUrl"],
        "durationSec": duration_sec,
        "cacheKey": cache_key,
        "metadata": metadata,
    }
