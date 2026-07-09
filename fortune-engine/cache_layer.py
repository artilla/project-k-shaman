"""Text/TTS cache layer — get-or-compute dedup with injectable store.

§3 hold: real Redis/S3/CDN backends are NOT implemented here.
Default stores are in-memory or file-backed (no network, no cost).
To plug in a real backend, inject a store that implements get(key)/set(key, value).
"""
import hashlib
import json
import logging
import threading
from collections import defaultdict
from pathlib import Path

_logger = logging.getLogger("fortune_engine.cache_layer")

# 리뷰 P1-9: miss→compute→set 경합으로 동일 키 compute가 중복 실행되던 문제 —
# 키별 락으로 단일 프로세스 내 원자성을 보장한다 (실 TTS 중복 과금·파일 쓰기 경합 방지).
# 다중 프로세스 배포 시에는 store 계층(Redis SETNX 등)에서 해결한다 (§3 hold).
_key_locks: dict = defaultdict(threading.Lock)
_key_locks_guard = threading.Lock()


def _lock_for(key: str) -> threading.Lock:
    with _key_locks_guard:
        return _key_locks[key]


def _default_event_sink(event: dict) -> None:
    """Structured log line for beta instrumentation hooks (v3 §17)."""
    _logger.info(json.dumps(event, ensure_ascii=False))


# ── Key helpers ─────────────────────────────────────────────────────────────

def fortune_cache_key(seed_hash: str) -> str:
    """Return the cache key for a fortune/text result.

    Args:
        seed_hash: hash string from seed_builder.build_seed["seed_hash"].

    Returns:
        "fortune:v1:{seed_hash}"
    """
    return f"fortune:v1:{seed_hash}"


# TTS side: use tts_adapter.synthesize result["cacheKey"] verbatim as the key.
# No helper needed — the adapter already returns the correct key.


# ── get-or-compute ───────────────────────────────────────────────────────────

def get_or_compute(store, key: str, compute_fn, *, layer: str = "unknown", event_sink=None):
    """Return cached value for key, or compute, store, and return it.

    Dedup invariant: if key is present in store, compute_fn is never called.
    On miss: compute_fn() is called exactly once, result is stored.

    Args:
        store: duck-typed cache store with get(key) → value|None and
               set(key, value). Also exposes hits/misses counters.
        key: cache key string.
        compute_fn: zero-argument callable returning the value to cache on miss.
        layer: cache layer tag for instrumentation (e.g. "fortune", "tts"; v3 §17).
        event_sink: callable(event: dict) for cache_hit/cache_miss.
                    Default: structured log line via the standard logging module.

    Returns:
        Cached or freshly computed value.
    """
    if event_sink is None:
        event_sink = _default_event_sink

    cached = store.get(key)
    if cached is not None:
        event_sink({"event": "cache_hit", "layer": layer, "key": key})
        return cached

    # 키별 락 + 이중 확인 — 동시 miss에서도 compute_fn은 프로세스당 1회만 실행된다 (P1-9)
    with _lock_for(key):
        cached = store.get(key)
        if cached is not None:
            event_sink({"event": "cache_hit", "layer": layer, "key": key})
            return cached
        event_sink({"event": "cache_miss", "layer": layer, "key": key})
        value = compute_fn()
        store.set(key, value)
        return value


# ── Store implementations ────────────────────────────────────────────────────

class InMemoryCacheStore:
    """dict-backed cache store. No network, no cost.

    §3 hold: replace with real Redis/Memcached backend via injection.
    Not safe for concurrent multi-process use (mock scope only).
    """

    def __init__(self):
        self._data: dict = {}
        self.hits: int = 0
        self.misses: int = 0

    def get(self, key: str):
        if key in self._data:
            self.hits += 1
            return self._data[key]
        self.misses += 1
        return None

    def set(self, key: str, value) -> None:
        self._data[key] = value


class FileCacheStore:
    """JSON-file-backed cache store. Values survive process restarts.

    Same base_dir → same persistent cache across instances.
    No network, no cost. Dev/test use only.

    §3 hold: replace with real S3/object-storage backend via injection.
    Concurrent multi-process writes are not safe (mock scope — single process).
    """

    def __init__(self, base_dir: str):
        self._base_dir = Path(base_dir)
        self._base_dir.mkdir(parents=True, exist_ok=True)
        self.hits: int = 0
        self.misses: int = 0

    def _file_path(self, key: str) -> Path:
        # Hash the key to produce a safe filename.
        key_hash = hashlib.sha256(key.encode("utf-8")).hexdigest()
        return self._base_dir / f"{key_hash}.json"

    def get(self, key: str):
        path = self._file_path(key)
        if path.exists():
            self.hits += 1
            with path.open("r", encoding="utf-8") as f:
                return json.load(f)
        self.misses += 1
        return None

    def set(self, key: str, value) -> None:
        path = self._file_path(key)
        with path.open("w", encoding="utf-8") as f:
            json.dump(value, f, ensure_ascii=False)
