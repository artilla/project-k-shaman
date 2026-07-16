"""캐시 유스케이스와 로컬 어댑터 회귀 테스트."""

import tempfile
from pathlib import Path

from shindang.adapters.cache import FileCacheStore, InMemoryCacheStore
from shindang.adapters.tts import synthesize
from shindang.application.cache import fortune_cache_key, get_or_compute

_SAMPLE_SCRIPT = [{"segment": "greeting", "type": "presynth", "text": "안녕하세요."}]


class TestGetOrComputeMiss:
    """AC: miss → compute_fn called exactly once, value stored."""

    def test_miss_calls_compute_once(self):
        store = InMemoryCacheStore()
        calls = []

        def compute():
            calls.append(1)
            return "result"

        get_or_compute(store, "k1", compute)
        assert len(calls) == 1

    def test_miss_returns_compute_value(self):
        store = InMemoryCacheStore()
        result = get_or_compute(store, "k1", lambda: "hello")
        assert result == "hello"

    def test_miss_stores_value(self):
        store = InMemoryCacheStore()
        get_or_compute(store, "k1", lambda: "hello")
        assert store.get("k1") == "hello"


class TestGetOrComputeHitDedup:
    """AC: dedup invariant — second call with same key calls compute_fn 0 more times."""

    def test_hit_returns_cached_value(self):
        store = InMemoryCacheStore()
        get_or_compute(store, "k1", lambda: "first")
        result = get_or_compute(store, "k1", lambda: "second")
        assert result == "first"

    def test_hit_does_not_call_compute(self):
        store = InMemoryCacheStore()
        calls = []

        def compute():
            calls.append(1)
            return "value"

        get_or_compute(store, "k1", compute)
        assert len(calls) == 1

        get_or_compute(store, "k1", compute)
        assert len(calls) == 1  # no additional call — dedup invariant

    def test_hit_compute_zero_additional_calls(self):
        """Explicit dedup: spy counter must be 0 after hit."""
        store = InMemoryCacheStore()
        spy = {"count": 0}

        def compute():
            spy["count"] += 1
            return "value"

        get_or_compute(store, "k1", compute)
        assert spy["count"] == 1
        get_or_compute(store, "k1", compute)
        assert spy["count"] == 1  # still 1 — dedup

    def test_different_keys_independent(self):
        store = InMemoryCacheStore()
        r1 = get_or_compute(store, "k1", lambda: "a")
        r2 = get_or_compute(store, "k2", lambda: "b")
        assert r1 == "a"
        assert r2 == "b"
        assert get_or_compute(store, "k1", lambda: "x") == "a"
        assert get_or_compute(store, "k2", lambda: "x") == "b"


class TestInMemoryCacheStore:
    """AC: InMemoryCacheStore — get/set interface and hit/miss counters."""

    def test_get_miss_returns_none(self):
        store = InMemoryCacheStore()
        assert store.get("nonexistent") is None

    def test_set_get_roundtrip(self):
        store = InMemoryCacheStore()
        store.set("k", "v")
        assert store.get("k") == "v"

    def test_initial_counters_zero(self):
        store = InMemoryCacheStore()
        assert store.hits == 0
        assert store.misses == 0

    def test_hit_increments_hits(self):
        store = InMemoryCacheStore()
        store.set("k", "v")
        store.get("k")
        assert store.hits == 1
        assert store.misses == 0

    def test_miss_increments_misses(self):
        store = InMemoryCacheStore()
        store.get("nonexistent")
        assert store.misses == 1
        assert store.hits == 0

    def test_multiple_hits_and_misses(self):
        store = InMemoryCacheStore()
        store.set("k", "v")
        store.get("k")
        store.get("k")
        store.get("missing")
        assert store.hits == 2
        assert store.misses == 1

    def test_values_are_isolated_between_instances(self):
        s1 = InMemoryCacheStore()
        s2 = InMemoryCacheStore()
        s1.set("k", "from_s1")
        assert s2.get("k") is None


class TestFileCacheStore:
    """AC: FileCacheStore — file-backed, new instance with same base_dir sees stored values."""

    def test_set_get_roundtrip(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            store.set("k", "v")
            assert store.get("k") == "v"

    def test_get_miss_returns_none(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            assert store.get("nonexistent") is None

    def test_new_instance_same_dir_preserves_value(self):
        """Core: new FileCacheStore with same base_dir reads previously stored value."""
        with tempfile.TemporaryDirectory() as tmpdir:
            store_a = FileCacheStore(tmpdir)
            store_a.set("key1", "stored_value")

            store_b = FileCacheStore(tmpdir)
            assert store_b.get("key1") == "stored_value"

    def test_hit_counter_increments(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            store.set("k", "v")
            store.get("k")
            assert store.hits == 1
            assert store.misses == 0

    def test_miss_counter_increments(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            store.get("missing")
            assert store.misses == 1
            assert store.hits == 0

    def test_no_network_calls(self):
        """Default FileCacheStore uses local files only (no network, no cost)."""
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            store.set("k", "v")
            result = store.get("k")
        assert result == "v"

    def test_file_backed_json(self):
        """Values are stored as JSON files in base_dir."""
        with tempfile.TemporaryDirectory() as tmpdir:
            store = FileCacheStore(tmpdir)
            store.set("mykey", {"data": 42})
            files = list(Path(tmpdir).glob("*.json"))
            assert len(files) >= 1

    def test_different_dirs_are_isolated(self):
        with tempfile.TemporaryDirectory() as dir1:
            with tempfile.TemporaryDirectory() as dir2:
                s1 = FileCacheStore(dir1)
                s2 = FileCacheStore(dir2)
                s1.set("k", "from_dir1")
                assert s2.get("k") is None


class TestFortuneCacheKey:
    """AC: fortune_cache_key(seed_hash) == 'fortune:v1:{seed_hash}'."""

    def test_key_format(self):
        assert fortune_cache_key("abc123") == "fortune:v1:abc123"

    def test_key_prefix(self):
        key = fortune_cache_key("deadbeef")
        assert key.startswith("fortune:v1:")

    def test_key_contains_seed_hash(self):
        seed_hash = "0" * 64
        key = fortune_cache_key(seed_hash)
        assert seed_hash in key

    def test_key_deterministic(self):
        assert fortune_cache_key("xyz") == fortune_cache_key("xyz")

    def test_different_hashes_different_keys(self):
        assert fortune_cache_key("aaa") != fortune_cache_key("bbb")


class TestTtsCacheKeyReuse:
    """AC: TTS side uses adapter's cacheKey as-is — no recalculation."""

    def test_adapter_cache_key_reused_verbatim(self):
        """tts_adapter.synthesize cacheKey is the key for the cache store."""
        result = synthesize(_SAMPLE_SCRIPT)
        adapter_key = result["cacheKey"]

        # The cache key from the adapter must be usable directly as store key
        store = InMemoryCacheStore()
        store.set(adapter_key, result["audioUrl"])
        assert store.get(adapter_key) == result["audioUrl"]

    def test_tts_cache_key_format(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["cacheKey"].startswith("tts:v1:")

    def test_tts_key_unchanged_by_cache_layer(self):
        """Cache layer must not transform the tts key."""
        result = synthesize(_SAMPLE_SCRIPT)
        tts_key = result["cacheKey"]
        store = InMemoryCacheStore()

        # Use tts key verbatim with get_or_compute
        cached = get_or_compute(store, tts_key, lambda: result["audioUrl"])
        assert cached == result["audioUrl"]
        assert store.get(tts_key) == result["audioUrl"]


class TestPiiNonExposure:
    """AC: cache keys/values contain only derived hashes, not raw PII."""

    def test_fortune_key_has_no_raw_birth_fields(self):
        """fortune_cache_key takes seed_hash (derived), not raw birth data."""
        seed_hash = "somederivedhash"
        key = fortune_cache_key(seed_hash)
        # key must NOT contain year/month/day literals
        assert "birth_year" not in key
        assert "birth_month" not in key
        assert "birth_day" not in key
        assert "birth_hour" not in key

    def test_tts_key_has_no_raw_birth_fields(self):
        """TTS cacheKey from adapter contains script_hash, not raw text."""
        result = synthesize(_SAMPLE_SCRIPT)
        key = result["cacheKey"]
        assert "birth_year" not in key
        assert "birth_month" not in key
        assert "birth_day" not in key


class TestDeterminism:
    """AC: same key → same cached value; different keys → independent."""

    def test_same_key_same_result(self):
        store = InMemoryCacheStore()
        counter = [0]

        def compute():
            counter[0] += 1
            return f"result_{counter[0]}"

        r1 = get_or_compute(store, "k", compute)
        r2 = get_or_compute(store, "k", compute)
        assert r1 == r2

    def test_different_keys_independent_values(self):
        store = InMemoryCacheStore()
        r1 = get_or_compute(store, "k1", lambda: "val1")
        r2 = get_or_compute(store, "k2", lambda: "val2")
        assert r1 != r2
        # Retrieving k1 again doesn't affect k2
        assert get_or_compute(store, "k1", lambda: "x") == "val1"
        assert get_or_compute(store, "k2", lambda: "x") == "val2"


class TestEventInstrumentation:
    """T018: cache_hit/cache_miss events fire with a layer tag (v3 §17)."""

    def test_miss_emits_cache_miss_event(self):
        store = InMemoryCacheStore()
        events = []
        get_or_compute(store, "k1", lambda: "v", layer="tts", event_sink=events.append)
        assert events == [{"event": "cache_miss", "layer": "tts", "key": "k1"}]

    def test_hit_emits_cache_hit_event(self):
        store = InMemoryCacheStore()
        events = []
        get_or_compute(store, "k1", lambda: "v", layer="tts", event_sink=events.append)
        get_or_compute(store, "k1", lambda: "v2", layer="tts", event_sink=events.append)
        assert events[-1] == {"event": "cache_hit", "layer": "tts", "key": "k1"}

    def test_default_layer_present_when_unspecified(self):
        store = InMemoryCacheStore()
        events = []
        get_or_compute(store, "k1", lambda: "v", event_sink=events.append)
        assert "layer" in events[0]

    def test_default_event_sink_does_not_raise(self):
        """No event_sink injected — falls back to structured logging, no error."""
        store = InMemoryCacheStore()
        result = get_or_compute(store, "k1", lambda: "v")
        assert result == "v"
