"""T003: narration_composer ↔ 캐릭터 시트 §4 / 프롬프트 v1.1 정합 회귀 테스트.

정본 출처: fortune-engine/character-sheet-hongyeon.md §4 narration 조립 순서
  (= fortune-prompt-hongyeon.v1.1.md §변경요약과 동일)
조립 순서: greeting → summary → scores → advice → lucky → avoid → blessing → ending
"""
import importlib.util
import json
from pathlib import Path

# ── 경로 상수 ────────────────────────────────────────────────
ROOT = Path(__file__).parent.parent
COMPOSER_PATH = ROOT / "fortune-engine" / "tts-ab-kit" / "narration_composer.py"
SAMPLES_PATH = ROOT / "fortune-engine" / "fortune-samples.v1.1.json"

# ── importlib로 하이픈 포함 경로 모듈 로드 ────────────────────
_spec = importlib.util.spec_from_file_location("narration_composer", COMPOSER_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
compose_narration = _mod.compose_narration
PRESYNTH = _mod.PRESYNTH

# ── 테스트 픽스처 ─────────────────────────────────────────────
_FIXTURE = {
    "scores": {"love": 88, "money": 61, "work": 55, "relationship": 79, "condition": 48},
    "scores_line": "연애운이 활짝 열렸고 인간관계도 좋아요.",
    "summary": ["오늘은 마음이 먼저 움직이는 날이에요.", "솔직한 한마디가 관계의 온도를 한 칸 올려줘요."],
    "advice": "마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.",
    "lucky": {"color": "코랄 핑크", "item": "작은 손거울"},
    "avoid": "지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.",
}

# ── 정본 순서 (캐릭터 시트 §4 표) ────────────────────────────────
EXPECTED_ORDER = ["greeting", "summary", "scores", "advice", "lucky", "avoid", "blessing", "ending"]


class TestSegmentOrder:
    """조립 순서가 캐릭터 시트 §4 정본과 일치하는지 검증."""

    def test_returns_exactly_8_segments(self):
        result = compose_narration(_FIXTURE)
        assert len(result) == 8, f"세그먼트 수 불일치: {len(result)} (기대: 8)"

    def test_segment_order_matches_spec(self):
        result = compose_narration(_FIXTURE)
        actual_order = [seg["segment"] for seg in result]
        assert actual_order == EXPECTED_ORDER, (
            f"세그먼트 순서 불일치\n  실제: {actual_order}\n  정본(시트 §4): {EXPECTED_ORDER}"
        )

    # NOTE: transition 세그먼트 미포함 = Sprint 후속 product 결정 (선택)
    # 캐릭터 시트 §5 "(선택) 전환" 참조 — 이 테스트에서 실패로 취급하지 않음


class TestSegmentTypes:
    """세그먼트 type이 티켓 AC 및 시트 §4 명세에 맞는지 검증."""

    def test_presynth_segments_have_correct_type(self):
        result = compose_narration(_FIXTURE)
        seg_map = {s["segment"]: s for s in result}
        for name in ("greeting", "blessing", "ending"):
            assert seg_map[name]["type"] == "presynth", (
                f"{name} type={seg_map[name]['type']!r} (기대: 'presynth')"
            )

    def test_personalized_segments_come_from_llm_fields(self):
        result = compose_narration(_FIXTURE)
        seg_map = {s["segment"]: s for s in result}
        for name in ("summary", "scores", "advice", "avoid"):
            assert seg_map[name]["type"] == "personalized", (
                f"{name} type={seg_map[name]['type']!r} (기대: 'personalized')"
            )

    def test_lucky_segment_is_semi_type(self):
        result = compose_narration(_FIXTURE)
        seg_map = {s["segment"]: s for s in result}
        assert seg_map["lucky"]["type"] == "semi", (
            f"lucky type={seg_map['lucky']['type']!r} (기대: 'semi')"
        )


class TestPresynthPool:
    """presynth 세그먼트가 PRESYNTH 풀에서 나오는지 검증.

    NOTE: presynth 단일 문자열 = MVP 허용 편차.
    풀 확장(변형 세트)은 Sprint 후속 product 결정 (Plan.md §10 풀 분리 참조).
    """

    def test_presynth_texts_come_from_pool(self):
        result = compose_narration(_FIXTURE)
        seg_map = {s["segment"]: s for s in result}
        for name in ("greeting", "blessing", "ending"):
            expected = PRESYNTH[name]
            actual = seg_map[name]["text"]
            assert actual == expected, (
                f"{name} text 불일치\n  실제: {actual!r}\n  풀 값: {expected!r}"
            )


class TestSmokeWithFileSample:
    """fortune-samples.v1.1.json의 유효 샘플 1건으로 스모크 검증."""

    def test_all_segments_nonempty_with_file_sample(self):
        with SAMPLES_PATH.open(encoding="utf-8") as f:
            samples = json.load(f)["samples"]
        assert samples, "fortune-samples.v1.1.json에 샘플이 없음"

        sample = samples[0]
        # 테스트 전제: 누락 시 명확히 실패 메시지 (티켓 §6 위험 완화)
        assert len(sample.get("summary", [])) == 2, (
            f"샘플 summary 길이 불일치: {sample.get('summary')}"
        )
        assert "color" in sample.get("lucky", {}), "샘플 lucky.color 누락"
        assert "item" in sample.get("lucky", {}), "샘플 lucky.item 누락"
        assert "avoid" in sample, "샘플 avoid 필드 누락"
        assert "advice" in sample, "샘플 advice 필드 누락"

        result = compose_narration(sample)
        for seg in result:
            assert seg["text"].strip(), (
                f"세그먼트 '{seg['segment']}' text가 비어 있음: {seg['text']!r}"
            )
