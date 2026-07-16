"""캐시 포트 위에서 동작하는 원자적 get-or-compute 유스케이스."""

from __future__ import annotations

import json
import logging
import threading
from contextlib import contextmanager
from typing import Callable, Iterator, TypeVar

from .ports import CacheStore

T = TypeVar("T")
EventSink = Callable[[dict], None]
_logger = logging.getLogger("shindang.application.cache")


class _KeyedLockPool:
    """키별 락을 사용 중인 동안만 보존해 장기 프로세스의 키 누적을 막는다."""

    def __init__(self) -> None:
        self._guard = threading.Lock()
        self._entries: dict[str, tuple[threading.Lock, int]] = {}

    @contextmanager
    def hold(self, key: str) -> Iterator[None]:
        with self._guard:
            lock, users = self._entries.get(key, (threading.Lock(), 0))
            self._entries[key] = (lock, users + 1)
        lock.acquire()
        try:
            yield
        finally:
            lock.release()
            with self._guard:
                current_lock, users = self._entries[key]
                if users == 1:
                    self._entries.pop(key, None)
                else:
                    self._entries[key] = (current_lock, users - 1)


_keyed_locks = _KeyedLockPool()


def _log_event(event: dict) -> None:
    _logger.info(json.dumps(event, ensure_ascii=False))


def fortune_cache_key(seed_hash: str) -> str:
    return f"fortune:v1:{seed_hash}"


def get_or_compute(
    store: CacheStore[T],
    key: str,
    compute: Callable[[], T],
    *,
    layer: str = "unknown",
    event_sink: EventSink | None = None,
) -> T:
    """동일 프로세스의 동시 miss에서도 계산을 한 번만 수행한다."""
    emit = event_sink or _log_event
    cached = store.get(key)
    if cached is not None:
        emit({"event": "cache_hit", "layer": layer, "key": key})
        return cached

    with _keyed_locks.hold(key):
        cached = store.get(key)
        if cached is not None:
            emit({"event": "cache_hit", "layer": layer, "key": key})
            return cached
        emit({"event": "cache_miss", "layer": layer, "key": key})
        value = compute()
        store.set(key, value)
        return value
