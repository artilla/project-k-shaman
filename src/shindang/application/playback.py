"""운세 생성, 2단 캐시, 선택적 TTS를 조립하는 애플리케이션 유스케이스."""

from __future__ import annotations

from collections.abc import Callable

from shindang.domain.fortune import build_fortune
from shindang.domain.seed import build_seed

from .cache import fortune_cache_key, get_or_compute
from .ports import CacheStore, SpeechSynthesizer

FortuneBuilder = Callable[[dict, dict], dict]
SeedHashFunction = Callable[[str], str]


class PlaybackService:
    def __init__(
        self,
        cache: CacheStore[dict],
        speech: SpeechSynthesizer,
        *,
        seed_hash_fn: SeedHashFunction | None = None,
    ) -> None:
        self.cache = cache
        self.speech = speech
        self.seed_hash_fn = seed_hash_fn

    def build(
        self,
        request: dict,
        *,
        include_tts: bool,
        fortune_builder: FortuneBuilder = build_fortune,
    ) -> dict:
        """텍스트 경로는 TTS 합성과 TTS 캐시 쓰기를 모두 건너뛴다."""
        events: list[dict] = []
        seed = (
            build_seed(request, hash_fn=self.seed_hash_fn)
            if self.seed_hash_fn is not None
            else build_seed(request)
        )
        fortune_data = get_or_compute(
            self.cache,
            fortune_cache_key(seed["seed_hash"]),
            lambda: fortune_builder(request, seed),
            layer="fortune",
            event_sink=events.append,
        )
        script = fortune_data["script"]
        tts_key = self.speech.cache_key(script)

        if not include_tts:
            return {
                "fortuneId": fortune_data["fortune_id"],
                "audioUrl": None,
                "durationSec": None,
                "script": script,
                "fortune": fortune_data["fortune"],
                "tts": {"cacheKey": tts_key},
                "events": events,
            }

        tts = get_or_compute(
            self.cache,
            tts_key,
            lambda: self.speech.synthesize(script, event_sink=events.append),
            layer="tts",
            event_sink=events.append,
        )
        return {
            "fortuneId": fortune_data["fortune_id"],
            "audioUrl": tts["audioUrl"],
            "durationSec": tts["durationSec"],
            "script": script,
            "fortune": fortune_data["fortune"],
            "tts": {
                "cacheKey": tts["cacheKey"],
                "provider": tts["metadata"]["provider"],
                "voice": tts["metadata"]["voice"],
                "model": tts["metadata"]["model"],
                "speed": tts["metadata"]["speed"],
                "emotion": tts["metadata"]["emotion"],
            },
            "events": events,
        }
