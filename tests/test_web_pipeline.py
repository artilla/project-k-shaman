"""T019: 재생 파이프라인 조립(fortune-engine/web/pipeline.py) — 서버 이벤트 캡처,
재방문 cache_hit 회귀(신규합성 0회) 테스트."""
import importlib.util
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
PIPELINE_PATH = ROOT / "fortune-engine" / "web" / "pipeline.py"
CACHE_LAYER_PATH = ROOT / "fortune-engine" / "cache_layer.py"


def _load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_pipeline = _load("t019_web_pipeline", PIPELINE_PATH)
build_playback_response = _pipeline.build_playback_response

_cache_layer = _load("cache_layer", CACHE_LAYER_PATH)
InMemoryCacheStore = _cache_layer.InMemoryCacheStore

_BASE_REQ = {"date": "2026-07-07", "topic": "love", "character_id": "hongyeon"}


class TestEnvelope:
    """엔벨로프에 기존 fortune_api_mock 키 + events가 함께 있다."""

    def test_returns_fortune_envelope_keys(self):
        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore())
        for key in ("fortuneId", "script", "audioUrl", "durationSec", "fortune", "tts", "events"):
            assert key in result, f"'{key}' 키 누락"

    def test_events_is_nonempty_list_of_dicts(self):
        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore())
        assert isinstance(result["events"], list)
        assert result["events"], "이벤트가 하나도 캡처되지 않음"
        for e in result["events"]:
            assert isinstance(e, dict)
            assert "event" in e


class TestFirstCallEvents:
    """신규 방문(빈 store) → tts_generate_*, cache_miss가 캡처된다."""

    def test_first_call_has_tts_generate_events(self):
        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore())
        names = [e["event"] for e in result["events"]]
        assert "tts_generate_start" in names
        assert "tts_generate_complete" in names

    def test_first_call_has_cache_miss(self):
        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore())
        names = [e["event"] for e in result["events"]]
        assert "cache_miss" in names
        assert "cache_hit" not in names


class TestRevisitCacheHit:
    """AC: 같은 seed 재방문 시 cache_hit 경로로 재생 (신규합성 0회)."""

    def test_second_call_same_store_has_no_new_synthesis(self):
        store = InMemoryCacheStore()
        build_playback_response(_BASE_REQ, store=store)
        result2 = build_playback_response(_BASE_REQ, store=store)
        names2 = [e["event"] for e in result2["events"]]
        assert "tts_generate_start" not in names2, "재방문인데 신규 합성이 발생함"
        assert "tts_generate_complete" not in names2
        assert "cache_hit" in names2

    def test_second_call_returns_same_audio_url(self):
        store = InMemoryCacheStore()
        r1 = build_playback_response(_BASE_REQ, store=store)
        r2 = build_playback_response(_BASE_REQ, store=store)
        assert r1["audioUrl"] == r2["audioUrl"]

    def test_different_seed_recomputes_fortune_layer(self):
        """다른 요청(다른 seed_hash) → fortune 레이어는 항상 새로 캐시 미스한다.

        TTS 레이어는 narration pool 충돌로 우연히 동일 스크립트가 나올 수 있어(고정 5종 pool)
        tts_generate_start까지는 보장하지 않는다 — 그건 fortune_api_mock(T012/T016)의 기존
        동작이며 T019 범위 밖이다.
        """
        store = InMemoryCacheStore()
        build_playback_response(_BASE_REQ, store=store)
        other_req = {**_BASE_REQ, "topic": "money"}
        result = build_playback_response(other_req, store=store)
        fortune_layer_events = [e for e in result["events"] if e.get("layer") == "fortune"]
        assert any(e["event"] == "cache_miss" for e in fortune_layer_events)


class TestTtsBackendInjection:
    """T020: tts_backend 옵트인 배선 — 실백엔드 분기를 mock backend 주입으로 단위 검증한다."""

    def test_default_tts_backend_is_unchanged_mock_path(self):
        """tts_backend 인자를 생략하면 기존 T019 mock 경로와 완전히 동일하다."""
        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore())
        assert result["audioUrl"].startswith("mock://")

    def test_callable_tts_backend_is_invoked(self):
        calls = []

        def spy_backend(script, cache_key, metadata):
            calls.append(cache_key)
            return {"audioUrl": "mock://spy-injected"}

        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore(), tts_backend=spy_backend)
        assert len(calls) == 1
        assert result["audioUrl"] == "mock://spy-injected"

    def test_callable_tts_backend_cache_key_matches_default_formula(self):
        received = {}

        def spy_backend(script, cache_key, metadata):
            received["cache_key"] = cache_key
            return {"audioUrl": "mock://spy"}

        result = build_playback_response(_BASE_REQ, store=InMemoryCacheStore(), tts_backend=spy_backend)
        assert received["cache_key"] == result["tts"]["cacheKey"]

    def test_openai_backend_without_api_key_raises(self, monkeypatch):
        """실백엔드("openai") 옵트인 + 키 없음 → 네트워크 호출 전에 즉시 거부 (T018 계약)."""
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        with pytest.raises(RuntimeError):
            build_playback_response(_BASE_REQ, store=InMemoryCacheStore(), tts_backend="openai")

    def test_revisit_with_injected_backend_skips_new_synthesis(self):
        """AC: 같은 seed 재방문 → cache_hit 경로 재생, 신규합성 0회 (백엔드 종류와 무관하게 성립).

        실백엔드("openai") 자체는 네트워크가 필요해 여기서 직접 쓰지 않지만, get_or_compute의
        dedup은 tts_backend 종류와 무관하게 캐시 키 기준으로 동작하므로 spy backend 주입으로
        동일한 배선을 네트워크 없이 검증한다.
        """
        calls = []

        def spy_backend(script, cache_key, metadata):
            calls.append(cache_key)
            return {"audioUrl": "mock://spy"}

        store = InMemoryCacheStore()
        build_playback_response(_BASE_REQ, store=store, tts_backend=spy_backend)
        build_playback_response(_BASE_REQ, store=store, tts_backend=spy_backend)

        assert len(calls) == 1, "재방문인데 백엔드가 다시 호출됨 (신규 합성 발생)"
