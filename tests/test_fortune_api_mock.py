"""T010/T012/T016: Fortune API mock — 계약 경계, 결정적 응답, birth-의존, 2단 캐시 테스트."""
import importlib.util
import json
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).parent.parent
MOCK_PATH = ROOT / "fortune-engine" / "fortune_api_mock.py"
SCHEMA_PATH = ROOT / "fortune-engine" / "fortune-schema.v1.1.json"
SEED_BUILDER_PATH = ROOT / "fortune-engine" / "seed_builder.py"
CACHE_LAYER_PATH = ROOT / "fortune-engine" / "cache_layer.py"

_sb_spec = importlib.util.spec_from_file_location("seed_builder", SEED_BUILDER_PATH)
_sb_mod = importlib.util.module_from_spec(_sb_spec)
_sb_spec.loader.exec_module(_sb_mod)
build_seed = _sb_mod.build_seed

_spec = importlib.util.spec_from_file_location("fortune_api_mock", MOCK_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
get_today_fortune = _mod.get_today_fortune

_cl_spec = importlib.util.spec_from_file_location("cache_layer", CACHE_LAYER_PATH)
_cl_mod = importlib.util.module_from_spec(_cl_spec)
_cl_spec.loader.exec_module(_cl_mod)
InMemoryCacheStore = _cl_mod.InMemoryCacheStore
fortune_cache_key = _cl_mod.fortune_cache_key

_BASE_REQ = {
    "date": "2026-06-02",
    "topic": "love",
    "character_id": "hongyeon",
}

_BIRTH_REQ = {
    **_BASE_REQ,
    "birth_year": 1990,
    "birth_month": 3,
    "birth_day": 15,
    "birth_hour": 7,
}


@pytest.fixture(scope="module")
def schema():
    with SCHEMA_PATH.open() as f:
        return json.load(f)


class TestSchemaValidation:
    """AC1: fortune 객체가 fortune-schema.v1.1 검증을 통과한다."""

    def test_fortune_object_passes_schema(self, schema):
        result = get_today_fortune(_BASE_REQ)
        fortune = result["fortune"]
        validator = jsonschema.Draft202012Validator(schema)
        errors = list(validator.iter_errors(fortune))
        assert not errors, f"스키마 검증 실패: {errors[0].message}"

    def test_fortune_with_birth_fields_passes_schema(self, schema):
        result = get_today_fortune(_BIRTH_REQ)
        fortune = result["fortune"]
        validator = jsonschema.Draft202012Validator(schema)
        errors = list(validator.iter_errors(fortune))
        assert not errors, f"birth 필드 포함 요청의 스키마 검증 실패: {errors[0].message}"

    @pytest.mark.parametrize("topic", ["total", "love", "money", "work", "relationship"])
    def test_all_topics_pass_schema(self, schema, topic):
        req = {**_BASE_REQ, "topic": topic}
        result = get_today_fortune(req)
        fortune = result["fortune"]
        validator = jsonschema.Draft202012Validator(schema)
        errors = list(validator.iter_errors(fortune))
        assert not errors, f"topic={topic} 스키마 검증 실패: {errors[0].message}"


class TestDeterminism:
    """AC2: 동일 요청 → 동일 응답(딕셔너리 동등)."""

    def test_same_request_same_response(self):
        result1 = get_today_fortune(_BASE_REQ)
        result2 = get_today_fortune(_BASE_REQ)
        assert result1 == result2

    def test_different_topic_gives_different_fortune_id(self):
        req_love = {**_BASE_REQ, "topic": "love"}
        req_money = {**_BASE_REQ, "topic": "money"}
        assert get_today_fortune(req_love)["fortuneId"] != get_today_fortune(req_money)["fortuneId"]

    def test_different_date_gives_different_fortune_id(self):
        req1 = {**_BASE_REQ, "date": "2026-06-02"}
        req2 = {**_BASE_REQ, "date": "2026-06-03"}
        assert get_today_fortune(req1)["fortuneId"] != get_today_fortune(req2)["fortuneId"]


class TestEnvelope:
    """AC3: 엔벨로프에 fortuneId, audioUrl(mock://), durationSec가 있다."""

    def test_fortune_id_present_and_nonempty(self):
        result = get_today_fortune(_BASE_REQ)
        assert "fortuneId" in result
        assert isinstance(result["fortuneId"], str) and result["fortuneId"]

    def test_audio_url_is_mock_placeholder(self):
        result = get_today_fortune(_BASE_REQ)
        assert "audioUrl" in result
        assert result["audioUrl"].startswith("mock://"), (
            f"audioUrl이 mock:// 플레이스홀더가 아님: {result['audioUrl']!r}"
        )

    def test_duration_sec_present_and_positive(self):
        result = get_today_fortune(_BASE_REQ)
        assert "durationSec" in result
        assert isinstance(result["durationSec"], (int, float))
        assert result["durationSec"] > 0


class TestScript:
    """AC3: script는 compose_narration 8세그먼트로 조립된다."""

    def test_script_has_8_segments(self):
        result = get_today_fortune(_BASE_REQ)
        assert "script" in result
        assert len(result["script"]) == 8, (
            f"script 세그먼트 수: {len(result['script'])} (기대: 8)"
        )

    def test_script_segment_order_matches_spec(self):
        result = get_today_fortune(_BASE_REQ)
        expected = ["greeting", "summary", "scores", "advice", "lucky", "avoid", "blessing", "ending"]
        actual = [s["segment"] for s in result["script"]]
        assert actual == expected

    def test_script_segments_have_required_keys(self):
        result = get_today_fortune(_BASE_REQ)
        for seg in result["script"]:
            assert "segment" in seg
            assert "type" in seg
            assert "text" in seg
            assert seg["text"].strip(), f"세그먼트 '{seg['segment']}' text가 비어 있음"


class TestRequestFieldHandling:
    """요청 필드(topic, date, character_id)가 fortune.meta에 반영된다."""

    def test_date_reflected_in_fortune_meta(self):
        req = {**_BASE_REQ, "date": "2026-06-15"}
        result = get_today_fortune(req)
        assert result["fortune"]["meta"]["date"] == "2026-06-15"

    def test_topic_reflected_in_fortune_meta(self):
        for topic in ("total", "love", "money", "work", "relationship"):
            req = {**_BASE_REQ, "topic": topic}
            result = get_today_fortune(req)
            assert result["fortune"]["meta"]["topic"] == topic

    def test_character_id_reflected_in_fortune_meta(self):
        result = get_today_fortune(_BASE_REQ)
        assert result["fortune"]["meta"]["character_id"] == "hongyeon"


class TestPrivacyGuard:
    """AC5: birth 필드는 응답·로그·파일에 평문으로 남지 않는다 (§4 보안 3요소 준수)."""

    def _collect_keys(self, obj):
        keys = set()
        if isinstance(obj, dict):
            for k, v in obj.items():
                keys.add(k)
                keys |= self._collect_keys(v)
        elif isinstance(obj, list):
            for item in obj:
                keys |= self._collect_keys(item)
        return keys

    def test_birth_field_names_not_in_response_keys(self):
        result = get_today_fortune(_BIRTH_REQ)
        all_keys = self._collect_keys(result)
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            assert field not in all_keys, f"birth 필드 '{field}'가 응답 키에 존재함"

    def test_birth_field_names_not_in_json_string(self):
        result = get_today_fortune(_BIRTH_REQ)
        result_str = json.dumps(result, ensure_ascii=False)
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            assert field not in result_str, f"birth 필드명 '{field}'가 응답 JSON에 존재함"


# ─── T012 ────────────────────────────────────────────────────────────────────
# 이하 클래스는 T012(build_seed 연결) 수용 기준 검증용이다.

_MORNING_BIRTH_REQ = {
    **_BASE_REQ,
    "birth_year": 1990,
    "birth_month": 3,
    "birth_day": 15,
    "birth_hour": 7,   # morning bucket (5–11)
}
_MORNING_BIRTH_REQ2 = {
    **_BASE_REQ,
    "birth_year": 1990,
    "birth_month": 3,
    "birth_day": 15,
    "birth_hour": 10,  # same morning bucket
}
_EVENING_BIRTH_REQ = {
    **_BASE_REQ,
    "birth_year": 1990,
    "birth_month": 3,
    "birth_day": 15,
    "birth_hour": 19,  # evening bucket (18–21)
}


class TestBirthDependency:
    """AC4: birth-의존 결정성 — 버킷이 다른 birth → 다른 응답."""

    def test_different_birth_bucket_different_fortune_id(self):
        """morning vs evening 버킷 → fortuneId 상이."""
        r_morning = get_today_fortune(_MORNING_BIRTH_REQ)
        r_evening = get_today_fortune(_EVENING_BIRTH_REQ)
        assert r_morning["fortuneId"] != r_evening["fortuneId"]

    def test_different_birth_bucket_different_seed_hash(self):
        """morning vs evening 버킷 → fortune.meta.seed_hash 상이."""
        r_morning = get_today_fortune(_MORNING_BIRTH_REQ)
        r_evening = get_today_fortune(_EVENING_BIRTH_REQ)
        assert r_morning["fortune"]["meta"]["seed_hash"] != r_evening["fortune"]["meta"]["seed_hash"]

    def test_same_birth_bucket_same_response(self):
        """birth_hour=7과 birth_hour=10은 동일 morning 버킷 → 동일 응답."""
        r1 = get_today_fortune(_MORNING_BIRTH_REQ)
        r2 = get_today_fortune(_MORNING_BIRTH_REQ2)
        assert r1 == r2

    def test_birth_request_is_deterministic(self):
        """동일 birth 요청 반복 → 동일 응답."""
        r1 = get_today_fortune(_MORNING_BIRTH_REQ)
        r2 = get_today_fortune(_MORNING_BIRTH_REQ)
        assert r1 == r2

    def test_birth_changes_seed_hash_vs_no_birth(self):
        """birth 포함 요청 vs 제외 요청 → seed_hash 상이 (birth가 키에 반영됨)."""
        r_no_birth = get_today_fortune(_BASE_REQ)
        r_birth = get_today_fortune(_MORNING_BIRTH_REQ)
        assert r_no_birth["fortune"]["meta"]["seed_hash"] != r_birth["fortune"]["meta"]["seed_hash"]


# ─── T014 ────────────────────────────────────────────────────────────────────
# 이하 클래스는 T014(tts_adapter 연결) 수용 기준 검증용이다.

class TestTtsMetadata:
    """T014: 엔벨로프에 tts metadata(cacheKey·provider·voice)가 포함된다."""

    def test_tts_key_in_envelope(self):
        result = get_today_fortune(_BASE_REQ)
        assert "tts" in result, "응답 엔벨로프에 'tts' 키가 없음"

    def test_tts_has_cache_key(self):
        result = get_today_fortune(_BASE_REQ)
        assert "cacheKey" in result["tts"], "tts.cacheKey가 없음"
        assert result["tts"]["cacheKey"].startswith("tts:v1:")

    def test_tts_has_provider(self):
        result = get_today_fortune(_BASE_REQ)
        assert "provider" in result["tts"]
        assert result["tts"]["provider"] == "openai"

    def test_tts_has_voice(self):
        result = get_today_fortune(_BASE_REQ)
        assert "voice" in result["tts"]
        assert result["tts"]["voice"] == "coral"

    def test_audio_url_from_tts_adapter(self):
        """audioUrl은 tts_adapter.synthesize()에서 도출된다 (기존 placeholder 아님)."""
        result = get_today_fortune(_BASE_REQ)
        assert not result["audioUrl"].startswith("mock://audio/"), (
            "audioUrl이 기존 하드코딩 placeholder 형식(mock://audio/)임"
        )
        assert result["audioUrl"].startswith("mock://")

    def test_duration_sec_from_adapter_band(self):
        """durationSec은 tts_adapter 밴드(45–60s) 내 결정적 값."""
        result = get_today_fortune(_BASE_REQ)
        dur = result["durationSec"]
        assert 45 <= dur <= 60, f"durationSec={dur} 가 45–60 범위 밖"

    def test_tts_deterministic(self):
        """동일 요청 → tts metadata 동일."""
        r1 = get_today_fortune(_BASE_REQ)
        r2 = get_today_fortune(_BASE_REQ)
        assert r1["tts"] == r2["tts"]

    def test_tts_cache_key_contains_script_hash(self):
        """tts.cacheKey는 64자 script hash를 포함한다."""
        result = get_today_fortune(_BASE_REQ)
        parts = result["tts"]["cacheKey"].split(":")
        # format: tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion}
        assert len(parts) >= 7
        script_hash = parts[4]
        assert len(script_hash) == 64
        assert all(c in "0123456789abcdef" for c in script_hash)


class TestSeedBuilderContract:
    """AC1: get_today_fortune이 build_seed의 seed_hash를 그대로 사용한다."""

    def test_fortune_seed_hash_matches_build_seed(self):
        """응답의 fortune.meta.seed_hash == build_seed(req)['seed_hash']."""
        seed_result = build_seed(_MORNING_BIRTH_REQ)
        result = get_today_fortune(_MORNING_BIRTH_REQ)
        assert result["fortune"]["meta"]["seed_hash"] == seed_result["seed_hash"]

    def test_fortune_id_derived_from_seed_hash(self):
        """fortuneId에 seed_hash 앞 16자리가 포함된다."""
        seed_result = build_seed(_MORNING_BIRTH_REQ)
        result = get_today_fortune(_MORNING_BIRTH_REQ)
        assert seed_result["seed_hash"][:16] in result["fortuneId"]

    def test_no_birth_request_seed_hash_matches_build_seed(self):
        """birth 없는 요청도 build_seed 계약을 따른다."""
        seed_result = build_seed(_BASE_REQ)
        result = get_today_fortune(_BASE_REQ)
        assert result["fortune"]["meta"]["seed_hash"] == seed_result["seed_hash"]


# ─── T016 ────────────────────────────────────────────────────────────────────
# 이하 클래스는 T016(cache_layer 2단 배선) 수용 기준 검증용이다.

class TestCacheIntegration:
    """T016: 2단 캐시 dedup — fortune build·TTS synthesize가 각각 1회만 호출된다."""

    @staticmethod
    def _fresh_store():
        return InMemoryCacheStore()

    def test_same_request_fortune_build_called_once(self):
        """동일 request 2회 호출 시 fortune build compute가 추가 0회."""
        store = self._fresh_store()
        calls = []
        original_build = _mod._build_fortune_data

        def spy_build(request, seed_result):
            calls.append(1)
            return original_build(request, seed_result)

        get_today_fortune(_BASE_REQ, store=store, fortune_build_fn=spy_build)
        assert len(calls) == 1
        get_today_fortune(_BASE_REQ, store=store, fortune_build_fn=spy_build)
        assert len(calls) == 1, f"fortune build가 2회차에 추가 호출됨: {len(calls)}회"

    def test_same_request_tts_synthesize_called_once(self):
        """동일 request 2회 호출 시 TTS synthesize compute가 추가 0회."""
        store = self._fresh_store()
        calls = []
        original_tts = _mod._tts_synthesize

        def spy_tts(script):
            calls.append(1)
            return original_tts(script)

        get_today_fortune(_BASE_REQ, store=store, tts_synthesize_fn=spy_tts)
        assert len(calls) == 1
        get_today_fortune(_BASE_REQ, store=store, tts_synthesize_fn=spy_tts)
        assert len(calls) == 1, f"TTS synthesize가 2회차에 추가 호출됨: {len(calls)}회"

    def test_cached_response_identical(self):
        """동일 request + 동일 store → 응답 완전 동일."""
        store = self._fresh_store()
        r1 = get_today_fortune(_BASE_REQ, store=store)
        r2 = get_today_fortune(_BASE_REQ, store=store)
        assert r1 == r2

    def test_fortune_cache_key_format(self):
        """Fortune 캐시 키는 fortune:v1:{seed_hash} 형식이다."""
        seed_result = build_seed(_BASE_REQ)
        key = fortune_cache_key(seed_result["seed_hash"])
        assert key == f"fortune:v1:{seed_result['seed_hash']}"

    def test_tts_cache_key_matches_adapter(self):
        """TTS 캐시 키는 tts_adapter가 반환하는 cacheKey와 동일하다."""
        store = self._fresh_store()
        captured = []
        original_tts = _mod._tts_synthesize

        def spy_tts(script):
            result = original_tts(script)
            captured.append(result)
            return result

        response = get_today_fortune(_BASE_REQ, store=store, tts_synthesize_fn=spy_tts)
        assert len(captured) == 1
        assert response["tts"]["cacheKey"] == captured[0]["cacheKey"]

    def test_different_requests_independent_misses(self):
        """다른 date → 독립 캐시 미스 (각각 1회 fortune build 호출)."""
        store = self._fresh_store()
        calls = []
        original_build = _mod._build_fortune_data

        def spy_build(request, seed_result):
            calls.append(1)
            return original_build(request, seed_result)

        req1 = {**_BASE_REQ, "date": "2026-06-02"}
        req2 = {**_BASE_REQ, "date": "2026-06-03"}
        get_today_fortune(req1, store=store, fortune_build_fn=spy_build)
        get_today_fortune(req2, store=store, fortune_build_fn=spy_build)
        assert len(calls) == 2

    def test_fresh_store_always_miss(self):
        """fresh store 주입 시 첫 요청은 항상 miss — 테스트 간 오염 없음."""
        for _ in range(2):
            store = self._fresh_store()
            calls = []
            original_build = _mod._build_fortune_data

            def spy_build(request, seed_result):
                calls.append(1)
                return original_build(request, seed_result)

            get_today_fortune(_BASE_REQ, store=store, fortune_build_fn=spy_build)
            assert len(calls) == 1

    def test_cached_fortune_passes_schema(self, schema):
        """캐시에서 반환된 fortune도 스키마 검증을 통과한다."""
        store = self._fresh_store()
        get_today_fortune(_BASE_REQ, store=store)
        result = get_today_fortune(_BASE_REQ, store=store)
        validator = jsonschema.Draft202012Validator(schema)
        errors = list(validator.iter_errors(result["fortune"]))
        assert not errors, f"캐시 응답 스키마 오류: {errors[0].message}"

    def test_cached_response_no_raw_birth(self):
        """캐시에서 반환된 응답에도 raw birth 필드가 없다."""
        store = self._fresh_store()
        get_today_fortune(_BIRTH_REQ, store=store)
        result = get_today_fortune(_BIRTH_REQ, store=store)
        result_str = json.dumps(result, ensure_ascii=False)
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            assert field not in result_str, f"캐시 응답에 '{field}' 노출"

    def test_default_call_still_works(self):
        """기존 호출 방식 get_today_fortune(req) 은 그대로 동작한다."""
        result = get_today_fortune(_BASE_REQ)
        assert "fortuneId" in result
        assert "fortune" in result
        assert result["audioUrl"].startswith("mock://")
