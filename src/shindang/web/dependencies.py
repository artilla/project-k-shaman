"""여러 HTTP 라우터가 공유하는 인증·비용 게이트."""

from __future__ import annotations

from fastapi import Request, Response
from fastapi.responses import JSONResponse

from shindang.adapters.rate_limit import client_identity
from shindang.adapters.session import SESSION_COOKIE_NAME, verify_session_cookie_value
from shindang.bootstrap import AppContainer


def container(request: Request) -> AppContainer:
    return request.app.state.container


def set_auth_cookie(
    response: Response, name: str, value: str, app: AppContainer, **kwargs
) -> None:
    response.set_cookie(
        name,
        value,
        path="/",
        httponly=True,
        secure=app.settings.secure_cookie,
        samesite="lax",
        **kwargs,
    )


def current_session_id(request: Request) -> str | None:
    app = container(request)
    session_id = verify_session_cookie_value(
        request.cookies.get(SESSION_COOKIE_NAME), app.settings.session_secret
    )
    if session_id is None or not app.sessions.contains(session_id):
        return None
    return session_id


def current_session(request: Request) -> dict | None:
    session_id = current_session_id(request)
    return container(request).sessions.get(session_id) if session_id else None


def login_gate(request: Request) -> JSONResponse | None:
    if current_session(request) is None:
        return JSONResponse({"error": "login required"}, status_code=401)
    return None


def rate_gate(request: Request, scope: str) -> JSONResponse | None:
    app = container(request)
    limit, window = app.rate_limits.hourly[scope]
    identity = client_identity(
        request, current_session_id(request), trust_proxy=app.settings.trust_proxy
    )
    allowed, retry_after = app.rate_limiter.check(scope, identity, limit, window)
    if allowed:
        return None
    return JSONResponse(
        {"error": "rate limited", "retryAfterSec": retry_after},
        status_code=429,
        headers={"Retry-After": str(retry_after)},
    )


def daily_gate(request: Request, scope: str) -> JSONResponse | None:
    app = container(request)
    identity = client_identity(
        request, current_session_id(request), trust_proxy=app.settings.trust_proxy
    )
    allowed, retry_after = app.rate_limiter.check(
        scope, identity, app.rate_limits.daily[scope], 86400
    )
    if allowed:
        return None
    return JSONResponse(
        {"error": "daily limit reached", "retryAfterSec": retry_after},
        status_code=429,
        headers={"Retry-After": str(retry_after)},
    )
