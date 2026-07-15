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

from backend import core, dream, dream_card, ratelimit  # noqa: E402 — 헬퍼·꿈 해몽·꿈 부적·리미터

_logger = logging.getLogger("fortune_engine.backend")

SESSION_COOKIE = core.SESSION_COOKIE_NAME
STATE_COOKIE = core.OAUTH_STATE_COOKIE_NAME
_DEPLOYED_ENVIRONMENTS = {"staging", "production"}
_VALID_ENVIRONMENTS = {"development", "test", *_DEPLOYED_ENVIRONMENTS}


def _deployment_config() -> tuple[str, str, bool]:
    """Return (environment, session_secret, secure_cookie) with fail-closed deploy guards."""
    environment = os.getenv("SHINDANG_ENV", "development").strip().lower()
    if environment not in _VALID_ENVIRONMENTS:
        raise RuntimeError(
            "SHINDANG_ENV must be one of development|test|staging|production"
        )

    session_secret = os.getenv("SESSION_SECRET", "")
    if environment in _DEPLOYED_ENVIRONMENTS:
        if not session_secret:
            raise RuntimeError(
                f"SESSION_SECRET is required when SHINDANG_ENV={environment}"
            )
        if os.getenv("SHINDANG_DEV_LOGIN") == "1":
            raise RuntimeError(
                f"SHINDANG_DEV_LOGIN=1 is forbidden when SHINDANG_ENV={environment}"
            )
    if not session_secret:
        session_secret = secrets.token_hex(32)
    return environment, session_secret, environment in _DEPLOYED_ENVIRONMENTS


def create_app(*, backend: str = "mock") -> FastAPI:
    environment, session_secret, secure_cookie = _deployment_config()
    app = FastAPI(title="오늘신당 backend", docs_url=None, redoc_url=None)
    app.state.tts_backend_mode = backend
    app.state.sessions = {}
    app.state.environment = environment
    app.state.session_secret = session_secret
    app.state.secure_cookie = secure_cookie
    app.state.fortune_cache_by_id = {}
    app.state.rate_limiter = ratelimit.MemoryRateLimiter()

    def set_auth_cookie(response: Response, name: str, value: str, **kwargs) -> None:
        """Set/clear auth cookies with one environment-derived security policy."""
        response.set_cookie(
            name,
            value,
            path="/",
            httponly=True,
            secure=app.state.secure_cookie,
            samesite="lax",
            **kwargs,
        )

    # ── 세션/게이트 헬퍼 ──
    def current_session_id(request: Request):
        raw = request.cookies.get(SESSION_COOKIE)
        if not raw:
            return None
        session_id = core.verify_session_cookie_value(raw, app.state.session_secret)
        if session_id is None or session_id not in app.state.sessions:
            return None
        return session_id

    def current_session(request: Request):
        session_id = current_session_id(request)
        return app.state.sessions.get(session_id) if session_id else None

    # ── rate limit (P0 비용 방어 — LLM·TTS 실과금 전 전제 조건) ──
    def rate_gate(request: Request, scope: str):
        limit, window = ratelimit.LIMITS[scope]
        identity = ratelimit.client_identity(request, current_session_id(request))
        allowed, retry_after = app.state.rate_limiter.check(scope, identity, limit, window)
        if not allowed:
            return JSONResponse(
                {"error": "rate limited", "retryAfterSec": retry_after},
                status_code=429,
                headers={"Retry-After": str(retry_after)},
            )
        return None

    def daily_gate(request: Request, scope: str):
        """하루 사용 상한 (UTC 자정 고정 윈도우) — Plan.md '하루 N회' 제품 정책."""
        limit = ratelimit.DAILY_LIMITS[scope]
        identity = ratelimit.client_identity(request, current_session_id(request))
        allowed, retry_after = app.state.rate_limiter.check(scope, identity, limit, 86400)
        if not allowed:
            return JSONResponse(
                {"error": "daily limit reached", "retryAfterSec": retry_after},
                status_code=429,
                headers={"Retry-After": str(retry_after)},
            )
        return None

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
        set_auth_cookie(resp, STATE_COOKIE, "", max_age=0)
        return resp

    # ── runtime probes ──
    @app.get("/healthz")
    def healthz():
        return {"status": "ok"}

    @app.get("/readyz")
    def readyz():
        # T029가 DB adapter를 연결하기 전에는 DB 미구성을 명시한다. DATABASE_URL만
        # 먼저 주입된 상태를 ready로 위장하지 않는다.
        if os.getenv("DATABASE_URL"):
            return JSONResponse(
                {"status": "not_ready", "checks": {"database": "adapter-unavailable"}},
                status_code=503,
            )
        return {"status": "ready", "checks": {"database": "not-configured"}}

    # ── 운세 요청 파싱·검증 (리뷰 P2: 잘못된 입력이 500/schema-invalid 200이 되지 않게) ──
    # canonical topic은 fortune-schema.v1.1의 enum과 동일 — 'rel' 별칭은 쓰지 않는다 (리뷰 P1-2)
    _VALID_TOPICS = {"total", "love", "money", "work", "relationship"}
    _VALID_CHARACTERS = {"hongyeon"}
    _DATE_RE = __import__("re").compile(r"^\d{4}-\d{2}-\d{2}$")
    _BIRTH_RANGES = {
        "birth_year": (1900, 2100),
        "birth_month": (1, 12),
        "birth_day": (1, 31),
        "birth_hour": (0, 23),
    }

    def _parse_fortune_request(params):
        """query/body 공용 파서. (request dict, error response) 튜플을 반환한다."""
        if not isinstance(params, dict):
            return None, JSONResponse({"error": "invalid body"}, status_code=400)
        topic = str(params.get("topic", core.DEFAULT_TOPIC))
        if topic not in _VALID_TOPICS:
            return None, JSONResponse({"error": "invalid topic"}, status_code=400)
        date = str(params.get("date", core.DEFAULT_DATE))
        if not _DATE_RE.match(date):
            return None, JSONResponse({"error": "invalid date"}, status_code=400)
        import datetime as _dt
        try:
            _dt.date.fromisoformat(date)
        except ValueError:
            return None, JSONResponse({"error": "invalid date"}, status_code=400)
        character_id = str(params.get("character_id", core.DEFAULT_CHARACTER_ID))
        if character_id not in _VALID_CHARACTERS:
            return None, JSONResponse({"error": "invalid character_id"}, status_code=400)
        req = {"date": date, "topic": topic, "character_id": character_id}
        for field, (lo, hi) in _BIRTH_RANGES.items():
            value = params.get(field)
            if value is None or value == "":
                continue
            try:
                number = int(value)
            except (TypeError, ValueError):
                return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
            if not lo <= number <= hi:
                return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
            req[field] = number
        return req, None

    def _audio_url_for(cache_key: str) -> str:
        return (
            core.real_audio_url_for(cache_key)
            if app.state.tts_backend_mode == "openai"
            else core.mock_audio_url_for(cache_key)
        )

    def _fortune_response(req: dict) -> dict:
        # 리뷰 P1-3(text-first) + 2차 P1-1: 텍스트 API는 TTS 단계를 완전히 건너뛴다("skip").
        # 합성뿐 아니라 캐시 기록도 하지 않는다 — mock 결과가 공용 캐시 키를 선점해
        # 이후 /api/tts/prepare의 실합성이 hit로 skip되던 회귀 방지.
        result = core.build_playback_response(req, tts_backend="skip")
        cache_key = result["tts"]["cacheKey"]
        core.remember_fortune(app.state.fortune_cache_by_id, result["fortuneId"], result["fortune"])
        return {**result, "audioUrl": _audio_url_for(cache_key)}

    # ── 운세 (게스트 허용) ──
    @app.get("/api/fortune/today")
    def fortune_today_get(request: Request):
        """레거시 호환 GET — 리뷰 P1-2에 따라 birth 원문은 받지 않는다(topic·date만)."""
        gate = rate_gate(request, "fortune") or daily_gate(request, "fortune-daily")
        if gate:
            return gate
        params = {k: v for k, v in request.query_params.items() if not k.startswith("birth_")}
        req, err = _parse_fortune_request(params)
        if err:
            return err
        return _fortune_response(req)

    @app.post("/api/fortune/today")
    async def fortune_today_post(request: Request):
        """개인화 운세 — birth 필드는 URL이 아닌 본문으로만 받는다 (URL·접근 로그 노출 방지)."""
        gate = rate_gate(request, "fortune") or daily_gate(request, "fortune-daily")
        if gate:
            return gate
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        if not isinstance(payload, dict):
            return JSONResponse({"error": "invalid body"}, status_code=400)
        req, err = _parse_fortune_request(payload)
        if err:
            return err
        return _fortune_response(req)

    # ── TTS 준비 (로그인 필요 — 실 합성·과금은 여기서만, 듣기 탭 시점) ──
    @app.post("/api/tts/prepare")
    async def tts_prepare(request: Request):
        gate = login_required(request) or rate_gate(request, "tts")
        if gate:
            return gate
        try:
            payload = json.loads(await request.body() or b"{}")
        except json.JSONDecodeError:
            return JSONResponse({"error": "invalid JSON body"}, status_code=400)
        req, err = _parse_fortune_request(payload)
        if err:
            return err
        # 클라이언트가 준 cacheKey를 신뢰하지 않는다 — 동일 파라미터로 서버가 재계산·합성.
        # mock 모드는 "skip": mock 톤은 /audio/mock/*가 즉석 생성하므로 합성이 불필요하고,
        # mock 결과가 공용 캐시 키(provider=openai 고정)를 선점하는 것도 방지한다 (2차 P1-1).
        backend_mode = app.state.tts_backend_mode
        tts_backend = "openai" if backend_mode == "openai" else "skip"
        result = core.build_playback_response(req, tts_backend=tts_backend)
        cache_key = result["tts"]["cacheKey"]
        return {"audioUrl": _audio_url_for(cache_key), "durationSec": result.get("durationSec")}

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
        gate = login_required(request) or rate_gate(request, "dream") or daily_gate(request, "dream-daily")
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

    # ── 꿈 부적 SVG (로그인 필요, 무저장 — 상징 조합만으로 풀이 재구성) ──
    @app.get("/api/dream/share-card")
    def dream_share_card(request: Request):
        gate = login_required(request)
        if gate:
            return gate
        raw = request.query_params.get("symbols", "")
        symbols = [s for s in (part.strip() for part in raw.split(",")) if s in dream.SYMBOLS]
        if not symbols:
            return JSONResponse({"error": "valid symbols required"}, status_code=400)
        svg = dream_card.render_dream_card_svg(symbols[: dream.MAX_SYMBOLS], nickname=core.SHARE_CARD_NICKNAME)
        return Response(svg, media_type="image/svg+xml; charset=utf-8")

    # ── 인증 ──
    @app.get("/api/auth/providers")
    def auth_providers():
        return {"providers": core.oauth_provider_status()}

    @app.get("/api/auth/login/{provider}")
    def auth_login(provider: str, request: Request):
        if provider not in core.OAUTH_PROVIDERS:
            return JSONResponse({"error": "unknown provider"}, status_code=404)
        gate = rate_gate(request, "login")
        if gate:
            return gate
        state = secrets.token_hex(16)
        url = core.build_oauth_authorize_url(
            provider, redirect_uri=redirect_uri_for(request, provider), state=state
        )
        if url is None:
            return JSONResponse({"error": "provider not configured"}, status_code=400)
        resp = RedirectResponse(url, status_code=302)
        set_auth_cookie(resp, STATE_COOKIE, state, max_age=600)
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
        set_auth_cookie(resp, SESSION_COOKIE, cookie_value)
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
        set_auth_cookie(resp, SESSION_COOKIE, "", max_age=0)
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
            set_auth_cookie(resp, SESSION_COOKIE, cookie_value)
            return resp

    # ── 이벤트 수집 ──
    @app.post("/api/event")
    async def event(request: Request):
        gate = rate_gate(request, "event")
        if gate:
            return gate
        body = await request.body()
        if len(body) > ratelimit.EVENT_BODY_MAX_BYTES:
            return JSONResponse({"error": "payload too large"}, status_code=413)
        try:
            payload = json.loads(body or b"{}")
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
