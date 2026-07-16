"""단일 인스턴스용 비용 방어 rate-limit 어댑터."""

from __future__ import annotations

import os
import threading
import time
from dataclasses import dataclass


def _positive_int_env(name: str, default: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError as error:
        raise RuntimeError(f"{name} must be a positive integer") from error
    if value <= 0:
        raise RuntimeError(f"{name} must be a positive integer")
    return value


@dataclass(frozen=True)
class RateLimits:
    hourly: dict[str, tuple[int, int]]
    daily: dict[str, int]
    event_body_max_bytes: int

    @classmethod
    def from_env(cls) -> "RateLimits":
        return cls(
            hourly={
                "fortune": (_positive_int_env("RL_FORTUNE_PER_HOUR", 30), 3600),
                "dream": (_positive_int_env("RL_DREAM_PER_HOUR", 10), 3600),
                "login": (_positive_int_env("RL_LOGIN_PER_10MIN", 10), 600),
                "event": (_positive_int_env("RL_EVENT_PER_HOUR", 120), 3600),
                "tts": (_positive_int_env("RL_TTS_PER_HOUR", 20), 3600),
            },
            daily={
                "fortune-daily": _positive_int_env("FORTUNE_DAILY_LIMIT", 5),
                "dream-daily": _positive_int_env("DREAM_DAILY_LIMIT", 10),
            },
            event_body_max_bytes=_positive_int_env("EVENT_BODY_MAX_BYTES", 32 * 1024),
        )


class MemoryRateLimiter:
    def __init__(self) -> None:
        self._buckets: dict[tuple, int] = {}
        self._last_sweep = 0.0
        self._guard = threading.Lock()

    def check(
        self, scope: str, identity: str, limit: int, window_sec: int
    ) -> tuple[bool, int]:
        now = time.time()
        with self._guard:
            if now - self._last_sweep >= 60:
                self._last_sweep = now
                self._buckets = {
                    key: value for key, value in self._buckets.items() if key[3] >= now
                }
            window_start = int(now // window_sec) * window_sec
            window_end = window_start + window_sec
            key = (scope, identity, window_start, window_end)
            count = self._buckets.get(key, 0)
            if count >= limit:
                return False, max(1, int(window_end - now))
            self._buckets[key] = count + 1
            return True, 0
