"""T011: Seed builder — determinism, structure, PII non-leakage, bucketing, hash_fn injection."""
import hashlib
import json
import importlib.util
from pathlib import Path

ROOT = Path(__file__).parent.parent
SEED_BUILDER_PATH = ROOT / "fortune-engine" / "seed_builder.py"

_spec = importlib.util.spec_from_file_location("seed_builder", SEED_BUILDER_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
build_seed = _mod.build_seed

_BASE_REQ = {
    "date": "2026-06-02",
    "topic": "love",
    "character_id": "hongyeon",
    "tone": "bright",
    "locale": "ko-KR",
}

_BIRTH_REQ = {
    **_BASE_REQ,
    "birth_year": 1990,
    "birth_month": 3,
    "birth_day": 15,
    "birth_hour": 7,
}

_SCORE_FIELDS = {"love", "money", "work", "relationship", "condition"}
_SCORE_LEVELS = {"high", "mid", "low"}


class TestStructure:
    """AC1: build_seed returns seed_hash (str) + seed_signals with correct structure."""

    def test_returns_seed_hash_str(self):
        result = build_seed(_BIRTH_REQ)
        assert "seed_hash" in result
        assert isinstance(result["seed_hash"], str)
        assert result["seed_hash"]

    def test_returns_seed_signals(self):
        result = build_seed(_BIRTH_REQ)
        assert "seed_signals" in result
        signals = result["seed_signals"]
        assert "score_bias" in signals
        assert "day_theme" in signals

    def test_score_bias_has_all_five_fields(self):
        score_bias = build_seed(_BIRTH_REQ)["seed_signals"]["score_bias"]
        assert set(score_bias.keys()) == _SCORE_FIELDS

    def test_score_bias_values_are_valid_levels(self):
        score_bias = build_seed(_BIRTH_REQ)["seed_signals"]["score_bias"]
        for field, level in score_bias.items():
            assert level in _SCORE_LEVELS, f"{field}={level!r} not in {_SCORE_LEVELS}"

    def test_day_theme_is_nonempty_string(self):
        day_theme = build_seed(_BIRTH_REQ)["seed_signals"]["day_theme"]
        assert isinstance(day_theme, str)
        assert day_theme.strip()

    def test_works_without_birth_fields(self):
        result = build_seed(_BASE_REQ)
        assert isinstance(result["seed_hash"], str)
        assert result["seed_hash"]


class TestDeterminism:
    """AC2: Same input always produces the same output."""

    def test_same_request_returns_identical_result(self):
        assert build_seed(_BIRTH_REQ) == build_seed(_BIRTH_REQ)

    def test_different_date_different_seed_hash(self):
        r1 = {**_BIRTH_REQ, "date": "2026-06-02"}
        r2 = {**_BIRTH_REQ, "date": "2026-06-03"}
        assert build_seed(r1)["seed_hash"] != build_seed(r2)["seed_hash"]

    def test_different_topic_different_seed_hash(self):
        r1 = {**_BIRTH_REQ, "topic": "love"}
        r2 = {**_BIRTH_REQ, "topic": "money"}
        assert build_seed(r1)["seed_hash"] != build_seed(r2)["seed_hash"]

    def test_different_birth_year_different_seed_hash(self):
        r1 = {**_BIRTH_REQ, "birth_year": 1990}
        r2 = {**_BIRTH_REQ, "birth_year": 1991}
        assert build_seed(r1)["seed_hash"] != build_seed(r2)["seed_hash"]


class TestBucketing:
    """AC3: birth_hour is bucketed — exact hour never forwarded (Plan.md §11)."""

    def test_same_bucket_same_seed_hash(self):
        """birth_hour=7 and birth_hour=10 are both 'morning' → same seed_hash."""
        r7 = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 7}
        r10 = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 10}
        assert build_seed(r7)["seed_hash"] == build_seed(r10)["seed_hash"]

    def test_different_bucket_different_seed_hash(self):
        """birth_hour=7 (morning) vs birth_hour=19 (evening) → different seed_hash."""
        r_morning = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 7}
        r_evening = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 19}
        assert build_seed(r_morning)["seed_hash"] != build_seed(r_evening)["seed_hash"]

    def test_night_bucket_spans_midnight(self):
        """birth_hour=23 and birth_hour=2 are both 'night' → same seed_hash."""
        r23 = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 23}
        r2 = {**_BASE_REQ, "birth_year": 1990, "birth_month": 3, "birth_day": 15, "birth_hour": 2}
        assert build_seed(r23)["seed_hash"] == build_seed(r2)["seed_hash"]


class TestPIILeakage:
    """AC3: birth PII never appears in output (runbook §4 보안 3요소 준수)."""

    def test_birth_field_names_not_in_output_json(self):
        result = build_seed(_BIRTH_REQ)
        result_str = json.dumps(result, ensure_ascii=False)
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            assert field not in result_str, f"PII field name '{field}' found in output JSON"

    def test_birth_date_string_not_verbatim_in_seed_hash(self):
        """'1990-03-15' should never appear verbatim in seed_hash."""
        seed_hash = build_seed(_BIRTH_REQ)["seed_hash"]
        assert "1990-03-15" not in seed_hash

    def test_result_has_no_birth_keys(self):
        result = build_seed(_BIRTH_REQ)
        result_str = json.dumps(result, ensure_ascii=False)
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            assert field not in result_str, f"'{field}' found in output"


class TestHashFnInjection:
    """AC4: hash_fn can be injected; dev default is SHA-256 (§3 hold for real HMAC)."""

    def test_custom_hash_fn_is_invoked(self):
        calls = []

        def spy_hash(data):
            calls.append(data)
            return hashlib.sha256(data.encode()).hexdigest()

        build_seed(_BIRTH_REQ, hash_fn=spy_hash)
        assert len(calls) >= 1, "hash_fn was never called"

    def test_injected_hash_fn_result_used_as_seed_hash(self):
        """When hash_fn always returns a fixed hex string, seed_hash must equal it."""
        fixed = "deadbeef" + "0" * 56  # 64 hex chars

        def fixed_hash(data):  # noqa: ARG001
            return fixed

        result = build_seed(_BIRTH_REQ, hash_fn=fixed_hash)
        assert result["seed_hash"] == fixed

    def test_different_hash_fns_produce_different_seed_hashes(self):
        def hash_a(data):
            return hashlib.sha256(data.encode()).hexdigest()

        def hash_b(data):
            return hashlib.sha256(("secret:" + data).encode()).hexdigest()

        r_a = build_seed(_BIRTH_REQ, hash_fn=hash_a)
        r_b = build_seed(_BIRTH_REQ, hash_fn=hash_b)
        assert r_a["seed_hash"] != r_b["seed_hash"]
