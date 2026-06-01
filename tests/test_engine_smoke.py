"""T008: 엔진 통합 스모크 — validator → narration composer → share card SVG.

단일 샘플(fortune-samples.v1.1.json[0])이 세 모듈을 모두 무오류로 통과함을 단언한다.
"""
import importlib.util
import json
import xml.etree.ElementTree as ET
from pathlib import Path

import jsonschema

# ── 경로 상수 ──────────────────────────────────────────────────
ROOT = Path(__file__).parent.parent
SAMPLES_PATH = ROOT / "fortune-engine" / "fortune-samples.v1.1.json"
SCHEMA_PATH = ROOT / "fortune-engine" / "fortune-schema.v1.1.json"
COMPOSER_PATH = ROOT / "fortune-engine" / "tts-ab-kit" / "narration_composer.py"
SHARE_CARD_PATH = ROOT / "fortune-engine" / "share_card.py"

# ── importlib로 하이픈 포함 경로 모듈 로드 ────────────────────
_nc_spec = importlib.util.spec_from_file_location("narration_composer", COMPOSER_PATH)
_nc_mod = importlib.util.module_from_spec(_nc_spec)
_nc_spec.loader.exec_module(_nc_mod)
compose_narration = _nc_mod.compose_narration

_sc_spec = importlib.util.spec_from_file_location("share_card", SHARE_CARD_PATH)
_sc_mod = importlib.util.module_from_spec(_sc_spec)
_sc_spec.loader.exec_module(_sc_mod)
render_share_card_svg = _sc_mod.render_share_card_svg


def _first_sample() -> dict:
    with SAMPLES_PATH.open(encoding="utf-8") as f:
        return json.load(f)["samples"][0]


def _schema() -> dict:
    with SCHEMA_PATH.open(encoding="utf-8") as f:
        return json.load(f)


class TestEngineSmokeIntegration:
    """단일 샘플이 validator → narration composer → share card를 무오류 통과."""

    def test_validator_passes(self):
        sample = _first_sample()
        validator = jsonschema.Draft202012Validator(_schema())
        errors = list(validator.iter_errors(sample))
        assert not errors, f"validator 실패: {errors[0].message}"

    def test_narration_composer_returns_8_segments(self):
        sample = _first_sample()
        result = compose_narration(sample)
        assert len(result) == 8, f"세그먼트 수 불일치: {len(result)} (기대: 8)"

    def test_share_card_produces_well_formed_svg(self):
        sample = _first_sample()
        svg = render_share_card_svg(sample)
        try:
            ET.fromstring(svg)
        except ET.ParseError as exc:
            raise AssertionError(f"SVG 파싱 실패: {exc}") from exc
