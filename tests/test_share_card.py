"""T006: static Hongyeon share-card SVG renderer regression tests."""
import base64
import importlib.util
import json
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
SHARE_CARD_PATH = ROOT / "fortune-engine" / "share_card.py"
SAMPLES_PATH = ROOT / "fortune-engine" / "fortune-samples.v1.1.json"

_spec = importlib.util.spec_from_file_location("share_card", SHARE_CARD_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)


def _sample(seed_hash: str = "h_love_001"):
    samples = json.loads(SAMPLES_PATH.read_text(encoding="utf-8"))["samples"]
    return next(s for s in samples if s["meta"]["seed_hash"] == seed_hash)


def test_render_svg_contains_required_share_card_fields():
    fortune = _sample()
    svg = _mod.render_share_card_svg(fortune, nickname="민지")

    assert svg.startswith('<svg xmlns="http://www.w3.org/2000/svg"')
    assert 'viewBox="0 0 1080 1350"' in svg
    for expected in (
        "오늘신당",
        "홍연",
        fortune["meta"]["date"],
        "연애운",
        fortune["summary"][0],
        fortune["scores_line"],
        fortune["lucky"]["color"],
        fortune["lucky"]["item"],
        fortune["avoid"],
        "민지님의 오늘 운세",
    ):
        assert expected in svg


def test_render_svg_does_not_expose_private_birth_or_cache_identifiers():
    fortune = _sample()
    svg = _mod.render_share_card_svg(fortune, nickname="손님")

    forbidden = (
        "birth",
        "생년월일",
        "출생시간",
        "profile_hash",
        "HMAC",
        "hmac",
        fortune["meta"]["seed_hash"],
    )
    for needle in forbidden:
        assert needle not in svg


def test_lucky_color_palette_is_fixed_to_character_sheet_set():
    assert set(_mod.PALETTE) == {
        "코랄 핑크",
        "진홍",
        "자수정 보라",
        "청록",
        "살구색",
        "금빛",
        "먹색",
        "은백",
    }

    bad = _sample()
    bad["lucky"] = {**bad["lucky"], "color": "검정"}
    with pytest.raises(ValueError, match="허용되지 않은 lucky.color"):
        _mod.render_share_card_svg(bad)


def test_default_output_path_is_deterministic_and_not_embedded_in_svg():
    fortune = _sample("h_money_001")

    assert _mod.default_output_path(fortune) == Path("share-h_money_001.svg")
    assert "h_money_001" not in _mod.render_share_card_svg(fortune)


def test_write_share_card_creates_svg_file(tmp_path):
    target = tmp_path / "card.svg"
    written = _mod.write_share_card(_sample(), target, nickname="하루")

    assert written == target
    text = target.read_text(encoding="utf-8")
    assert "하루님의 오늘 운세" in text
    assert text.endswith("</svg>\n")


def test_cli_writes_selected_sample(tmp_path):
    target = tmp_path / "h_love_001.svg"
    result = subprocess.run(
        [
            sys.executable,
            str(SHARE_CARD_PATH),
            "--sample",
            "h_love_001",
            "--nickname",
            "손님",
            "--out",
            str(target),
        ],
        cwd=ROOT,
        text=True,
        capture_output=True,
        check=False,
    )

    assert result.returncode == 0, result.stderr
    assert str(target) in result.stdout
    assert target.exists()
    svg = target.read_text(encoding="utf-8")
    assert "손님님의 오늘 운세" in svg
    assert "코랄 핑크" in svg


class TestShareCardIllustrationEmbed:
    """T024: 공유카드 일러스트(hongyeon-share-card.webp) 존재 시 base64 임베드,
    부재 시 기존 텍스트 카드 유지 (ADR-0002 폴백 불변식)."""

    def test_falls_back_to_existing_card_when_illustration_missing(self, tmp_path):
        fortune = _sample()
        missing_path = tmp_path / "does-not-exist.webp"

        svg = _mod.render_share_card_svg(fortune, nickname="민지", illustration_path=missing_path)

        assert "<image" not in svg
        assert "data:image/webp" not in svg

    def test_embeds_illustration_as_base64_when_present(self, tmp_path):
        fortune = _sample()
        stub_path = tmp_path / "hongyeon-share-card.webp"
        stub_bytes = b"RIFF____WEBPVP8 stub-1px-fixture"
        stub_path.write_bytes(stub_bytes)

        svg = _mod.render_share_card_svg(fortune, nickname="민지", illustration_path=stub_path)

        assert "<image" in svg
        expected_data_uri = "data:image/webp;base64," + base64.b64encode(stub_bytes).decode("ascii")
        assert expected_data_uri in svg

    def test_embed_does_not_leak_private_fields(self, tmp_path):
        fortune = _sample()
        stub_path = tmp_path / "hongyeon-share-card.webp"
        stub_path.write_bytes(b"RIFF____WEBPVP8 stub-1px-fixture")

        svg = _mod.render_share_card_svg(fortune, nickname="손님", illustration_path=stub_path)

        forbidden = (
            "birth",
            "생년월일",
            "출생시간",
            "profile_hash",
            "HMAC",
            "hmac",
            fortune["meta"]["seed_hash"],
        )
        for needle in forbidden:
            assert needle not in svg

    def test_default_illustration_path_points_to_static_assets_dir(self):
        expected = _mod.HERE / "web" / "static" / "assets" / "hongyeon-share-card.webp"
        assert _mod.DEFAULT_SHARE_CARD_ILLUSTRATION_PATH == expected
