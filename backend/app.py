"""오늘신당 backend — FastAPI 이식 (ADR-0003 FE/BE 분리).

레거시 fortune-engine/web/server.py의 HTTP 계약을 계승한다.
헬퍼는 backend/core.py로 승격 완료(2026-07-09).
엔진 계층(pipeline·share_card 등)은 fortune-engine/에 유지하고 import만 한다.

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
import os
import secrets
from pathlib import Path

from fastapi import FastAPI, Request, Response
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles

_ROOT = Path(__file__).resolve().parent.parent

from backend import core, dream  # noqa: E402 — 헬퍼(레거시에서 승격)·꿈 해몽 로직

_logger = logging.getLogger("fortune_engine.backend")

SESSION_COOKIE = core.SESSION_COOKIE_NAME
STATE_COOKIE = core.OAUTH_STATE_COOKIE_NAME


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
        session_id = core.verify_session_cookie_value(raw, app.state.session_secret)
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
            "date": request.query_params.get("date", core.DEFAULT_DATE),
            "topic": request.query_params.get("topic", core.DEFAULT_TOPIC),
            "character_id": request.query_params.get("character_id", core.DEFAULT_CHARACTER_ID),
        }
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            value = request.query_params.get(field)
            if value is not None:
                req[field] = int(value)

        backend_mode = app.state.tts_backend_mode
        tts_backend = "openai" if backend_mode == "openai" else None
        result = core.build_playback_response(req, tts_backend=tts_backend)
        cache_key = result["tts"]["cacheKey"]
        audio_url = (
            core.real_audio_url_for(cache_key)
            if backend_mode == "openai"
            else core.mock_audio_url_for(cache_key)
        )
        core.remember_fortune(app.state.fortune_cache_by_id, result["fortuneId"], result["fortune"])
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
        svg = core.share_card.render_share_card_svg(fortune, nickname=core.SHARE_CARD_NICKNAME)
        return Response(svg, media_type="image/svg+xml; charset=utf-8")

    # ── 오디오 (로그인 필요) ──
    @app.get("/audio/mock/{key_hash}.wav")
    def audio_mock(key_hash: str, request: Request):
        gate = login_required(request)
        if gate:
            return gate
        if not core.KEY_RE.match(key_hash):
            return JSONResponse({"error": "invalid audio key"}, status_code=404)
        return Response(core.mock_placeholder_wav(), media_type="audio/wav")

    @app.get("/audio/real/{key_hash}.mp3")
    def audio_real(key_hash: str, request: Request):
        gate = login_required(request)
        if gate:
            return gate
        if not core.KEY_RE.match(key_hash):
            return JSONResponse({"error": "invalid audio key"}, status_code=404)
        path = core.TTS_REAL_CACHE_DIR / f"{key_hash}.mp3"
        if not path.is_file():
            return JSONResponse({"error": "audio not found"}, status_code=404)
        return Response(path.read_bytes(), media_type="audio/mpeg")

    # ── 꿈 해몽 (로그인 필요 — 사용자 확정 정책, LLM 도입 시 최대 비용 엔드포인트) ──
    @app.post("/api/dream/interpret")
    async def dream_interpret(request: Request):
        gate = login_required(request)
        if gate:
            return gate
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        text = payload.get("text", "")
        selected = payload.get("symbols", [])
        if not isinstance(text, str) or not isinstance(selected, list):
            return JSONResponse({"error": "invalid body"}, status_code=400)
        if not text.strip() and not selected:
            return JSONResponse({"error": "text or symbols required"}, status_code=400)
        # 프라이버시 불변식: 꿈 원문은 interpret() 안에서만 소비 — 저장·로깅 금지 (v3 §12 정신)
        result = dream.interpret(text, selected)
        cache_key = "dream:" + result["dreamId"]
        result["audioUrl"] = core.mock_audio_url_for(cache_key)
        return result

    # ── 인증 ──
    @app.get("/api/auth/providers")
    def auth_providers():
        return {"providers": core.oauth_provider_status()}

    @app.get("/api/auth/login/{provider}")
    def auth_login(provider: str, request: Request):
        if provider not in core.OAUTH_PROVIDERS:
            return JSONResponse({"error": "unknown provider"}, status_code=404)
        state = secrets.token_hex(16)
        url = core.build_oauth_authorize_url(
            provider, redirect_uri=redirect_uri_for(request, provider), state=state
        )
        if url is None:
            return JSONResponse({"error": "provider not configured"}, status_code=400)
        resp = RedirectResponse(url, status_code=302)
        resp.set_cookie(STATE_COOKIE, state, path="/", httponly=True, samesite="lax", max_age=600)
        return resp

    @app.get("/api/auth/callback/{provider}")
    def auth_callback(provider: str, request: Request):
        if provider not in core.OAUTH_PROVIDERS:
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
            profile = core.oauth_token_and_profile(
                provider, code, redirect_uri=redirect_uri_for(request, provider)
            )
        except Exception:
            _logger.exception("oauth token exchange failed for provider=%s", provider)
            return auth_error_redirect()
        session_id = secrets.token_hex(16)
        app.state.sessions[session_id] = {"provider": provider, "nickname": profile.get("nickname")}
        cookie_value = core.make_session_cookie_value(session_id, app.state.session_secret)
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
            session_id = core.verify_session_cookie_value(raw, app.state.session_secret)
            if session_id is not None:
                app.state.sessions.pop(session_id, None)
        resp = JSONResponse({"ok": True})
        resp.set_cookie(SESSION_COOKIE, "", path="/", httponly=True, samesite="lax", max_age=0)
        return resp

    # 개발 전용: SHINDANG_DEV_LOGIN=1 일 때만 노출 — 게이트 뒤 플로우(QA)를 실 OAuth 키 없이
    # 확인하기 위한 가짜 세션. 프로덕션 환경에 절대 설정하지 말 것 (기본 비활성).
    if os.getenv("SHINDANG_DEV_LOGIN") == "1":
        @app.get("/api/auth/dev-login")
        def dev_login():
            session_id = secrets.token_hex(16)
            app.state.sessions[session_id] = {"provider": "dev", "nickname": "하늘이"}
            cookie_value = core.make_session_cookie_value(session_id, app.state.session_secret)
            resp = RedirectResponse("/", status_code=302)
            resp.set_cookie(SESSION_COOKIE, cookie_value, path="/", httponly=True, samesite="lax")
            return resp

    # ── 이벤트 수집 ──
    @app.post("/api/event")
    async def event(request: Request):
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        merged = [*payload.get("serverEvents", []), *payload.get("clientEvents", [])]
        missing = core.validate_timeline(merged)
        summary = core.summarize_latency(merged, session_start_ms=payload.get("sessionStartMs", 0))
        core.append_event_log({
            "fortuneId": payload.get("fortuneId"),
            "events": merged,
            "summary": summary,
        })
        return {"ok": True, "missing": missing, "summary": summary}

    # ── 정적 서빙 ──
    # 공용 에셋(캐릭터 webp·Live2D 벤더) — fortune-engine/web/static (엔진 자산 위치 유지)
    app.mount("/static", StaticFiles(directory=str(core.STATIC_DIR)), name="shared-static")
    # 프로덕션: frontend 빌드 산출물이 있으면 SPA로 서빙 (dev에서는 Vite가 프록시로 대신한다).
    dist = _ROOT / "frontend" / "dist"
    if dist.is_dir():
        app.mount("/", StaticFiles(directory=str(dist), html=True), name="spa")

    return app


# TTS_BACKEND=openai 시 실백엔드 (OPENAI_API_KEY 필요 — 기동 가드)
_mode = os.getenv("TTS_BACKEND", "mock")
core.validate_backend_startup(_mode, has_api_key=bool(os.getenv("OPENAI_API_KEY")))
app = create_app(backend=_mode)
