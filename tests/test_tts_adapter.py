"""T013: TTS adapter — determinism, cache key format, mock URL, defaults, duration, backend injection."""
import importlib.util
from pathlib import Path

ROOT = Path(__file__).parent.parent
TTS_ADAPTER_PATH = ROOT / "fortune-engine" / "tts_adapter.py"

_spec = importlib.util.spec_from_file_location("tts_adapter", TTS_ADAPTER_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
synthesize = _mod.synthesize

_SAMPLE_SCRIPT = [
    {"segment": "greeting", "type": "presynth",
     "text": "오늘신당에 오셨군요. 홍연이 오늘의 기운을 무대 위에 올려볼게요."},
    {"segment": "summary", "type": "personalized",
     "text": "오늘은 마음이 먼저 움직이는 날이에요. 솔직한 한마디가 관계의 온도를 한 칸 올려줘요."},
    {"segment": "scores", "type": "personalized",
     "text": "연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요."},
    {"segment": "advice", "type": "personalized",
     "text": "마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요."},
    {"segment": "lucky", "type": "semi",
     "text": "오늘의 행운 색은 코랄 핑크, 행운 아이템은 작은 손거울이에요."},
    {"segment": "avoid", "type": "personalized",
     "text": "지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요."},
    {"segment": "blessing", "type": "presynth",
     "text": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요."},
    {"segment": "ending", "type": "presynth",
     "text": "내일도 무대는 열려 있어요. 오늘도 좋은 하루 보내요."},
]


class TestReturnStructure:
    """AC1: synthesize returns dict with required keys."""

    def test_returns_dict(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert isinstance(result, dict)

    def test_has_audio_url(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert "audioUrl" in result
        assert isinstance(result["audioUrl"], str)

    def test_has_duration_sec(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert "durationSec" in result
        assert isinstance(result["durationSec"], (int, float))

    def test_has_cache_key(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert "cacheKey" in result
        assert isinstance(result["cacheKey"], str)

    def test_has_metadata(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert "metadata" in result
        assert isinstance(result["metadata"], dict)


class TestCacheKey:
    """AC2: cacheKey == tts:v1:{provider}:{voice_id}:{script_hash}:{speed}:{emotion}"""

    def test_cache_key_token_order(self):
        result = synthesize(_SAMPLE_SCRIPT, provider="openai", voice="coral",
                            speed=1.0, emotion="bright")
        parts = result["cacheKey"].split(":")
        assert parts[0] == "tts"
        assert parts[1] == "v1"
        assert parts[2] == "openai"
        assert parts[3] == "coral"
        # parts[4] is script_hash (64-char hex, no colons)
        assert len(parts[4]) == 64
        assert all(c in "0123456789abcdef" for c in parts[4])
        assert parts[5] == "1.0"
        assert parts[6] == "bright"

    def test_cache_key_prefix(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["cacheKey"].startswith("tts:v1:")

    def test_cache_key_contains_provider(self):
        result = synthesize(_SAMPLE_SCRIPT, provider="google")
        assert ":google:" in result["cacheKey"]

    def test_cache_key_contains_voice(self):
        result = synthesize(_SAMPLE_SCRIPT, voice="nova")
        assert ":nova:" in result["cacheKey"]

    def test_cache_key_contains_emotion(self):
        result = synthesize(_SAMPLE_SCRIPT, emotion="energetic")
        assert result["cacheKey"].endswith(":energetic")

    def test_different_speed_different_cache_key(self):
        r1 = synthesize(_SAMPLE_SCRIPT, speed=1.0)
        r2 = synthesize(_SAMPLE_SCRIPT, speed=1.2)
        assert r1["cacheKey"] != r2["cacheKey"]


class TestDeterminism:
    """AC3: deterministic — same inputs → same audioUrl, cacheKey, durationSec."""

    def test_same_input_same_output(self):
        r1 = synthesize(_SAMPLE_SCRIPT)
        r2 = synthesize(_SAMPLE_SCRIPT)
        assert r1 == r2

    def test_different_script_different_cache_key(self):
        script2 = [{"segment": "greeting", "type": "presynth", "text": "다른 텍스트입니다."}]
        r1 = synthesize(_SAMPLE_SCRIPT)
        r2 = synthesize(script2)
        assert r1["cacheKey"] != r2["cacheKey"]

    def test_different_script_different_audio_url(self):
        script2 = [{"segment": "greeting", "type": "presynth", "text": "다른 텍스트입니다."}]
        r1 = synthesize(_SAMPLE_SCRIPT)
        r2 = synthesize(script2)
        assert r1["audioUrl"] != r2["audioUrl"]

    def test_same_script_same_duration(self):
        r1 = synthesize(_SAMPLE_SCRIPT)
        r2 = synthesize(_SAMPLE_SCRIPT)
        assert r1["durationSec"] == r2["durationSec"]

    def test_different_provider_different_cache_key(self):
        r1 = synthesize(_SAMPLE_SCRIPT, provider="openai")
        r2 = synthesize(_SAMPLE_SCRIPT, provider="google")
        assert r1["cacheKey"] != r2["cacheKey"]


class TestDefaults:
    """AC4: defaults follow ADR-0001 (openai, coral, gpt-4o-mini-tts)."""

    def test_default_provider_is_openai(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["metadata"]["provider"] == "openai"

    def test_default_voice_is_coral(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["metadata"]["voice"] == "coral"

    def test_default_model_is_gpt4o_mini_tts(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["metadata"]["model"] == "gpt-4o-mini-tts"

    def test_default_cache_key_has_openai_coral(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert ":openai:" in result["cacheKey"]
        assert ":coral:" in result["cacheKey"]


class TestAudioUrl:
    """AC5: default mock backend returns mock:// URL."""

    def test_default_audio_url_is_mock_scheme(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["audioUrl"].startswith("mock://")

    def test_mock_url_is_nonempty(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert len(result["audioUrl"]) > len("mock://")


class TestDuration:
    """AC6: durationSec is deterministic, derived from script length, within 45-60s band."""

    def test_duration_in_band(self):
        result = synthesize(_SAMPLE_SCRIPT)
        assert 45 <= result["durationSec"] <= 60

    def test_duration_is_deterministic(self):
        r1 = synthesize(_SAMPLE_SCRIPT)
        r2 = synthesize(_SAMPLE_SCRIPT)
        assert r1["durationSec"] == r2["durationSec"]

    def test_empty_script_duration_at_minimum(self):
        result = synthesize([])
        assert result["durationSec"] == 45

    def test_very_long_script_duration_at_maximum(self):
        long_script = [{"segment": "long", "type": "personalized", "text": "가" * 1000}]
        result = synthesize(long_script)
        assert result["durationSec"] == 60

    def test_longer_script_not_shorter_duration(self):
        short_script = [{"segment": "a", "type": "personalized", "text": "짧은 텍스트"}]
        r_short = synthesize(short_script)
        r_long = synthesize(_SAMPLE_SCRIPT)
        assert r_long["durationSec"] >= r_short["durationSec"]


class TestBackendInjection:
    """AC7: backend is injectable; default mock has no network calls."""

    def test_custom_backend_is_called(self):
        calls = []

        def spy_backend(script, cache_key, metadata):
            calls.append({"script": script, "cache_key": cache_key})
            return {"audioUrl": "mock://spy"}

        synthesize(_SAMPLE_SCRIPT, backend=spy_backend)
        assert len(calls) == 1

    def test_custom_backend_receives_script(self):
        received = {}

        def spy_backend(script, cache_key, metadata):
            received["script"] = script
            return {"audioUrl": "mock://spy"}

        synthesize(_SAMPLE_SCRIPT, backend=spy_backend)
        assert received["script"] == _SAMPLE_SCRIPT

    def test_custom_backend_receives_cache_key(self):
        received = {}

        def spy_backend(script, cache_key, metadata):
            received["cache_key"] = cache_key
            return {"audioUrl": "mock://spy"}

        result = synthesize(_SAMPLE_SCRIPT, backend=spy_backend)
        assert received["cache_key"] == result["cacheKey"]

    def test_custom_backend_receives_metadata(self):
        received = {}

        def spy_backend(script, cache_key, metadata):
            received["metadata"] = metadata
            return {"audioUrl": "mock://spy"}

        synthesize(_SAMPLE_SCRIPT, backend=spy_backend)
        assert "provider" in received["metadata"]
        assert "voice" in received["metadata"]
        assert "model" in received["metadata"]

    def test_custom_backend_audio_url_used(self):
        def custom_backend(script, cache_key, metadata):
            return {"audioUrl": "mock://custom-audio-url"}

        result = synthesize(_SAMPLE_SCRIPT, backend=custom_backend)
        assert result["audioUrl"] == "mock://custom-audio-url"

    def test_default_backend_no_network(self):
        """Default mock backend returns mock:// — no network, no cost."""
        result = synthesize(_SAMPLE_SCRIPT)
        assert result["audioUrl"].startswith("mock://")
