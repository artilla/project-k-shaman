"""T019/T020: web/server.py 스모크 테스트 — 브라우저 없이 검증 가능한 HTTP 계약만 확인한다.

수용 기준 매핑:
- 탭 이후 흐름(텍스트→오디오)은 브라우저 스크립트(static/app.js) 영역이라 여기서 다루지 않는다.
- 이 파일은 서버가 내보내는 계약(JSON 엔벨로프, 재생 가능한 오디오 응답, 이벤트 수집 엔드포인트,
  정적 페이지 서빙)이 실제로 성립하는지를 검증한다.
- T020: --backend openai 옵트인 분기(키 가드, /audio/real/* 서빙 경로)는 실 네트워크 호출 없이
  라우팅/가드 로직만 단위 검증한다 (실 계약 테스트는 tests/test_tts_adapter.py에 이미 존재).
"""
import hashlib
import http.client
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


def _login_headers(httpd):
    """오디오·부적 게이트용 — 서버 메모리에 세션을 직접 심고 서명 쿠키 헤더를 돌려준다."""
    session_id = "testsession0001"
    httpd.sessions[session_id] = {"provider": "google", "nickname": "테스트"}
    value = web_server._make_session_cookie_value(session_id, httpd.session_secret)
    return {"Cookie": f"shindang_session={value}"}


def _open(httpd, path, headers=None):
    req = urllib.request.Request(_url(httpd, path), headers=headers or {})
    return urllib.request.urlopen(req)


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
            with _open(httpd, data["audioUrl"], headers=_login_headers(httpd)) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type") == "audio/wav"
                body = resp.read()
            assert body[:4] == b"RIFF", "유효한 WAV 헤더가 아님"
            assert len(body) > 44
        finally:
            _stop(httpd, thread)

    def test_audio_requires_login(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            try:
                urllib.request.urlopen(_url(httpd, data["audioUrl"]))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 401
            assert raised
        finally:
            _stop(httpd, thread)

    def test_invalid_audio_key_rejected(self):
        httpd, thread = _start_server()
        try:
            try:
                _open(httpd, "/audio/mock/../../etc-passwd.wav", headers=_login_headers(httpd))
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
                # 실자산 커밋 후에도 유효하도록 "존재할 수 없는 상태명"으로 계약을 고정한다
                # (T025에서 수정 — 원래는 hongyeon-idle.webp를 조회해 실자산과 충돌·삭제 사고).
                urllib.request.urlopen(_url(httpd, "/static/assets/hongyeon-nonexistent-state.webp"))
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
        # 실자산 파일명과 절대 겹치지 않는 스텁 이름 사용 (실자산 삭제 사고 방지, T025)
        stub_path = assets_dir / "hongyeon-stub-fixture.webp"
        stub_bytes = b"RIFF____WEBPVP8 stub-1px-fixture"
        stub_path.write_bytes(stub_bytes)
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(
                _url(httpd, "/static/assets/hongyeon-stub-fixture.webp")
            ) as resp:
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
            with _open(
                httpd, f"/api/share-card?fortuneId={data['fortuneId']}", headers=_login_headers(httpd)
            ) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type", "").startswith("image/svg+xml")
                body = resp.read().decode("utf-8")
            assert body.startswith("<svg")
            assert "오늘신당" in body
        finally:
            _stop(httpd, thread)

    def test_share_card_requires_login(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/api/share-card?fortuneId=whatever"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 401
            assert raised
        finally:
            _stop(httpd, thread)

    def test_unknown_fortune_id_returns_404(self):
        httpd, thread = _start_server()
        try:
            try:
                _open(httpd, "/api/share-card?fortuneId=does-not-exist", headers=_login_headers(httpd))
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
                _open(httpd, "/api/share-card", headers=_login_headers(httpd))
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
            with _open(
                httpd, f"/api/share-card?fortuneId={data['fortuneId']}", headers=_login_headers(httpd)
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
            with _open(httpd, f"/audio/real/{key_hash}.mp3", headers=_login_headers(httpd)) as resp:
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
                _open(httpd, f"/audio/real/{missing_hash}.mp3", headers=_login_headers(httpd))
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
                _open(httpd, "/audio/real/../../etc-passwd.mp3", headers=_login_headers(httpd))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)

    def test_real_audio_requires_login(self):
        httpd, thread = _start_server(backend="openai")
        try:
            try:
                urllib.request.urlopen(_url(httpd, f"/audio/real/{'0' * 64}.mp3"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 401
            assert raised
        finally:
            _stop(httpd, thread)


class TestLive2DIntegration:
    """T025: Live2D 아바타 통합 — 벤더 자산 서빙·프론트 배선·폴백 계약."""

    def test_model3_json_served_with_json_content_type(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(
                _url(httpd, "/static/live2d/models/Mao/Mao.model3.json")
            ) as resp:
                assert resp.status == 200
                assert "application/json" in resp.headers["Content-Type"]
                json.loads(resp.read())
        finally:
            _stop(httpd, thread)

    def test_moc3_and_runtime_scripts_served(self):
        httpd, thread = _start_server()
        try:
            for path in (
                "/static/live2d/models/Mao/Mao.moc3",
                "/static/live2d/live2dcubismcore.min.js",
                "/static/live2d/pixi.min.js",
                "/static/live2d/cubism4.min.js",
                "/static/live2d-avatar.js",
            ):
                with urllib.request.urlopen(_url(httpd, path)) as resp:
                    assert resp.status == 200, path
        finally:
            _stop(httpd, thread)

    def test_index_wires_live2d_before_app(self):
        index = (web_server._STATIC_DIR / "index.html").read_text(encoding="utf-8")
        live2d_pos = index.find("/static/live2d-avatar.js")
        app_pos = index.find("/static/app.js")
        assert live2d_pos != -1 and app_pos != -1
        assert live2d_pos < app_pos  # app.js가 window.HongyeonLive2D를 참조

    def test_app_js_wiring_and_fallback_contract(self):
        app_js = (web_server._STATIC_DIR / "app.js").read_text(encoding="utf-8")
        # FSM·립싱크 배선
        assert "HongyeonLive2D.setState" in app_js
        assert "HongyeonLive2D.setMouth" in app_js
        assert "HongyeonLive2D.init" in app_js
        # T024 폴백 체계는 그대로 남아 있어야 한다 (정지컷·플레이스홀더)
        assert "hongyeon-" in app_js
        assert "preloadAvatarAssets" in app_js

    def test_live2d_module_is_self_disabling_without_assets(self):
        module = (web_server._STATIC_DIR / "live2d-avatar.js").read_text(encoding="utf-8")
        # 자산 부재(404)·로드 실패 시 스스로 비활성 — 폴백 무간섭 계약.
        # 감지는 GET이어야 한다: 이 서버는 do_HEAD 미구현이라 HEAD가 501을 반환한다 (실측).
        assert "detectModel" in module
        assert '"HEAD"' not in module
        assert "catch" in module
        assert "ParamMouthOpenY" in module


def _raw_get(httpd, path, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1])
    conn.request("GET", path, headers=headers or {})
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    return resp, body


def _raw_post(httpd, path, headers=None):
    conn = http.client.HTTPConnection("127.0.0.1", httpd.server_address[1])
    conn.request("POST", path, headers=headers or {})
    resp = conn.getresponse()
    body = resp.read()
    conn.close()
    return resp, body


class TestAuthProvidersEndpoint:
    """T026: 키 없는 환경(기본)에서는 소셜 로그인 버튼이 전부 비활성이어야 한다."""

    def test_providers_all_disabled_without_env(self, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        monkeypatch.delenv("KAKAO_REST_API_KEY", raising=False)
        assert web_server.oauth_provider_status() == {"google": False, "kakao": False}

    def test_providers_reflect_env_presence(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "test-client-id")
        monkeypatch.delenv("KAKAO_REST_API_KEY", raising=False)
        assert web_server.oauth_provider_status() == {"google": True, "kakao": False}

    def test_provider_keys_never_appear_in_response(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "super-secret-client-id")
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/providers")
            assert resp.status == 200
            data = json.loads(body)
            assert data == {"providers": {"google": True, "kakao": False}}
            assert "super-secret-client-id" not in body.decode("utf-8")
        finally:
            _stop(httpd, thread)


class TestOAuthAuthorizeUrl:
    """T026: 순수 함수 — 리다이렉트 URL 조립을 네트워크 없이 계약 테스트로 고정."""

    def test_returns_none_when_client_id_missing(self, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        assert web_server.build_oauth_authorize_url(
            "google", redirect_uri="http://127.0.0.1:8787/api/auth/callback/google", state="s1"
        ) is None

    def test_builds_url_with_client_id_and_state(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "abc123")
        url = web_server.build_oauth_authorize_url(
            "google", redirect_uri="http://127.0.0.1:8787/api/auth/callback/google", state="s1"
        )
        assert url.startswith("https://accounts.google.com/o/oauth2/v2/auth?")
        assert "client_id=abc123" in url
        assert "state=s1" in url
        assert "redirect_uri=http" in url

    def test_unknown_provider_returns_none(self):
        assert web_server.build_oauth_authorize_url("naver", redirect_uri="x", state="s") is None


class TestOAuthProfileExtraction:
    """T026: provider별 userinfo 응답 파싱 — 순수 함수, 네트워크 없이 고정."""

    def test_google_profile_extraction(self):
        profile = web_server._extract_profile("google", {"sub": "g1", "name": "홍길동"})
        assert profile == {"subject": "g1", "nickname": "홍길동"}

    def test_kakao_profile_extraction(self):
        profile = web_server._extract_profile(
            "kakao", {"id": 12345, "kakao_account": {"profile": {"nickname": "카카오유저"}}}
        )
        assert profile == {"subject": "12345", "nickname": "카카오유저"}

    def test_unknown_provider_extraction(self):
        assert web_server._extract_profile("naver", {}) == {"subject": None, "nickname": None}


class TestSessionCookieSigning:
    """T026: 서명 쿠키 — 서버 메모리 세션과 짝을 이루는 순수 함수."""

    def test_round_trip(self):
        cookie = web_server._make_session_cookie_value("sid123", "test-secret")
        assert web_server._verify_session_cookie_value(cookie, "test-secret") == "sid123"

    def test_tampered_signature_rejected(self):
        cookie = web_server._make_session_cookie_value("sid123", "test-secret")
        tampered = cookie[:-1] + ("0" if cookie[-1] != "0" else "1")
        assert web_server._verify_session_cookie_value(tampered, "test-secret") is None

    def test_wrong_secret_rejected(self):
        cookie = web_server._make_session_cookie_value("sid123", "secret-a")
        assert web_server._verify_session_cookie_value(cookie, "secret-b") is None

    def test_malformed_cookie_rejected(self):
        assert web_server._verify_session_cookie_value("not-a-valid-cookie", "test-secret") is None
        assert web_server._verify_session_cookie_value("", "test-secret") is None
        assert web_server._verify_session_cookie_value(None, "test-secret") is None


class TestOAuthLoginRedirect:
    """T026: GET /api/auth/login/{provider} — 리다이렉트 라우팅 계약."""

    def test_disabled_provider_returns_400(self, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/login/google")
            assert resp.status == 400
        finally:
            _stop(httpd, thread)

    def test_unknown_provider_returns_404(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/login/naver")
            assert resp.status == 404
        finally:
            _stop(httpd, thread)

    def test_enabled_provider_redirects_with_state_cookie(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "abc123")
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/login/google")
            assert resp.status == 302
            location = resp.getheader("Location")
            assert location.startswith("https://accounts.google.com/")
            set_cookie = resp.getheader("Set-Cookie")
            assert "shindang_oauth_state=" in set_cookie
            assert "HttpOnly" in set_cookie
        finally:
            _stop(httpd, thread)


class TestOAuthCallback:
    """T026: GET /api/auth/callback/{provider} — 코드 교환 경로를 실 네트워크 없이 monkeypatch로 고정."""

    def test_missing_code_redirects_to_auth_error(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/callback/google")
            assert resp.status == 302
            assert resp.getheader("Location") == "/?auth_error=1"
        finally:
            _stop(httpd, thread)

    def test_state_mismatch_redirects_to_auth_error(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(
                httpd, "/api/auth/callback/google?code=abc&state=bad",
                headers={"Cookie": "shindang_oauth_state=good"},
            )
            assert resp.status == 302
            assert resp.getheader("Location") == "/?auth_error=1"
            # 실패 시 세션 쿠키가 생기지 않고 state 쿠키만 정리된다
            set_cookie = resp.getheader("Set-Cookie") or ""
            assert "shindang_session=" not in set_cookie
            assert "shindang_oauth_state=" in set_cookie and "Max-Age=0" in set_cookie
        finally:
            _stop(httpd, thread)

    def test_missing_state_cookie_redirects_to_auth_error(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/callback/google?code=abc&state=st1")
            assert resp.status == 302
            assert resp.getheader("Location") == "/?auth_error=1"
        finally:
            _stop(httpd, thread)

    def test_unknown_provider_returns_404(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/callback/naver?code=abc&state=st1")
            assert resp.status == 404
        finally:
            _stop(httpd, thread)

    def test_successful_callback_sets_session_cookie_and_redirects(self, monkeypatch):
        def fake_exchange(provider, code, *, redirect_uri):
            assert provider == "google"
            assert code == "authcode123"
            return {"subject": "u1", "nickname": "테스트유저"}

        monkeypatch.setattr(web_server, "_oauth_token_and_profile", fake_exchange)

        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(
                httpd, "/api/auth/callback/google?code=authcode123&state=st1",
                headers={"Cookie": "shindang_oauth_state=st1"},
            )
            assert resp.status == 302
            assert resp.getheader("Location") == "/"
            set_cookie = resp.getheader("Set-Cookie")
            assert "shindang_session=" in set_cookie

            session_cookie = set_cookie.split(";")[0]
            resp2, body2 = _raw_get(httpd, "/api/auth/me", headers={"Cookie": session_cookie})
            data = json.loads(body2)
            assert data == {"loggedIn": True, "provider": "google", "nickname": "테스트유저"}
        finally:
            _stop(httpd, thread)

    def test_exchange_failure_redirects_to_auth_error(self, monkeypatch):
        def fake_exchange(provider, code, *, redirect_uri):
            raise RuntimeError("network unreachable")

        monkeypatch.setattr(web_server, "_oauth_token_and_profile", fake_exchange)

        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(
                httpd, "/api/auth/callback/google?code=authcode123&state=st1",
                headers={"Cookie": "shindang_oauth_state=st1"},
            )
            assert resp.status == 302
            assert resp.getheader("Location") == "/?auth_error=1"
            assert "shindang_session=" not in (resp.getheader("Set-Cookie") or "")
        finally:
            _stop(httpd, thread)


class TestAuthMeAndLogout:
    """T026: GET /api/auth/me, POST /api/auth/logout — 서버 메모리 세션 조회/삭제."""

    def test_me_without_cookie_returns_logged_out(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/me")
            assert json.loads(body) == {"loggedIn": False}
        finally:
            _stop(httpd, thread)

    def test_tampered_cookie_rejected(self):
        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(httpd, "/api/auth/me", headers={"Cookie": "shindang_session=deadbeef.tampered"})
            assert json.loads(body) == {"loggedIn": False}
        finally:
            _stop(httpd, thread)

    def test_logout_clears_session(self, monkeypatch):
        def fake_exchange(provider, code, *, redirect_uri):
            return {"subject": "u1", "nickname": "테스트유저"}

        monkeypatch.setattr(web_server, "_oauth_token_and_profile", fake_exchange)

        httpd, thread = _start_server()
        try:
            resp, body = _raw_get(
                httpd, "/api/auth/callback/google?code=x&state=s",
                headers={"Cookie": "shindang_oauth_state=s"},
            )
            session_cookie = resp.getheader("Set-Cookie").split(";")[0]

            logout_resp, logout_body = _raw_post(httpd, "/api/auth/logout", headers={"Cookie": session_cookie})
            assert logout_resp.status == 200
            assert json.loads(logout_body) == {"ok": True}

            resp2, body2 = _raw_get(httpd, "/api/auth/me", headers={"Cookie": session_cookie})
            assert json.loads(body2) == {"loggedIn": False}
        finally:
            _stop(httpd, thread)


class TestGuestFlowNonRegression:
    """AC: 키 없는 환경(기본)에서 게스트 흐름(탭→재생)이 무회귀해야 한다."""

    def test_fortune_text_stays_guest_but_share_requires_login(self, monkeypatch):
        """정책 변경(2026-07-08): 운세 텍스트는 게스트 유지, 재생·부적은 로그인 게이트."""
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        monkeypatch.delenv("KAKAO_REST_API_KEY", raising=False)
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            assert data["audioUrl"].startswith("/audio/mock/")
            try:
                urllib.request.urlopen(_url(httpd, f"/api/share-card?fortuneId={data['fortuneId']}"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 401
            assert raised
            with _open(
                httpd, f"/api/share-card?fortuneId={data['fortuneId']}", headers=_login_headers(httpd)
            ) as resp:
                assert resp.status == 200
        finally:
            _stop(httpd, thread)


class TestBirthProfileQueryMapping:
    """AC: 프로필→쿼리 매핑 — 같은 생년월일 재방문 시 동일 fortuneId(결정성 유지),
    '모름'(birth_hour 미첨부)이면 미첨부 상태와 동일한 seed로 계산돼야 한다."""

    def test_revisit_with_same_birth_fields_yields_same_fortune_id(self):
        httpd, thread = _start_server()
        try:
            path = (
                "/api/fortune/today?topic=love&date=2026-07-07"
                "&birth_year=1995&birth_month=3&birth_day=21&birth_hour=8"
            )
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                first = json.loads(resp.read())
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                second = json.loads(resp.read())
            assert first["fortuneId"] == second["fortuneId"]
        finally:
            _stop(httpd, thread)

    def test_missing_birth_hour_matches_no_birth_hour_query(self):
        httpd, thread = _start_server()
        try:
            with_unknown_hour = (
                "/api/fortune/today?topic=love&date=2026-07-07"
                "&birth_year=1995&birth_month=3&birth_day=21"
            )
            with urllib.request.urlopen(_url(httpd, with_unknown_hour)) as resp:
                data = json.loads(resp.read())
            assert data["fortuneId"]
        finally:
            _stop(httpd, thread)


class TestFrontendOnboardingWiring:
    """T026: S0 온보딩 + S2 입력 마크업/배선이 정적 파일에 존재하는지 문자열 수준으로 잠근다
    (브라우저 렌더링 자체는 수동 확인, 관례는 T022/T024와 동일). 기존 훅은 무회귀여야 한다."""

    def test_index_has_onboarding_and_profile_form_elements(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                body = resp.read().decode("utf-8")
            for hook in (
                "onboarding", "guest-start-btn", "google-login-btn", "kakao-login-btn", "logout-btn",
                "profile-form", "profile-nickname", "profile-birth-date", "profile-birth-hour",
                "profile-next-btn", "main-stage", "profile-summary", "edit-profile-btn",
            ):
                assert f'id="{hook}"' in body, f"온보딩 요소 누락: {hook}"
            # 기존 훅 무회귀
            for hook in ("start-btn", "share-btn", "share-status", "fortune-card", "player"):
                assert f'id="{hook}"' in body, f"기존 훅 회귀: {hook}"
        finally:
            _stop(httpd, thread)

    def test_sijin_options_present(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                body = resp.read().decode("utf-8")
            for label in (
                "자시", "축시", "인시", "묘시", "진시", "사시",
                "오시", "미시", "신시", "유시", "술시", "해시", "모름",
            ):
                assert label in body, f"시진 옵션 누락: {label}"
        finally:
            _stop(httpd, thread)

    def test_app_js_appends_birth_query_and_stores_profile_locally(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            assert "shindang.profile" in body
            assert "localStorage" in body
            assert "birth_year" in body and "birth_month" in body
            assert "birth_day" in body and "birth_hour" in body
            assert "buildBirthQuery" in body
        finally:
            _stop(httpd, thread)

    def test_app_js_profile_saved_event_excludes_raw_birth_values(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            idx = body.index('"profile_saved"')
            snippet_end = body.index("}", idx)
            snippet = body[idx:snippet_end]
            for forbidden in ("profile.birthYear", "profile.birthMonth", "profile.birthDay"):
                assert forbidden not in snippet, f"profile_saved 이벤트에 원문 필드 노출: {forbidden}"
        finally:
            _stop(httpd, thread)

    def test_app_js_wires_onboarding_and_auth_endpoints(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                body = resp.read().decode("utf-8")
            assert "/api/auth/providers" in body
            assert "/api/auth/login/" in body
            assert "/api/auth/me" in body
            assert "/api/auth/logout" in body
            assert "onboarding_started" in body
            assert "profile_saved" in body
            assert "login_" in body
        finally:
            _stop(httpd, thread)
