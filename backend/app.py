"""오늘신당 backend — FastAPI 이식 (ADR-0003 FE/BE 분리).

기존 fortune-engine/web/server.py의 HTTP 계약을 그대로 유지하되,
엔진·헬퍼 로직은 legacy 모듈을 import로 재사용한다 (로직 중복 금지).
legacy web가 패리티 확인 후 제거되면 헬퍼를 이 패키지로 승격한다.

계약 (test_web_server.py와 동일):
- GET  /api/fortune/today          — 게스트 허용 (텍스트 먼저 원칙)
- GET  /api/share-card             — 로그인 필요 (401)
- GET  /audio/mock|real/*          — 로그인 필요 (401)
- GET  /api/auth/providers|login|callback|me, POST /api/auth/logout
- POST /api/event                  — 계측 수집
- 콜백 실패 시 302 → /?auth_error=1 (+ state 쿠키 삭제)
"""
from __future__ import annotations

import json
import logging
import secrets
import sys
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

_ROOT = Path(__file__).resolve().parent.parent
_LEGACY_WEB = _ROOT / "fortune-engine" / "web"
sys.path.insert(0, str(_LEGACY_WEB))

import server as legacy  # noqa: E402 — fortune-engine/web/server.py (헬퍼 재사용)

_logger = logging.getLogger("fortune_engine.backend")

SESSION_COOKIE = legacy._SESSION_COOKIE_NAME
STATE_COOKIE = legacy._OAUTH_STATE_COOKIE_NAME


def create_app(*, backend: str = "mock") -> FastAPI:
    app = FastAPI(title="오늘신당 backend", docs_url=None, redoc_url=None)
    app.state.tts_backend_mode = backend
    app.state.sessions = {}
    app.state.session_secret = secrets.token_hex(32)
    app.state.fortune_cache_by_id = {}

    # ── 세션/게이트 헬퍼 ──
    def current_session(request: Request):
        raw = request.cookies.get(SESSION_COOKIE)
        if not raw:
            return None
        session_id = legacy._verify_session_cookie_value(raw, app.state.session_secret)
        if session_id is None:
            return None
        return app.state.sessions.get(session_id)

    def login_required(request: Request):
        """재생·부적 게이트 — 운세 텍스트는 게스트 허용 유지 (US-9와 동일 정책)."""
        if current_session(request) is None:
            return JSONResponse({"error": "login required"}, status_code=401)
        return None

    def redirect_uri_for(request: Request, provider: str) -> str:
        # 프록시 뒤 https 지원: X-Forwarded-Proto 우선 (production-readiness §3)
        proto = request.headers.get("x-forwarded-proto", request.url.scheme or "http")
        host = request.headers.get("host", "127.0.0.1")
        return f"{proto}://{host}/api/auth/callback/{provider}"

    def auth_error_redirect() -> RedirectResponse:
        resp = RedirectResponse("/?auth_error=1", status_code=302)
        resp.set_cookie(STATE_COOKIE, "", path="/", httponly=True, samesite="lax", max_age=0)
        return resp

    # ── 운세 (게스트 허용) ──
    @app.get("/api/fortune/today")
    def fortune_today(request: Request):
        req = {
            "date": request.query_params.get("date", legacy._DEFAULT_DATE),
            "topic": request.query_params.get("topic", legacy._DEFAULT_TOPIC),
            "character_id": request.query_params.get("character_id", legacy._DEFAULT_CHARACTER_ID),
        }
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            value = request.query_params.get(field)
            if value is not None:
                req[field] = int(value)

        backend_mode = app.state.tts_backend_mode
        tts_backend = "openai" if backend_mode == "openai" else None
        result = legacy.build_playback_response(req, tts_backend=tts_backend)
        cache_key = result["tts"]["cacheKey"]
        audio_url = (
            legacy._real_audio_url_for(cache_key)
            if backend_mode == "openai"
            else legacy._mock_audio_url_for(cache_key)
        )
        legacy._remember_fortune(app.state.fortune_cache_by_id, result["fortuneId"], result["fortune"])
        return {**result, "audioUrl": audio_url}

    # ── 부적 카드 (로그인 필요) ──
    @app.get("/api/share-card")
    def share_card(request: Request):
        gate = login_required(request)
        if gate:
            return gate
        fortune_id = request.query_params.get("fortuneId")
        fortune = app.state.fortune_cache_by_id.get(fortune_id) if fortune_id else None
        if fortune is None:
            return JSONResponse({"error": "fortune not found"}, status_code=404)
        svg = legacy._share_card.render_share_card_svg(fortune, nickname=legacy._SHARE_CARD_NICKNAME)
        return Response(svg, media_type="image/svg+xml; charset=utf-8")

    # ── 오디오 (로그인 필요) ──
    @app.get("/audio/mock/{key_hash}.wav")
    def audio_mock(key_hash: str, request: Request):
        gate = login_required(request)
        if gate:
            return gate
        if not legacy._KEY_RE.match(key_hash):
            return JSONResponse({"error": "invalid audio key"}, status_code=404)
        return Response(legacy._mock_placeholder_wav(), media_type="audio/wav")

    @app.get("/audio/real/{key_hash}.mp3")
    def audio_real(key_hash: str, request: Request):
        gate = login_required(request)
        if gate:
            return gate
        if not legacy._KEY_RE.match(key_hash):
            return JSONResponse({"error": "invalid audio key"}, status_code=404)
        path = legacy._TTS_REAL_CACHE_DIR / f"{key_hash}.mp3"
        if not path.is_file():
            return JSONResponse({"error": "audio not found"}, status_code=404)
        return Response(path.read_bytes(), media_type="audio/mpeg")

    # ── 인증 ──
    @app.get("/api/auth/providers")
    def auth_providers():
        return {"providers": legacy.oauth_provider_status()}

    @app.get("/api/auth/login/{provider}")
    def auth_login(provider: str, request: Request):
        if provider not in legacy._OAUTH_PROVIDERS:
            return JSONResponse({"error": "unknown provider"}, status_code=404)
        state = secrets.token_hex(16)
        url = legacy.build_oauth_authorize_url(
            provider, redirect_uri=redirect_uri_for(request, provider), state=state
        )
        if url is None:
            return JSONResponse({"error": "provider not configured"}, status_code=400)
        resp = RedirectResponse(url, status_code=302)
        resp.set_cookie(STATE_COOKIE, state, path="/", httponly=True, samesite="lax", max_age=600)
        return resp

    @app.get("/api/auth/callback/{provider}")
    def auth_callback(provider: str, request: Request):
        if provider not in legacy._OAUTH_PROVIDERS:
            return JSONResponse({"error": "unknown provider"}, status_code=404)
        code = request.query_params.get("code")
        if not code:
            return auth_error_redirect()
        state = request.query_params.get("state")
        expected_state = request.cookies.get(STATE_COOKIE)
        import hmac as _hmac
        if not state or not expected_state or not _hmac.compare_digest(state, expected_state):
            return auth_error_redirect()
        try:
            profile = legacy._oauth_token_and_profile(
                provider, code, redirect_uri=redirect_uri_for(request, provider)
            )
        except Exception:
            _logger.exception("oauth token exchange failed for provider=%s", provider)
            return auth_error_redirect()
        session_id = secrets.token_hex(16)
        app.state.sessions[session_id] = {"provider": provider, "nickname": profile.get("nickname")}
        cookie_value = legacy._make_session_cookie_value(session_id, app.state.session_secret)
        resp = RedirectResponse("/", status_code=302)
        resp.set_cookie(SESSION_COOKIE, cookie_value, path="/", httponly=True, samesite="lax")
        return resp

    @app.get("/api/auth/me")
    def auth_me(request: Request):
        session = current_session(request)
        if session is None:
            return {"loggedIn": False}
        return {"loggedIn": True, "provider": session["provider"], "nickname": session.get("nickname")}

    @app.post("/api/auth/logout")
    def auth_logout(request: Request):
        raw = request.cookies.get(SESSION_COOKIE)
        if raw:
            session_id = legacy._verify_session_cookie_value(raw, app.state.session_secret)
            if session_id is not None:
                app.state.sessions.pop(session_id, None)
        resp = JSONResponse({"ok": True})
        resp.set_cookie(SESSION_COOKIE, "", path="/", httponly=True, samesite="lax", max_age=0)
        return resp

    # ── 이벤트 수집 ──
    @app.post("/api/event")
    async def event(request: Request):
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        merged = [*payload.get("serverEvents", []), *payload.get("clientEvents", [])]
        missing = legacy.validate_timeline(merged)
        summary = legacy.summarize_latency(merged, session_start_ms=payload.get("sessionStartMs", 0))
        legacy._append_event_log({
            "fortuneId": payload.get("fortuneId"),
            "events": merged,
            "summary": summary,
        })
        return {"ok": True, "missing": missing, "summary": summary}

    # ── 정적 서빙 ──
    # 공용 에셋(캐릭터 webp·Live2D 벤더)은 legacy static을 그대로 마운트해 중복을 피한다.
    app.mount("/static", StaticFiles(directory=str(legacy._STATIC_DIR)), name="legacy-static")
    # 프로덕션: frontend 빌드 산출물이 있으면 SPA로 서빙 (dev에서는 Vite가 프록시로 대신한다).
    dist = _ROOT / "frontend" / "dist"
    if dist.is_dir():
        app.mount("/", StaticFiles(directory=str(dist), html=True), name="spa")

    return app


import os  # noqa: E402

# TTS_BACKEND=openai 시 실백엔드 (OPENAI_API_KEY 필요 — legacy validate와 동일 가드)
_mode = os.getenv("TTS_BACKEND", "mock")
legacy.validate_backend_startup(_mode, has_api_key=bool(os.getenv("OPENAI_API_KEY")))
app = create_app(backend=_mode)
