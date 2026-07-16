"""결정적 캐시 키를 가진 mock/OpenAI 음성 합성 어댑터."""

from __future__ import annotations

import hashlib
import json
import logging
import os
import tempfile
import time
from pathlib import Path
from typing import Callable

DEFAULT_PROVIDER = "openai"
DEFAULT_VOICE = "coral"
DEFAULT_MODEL = "gpt-4o-mini-tts"
DEFAULT_SPEED = 1.0
DEFAULT_EMOTION = "bright"

_CHARS_PER_SEC = 4.5
_DURATION_MIN_SEC = 45
_DURATION_MAX_SEC = 60
_COST_PER_MIN_USD = 0.015
_logger = logging.getLogger("shindang.adapters.tts")

Backend = Callable[[list[dict] | str, str, dict], dict]
_TTS_CACHE_DIR = Path.cwd() / "state" / "tts_cache"


def compute_script_hash(script: list[dict] | str) -> str:
    serialized = json.dumps(script, ensure_ascii=False, sort_keys=True)
    return hashlib.sha256(serialized.encode("utf-8")).hexdigest()


def compute_cache_key(
    script: list[dict] | str,
    *,
    provider: str = DEFAULT_PROVIDER,
    voice: str = DEFAULT_VOICE,
    speed: float = DEFAULT_SPEED,
    emotion: str = DEFAULT_EMOTION,
) -> str:
    return f"tts:v1:{provider}:{voice}:{compute_script_hash(script)}:{speed}:{emotion}"


def estimate_duration(script: list[dict] | str) -> float:
    if isinstance(script, list):
        total_chars = sum(len(segment.get("text", "")) for segment in script)
    else:
        total_chars = len(script)
    return max(_DURATION_MIN_SEC, min(_DURATION_MAX_SEC, total_chars / _CHARS_PER_SEC))


def _full_text(script: list[dict] | str) -> str:
    if isinstance(script, list):
        return " ".join(segment.get("text", "") for segment in script)
    return script


def _log_event(event: dict) -> None:
    _logger.info(json.dumps(event, ensure_ascii=False))


class TTSAdapter:
    """비용 발생 구현을 composition root에서만 선택하는 음성 합성 어댑터."""

    def __init__(
        self,
        *,
        mode: str,
        cache_dir: Path,
        backend: Backend | None = None,
        provider: str = DEFAULT_PROVIDER,
        voice: str = DEFAULT_VOICE,
        speed: float = DEFAULT_SPEED,
        emotion: str = DEFAULT_EMOTION,
    ) -> None:
        if mode not in {"mock", "openai"}:
            raise ValueError("TTS mode must be mock or openai")
        self.mode = mode
        self.cache_dir = cache_dir
        self.provider = provider
        self.voice = voice
        self.speed = speed
        self.emotion = emotion
        self._backend = backend

    def cache_key(self, script: list[dict] | str) -> str:
        return compute_cache_key(
            script,
            provider=self.provider,
            voice=self.voice,
            speed=self.speed,
            emotion=self.emotion,
        )

    def synthesize(self, script: list[dict] | str, *, event_sink=None) -> dict:
        emit = event_sink or _log_event
        cache_key = self.cache_key(script)
        metadata = {
            "provider": self.provider,
            "voice": self.voice,
            "model": DEFAULT_MODEL,
            "speed": self.speed,
            "emotion": self.emotion,
            "script_hash": compute_script_hash(script),
        }
        emit(
            {
                "event": "tts_generate_start",
                "cacheKey": cache_key,
                "provider": self.provider,
                "voice": self.voice,
                "model": DEFAULT_MODEL,
            }
        )
        started = time.monotonic()
        backend = self._backend or (
            self._openai_backend if self.mode == "openai" else self._mock_backend
        )
        result = backend(script, cache_key, metadata)
        duration_sec = estimate_duration(script)
        emit(
            {
                "event": "tts_generate_complete",
                "cacheKey": cache_key,
                "provider": self.provider,
                "voice": self.voice,
                "model": DEFAULT_MODEL,
                "latencyMs": round((time.monotonic() - started) * 1000, 1),
                "costUsd": round(duration_sec / 60 * _COST_PER_MIN_USD, 5),
            }
        )
        return {
            "audioUrl": result["audioUrl"],
            "durationSec": duration_sec,
            "cacheKey": cache_key,
            "metadata": metadata,
        }

    @staticmethod
    def _mock_backend(script, cache_key: str, metadata: dict) -> dict:
        del script, metadata
        return {"audioUrl": f"mock://{cache_key}"}

    def _openai_backend(self, script, cache_key: str, metadata: dict) -> dict:
        if not os.getenv("OPENAI_API_KEY"):
            raise RuntimeError(
                "OPENAI_API_KEY is not set — refusing billed TTS synthesis"
            )

        from openai import OpenAI

        self.cache_dir.mkdir(parents=True, exist_ok=True)
        output = (
            self.cache_dir / f"{hashlib.sha256(cache_key.encode()).hexdigest()}.mp3"
        )
        if not output.is_file() or output.stat().st_size == 0:
            client = OpenAI()
            temporary_path: Path | None = None
            try:
                with tempfile.NamedTemporaryFile(
                    dir=self.cache_dir,
                    prefix=f".{output.stem}.",
                    suffix=".tmp",
                    delete=False,
                ) as temporary:
                    temporary_path = Path(temporary.name)
                with client.audio.speech.with_streaming_response.create(
                    model=metadata["model"],
                    voice=metadata["voice"],
                    input=_full_text(script),
                ) as response:
                    response.stream_to_file(str(temporary_path))
                if temporary_path.stat().st_size == 0:
                    raise RuntimeError("OpenAI TTS returned an empty audio file")
                with temporary_path.open("rb") as audio_file:
                    os.fsync(audio_file.fileno())
                os.replace(temporary_path, output)
                temporary_path = None
            finally:
                if temporary_path is not None:
                    temporary_path.unlink(missing_ok=True)
        return {"audioUrl": f"file://{output}"}


def openai_backend(script, cache_key: str, metadata: dict) -> dict:
    """오프라인 도구·회귀 테스트용 함수형 OpenAI 어댑터."""
    return TTSAdapter(mode="openai", cache_dir=_TTS_CACHE_DIR)._openai_backend(
        script, cache_key, metadata
    )


def synthesize(
    script,
    *,
    provider: str = DEFAULT_PROVIDER,
    voice: str = DEFAULT_VOICE,
    speed: float = DEFAULT_SPEED,
    emotion: str = DEFAULT_EMOTION,
    backend: Backend | None = None,
    event_sink=None,
) -> dict:
    """함수형 호출이 필요한 실험·테스트를 위한 얇은 어댑터."""
    adapter = TTSAdapter(
        mode="mock",
        cache_dir=_TTS_CACHE_DIR,
        backend=backend,
        provider=provider,
        voice=voice,
        speed=speed,
        emotion=emotion,
    )
    return adapter.synthesize(script, event_sink=event_sink)
