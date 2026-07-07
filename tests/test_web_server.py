"""T019/T020: web/server.py 스모크 테스트 — 브라우저 없이 검증 가능한 HTTP 계약만 확인한다.

수용 기준 매핑:
- 탭 이후 흐름(텍스트→오디오)은 브라우저 스크립트(static/app.js) 영역이라 여기서 다루지 않는다.
- 이 파일은 서버가 내보내는 계약(JSON 엔벨로프, 재생 가능한 오디오 응답, 이벤트 수집 엔드포인트,
  정적 페이지 서빙)이 실제로 성립하는지를 검증한다.
- T020: --backend openai 옵트인 분기(키 가드, /audio/real/* 서빙 경로)는 실 네트워크 호출 없이
  라우팅/가드 로직만 단위 검증한다 (실 계약 테스트는 tests/test_tts_adapter.py에 이미 존재).
"""
import hashlib
import importlib.util
import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

import pytest

ROOT = Path(__file__).parent.parent
SERVER_PATH = ROOT / "fortune-engine" / "web" / "server.py"

_spec = importlib.util.spec_from_file_location("t019_web_server", SERVER_PATH)
web_server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(web_server)


def _start_server(backend="mock"):
    httpd = web_server.make_server(("127.0.0.1", 0), backend=backend)
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, thread


def _url(httpd, path):
    port = httpd.server_address[1]
    return f"http://127.0.0.1:{port}{path}"


def _stop(httpd, thread):
    httpd.shutdown()
    thread.join(timeout=2)
    httpd.server_close()


class TestFortuneEndpoint:
    def test_returns_json_envelope_with_playable_audio_url(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                assert resp.status == 200
                data = json.loads(resp.read())
            for key in ("fortuneId", "script", "audioUrl", "durationSec", "events"):
                assert key in data, f"'{key}' 키 누락"
            assert data["audioUrl"].startswith("/audio/mock/"), (
                f"audioUrl이 재생 가능한 로컬 경로가 아님: {data['audioUrl']!r}"
            )
        finally:
            _stop(httpd, thread)

    def test_revisit_same_seed_reuses_audio_url_and_skips_new_synthesis(self):
        httpd, thread = _start_server()
        try:
            path = "/api/fortune/today?topic=love&date=2026-07-07&character_id=hongyeon"
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                first = json.loads(resp.read())
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                second = json.loads(resp.read())

            assert first["audioUrl"] == second["audioUrl"]
            second_names = [e["event"] for e in second["events"]]
            assert "tts_generate_start" not in second_names, "재방문인데 신규 합성 발생"
            assert "cache_hit" in second_names
        finally:
            _stop(httpd, thread)


class TestFortuneCardFieldsContract:
    """T022: S4 phase C 텍스트 카드가 렌더링에 쓰는 fortune 필드가 응답에 고정 존재하는지 잠근다."""

    def test_fortune_object_has_card_fields(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            fortune = data["fortune"]

            assert isinstance(fortune["summary"], list) and len(fortune["summary"]) >= 1
            assert isinstance(fortune["scores_line"], str) and fortune["scores_line"]
            assert isinstance(fortune["avoid"], str) and fortune["avoid"]

            scores = fortune["scores"]
            for key in ("love", "money", "work", "relationship", "condition"):
                assert key in scores, f"scores.{key} 누락"
                assert 0 <= scores[key] <= 100

            lucky = fortune["lucky"]
            assert isinstance(lucky["color"], str) and lucky["color"]
            assert isinstance(lucky["item"], str) and lucky["item"]
        finally:
            _stop(httpd, thread)


class TestAudioEndpoint:
    def test_audio_endpoint_serves_playable_wav(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            with urllib.request.urlopen(_url(httpd, data["audioUrl"])) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type") == "audio/wav"
                body = resp.read()
            assert body[:4] == b"RIFF", "유효한 WAV 헤더가 아님"
            assert len(body) > 44
        finally:
            _stop(httpd, thread)

    def test_invalid_audio_key_rejected(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/audio/mock/../../etc-passwd.wav"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)


class TestEventEndpoint:
    def test_post_event_round_trip(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())

            payload = json.dumps({
                "fortuneId": data["fortuneId"],
                "sessionStartMs": 0,
                "clientEvents": [
                    {"event": "first_text_visible", "clientTs": 100},
                    {"event": "first_audio_play", "clientTs": 300},
                ],
                "serverEvents": data["events"],
            }).encode("utf-8")
            req = urllib.request.Request(
                _url(httpd, "/api/event"), data=payload,
                headers={"Content-Type": "application/json"}, method="POST",
            )
            with urllib.request.urlopen(req) as resp:
                assert resp.status == 200
                result = json.loads(resp.read())
            assert result["missing"] == []
            assert result["summary"]["textLatencyMs"] == 100
            assert result["summary"]["audioLatencyMs"] == 300
        finally:
            _stop(httpd, thread)


class TestStaticPage:
    def test_index_html_served_at_root(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type", "").startswith("text/html")
                body = resp.read().decode("utf-8")
            assert "<html" in body.lower()
            assert "start-btn" in body
        finally:
            _stop(httpd, thread)

    def test_app_js_served(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                assert resp.status == 200
                assert "javascript" in resp.headers.get("Content-Type", "")
        finally:
            _stop(httpd, thread)


class TestStagePlaybackUXMarkup:
    """T022: phase C 텍스트 카드 + phase D 플레이어 FSM 요소가 정적 파일에 존재하는지
    문자열 수준으로 잠근다 (브라우저 렌더링 자체는 수동 확인, 관례는 T019).
    무회귀: 기존 훅(start-btn·share-btn·share-status)과 이벤트명은 그대로 유지되어야 한다.
    """

    def test_index_html_has_card_and_player_elements(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                body = resp.read().decode("utf-8")
            # phase C 텍스트 카드
            for hook in (
                "fortune-card", "card-summary", "card-scores-line", "card-scores",
                "card-lucky-color", "card-lucky-item", "card-avoid",
            ):
                assert f'id="{hook}"' in body, f"카드 요소 누락: {hook}"
            # phase D 플레이어 FSM
            for hook in ("player", "player-state", "player-progress-bar", "listen-btn", "play-pause-btn", "replay-btn"):
                assert f'id="{hook}"' in body, f"플레이어 요소 누락: {hook}"
            # 무대 아바타 플레이스홀더
            assert 'id="avatar"' in body
            # 기존 훅 무회귀
            for hook in ("start-btn", "share-btn", "share-status"):
                assert f'id="{hook}"' in body, f"기존 훅 회귀: {hook}"
        finally:
            _stop(httpd, thread)

    def test_app_js_keeps_existing_event_hooks_and_adds_player_fsm(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            # 이벤트 훅 무회귀
            assert "first_text_visible" in body
            assert "first_audio_play" in body
            # 부적 받기(T021) 무회귀
            assert "share-btn" in body or "shareBtn" in body
            # 플레이어 FSM 상태 라벨
            for state in ("greeting", "speaking", "blessing"):
                assert state in body, f"FSM 상태 누락: {state}"
        finally:
            _stop(httpd, thread)

    def test_styles_css_has_stage_and_player_classes(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/styles.css")) as resp:
                body = resp.read().decode("utf-8")
            for selector in (".avatar", ".fortune-card", ".score-bar", ".player-progress-bar"):
                assert selector in body, f"스타일 셀렉터 누락: {selector}"
        finally:
            _stop(httpd, thread)


class TestAvatarAssetStaticServing:
    """T024: 아바타 에셋(assets/hongyeon-*.webp)은 정적 서빙 규칙을 그대로 탄다 —
    부재 시 404(프론트가 무음 폴백), 존재 시 image/webp로 서빙."""

    def test_asset_missing_by_default_returns_404(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/static/assets/hongyeon-idle.webp"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)

    def test_asset_present_is_served_with_webp_content_type(self):
        assets_dir = web_server._STATIC_DIR / "assets"
        assets_dir.mkdir(parents=True, exist_ok=True)
        stub_path = assets_dir / "hongyeon-idle.webp"
        stub_bytes = b"RIFF____WEBPVP8 stub-1px-fixture"
        stub_path.write_bytes(stub_bytes)
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/assets/hongyeon-idle.webp")) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type") == "image/webp"
                assert resp.read() == stub_bytes
        finally:
            _stop(httpd, thread)
            stub_path.unlink(missing_ok=True)
            try:
                assets_dir.rmdir()
            except OSError:
                pass


class TestAvatarAssetFrontendWiring:
    """T024: FSM 상태별 이미지 스왑·음량 글로우·지연 preload 배선이 app.js/index.html/styles.css에
    존재하는지 문자열/구조 수준으로 잠근다 (브라우저 렌더링 자체는 수동 확인, 관례는 T022와 동일)."""

    def test_index_html_has_avatar_image_element(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                body = resp.read().decode("utf-8")
            assert 'id="avatar-image"' in body
            assert 'id="avatar"' in body  # 기존 훅 무회귀
        finally:
            _stop(httpd, thread)

    def test_app_js_maps_fsm_states_to_asset_filenames(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            for state in ("greeting", "idle", "speaking", "blessing"):
                assert f'"{state}"' in body, f"FSM 상태 누락: {state}"
            assert "hongyeon-" in body
            assert "/static/assets/" in body
        finally:
            _stop(httpd, thread)

    def test_app_js_preload_is_feature_detected_and_silent_on_404(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            assert "onerror" in body
            assert "onload" in body
        finally:
            _stop(httpd, thread)

    def test_app_js_preload_call_happens_after_first_text_visible_report(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            report_idx = body.index('"first_text_visible"')
            preload_call_idx = body.index("preloadAvatarAssets();")
            assert preload_call_idx > report_idx, "에셋 preload가 첫 텍스트 노출보다 먼저 실행되면 지연 회귀"
        finally:
            _stop(httpd, thread)

    def test_app_js_has_volume_reactive_glow_via_analyser_node(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            assert "createAnalyser" in body
            assert "createMediaElementSource" in body
            assert body.count("createMediaElementSource(") == 1, "AudioContext/analyser는 재사용해야 함(중복 생성 금지)"
        finally:
            _stop(httpd, thread)

    def test_styles_css_has_avatar_image_crossfade_and_glow_variable(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/styles.css")) as resp:
                body = resp.read().decode("utf-8")
            assert ".avatar-image" in body
            assert "transition" in body
            assert "--glow-level" in body
        finally:
            _stop(httpd, thread)


class TestBackendStartupGuard:
    """T020: --backend openai 옵트인인데 키가 없으면 기동 자체를 거부한다 (실수 과금 방지)."""

    def test_mock_backend_never_requires_key(self):
        web_server.validate_backend_startup("mock", has_api_key=False)  # 예외 없이 통과

    def test_openai_backend_without_key_raises(self):
        with pytest.raises(RuntimeError):
            web_server.validate_backend_startup("openai", has_api_key=False)

    def test_openai_backend_with_key_passes(self):
        web_server.validate_backend_startup("openai", has_api_key=True)  # 예외 없이 통과


class TestDefaultBackendUnchanged:
    """AC: 기본 실행(플래그 없음)은 T019와 완전히 동일 — mock 고정, 과금 0."""

    def test_default_make_server_backend_is_mock(self):
        httpd, thread = _start_server()
        try:
            assert httpd.tts_backend_mode == "mock"
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            assert data["audioUrl"].startswith("/audio/mock/")
        finally:
            _stop(httpd, thread)


class TestRealAudioUrlScheme:
    def test_real_audio_url_format(self):
        url = web_server._real_audio_url_for("tts:v1:openai:coral:deadbeef:1.0:bright")
        assert url.startswith("/audio/real/")
        assert url.endswith(".mp3")
        key_hash = url[len("/audio/real/"):-len(".mp3")]
        assert len(key_hash) == 64
        assert all(c in "0123456789abcdef" for c in key_hash)

    def test_real_audio_url_matches_openai_backend_file_naming(self):
        """T018 openai_backend가 state/tts_cache/에 쓰는 파일명과 해시가 정확히 일치해야 서빙이 성립한다."""
        cache_key = "tts:v1:openai:coral:deadbeef:1.0:bright"
        expected_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
        url = web_server._real_audio_url_for(cache_key)
        assert url == f"/audio/real/{expected_hash}.mp3"


class TestOpenAIBackendRouting:
    """실 네트워크 호출 없이, --backend openai 선택 시 응답이 실 오디오 서빙 경로를 쓰는지만 검증한다."""

    def test_openai_mode_uses_real_audio_url_scheme(self, monkeypatch):
        httpd, thread = _start_server(backend="openai")
        try:
            assert httpd.tts_backend_mode == "openai"

            def fake_build_playback_response(request, *, store=None, tts_backend=None):
                assert tts_backend == "openai"
                return {
                    "fortuneId": "mock_deadbeef",
                    "script": [],
                    "durationSec": 50,
                    "fortune": {},
                    "tts": {"cacheKey": "tts:v1:openai:coral:deadbeef:1.0:bright"},
                    "events": [],
                }

            monkeypatch.setattr(web_server, "build_playback_response", fake_build_playback_response)

            with urllib.request.urlopen(_url(httpd, "/api/fortune/today")) as resp:
                data = json.loads(resp.read())
            assert data["audioUrl"] == web_server._real_audio_url_for("tts:v1:openai:coral:deadbeef:1.0:bright")
            assert data["audioUrl"].startswith("/audio/real/")
        finally:
            _stop(httpd, thread)


class TestPresynth:
    """T020: --presynth는 기본 seed를 미리 합성해 cache_hit 경로를 준비한다 (실 네트워크 없이 배선만 검증)."""

    def test_presynth_calls_build_playback_response_with_openai_backend(self, monkeypatch):
        calls = []

        def fake_build_playback_response(request, *, store=None, tts_backend=None):
            calls.append({"request": request, "tts_backend": tts_backend})
            return {"events": [{"event": "tts_generate_complete", "costUsd": 0.0078}]}

        monkeypatch.setattr(web_server, "build_playback_response", fake_build_playback_response)
        web_server._presynth_default_seed()

        assert len(calls) == 1
        assert calls[0]["tts_backend"] == "openai"
        assert calls[0]["request"] == {
            "date": web_server._DEFAULT_DATE,
            "topic": web_server._DEFAULT_TOPIC,
            "character_id": web_server._DEFAULT_CHARACTER_ID,
        }

    def test_presynth_prints_cost_estimate_on_new_synthesis(self, monkeypatch, capsys):
        monkeypatch.setattr(
            web_server, "build_playback_response",
            lambda request, **kw: {"events": [{"event": "tts_generate_complete", "costUsd": 0.0078}]},
        )
        web_server._presynth_default_seed()
        out = capsys.readouterr().out
        assert "0.0078" in out

    def test_presynth_reports_already_warm_when_cache_hit(self, monkeypatch, capsys):
        monkeypatch.setattr(
            web_server, "build_playback_response",
            lambda request, **kw: {"events": [{"event": "cache_hit", "layer": "tts"}]},
        )
        web_server._presynth_default_seed()
        out = capsys.readouterr().out
        assert "already warm" in out


class TestShareCardEndpoint:
    """T021: GET /api/share-card?fortuneId=<id> — T006 렌더러를 실 재생 흐름에 연결."""

    def test_valid_fortune_id_returns_svg(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            with urllib.request.urlopen(
                _url(httpd, f"/api/share-card?fortuneId={data['fortuneId']}")
            ) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type", "").startswith("image/svg+xml")
                body = resp.read().decode("utf-8")
            assert body.startswith("<svg")
            assert "오늘신당" in body
        finally:
            _stop(httpd, thread)

    def test_unknown_fortune_id_returns_404(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/api/share-card?fortuneId=does-not-exist"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)

    def test_missing_fortune_id_param_returns_404(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/api/share-card"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)

    def test_share_card_does_not_leak_birth_fields_or_full_seed_hash(self):
        httpd, thread = _start_server()
        try:
            path = (
                "/api/fortune/today?topic=love&date=2026-07-07"
                "&birth_year=1990&birth_month=5&birth_day=14&birth_hour=8"
            )
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                data = json.loads(resp.read())
            with urllib.request.urlopen(
                _url(httpd, f"/api/share-card?fortuneId={data['fortuneId']}")
            ) as resp:
                body = resp.read().decode("utf-8")
            assert "1990" not in body
            assert data["fortune"]["meta"]["seed_hash"] not in body
        finally:
            _stop(httpd, thread)


class TestFortuneCacheEviction:
    """세션 범위 상한 — 초과 시 가장 오래된 항목부터 제거 (메모리 누수 방지, 위험 완화)."""

    def test_evicts_oldest_when_over_capacity(self):
        cache = {}
        limit = web_server._FORTUNE_CACHE_MAX
        for i in range(limit + 1):
            web_server._remember_fortune(cache, f"id{i}", {"n": i})
        assert len(cache) == limit
        assert "id0" not in cache
        assert f"id{limit}" in cache


class TestAudioRealEndpoint:
    def test_serves_existing_real_audio_file(self):
        httpd, thread = _start_server(backend="openai")
        cache_key = "tts:v1:openai:coral:testfixture:1.0:bright"
        key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
        web_server._TTS_REAL_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        fixture_path = web_server._TTS_REAL_CACHE_DIR / f"{key_hash}.mp3"
        fixture_bytes = b"\xff\xfb\x90\x00fake-mp3-fixture"
        fixture_path.write_bytes(fixture_bytes)
        try:
            with urllib.request.urlopen(_url(httpd, f"/audio/real/{key_hash}.mp3")) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type") == "audio/mpeg"
                assert resp.read() == fixture_bytes
        finally:
            fixture_path.unlink(missing_ok=True)
            _stop(httpd, thread)

    def test_missing_real_audio_file_returns_404(self):
        httpd, thread = _start_server(backend="openai")
        try:
            missing_hash = "0" * 64
            try:
                urllib.request.urlopen(_url(httpd, f"/audio/real/{missing_hash}.mp3"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)

    def test_invalid_real_audio_key_rejected(self):
        httpd, thread = _start_server(backend="openai")
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/audio/real/../../etc-passwd.mp3"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)
