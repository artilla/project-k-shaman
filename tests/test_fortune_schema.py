"""T001: fortune-schema.v1.1 validator regression tests."""
import copy
import json
from pathlib import Path

import jsonschema
import pytest

SCHEMA_PATH = Path(__file__).parent.parent / "fortune-engine" / "fortune-schema.v1.1.json"
SAMPLES_PATH = Path(__file__).parent.parent / "fortune-engine" / "fortune-samples.v1.1.json"

_VALID_SAMPLE = {
    "schema_version": "fortune.v1.1",
    "meta": {
        "date": "2026-05-22",
        "character_id": "hongyeon",
        "topic": "love",
        "tone": "bright",
        "locale": "ko-KR",
        "seed_hash": "test_001a",
        "content_version": "prompt.v1.1",
    },
    "scores": {
        "love": 80,
        "money": 60,
        "work": 55,
        "relationship": 70,
        "condition": 45,
    },
    "scores_line": "테스트용 점수 한 줄 요약입니다.",
    "summary": ["첫 번째 요약 문장입니다.", "두 번째 요약 문장입니다."],
    "advice": "오늘 하루 좋은 일이 생길 거예요.",
    "lucky": {"color": "빨강", "item": "열쇠"},
    "avoid": "무리한 결정은 피하세요.",
    "blessing": "오늘 하루 행운이 함께해요.",
}


@pytest.fixture(scope="module")
def schema():
    with SCHEMA_PATH.open() as f:
        return json.load(f)


@pytest.fixture(scope="module")
def samples():
    with SAMPLES_PATH.open() as f:
        return json.load(f)["samples"]


def _errors(schema, instance):
    validator = jsonschema.Draft202012Validator(schema)
    return list(validator.iter_errors(instance))


def _valid(schema):
    return copy.deepcopy(_VALID_SAMPLE)


# ── 유효 샘플 통과 ──────────────────────────────────────────


class TestValidSamples:
    def test_all_file_samples_pass(self, schema, samples):
        for i, sample in enumerate(samples):
            errs = _errors(schema, sample)
            assert not errs, f"Sample {i} 실패: {errs[0].message}"


# ── 필수 필드 누락 거부 ────────────────────────────────────


class TestMissingRequiredFields:
    @pytest.mark.parametrize(
        "field",
        [
            "schema_version",
            "meta",
            "scores",
            "scores_line",
            "summary",
            "advice",
            "lucky",
            "avoid",
            "blessing",
        ],
    )
    def test_missing_top_level_field(self, schema, field):
        sample = _valid(schema)
        del sample[field]
        assert _errors(schema, sample), f"{field} 누락이 거부되지 않음"

    def test_missing_lucky_color(self, schema):
        sample = _valid(schema)
        del sample["lucky"]["color"]
        assert _errors(schema, sample), "lucky.color 누락이 거부되지 않음"

    def test_missing_lucky_item(self, schema):
        sample = _valid(schema)
        del sample["lucky"]["item"]
        assert _errors(schema, sample), "lucky.item 누락이 거부되지 않음"


# ── summary 2문장 제약 ────────────────────────────────────


class TestSummaryConstraint:
    def test_summary_one_sentence_rejected(self, schema):
        sample = _valid(schema)
        sample["summary"] = ["단 한 문장만 있어요."]
        assert _errors(schema, sample), "summary 1문장이 거부되지 않음"

    def test_summary_three_sentences_rejected(self, schema):
        sample = _valid(schema)
        sample["summary"] = ["첫 번째.", "두 번째.", "세 번째."]
        assert _errors(schema, sample), "summary 3문장이 거부되지 않음"


# ── scores 범위 제약 ──────────────────────────────────────


class TestScoresRange:
    @pytest.mark.parametrize("field", ["love", "money", "work", "relationship", "condition"])
    def test_score_above_100_rejected(self, schema, field):
        sample = _valid(schema)
        sample["scores"][field] = 101
        assert _errors(schema, sample), f"scores.{field}=101이 거부되지 않음"

    @pytest.mark.parametrize("field", ["love", "money", "work", "relationship", "condition"])
    def test_score_below_0_rejected(self, schema, field):
        sample = _valid(schema)
        sample["scores"][field] = -1
        assert _errors(schema, sample), f"scores.{field}=-1이 거부되지 않음"
