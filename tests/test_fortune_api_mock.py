"""T010/T012: Fortune API mock — 계약 경계, 결정적 응답, birth-의존 테스트."""
import importlib.util
import json
from pathlib import Path

import jsonschema
import pytest

ROOT = Path(__file__).parent.parent
MOCK_PATH = ROOT / "fortune-engine" / "fortune_api_mock.py"
SCHEMA_PATH = ROOT / "fortune-engine" / "fortune-schema.v1.1.json"
SEED_BUILDER_PATH = ROOT / "fortune-engine" / "seed_builder.py"

_sb_spec = importlib.util.spec_from_file_location("seed_builder", SEED_BUILDER_PATH)
_sb_mod = importlib.util.module_from_spec(_sb_spec)
_sb_spec.loader.exec_module(_sb_mod)
build_seed = _sb_mod.build_seed

_spec = importlib.util.spec_from_file_location("fortune_api_mock", MOCK_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
get_today_fortune = _mod.get_today_fortune

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
