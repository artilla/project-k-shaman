"""외부 어댑터를 유스케이스에 연결하는 유일한 composition root."""

from __future__ import annotations

from dataclasses import dataclass

from .adapters.audio import AudioStore
from .adapters.cache import InMemoryCacheStore
from .adapters.events import JsonlEventRepository
from .adapters.fortune_store import RecentFortuneStore
from .adapters.oauth import HttpOAuthGateway
from .adapters.rate_limit import MemoryRateLimiter, RateLimits
from .adapters.seed_hash import profile_hash_fn
from .adapters.session import InMemorySessionStore
from .adapters.tts import TTSAdapter
from .application.playback import PlaybackService
from .application.ports import (
    EventRepository,
    FortuneRepository,
    OAuthGateway,
    RateLimiter,
    SessionStore,
    SpeechSynthesizer,
)
from .config import Settings


@dataclass
class AppContainer:
    settings: Settings
    playback: PlaybackService
    speech: SpeechSynthesizer
    audio: AudioStore
    oauth: OAuthGateway
    sessions: SessionStore
    fortunes: FortuneRepository
    rate_limiter: RateLimiter
    rate_limits: RateLimits
    events: EventRepository


def build_container(
    settings: Settings,
    *,
    speech: SpeechSynthesizer | None = None,
    oauth: OAuthGateway | None = None,
) -> AppContainer:
    speech_adapter = speech or TTSAdapter(
        mode=settings.tts_backend, cache_dir=settings.tts_cache_dir
    )
    cache = InMemoryCacheStore[dict]()
    return AppContainer(
        settings=settings,
        playback=PlaybackService(
            cache,
            speech_adapter,
            seed_hash_fn=profile_hash_fn(settings.session_secret),
        ),
        speech=speech_adapter,
        audio=AudioStore(settings.tts_backend, settings.tts_cache_dir),
        oauth=oauth or HttpOAuthGateway.from_env(),
        sessions=InMemorySessionStore(),
        fortunes=RecentFortuneStore(),
        rate_limiter=MemoryRateLimiter(),
        rate_limits=RateLimits.from_env(),
        events=JsonlEventRepository(settings.events_log_path),
    )
