"""backend(FastAPI) 계약 테스트 — ADR-0003 신 스택.

레거시 test_web_server.py의 HTTP 계약을 계승해 잠근다 (레거시 서버는 2026-07-09 제거):
게이트 401 · 운세 게스트 허용 · 콜백 실패 리다이렉트 · 꿈 해몽(신규).
"""

import json
import secrets
from dataclasses import replace
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from shindang.adapters import rate_limit as ratelimit
from shindang.adapters.cache import InMemoryCacheStore
from shindang.adapters.fortune_store import RecentFortuneStore
from shindang.adapters.oauth import HttpOAuthGateway
from shindang.adapters.session import (
    OAUTH_STATE_COOKIE_NAME,
    SESSION_COOKIE_NAME,
    make_session_cookie_value,
    verify_session_cookie_value,
)
from shindang.adapters.tts import TTSAdapter
from shindang.application.cache import get_or_compute
from shindang.bootstrap import build_container
from shindang.config import Settings
from shindang.domain import dream
from shindang.web.app import create_app

ROOT = Path(__file__).parent.parent
SCHEMA_PATH = ROOT / "contracts" / "fortune" / "fortune-schema.v1.1.json"


@pytest.fixture()
def fastapi_app(monkeypatch):
    monkeypatch.setenv("SHINDANG_ENV", "test")
    monkeypatch.setenv("SESSION_SECRET", "test-session-secret")
    monkeypatch.delenv("DATABASE_URL", raising=False)
    monkeypatch.delenv("SHINDANG_DEV_LOGIN", raising=False)
    return create_app(settings=Settings.from_env(tts_backend="mock"))


@pytest.fixture()
def client(fastapi_app):
    return TestClient(fastapi_app, follow_redirects=False)


def login(fastapi_app, client):
    """서버의 세션 포트에 테스트 세션을 직접 심는다."""
    app = fastapi_app.state.container
    session_id = "testsession-" + secrets.token_hex(4)
    app.sessions.put(session_id, {"provider": "google", "nickname": "테스트"})
    value = make_session_cookie_value(session_id, app.settings.session_secret)
    client.cookies.set(SESSION_COOKIE_NAME, value)


# ── 운세: 게스트 허용 (텍스트 먼저 원칙) ──
class TestFortune:
    def test_guest_can_fetch_fortune(self, client):
        res = client.get("/api/fortune/today?topic=love&date=2026-07-07")
        assert res.status_code == 200
        data = res.json()
        for key in ("fortuneId", "script", "audioUrl", "fortune"):
            assert key in data
        assert data["audioUrl"].startswith("/audio/mock/")

    def test_post_birth_body_is_deterministic(self, client):
        """리뷰 P1-2: birth 원문은 POST 본문으로만 — 결정성은 유지된다."""
        body = {
            "topic": "love",
            "date": "2026-07-07",
            "birth_year": 1995,
            "birth_month": 3,
            "birth_day": 21,
        }
        first = client.post("/api/fortune/today", json=body).json()
        second = client.post("/api/fortune/today", json=body).json()
        assert first["fortuneId"] == second["fortuneId"]

    def test_get_ignores_birth_query_params(self, client):
        """GET은 birth 쿼리를 받지 않는다 (URL·접근 로그 노출 방지) — 무시되어 비개인화와 동일."""
        with_birth = client.get(
            "/api/fortune/today?topic=love&date=2026-07-07&birth_year=1995&birth_month=3&birth_day=21"
        ).json()
        without = client.get("/api/fortune/today?topic=love&date=2026-07-07").json()
        assert with_birth["fortuneId"] == without["fortuneId"]

    def test_date_changes_fortune(self, client):
        """리뷰 P1-1: 날짜가 seed에 반영돼 다른 날은 다른 운세가 나온다."""
        a = client.get("/api/fortune/today?topic=love&date=2026-07-07").json()
        b = client.get("/api/fortune/today?topic=love&date=2026-07-08").json()
        assert a["fortuneId"] != b["fortuneId"]
        assert a["fortune"]["meta"]["date"] == "2026-07-07"

    def test_invalid_topic_400(self, client):
        assert client.get("/api/fortune/today?topic=hack").status_code == 400

    def test_rel_alias_rejected_canonical_topic_accepted(self, client):
        """2차 P1-2: canonical은 schema enum의 'relationship' — 'rel' 별칭은 거부한다."""
        assert client.get("/api/fortune/today?topic=rel").status_code == 400
        assert client.get("/api/fortune/today?topic=relationship").status_code == 200

    def test_all_topics_match_schema_and_share_card(self, fastapi_app, client):
        """2차 회귀 매트릭스: 5개 주제 전부 schema enum 일치 + 부적 카드 200."""
        schema = json.loads(SCHEMA_PATH.read_text())
        allowed = set(schema["properties"]["meta"]["properties"]["topic"]["enum"])
        login(fastapi_app, client)
        for topic in ("total", "love", "money", "work", "relationship"):
            data = client.post(
                "/api/fortune/today", json={"topic": topic, "date": "2026-07-07"}
            ).json()
            assert data["fortune"]["meta"]["topic"] in allowed, topic
            share = client.get(f"/api/share-card?fortuneId={data['fortuneId']}")
            assert share.status_code == 200, topic

    def test_invalid_birth_400(self, client):
        res = client.post(
            "/api/fortune/today", json={"topic": "love", "birth_year": "abc"}
        )
        assert res.status_code == 400

    def test_fortune_never_runs_real_tts(self, fastapi_app):
        """리뷰 P1-3(text-first): openai 모드여도 텍스트 API는 실 합성을 호출하지 않는다."""
        calls = []
        settings = replace(fastapi_app.state.container.settings, tts_backend="openai")

        def fail_if_called(script, cache_key, metadata):
            calls.append(cache_key)
            raise AssertionError("text endpoint invoked TTS")

        speech = TTSAdapter(
            mode="openai",
            cache_dir=settings.tts_cache_dir,
            backend=fail_if_called,
        )
        app = create_app(
            settings=settings, app_container=build_container(settings, speech=speech)
        )
        client = TestClient(app, follow_redirects=False)
        res = client.get("/api/fortune/today?topic=love&date=2026-07-07")
        assert res.status_code == 200
        assert calls == []
        assert res.json()["audioUrl"].startswith("/audio/real/")

    def test_runtime_seed_is_keyed_by_server_secret(self, fastapi_app):
        """같은 생년 입력도 서버 secret이 다르면 공개 seed와 fortuneId가 달라진다."""
        base = fastapi_app.state.container.settings
        first_settings = replace(base, session_secret="a" * 32)
        second_settings = replace(base, session_secret="b" * 32)
        first = (
            TestClient(create_app(settings=first_settings))
            .post(
                "/api/fortune/today",
                json={
                    "topic": "love",
                    "date": "2026-07-07",
                    "birth_year": 1995,
                    "birth_month": 3,
                    "birth_day": 21,
                },
            )
            .json()
        )
        second = (
            TestClient(create_app(settings=second_settings))
            .post(
                "/api/fortune/today",
                json={
                    "topic": "love",
                    "date": "2026-07-07",
                    "birth_year": 1995,
                    "birth_month": 3,
                    "birth_day": 21,
                },
            )
            .json()
        )
        assert first["fortuneId"] != second["fortuneId"]
        assert (
            first["fortune"]["meta"]["seed_hash"]
            != second["fortune"]["meta"]["seed_hash"]
        )


# ── TTS 준비 (실 합성·과금 분리 지점) ──
class TestTtsPrepare:
    def test_requires_login(self, client):
        assert (
            client.post("/api/tts/prepare", json={"topic": "love"}).status_code == 401
        )

    def test_returns_audio_url_when_logged_in(self, fastapi_app, client):
        login(fastapi_app, client)
        res = client.post(
            "/api/tts/prepare", json={"topic": "love", "date": "2026-07-07"}
        )
        assert res.status_code == 200
        assert res.json()["audioUrl"].startswith("/audio/mock/")

    def test_matches_fortune_audio_url(self, fastapi_app, client):
        """동일 파라미터의 운세 응답 audioUrl과 prepare 결과가 일치 — 클라 cacheKey 신뢰 없음."""
        login(fastapi_app, client)
        body = {
            "topic": "love",
            "date": "2026-07-07",
            "birth_year": 1995,
            "birth_month": 3,
            "birth_day": 21,
        }
        fortune_url = client.post("/api/fortune/today", json=body).json()["audioUrl"]
        prepare_url = client.post("/api/tts/prepare", json=body).json()["audioUrl"]
        assert fortune_url == prepare_url

    def test_invalid_topic_400(self, fastapi_app, client):
        login(fastapi_app, client)
        assert (
            client.post("/api/tts/prepare", json={"topic": "hack"}).status_code == 400
        )

    def test_prepare_rejects_bad_inputs(self, fastapi_app, client):
        """2차 P2: 배열 body·잘못된 날짜·character·범위 밖 birth는 400."""
        login(fastapi_app, client)
        assert (
            client.post("/api/tts/prepare", json=["not", "a", "dict"]).status_code
            == 400
        )
        assert (
            client.post(
                "/api/tts/prepare", json={"topic": "love", "date": "2026-13-99"}
            ).status_code
            == 400
        )
        assert (
            client.post(
                "/api/tts/prepare", json={"topic": "love", "date": "not-a-date"}
            ).status_code
            == 400
        )
        assert (
            client.post(
                "/api/tts/prepare", json={"topic": "love", "character_id": "unknown"}
            ).status_code
            == 400
        )
        assert (
            client.post(
                "/api/tts/prepare", json={"topic": "love", "birth_month": 13}
            ).status_code
            == 400
        )
        assert (
            client.post(
                "/api/tts/prepare", json={"topic": "love", "birth_hour": 24}
            ).status_code
            == 400
        )
        assert (
            client.post(
                "/api/fortune/today", json={"topic": "love", "birth_year": 1800}
            ).status_code
            == 400
        )

    def test_text_endpoint_does_not_poison_tts_cache(self, fastapi_app):
        """2차 P1-1 회귀: 텍스트 응답이 TTS 캐시 키를 선점하지 않는다 —
        같은 파라미터의 prepare에서 합성 백엔드가 실제로 호출돼야 한다.

        주의: 엔진 기본 캐시 store는 프로세스 전역이라 다른 테스트와 겹치지 않는
        고유 날짜를 사용한다 (격리)."""
        body = {"topic": "love", "date": "2031-01-01"}
        synth_calls = []
        settings = replace(fastapi_app.state.container.settings, tts_backend="openai")

        def counting_backend(script, cache_key, metadata):
            synth_calls.append(cache_key)
            return {"audioUrl": "spy://synthesized"}

        speech = TTSAdapter(
            mode="openai",
            cache_dir=settings.tts_cache_dir,
            backend=counting_backend,
        )
        app = create_app(
            settings=settings, app_container=build_container(settings, speech=speech)
        )
        client = TestClient(app, follow_redirects=False)
        assert client.post("/api/fortune/today", json=body).status_code == 200
        login(app, client)
        res = client.post("/api/tts/prepare", json=body)
        assert res.status_code == 200
        assert len(synth_calls) == 1, (
            "텍스트 요청이 캐시를 선점해 실합성이 skip되면 회귀"
        )


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
        res = client.post(
            "/api/dream/interpret",
            json={"text": "커다란 구렁이가 품에 안기는 꿈", "symbols": []},
        )
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
            "/api/dream/interpret",
            content=b"not-json",
            headers={"Content-Type": "application/json"},
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
        fresh = TestClient(
            create_app(settings=Settings.from_env(tts_backend="mock")),
            follow_redirects=False,
        )
        assert fresh.get("/api/auth/login/google").status_code == 400

    def test_dev_login_disabled_by_default(self, client, monkeypatch):
        """SHINDANG_DEV_LOGIN 미설정 시 dev-login 라우트는 존재하지 않아야 한다 (프로덕션 안전)."""
        monkeypatch.delenv("SHINDANG_DEV_LOGIN", raising=False)
        fresh = TestClient(
            create_app(settings=Settings.from_env(tts_backend="mock")),
            follow_redirects=False,
        )
        assert fresh.get("/api/auth/dev-login").status_code == 404

    def test_staging_requires_session_secret(self, monkeypatch):
        monkeypatch.setenv("SHINDANG_ENV", "staging")
        monkeypatch.delenv("SESSION_SECRET", raising=False)
        with pytest.raises(RuntimeError, match="SESSION_SECRET is required"):
            Settings.from_env(tts_backend="mock")

    def test_staging_rejects_dev_login(self, monkeypatch):
        monkeypatch.setenv("SHINDANG_ENV", "staging")
        monkeypatch.setenv("SESSION_SECRET", "staging-test-secret-at-least-32-bytes")
        monkeypatch.setenv("SHINDANG_DEV_LOGIN", "1")
        with pytest.raises(RuntimeError, match="SHINDANG_DEV_LOGIN=1 is forbidden"):
            Settings.from_env(tts_backend="mock")

    def test_staging_auth_cookie_is_secure(self, monkeypatch):
        monkeypatch.setenv("SHINDANG_ENV", "staging")
        monkeypatch.setenv("SESSION_SECRET", "staging-test-secret-at-least-32-bytes")
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "test-client")
        monkeypatch.setenv(
            "SHINDANG_PUBLIC_BASE_URL", "https://staging.example.invalid"
        )
        monkeypatch.delenv("SHINDANG_DEV_LOGIN", raising=False)
        fresh = TestClient(
            create_app(settings=Settings.from_env(tts_backend="mock")),
            follow_redirects=False,
        )
        res = fresh.get("/api/auth/login/google")
        cookie = res.headers.get("set-cookie", "")
        assert res.status_code == 302
        assert "Secure" in cookie and "HttpOnly" in cookie and "SameSite=lax" in cookie


class TestRuntimeProbes:
    def test_health_and_ready_without_database(self, client, monkeypatch):
        monkeypatch.delenv("DATABASE_URL", raising=False)
        assert client.get("/healthz").json() == {"status": "ok"}
        res = client.get("/readyz")
        assert res.status_code == 200
        assert res.json() == {
            "status": "ready",
            "checks": {"database": "not-configured"},
        }

    def test_database_configured_without_adapter_is_not_ready(
        self, client, monkeypatch
    ):
        marker = "postgresql://must-not-appear.example.invalid/private"
        monkeypatch.setenv("DATABASE_URL", marker)
        fresh = TestClient(create_app(settings=Settings.from_env(tts_backend="mock")))
        res = fresh.get("/readyz")
        assert res.status_code == 503
        assert res.json() == {
            "status": "not_ready",
            "checks": {"database": "adapter-unavailable"},
        }
        assert marker not in res.text


# ── 레거시 스위트에서 이관한 고유 커버리지 (2026-07-09 레거시 서버 제거) ──
class TestShareCardPrivacy:
    def test_share_card_does_not_leak_birth_fields_or_seed_hash(
        self, fastapi_app, client
    ):
        """T021 개인정보 최소화 — SVG에 생년 원문·seed_hash가 노출되면 안 된다."""
        login(fastapi_app, client)
        body = {
            "topic": "love",
            "date": "2026-07-07",
            "birth_year": 1990,
            "birth_month": 5,
            "birth_day": 14,
            "birth_hour": 8,
        }
        data = client.post("/api/fortune/today", json=body).json()
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
        assert (
            client.get(path).json()["audioUrl"] == client.get(path).json()["audioUrl"]
        )

    def test_real_audio_served_from_cache_dir(self, fastapi_app, client):
        import hashlib

        login(fastapi_app, client)
        cache_key = "tts:v1:openai:coral:testfixture:1.0:bright"
        key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
        cache_dir = fastapi_app.state.container.settings.tts_cache_dir
        cache_dir.mkdir(parents=True, exist_ok=True)
        fixture = cache_dir / f"{key_hash}.mp3"
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
        res = client.post(
            "/api/event",
            json={
                "fortuneId": "f1",
                "sessionStartMs": 0,
                "clientEvents": [{"event": "first_text_visible", "clientTs": 100}],
                "serverEvents": [],
            },
        )
        assert res.status_code == 200
        data = res.json()
        assert data["ok"] is True
        assert "summary" in data and "missing" in data

    def test_event_invalid_json_400(self, client):
        res = client.post(
            "/api/event",
            content=b"broken",
            headers={"Content-Type": "application/json"},
        )
        assert res.status_code == 400


class TestCoreHelpers:
    def test_authorize_url_none_without_client_id(self, monkeypatch):
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        gateway = HttpOAuthGateway.from_env()
        assert (
            gateway.authorize_url("google", redirect_uri="http://x/cb", state="s1")
            is None
        )

    def test_authorize_url_contains_client_id_and_state(self, monkeypatch):
        monkeypatch.setenv("GOOGLE_CLIENT_ID", "abc123")
        url = HttpOAuthGateway.from_env().authorize_url(
            "google", redirect_uri="http://x/cb", state="s1"
        )
        assert url.startswith("https://accounts.google.com/")
        assert "client_id=abc123" in url and "state=s1" in url

    def test_session_cookie_roundtrip_and_tamper_reject(self):
        secret = "top-secret"
        value = make_session_cookie_value("sid123", secret)
        assert verify_session_cookie_value(value, secret) == "sid123"
        assert verify_session_cookie_value(value + "x", secret) is None
        assert verify_session_cookie_value(value, "other-secret") is None

    def test_fortune_cache_evicts_oldest(self):
        cache = RecentFortuneStore(max_items=500)
        for i in range(501):
            cache.put(f"id{i}", {"n": i})
        assert len(cache) == 500
        assert cache.get("id0") is None
        assert cache.get("id500") == {"n": 500}

    def test_openai_startup_guard(self, monkeypatch):
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        with pytest.raises(RuntimeError, match="OPENAI_API_KEY"):
            Settings.from_env(tts_backend="openai")
        monkeypatch.setenv("OPENAI_API_KEY", "test-key")
        assert Settings.from_env(tts_backend="openai").tts_backend == "openai"
        monkeypatch.delenv("OPENAI_API_KEY", raising=False)
        assert Settings.from_env(tts_backend="mock").tts_backend == "mock"

    def test_cache_get_or_compute_is_atomic(self):
        """리뷰 P1-9: 동일 키 병렬 miss에서 compute가 1회만 실행된다 (중복 과금 방지)."""
        import threading
        import time as time_mod

        store = InMemoryCacheStore()
        calls = []

        def slow_compute():
            calls.append(1)
            time_mod.sleep(0.05)
            return {"v": 1}

        threads = [
            threading.Thread(
                target=lambda: get_or_compute(
                    store, "same-key", slow_compute, layer="tts"
                )
            )
            for _ in range(8)
        ]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        assert len(calls) == 1


class TestCallbackFlows:
    def test_state_mismatch_redirects_without_session(self, client):
        client.cookies.set(OAUTH_STATE_COOKIE_NAME, "good")
        res = client.get("/api/auth/callback/google?code=abc&state=bad")
        assert res.status_code == 302
        assert res.headers["location"] == "/?auth_error=1"
        assert SESSION_COOKIE_NAME not in (res.headers.get("set-cookie") or "")

    def test_successful_callback_creates_session(
        self, fastapi_app, client, monkeypatch
    ):
        monkeypatch.setattr(
            fastapi_app.state.container.oauth,
            "exchange_profile",
            lambda provider, code, *, redirect_uri: {
                "subject": "u1",
                "nickname": "테스트유저",
            },
        )
        client.cookies.set(OAUTH_STATE_COOKIE_NAME, "st1")
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
        assert len(fastapi_app.state.container.sessions) == 0


# ── rate limit + 일일 제한 (P0 비용 방어) ──
class TestRateLimits:
    def test_invalid_limit_configuration_fails_closed(self, monkeypatch):
        monkeypatch.setenv("RL_TTS_PER_HOUR", "0")
        with pytest.raises(RuntimeError, match="positive integer"):
            ratelimit.RateLimits.from_env()

    def test_fortune_daily_limit_429(self, fastapi_app, client, monkeypatch):
        monkeypatch.setitem(
            fastapi_app.state.container.rate_limits.daily, "fortune-daily", 2
        )
        path = "/api/fortune/today?topic=love&date=2026-07-07"
        assert client.get(path).status_code == 200
        assert client.get(path).status_code == 200
        res = client.get(path)
        assert res.status_code == 429
        assert res.json()["error"] == "daily limit reached"
        assert "retry-after" in {k.lower() for k in res.headers}

    def test_dream_hourly_limit_429(self, fastapi_app, client, monkeypatch):
        monkeypatch.setitem(
            fastapi_app.state.container.rate_limits.hourly, "dream", (1, 3600)
        )
        login(fastapi_app, client)
        body = {"text": "뱀꿈", "symbols": []}
        assert client.post("/api/dream/interpret", json=body).status_code == 200
        assert client.post("/api/dream/interpret", json=body).status_code == 429

    def test_login_rate_limit_429(self, fastapi_app, client, monkeypatch):
        monkeypatch.setitem(
            fastapi_app.state.container.rate_limits.hourly, "login", (2, 600)
        )
        monkeypatch.delenv("GOOGLE_CLIENT_ID", raising=False)
        # 키 미설정이라 400이지만 rate 카운트는 소모된다 → 3번째는 429
        assert client.get("/api/auth/login/google").status_code == 400
        assert client.get("/api/auth/login/google").status_code == 400
        assert client.get("/api/auth/login/google").status_code == 429

    def test_event_body_size_cap_413(self, fastapi_app, client):
        fastapi_app.state.container.rate_limits = replace(
            fastapi_app.state.container.rate_limits, event_body_max_bytes=100
        )
        big = {
            "fortuneId": "f1",
            "clientEvents": [{"event": "x" * 200, "clientTs": 1}],
            "serverEvents": [],
        }
        res = client.post("/api/event", json=big)
        assert res.status_code == 413

    def test_identities_are_isolated(self):
        limiter = ratelimit.MemoryRateLimiter()
        assert limiter.check("s", "ip:a", 1, 3600) == (True, 0)
        allowed_a, retry_a = limiter.check("s", "ip:a", 1, 3600)
        assert allowed_a is False and retry_a >= 1
        assert limiter.check("s", "ip:b", 1, 3600)[0] is True  # 다른 identity는 독립

    def test_window_expiry_resets_count(self, monkeypatch):
        import time as time_mod

        limiter = ratelimit.MemoryRateLimiter()
        base = 1_000_000.0
        monkeypatch.setattr(ratelimit.time, "time", lambda: base)
        assert limiter.check("s", "ip:a", 1, 60)[0] is True
        assert limiter.check("s", "ip:a", 1, 60)[0] is False
        monkeypatch.setattr(ratelimit.time, "time", lambda: base + 61)
        assert limiter.check("s", "ip:a", 1, 60)[0] is True
        assert time_mod is not None


# ── 꿈 부적 SVG ──
class TestDreamShareCard:
    def test_requires_login(self, client):
        assert client.get("/api/dream/share-card?symbols=뱀").status_code == 401

    def test_renders_svg_from_symbols(self, fastapi_app, client):
        login(fastapi_app, client)
        res = client.get("/api/dream/share-card?symbols=뱀,물")
        assert res.status_code == 200
        assert res.headers["content-type"].startswith("image/svg+xml")
        assert res.text.startswith("<svg")
        assert "꿈 · 뱀" in res.text and "꿈 · 물" in res.text
        assert "오늘신당 · 꿈부적" in res.text

    def test_invalid_symbols_400(self, fastapi_app, client):
        login(fastapi_app, client)
        assert client.get("/api/dream/share-card?symbols=없는상징").status_code == 400
        assert client.get("/api/dream/share-card").status_code == 400

    def test_symbols_capped_and_no_nickname_leak(self, fastapi_app, client):
        """상징 3개 초과는 잘리고, 닉네임은 공용 기본값(손님)만 사용 — 개인정보 미포함."""
        login(fastapi_app, client)
        res = client.get("/api/dream/share-card?symbols=뱀,물,불,돈")
        assert res.status_code == 200
        assert "꿈 · 돈" not in res.text
        assert "손님" in res.text
        assert "테스트" not in res.text  # 세션 닉네임을 카드에 넣지 않는다


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
        good = dream.build_reading(["뱀", "불"])  # good 우세
        caution = dream.build_reading(["추락", "이빨 빠짐"])  # caution 우세
        mixed = dream.build_reading(["물"])  # 균형
        assert "길몽" in good["chips"][0]
        assert "액땜" in caution["chips"][0]
        assert "갈림길" in mixed["chips"][0]

    def test_dream_id_excludes_raw_text(self):
        a = dream.interpret("구렁이 꿈", [])
        b = dream.interpret("커다란 구렁이가 나온 전혀 다른 꿈", [])
        # 같은 상징 조합이면 같은 dreamId — 원문이 ID에 섞이지 않는다는 증거
        assert a["dreamId"] == b["dreamId"]
