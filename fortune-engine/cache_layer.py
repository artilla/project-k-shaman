"""Text/TTS cache layer — get-or-compute dedup with injectable store.

§3 hold: real Redis/S3/CDN backends are NOT implemented here.
Default stores are in-memory or file-backed (no network, no cost).
To plug in a real backend, inject a store that implements get(key)/set(key, value).
"""
import hashlib
import json
from pathlib import Path


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

def get_or_compute(store, key: str, compute_fn):
    """Return cached value for key, or compute, store, and return it.

    Dedup invariant: if key is present in store, compute_fn is never called.
    On miss: compute_fn() is called exactly once, result is stored.

    Args:
        store: duck-typed cache store with get(key) → value|None and
               set(key, value). Also exposes hits/misses counters.
        key: cache key string.
        compute_fn: zero-argument callable returning the value to cache on miss.

    Returns:
        Cached or freshly computed value.
    """
    cached = store.get(key)
    if cached is not None:
        return cached
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
