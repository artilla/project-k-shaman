"""TTS Adapter — deterministic cache key and mock audioUrl.

§3 hold: real TTS synthesis (API calls, network, cost) is NOT implemented here.
The default backend is mock only (no network, no cost).
To add real synthesis, inject a backend callable via the `backend` parameter.
"""
import hashlib
import json

DEFAULT_PROVIDER = "openai"
DEFAULT_VOICE = "coral"          # ADR-0001: coral voice
DEFAULT_MODEL = "gpt-4o-mini-tts"  # ADR-0001
DEFAULT_SPEED = 1.0
DEFAULT_EMOTION = "bright"

# Korean speech rate: ~4.5 chars/sec (270 chars/min, includes pauses)
_CHARS_PER_SEC = 4.5
_DURATION_MIN_SEC = 45  # Plan.md §2 band
_DURATION_MAX_SEC = 60  # Plan.md §2 band


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


def synthesize(
    script,
    *,
    provider=DEFAULT_PROVIDER,
    voice=DEFAULT_VOICE,
    speed=DEFAULT_SPEED,
    emotion=DEFAULT_EMOTION,
    backend=None,
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
                 §3 hold: inject real OpenAI backend here for production synthesis.

    Returns:
        {"audioUrl": str, "durationSec": float, "cacheKey": str, "metadata": dict}
    """
    if backend is None:
        backend = _mock_backend

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

    backend_result = backend(script, cache_key, metadata)
    duration_sec = _estimate_duration(script)

    return {
        "audioUrl": backend_result["audioUrl"],
        "durationSec": duration_sec,
        "cacheKey": cache_key,
        "metadata": metadata,
    }
