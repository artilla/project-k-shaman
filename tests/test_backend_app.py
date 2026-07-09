"""backend(FastAPI) 계약 테스트 — ADR-0003 신 스택.

레거시 test_web_server.py의 HTTP 계약을 계승해 잠근다 (레거시 서버는 2026-07-09 제거):
게이트 401 · 운세 게스트 허용 · 콜백 실패 리다이렉트 · 꿈 해몽(신규).
"""
import secrets
import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

ROOT = Path(__file__).parent.parent
sys.path.insert(0, str(ROOT))

from backend import core, dream  # noqa: E402
from backend.app import create_app  # noqa: E402


@pytest.fixture()
def fastapi_app():
    return create_app(backend="mock")


@pytest.fixture()
def client(fastapi_app):
    return TestClient(fastapi_app, follow_redirects=False)


def login(fastapi_app, client):
    """서버 메모리에 세션을 직접 심는다 (legacy _login_headers와 동일 전략)."""
    session_id = "testsession-" + secrets.token_hex(4)
    fastapi_app.state.sessions[session_id] = {"provider": "google", "nickname": "테스트"}
    value = core.make_session_cookie_value(session_id, fastapi_app.state.session_secret)
    client.cookies.set(core.SESSION_COOKIE_NAME, value)


# ── 운세: 게스트 허용 (텍스트 먼저 원칙) ──
class TestFortune:
    def test_guest_can_fetch_fortune(self, client):
        res = client.get("/api/fortune/today?topic=love&date=2026-07-07")
        assert res.status_code == 200
        data = res.json()
        for key in ("fortuneId", "script", "audioUrl", "fortune"):
            assert key in data
        assert data["audioUrl"].startswith("/audio/mock/")

    def test_birth_query_is_deterministic(self, client):
        path = "/api/fortune/today?topic=love&date=2026-07-07&birth_year=1995&birth_month=3&birth_day=21"
        first = client.get(path).json()
        second = client.get(path).json()
        assert first["fortuneId"] == second["fortuneId"]


# ── 게이트: 재생·부적·꿈 해몽 로그인 필요 (US-9) ──
class TestLoginGates:
    def test_audio_requires_login(self, client):
        res = client.get("/audio/mock/" + "a" * 16 + ".wav")
        assert res.status_code == 401

    def test_share_card_requires_login(self, client):
        res = client.get("/api/share-card?fortuneId=x")
        assert res.status_code == 401

    def test_dream_requires_login(self, client):
        res = client.post("/api/dream/interpret", json={"text": "뱀꿈"})
        assert res.status_code == 401

    def test_audio_serves_wav_when_logged_in(self, fastapi_app, client):
        login(fastapi_app, client)
        data = client.get("/api/fortune/today?topic=love&date=2026-07-07").json()
        res = client.get(data["audioUrl"])
        assert res.status_code == 200
        assert res.headers["content-type"] == "audio/wav"
        assert res.content[:4] == b"RIFF"

    def test_share_card_svg_when_logged_in(self, fastapi_app, client):
        login(fastapi_app, client)
        data = client.get("/api/fortune/today?topic=love&date=2026-07-07").json()
        res = client.get(f"/api/share-card?fortuneId={data['fortuneId']}")
        assert res.status_code == 200
        assert res.text.startswith("<svg")


# ── 꿈 해몽 API ──
class TestDreamInterpret:
    def test_snake_alias_detected(self, fastapi_app, client):
        login(fastapi_app, client)
        res = client.post("/api/dream/interpret", json={"text": "커다란 구렁이가 품에 안기는 꿈", "symbols": []})
        assert res.status_code == 200
        data = res.json()
        labels = [s["label"] for s in data["reading"]["symbols"]]
        assert "뱀" in labels
        assert data["audioUrl"].startswith("/audio/mock/")
        assert data["script"][0]["label"] == "greeting"
        assert data["script"][-1]["label"] == "축원"
        # 프라이버시: 응답 어디에도 꿈 원문이 그대로 노출되지 않는다
        assert "구렁이가 품에" not in res.text

    def test_empty_body_rejected(self, fastapi_app, client):
        login(fastapi_app, client)
        res = client.post("/api/dream/interpret", json={"text": "", "symbols": []})
        assert res.status_code == 400

    def test_invalid_json_rejected(self, fastapi_app, client):
        login(fastapi_app, client)
        res = client.post(
            "/api/dream/interpret", content=b"not-json", headers={"Content-Type": "application/json"}
        )
        assert res.status_code == 400


# ── 인증 플로우 ──
class TestAuth:
    def test_me_guest(self, client):
        assert client.get("/api/auth/me").json() == {"loggedIn": False}

    def test_me_logged_in(self, fastapi_app, client):
        login(fastapi_app, client)
        data = client.get("/api/auth/me").json()
        assert data["loggedIn"] is True
        assert data["nickname"] == "테스트"

    def test_callback_failure_redirects_to_auth_error(self, client):
        res = client.get("/api/auth/callback/google")  # code 누락
        assert res.status_code == 302
        assert res.headers["location"] == "/?auth_error=1"

    def test_unknown_provider_404(self, client):
        assert client.get("/api/auth/callback/naver?code=a&state=s").status_code == 404

    def test_login_without_keys_returns_400(self, client, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        assert client.get("/api/auth/login/google").status_code == 400

    def test_dev_login_disabled_by_default(self, client, monkeypatch):
        """SHINDANG_DEV_LOGIN 미설정 시 dev-login 라우트는 존재하지 않아야 한다 (프로덕션 안전)."""
        monkeypatch.delenv("SHINDANG_DEV_LOGIN", raising=False)
        fresh = TestClient(create_app(backend="mock"), follow_redirects=False)
        assert fresh.get("/api/auth/dev-login").status_code == 404


# ── 레거시 스위트에서 이관한 고유 커버리지 (2026-07-09 레거시 서버 제거) ──
class TestShareCardPrivacy:
    def test_share_card_does_not_leak_birth_fields_or_seed_hash(self, fastapi_app, client):
        """T021 개인정보 최소화 — SVG에 생년 원문·seed_hash가 노출되면 안 된다."""
        login(fastapi_app, client)
        path = (
            "/api/fortune/today?topic=love&date=2026-07-07"
            "&birth_year=1990&birth_month=5&birth_day=14&birth_hour=8"
        )
        data = client.get(path).json()
        svg = client.get(f"/api/share-card?fortuneId={data['fortuneId']}").text
        assert "1990" not in svg
        assert data["fortune"]["meta"]["seed_hash"] not in svg

    def test_unknown_fortune_id_404(self, fastapi_app, client):
        login(fastapi_app, client)
        assert client.get("/api/share-card?fortuneId=does-not-exist").status_code == 404


class TestAudioKeys:
    def test_invalid_audio_key_rejected_even_with_login(self, fastapi_app, client):
        login(fastapi_app, client)
        assert client.get("/audio/mock/NOT-A-HEX-KEY.wav").status_code == 404

    def test_same_seed_revisit_reuses_audio_url(self, client):
        path = "/api/fortune/today?topic=love&date=2026-07-07"
        assert client.get(path).json()["audioUrl"] == client.get(path).json()["audioUrl"]

    def test_real_audio_served_from_cache_dir(self, fastapi_app, client):
        import hashlib
        login(fastapi_app, client)
        cache_key = "tts:v1:openai:coral:testfixture:1.0:bright"
        key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
        core.TTS_REAL_CACHE_DIR.mkdir(parents=True, exist_ok=True)
        fixture = core.TTS_REAL_CACHE_DIR / f"{key_hash}.mp3"
        fixture.write_bytes(b"\xff\xfb\x90\x00fake-mp3-fixture")
        try:
            res = client.get(f"/audio/real/{key_hash}.mp3")
            assert res.status_code == 200
            assert res.headers["content-type"] == "audio/mpeg"
        finally:
            fixture.unlink(missing_ok=True)

    def test_missing_real_audio_404(self, fastapi_app, client):
        login(fastapi_app, client)
        assert client.get("/audio/real/" + "0" * 64 + ".mp3").status_code == 404


class TestEventEndpoint:
    def test_event_accepts_timeline_and_returns_summary(self, client):
        res = client.post("/api/event", json={
            "fortuneId": "f1",
            "sessionStartMs": 0,
            "clientEvents": [{"event": "first_text_visible", "clientTs": 100}],
            "serverEvents": [],
        })
        assert res.status_code == 200
        data = res.json()
        assert data["ok"] is True
        assert "summary" in data and "missing" in data

    def test_event_invalid_json_400(self, client):
        res = client.post("/api/event", content=b"broken", headers={"Content-Type": "application/json"})
        assert res.status_code == 400


class TestCoreHelpers:
    def test_authorize_url_none_without_client_id(self, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        assert core.build_oauth_authorize_url("google", redirect_uri="http://x/cb", state="s1") is None

    def test_authorize_url_contains_client_id_and_state(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "abc123")
        url = core.build_oauth_authorize_url("google", redirect_uri="http://x/cb", state="s1")
        assert url.startswith("https://accounts.google.com/")
        assert "client_id=abc123" in url and "state=s1" in url

    def test_session_cookie_roundtrip_and_tamper_reject(self):
        secret = "top-secret"
        value = core.make_session_cookie_value("sid123", secret)
        assert core.verify_session_cookie_value(value, secret) == "sid123"
        assert core.verify_session_cookie_value(value + "x", secret) is None
        assert core.verify_session_cookie_value(value, "other-secret") is None

    def test_fortune_cache_evicts_oldest(self):
        cache = {}
        for i in range(core.FORTUNE_CACHE_MAX + 1):
            core.remember_fortune(cache, f"id{i}", {"n": i})
        assert len(cache) == core.FORTUNE_CACHE_MAX
        assert "id0" not in cache
        assert f"id{core.FORTUNE_CACHE_MAX}" in cache

    def test_openai_startup_guard(self):
        with pytest.raises(RuntimeError):
            core.validate_backend_startup("openai", has_api_key=False)
        core.validate_backend_startup("openai", has_api_key=True)
        core.validate_backend_startup("mock", has_api_key=False)


class TestCallbackFlows:
    def test_state_mismatch_redirects_without_session(self, client):
        client.cookies.set(core.OAUTH_STATE_COOKIE_NAME, "good")
        res = client.get("/api/auth/callback/google?code=abc&state=bad")
        assert res.status_code == 302
        assert res.headers["location"] == "/?auth_error=1"
        assert core.SESSION_COOKIE_NAME not in (res.headers.get("set-cookie") or "")

    def test_successful_callback_creates_session(self, fastapi_app, client, monkeypatch):
        monkeypatch.setattr(
            core, "oauth_token_and_profile",
            lambda provider, code, *, redirect_uri: {"subject": "u1", "nickname": "테스트유저"},
        )
        client.cookies.set(core.OAUTH_STATE_COOKIE_NAME, "st1")
        res = client.get("/api/auth/callback/google?code=authcode123&state=st1")
        assert res.status_code == 302
        assert res.headers["location"] == "/"
        me = client.get("/api/auth/me").json()
        assert me == {"loggedIn": True, "provider": "google", "nickname": "테스트유저"}

    def test_logout_clears_session(self, fastapi_app, client):
        login(fastapi_app, client)
        assert client.get("/api/auth/me").json()["loggedIn"] is True
        assert client.post("/api/auth/logout").status_code == 200
        # 서버 메모리에서 세션 제거 확인 (쿠키는 클라이언트가 유지해도 무효)
        assert fastapi_app.state.sessions == {}


# ── dream 순수 로직 단위 테스트 ──
class TestDreamLogic:
    def test_detect_defaults_to_water(self):
        assert dream.detect_symbols("아무 상징 없는 꿈", []) == ["물"]

    def test_detect_caps_at_three(self):
        text = "뱀과 물과 불과 돈이 모두 나오는 꿈"
        assert len(dream.detect_symbols(text, [])) == 3

    def test_selected_symbols_validated(self):
        result = dream.interpret("", ["뱀", "존재하지않는상징"])
        labels = [s["label"] for s in result["reading"]["symbols"]]
        assert labels == ["뱀"]

    def test_tone_branches(self):
        good = dream.build_reading(["뱀", "불"])       # good 우세
        caution = dream.build_reading(["추락", "이빨 빠짐"])  # caution 우세
        mixed = dream.build_reading(["물"])             # 균형
        assert "길몽" in good["chips"][0]
        assert "액땜" in caution["chips"][0]
        assert "갈림길" in mixed["chips"][0]

    def test_dream_id_excludes_raw_text(self):
        a = dream.interpret("구렁이 꿈", [])
        b = dream.interpret("커다란 구렁이가 나온 전혀 다른 꿈", [])
        # 같은 상징 조합이면 같은 dreamId — 원문이 ID에 섞이지 않는다는 증거
        assert a["dreamId"] == b["dreamId"]
