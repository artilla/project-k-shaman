#!/usr/bin/env python3
"""T010/T012/T014/T016: /api/fortune/today mock — fortune-schema.v1.1 준수, build_seed·tts_adapter 연결, 2단 캐시.

T012: build_seed(T011)의 seed_hash·seed_signals를 기반으로 응답을 도출한다.
T014: tts_adapter.synthesize(script)로 audioUrl·durationSec·tts metadata를 도출한다.
T016: cache_layer.get_or_compute로 fortune/text + TTS 단계를 각각 캐싱한다 (2단 dedup).

§3 hold: 실제 HMAC seed 키, 실제 LLM 생성, 실제 TTS 합성은 구현하지 않는다.
birth 필드는 수신 가능하지만 키·응답·파일에 평문으로 남기지 않는다.
"""
import hashlib
import importlib.util
import json
from pathlib import Path

_DIR = Path(__file__).parent

# T003 compose_narration 재사용 (서버 조립)
_COMPOSER_PATH = _DIR / "tts-ab-kit" / "narration_composer.py"
_spec = importlib.util.spec_from_file_location("narration_composer", _COMPOSER_PATH)
_mod = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_mod)
_compose_narration = _mod.compose_narration

# T011 seed_builder (build_seed 계약)
_SEED_BUILDER_PATH = _DIR / "seed_builder.py"
_sb_spec = importlib.util.spec_from_file_location("seed_builder", _SEED_BUILDER_PATH)
_sb_mod = importlib.util.module_from_spec(_sb_spec)
_sb_spec.loader.exec_module(_sb_mod)
build_seed = _sb_mod.build_seed

# T013 tts_adapter (synthesize 계약) — mock backend 기본, 실제 합성 = §3 hold
_TTS_ADAPTER_PATH = _DIR / "tts_adapter.py"
_tts_spec = importlib.util.spec_from_file_location("tts_adapter", _TTS_ADAPTER_PATH)
_tts_mod = importlib.util.module_from_spec(_tts_spec)
_tts_spec.loader.exec_module(_tts_mod)
_tts_synthesize = _tts_mod.synthesize

# T015 cache_layer (get_or_compute, InMemoryCacheStore, fortune_cache_key)
# §3 hold: inject real Redis/S3 store for production via store parameter.
_CACHE_LAYER_PATH = _DIR / "cache_layer.py"
_cl_spec = importlib.util.spec_from_file_location("cache_layer", _CACHE_LAYER_PATH)
_cl_mod = importlib.util.module_from_spec(_cl_spec)
_cl_spec.loader.exec_module(_cl_mod)
get_or_compute = _cl_mod.get_or_compute
InMemoryCacheStore = _cl_mod.InMemoryCacheStore
fortune_cache_key = _cl_mod.fortune_cache_key

# Module-level default store (in-memory, no network).
# §3 hold: replace with Redis/Memcached injection for production.
_default_store = InMemoryCacheStore()

# 결정적 풀 — 텍스트 필드 소스 (scores_line, summary, advice, lucky, avoid, blessing)
_POOL = [
    {
        "scores_line": "연애운이 활짝 열렸고 인간관계도 좋아요. 다만 컨디션은 조금 낮으니 무리하진 마세요.",
        "summary": ["오늘은 마음이 먼저 움직이는 날이에요.", "솔직한 한마디가 관계의 온도를 한 칸 올려줘요."],
        "advice": "마음에 둔 사람에게 짧은 안부 한마디를 먼저 건네 보세요.",
        "lucky": {"color": "코랄 핑크", "item": "작은 손거울"},
        "avoid": "지난 대화를 너무 곱씹으며 혼자 결론 내리는 일은 잠시 미뤄두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "금전운이 든든하게 올라와 있어요. 일운도 안정적이라 차근차근 정리하기 좋아요.",
        "summary": ["작게 모으던 것이 형태를 갖추는 날이에요.", "오늘의 알뜰한 선택이 다음 주의 여유가 돼요."],
        "advice": "미뤄둔 가계부나 영수증을 5분만 정리해 보세요.",
        "lucky": {"color": "금빛", "item": "단추"},
        "avoid": "기분에 휩쓸린 즉흥 결제는 오늘만 잠시 멈춰두세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "일과 학업운이 아주 좋아요. 컨디션도 받쳐주니 중요한 일을 먼저 처리하기 좋아요.",
        "summary": ["집중력이 또렷하게 모이는 날이에요.", "미뤄둔 일 하나를 끝내면 흐름이 쭉 풀려요."],
        "advice": "가장 부담스러운 일을 오전 첫 30분에 먼저 손대 보세요.",
        "lucky": {"color": "먹색", "item": "메모지"},
        "avoid": "여러 일을 동시에 벌여 놓고 끝을 못 맺는 패턴은 오늘만 피하세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "인간관계운과 컨디션이 모두 좋아요. 연애운도 살짝 올라 기분 좋은 하루가 돼요.",
        "summary": ["분위기를 살리는 역할이 잘 어울리는 날이에요.", "당신이 웃으면 주변 공기가 한결 가벼워져요."],
        "advice": "오늘은 모임에서 먼저 분위기를 띄우는 한마디를 건네 보세요.",
        "lucky": {"color": "자수정 보라", "item": "작은 종"},
        "avoid": "모두를 챙기느라 정작 내 기분을 뒤로 미루지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
    {
        "scores_line": "모든 운이 고르게 좋은 편이에요. 특별히 튀는 곳 없이 무난하고 든든한 하루예요.",
        "summary": ["전체적으로 균형이 잘 잡힌 안정적인 날이에요.", "큰 욕심 없이 흐름을 타면 하루가 매끄러워요."],
        "advice": "오늘 할 일 중 가장 쉬운 것부터 하나 끝내고 시작해 보세요.",
        "lucky": {"color": "은백", "item": "향초"},
        "avoid": "괜히 큰 결정을 서둘러 내리려 하지는 마세요.",
        "blessing": "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.",
    },
]

# score_bias(high|mid|low) → 0-100 정수 범위
_BIAS_RANGES = {
    "high": (70, 100),
    "mid": (40, 69),
    "low": (0, 39),
}
_SCORE_FIELDS = ["love", "money", "work", "relationship", "condition"]


def _apply_bias_scores(score_bias: dict, seed_hash: str) -> dict:
    """score_bias + seed_hash → 결정적 0-100 정수 scores (스키마 유효)."""
    scores = {}
    for i, field in enumerate(_SCORE_FIELDS):
        bias = score_bias.get(field, "mid")
        lo, hi = _BIAS_RANGES[bias]
        # seed_hash의 20번째 위치 이후 바이트를 사용 (앞 20자리는 pool 선택에 사용)
        byte_val = int(seed_hash[20 + i * 4: 20 + i * 4 + 4], 16)
        scores[field] = lo + byte_val % (hi - lo + 1)
    return scores


def _compute_tts_cache_key(
    script,
    provider: str = "openai",
    voice: str = "coral",
    speed: float = 1.0,
    emotion: str = "bright",
) -> str:
    """Compute TTS cache key matching tts_adapter.synthesize formula (no network call).

    Returns the same key as tts_adapter.synthesize(script)["cacheKey"].
    """
    serialized = json.dumps(script, ensure_ascii=False, sort_keys=True)
    script_hash = hashlib.sha256(serialized.encode("utf-8")).hexdigest()
    return f"tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion}"


def _build_fortune_data(request: dict, seed_result: dict) -> dict:
    """Build fortune dict + script from seed_result (no TTS). Compute_fn for fortune cache.

    Returns {"fortune": dict, "fortune_id": str, "script": list}
    """
    seed_hash = seed_result["seed_hash"]
    seed_signals = seed_result["seed_signals"]

    pool_idx = int(seed_hash[:8], 16) % len(_POOL)
    fields = _POOL[pool_idx]
    scores = _apply_bias_scores(seed_signals["score_bias"], seed_hash)

    date = request.get("date", "2026-01-01")
    topic = request.get("topic", "total")
    character_id = request.get("character_id", "hongyeon")

    fortune = {
        "schema_version": "fortune.v1.1",
        "meta": {
            "date": date,
            "character_id": character_id,
            "topic": topic,
            "tone": "bright",
            "locale": "ko-KR",
            "seed_hash": seed_hash,
            "content_version": "prompt.v1.1",
        },
        "scores": scores,
        "scores_line": fields["scores_line"],
        "summary": fields["summary"],
        "advice": fields["advice"],
        "lucky": fields["lucky"],
        "avoid": fields["avoid"],
        "blessing": fields["blessing"],
    }

    fortune_id = f"mock_{seed_hash[:16]}"
    script = _compose_narration({**fields, "scores": scores})

    return {"fortune": fortune, "fortune_id": fortune_id, "script": script}


def get_today_fortune(
    request: dict,
    *,
    store=None,
    fortune_build_fn=None,
    tts_synthesize_fn=None,
    include_tts: bool = True,
) -> dict:
    """결정적 fortune 응답을 반환한다 (2단 캐시 포함).

    build_seed(T011)의 seed_hash·seed_signals를 기반으로 응답을 도출한다.
    birth 필드는 seed_builder에서 버킷 해시로 변환되며, 응답에 평문으로 남기지 않는다.

    Args:
        request: fortune 요청 딕셔너리.
        store: CacheStore (get/set 인터페이스). None이면 모듈-레벨 InMemoryCacheStore 사용.
               §3 hold: inject real Redis/Memcached store for production.
        fortune_build_fn: (request, seed_result) → fortune_data. None이면 _build_fortune_data.
        tts_synthesize_fn: (script) → tts_result. None이면 _tts_synthesize.
                           §3 hold: inject real OpenAI TTS backend here for production synthesis.
        include_tts: False면 TTS 단계를 완전히 건너뛴다 — 합성도, 캐시 기록도 하지 않는다.
                     텍스트 전용 응답(text-first) 경로용: mock 합성 결과가 공용 TTS 캐시 키를
                     선점해 이후 실백엔드 합성이 hit로 skip되던 회귀 방지 (코드리뷰 P1).
                     이때 audioUrl·durationSec은 None, tts.cacheKey는 결정적으로 계산된 값.
    """
    if store is None:
        store = _default_store
    if fortune_build_fn is None:
        fortune_build_fn = _build_fortune_data
    if tts_synthesize_fn is None:
        tts_synthesize_fn = _tts_synthesize

    # T011 계약: birth → 버킷 해시 변환, seed_hash·seed_signals 생성
    seed_result = build_seed(request)
    seed_hash = seed_result["seed_hash"]

    # Stage 1: fortune/text cache (fortune:v1:{seed_hash})
    f_key = fortune_cache_key(seed_hash)
    fortune_data = get_or_compute(
        store, f_key, lambda: fortune_build_fn(request, seed_result), layer="fortune"
    )

    # Stage 2: TTS cache (tts:v1:{provider}:{voice}:{script_hash}:{speed}:{emotion})
    # Key verbatim matches tts_adapter.synthesize(script)["cacheKey"].
    script = fortune_data["script"]
    tts_key = _compute_tts_cache_key(script)

    if not include_tts:
        # 텍스트 전용 — 합성·캐시 기록 없이 결정적 cacheKey만 제공한다 (text-first 경로)
        return {
            "fortuneId": fortune_data["fortune_id"],
            "audioUrl": None,
            "durationSec": None,
            "script": script,
            "fortune": fortune_data["fortune"],
            "tts": {"cacheKey": tts_key},
        }

    tts_result = get_or_compute(store, tts_key, lambda: tts_synthesize_fn(script), layer="tts")

    return {
        "fortuneId": fortune_data["fortune_id"],
        "audioUrl": tts_result["audioUrl"],
        "durationSec": tts_result["durationSec"],
        "script": script,
        "fortune": fortune_data["fortune"],
        "tts": {
            "cacheKey": tts_result["cacheKey"],
            "provider": tts_result["metadata"]["provider"],
            "voice": tts_result["metadata"]["voice"],
            "model": tts_result["metadata"]["model"],
            "speed": tts_result["metadata"]["speed"],
            "emotion": tts_result["metadata"]["emotion"],
        },
    }
