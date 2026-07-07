"""T019/T020: 재생 파이프라인 조립 — seed_builder→fortune_api(mock)→narration composer→tts_adapter→
cache_layer 호출(fortune_api_mock.get_today_fortune, T012/T014/T016/T018 기연결)의 서버 측 이벤트
(tts_generate_start/complete, cache_hit/miss)를 캡처해 응답 엔벨로프와 함께 반환한다.

T020: `tts_backend="openai"` 옵트인 시에만 T018 실백엔드(tts_adapter.openai_backend)를
synthesize()에 주입한다. 기본값(None)은 지금처럼 mock 고정 — 과금 0.

브라우저 없이 단위 테스트 가능한 조립 지점 (tests/test_web_pipeline.py).
"""
import importlib.util
import json
import logging
from pathlib import Path

_WEB_DIR = Path(__file__).parent
_ENGINE_DIR = _WEB_DIR.parent


def _load(name: str, rel_path: str):
    spec = importlib.util.spec_from_file_location(name, _ENGINE_DIR / rel_path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


_fortune_api_mock = _load("fortune_api_mock", "fortune_api_mock.py")
get_today_fortune = _fortune_api_mock.get_today_fortune

_tts_adapter = _load("tts_adapter", "tts_adapter.py")


class _EventCollector(logging.Handler):
    """cache_layer.get_or_compute / tts_adapter.synthesize의 기본 event_sink(구조화 로그 라인)를
    가로채 이벤트 dict 리스트로 모은다.

    두 모듈 모두 "fortune_engine.<module>" 로거를 쓰고 propagate=True(기본값)이므로,
    공통 조상 로거 "fortune_engine"에 핸들러를 달면 get_today_fortune() 한 번 호출 중 발생한
    모든 tts_generate_*/cache_hit/miss 이벤트를 코드 변경 없이 관찰할 수 있다.
    """

    def __init__(self):
        super().__init__()
        self.events = []

    def emit(self, record):
        try:
            self.events.append(json.loads(record.getMessage()))
        except (json.JSONDecodeError, TypeError):
            pass


def build_playback_response(request: dict, *, store=None, tts_backend=None) -> dict:
    """fortune 파이프라인을 한 번 실행하고, 엔벨로프 + 서버 이벤트 타임라인을 함께 반환한다.

    Args:
        request: get_today_fortune에 그대로 전달되는 fortune 요청 dict.
        store: CacheStore. None이면 fortune_api_mock의 모듈-레벨 기본 store(프로세스 생존 기간
               공유) 사용 — 서버 프로세스에서 재방문 cache_hit를 재현하려면 None(기본값)으로 둔다.
        tts_backend: TTS 합성 백엔드 선택 (T020).
                     None(기본값) — mock 고정, 과금 0.
                     "openai" — T018 실백엔드(tts_adapter.openai_backend) 주입. 실행 시
                     OPENAI_API_KEY 필요, 실제 과금 발생.
                     callable(script, cache_key, metadata) — 테스트 전용 직접 주입
                     (실백엔드 분기 배선을 네트워크 없이 단위 검증하기 위함).

    Returns:
        get_today_fortune()의 모든 키(fortuneId, audioUrl, durationSec, script, fortune, tts)
        + "events": [{"event": "tts_generate_start"|"tts_generate_complete"
                      |"cache_hit"|"cache_miss", ...}, ...]
    """
    tts_synthesize_fn = None
    if tts_backend == "openai":
        backend_fn = _tts_adapter.openai_backend
        tts_synthesize_fn = lambda script: _tts_adapter.synthesize(script, backend=backend_fn)  # noqa: E731
    elif callable(tts_backend):
        tts_synthesize_fn = lambda script: _tts_adapter.synthesize(script, backend=tts_backend)  # noqa: E731

    collector = _EventCollector()
    logger = logging.getLogger("fortune_engine")
    prev_level = logger.level
    logger.addHandler(collector)
    logger.setLevel(logging.INFO)
    try:
        result = get_today_fortune(request, store=store, tts_synthesize_fn=tts_synthesize_fn)
    finally:
        logger.removeHandler(collector)
        logger.setLevel(prev_level)

    return {**result, "events": collector.events}
