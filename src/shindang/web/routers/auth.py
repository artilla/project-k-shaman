from __future__ import annotations

import hmac
import logging
import secrets

from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse, RedirectResponse

from shindang.adapters.session import (
    OAUTH_STATE_COOKIE_NAME,
    SESSION_COOKIE_NAME,
    make_session_cookie_value,
    verify_session_cookie_value,
)

from ..dependencies import (
    container,
    current_session,
    rate_gate,
    set_auth_cookie,
)

router = APIRouter(prefix="/api/auth", tags=["auth"])
_logger = logging.getLogger("shindang.web.auth")


def _redirect_uri(request: Request, provider: str) -> str:
    app = container(request)
    if app.settings.public_base_url:
        base = app.settings.public_base_url
    else:
        scheme = request.url.scheme
        if app.settings.trust_proxy:
            scheme = request.headers.get("x-forwarded-proto", scheme)
        base = f"{scheme}://{request.headers.get('host', '127.0.0.1')}"
    return f"{base}/api/auth/callback/{provider}"


def _auth_error(request: Request) -> RedirectResponse:
    response = RedirectResponse("/?auth_error=1", status_code=302)
    set_auth_cookie(
        response, OAUTH_STATE_COOKIE_NAME, "", container(request), max_age=0
    )
    return response


@router.get("/providers")
def providers(request: Request) -> dict:
    return {"providers": container(request).oauth.provider_status()}


@router.get("/login/{provider}")
def login(provider: str, request: Request):
    app = container(request)
    if not app.oauth.has_provider(provider):
        return JSONResponse({"error": "unknown provider"}, status_code=404)
    gate = rate_gate(request, "login")
    if gate:
        return gate
    state = secrets.token_hex(16)
    url = app.oauth.authorize_url(
        provider, redirect_uri=_redirect_uri(request, provider), state=state
    )
    if url is None:
        return JSONResponse({"error": "provider not configured"}, status_code=400)
    response = RedirectResponse(url, status_code=302)
    set_auth_cookie(response, OAUTH_STATE_COOKIE_NAME, state, app, max_age=600)
    return response


@router.get("/callback/{provider}")
def callback(provider: str, request: Request):
    app = container(request)
    if not app.oauth.has_provider(provider):
        return JSONResponse({"error": "unknown provider"}, status_code=404)
    code = request.query_params.get("code")
    state = request.query_params.get("state")
    expected = request.cookies.get(OAUTH_STATE_COOKIE_NAME)
    if (
        not code
        or not state
        or not expected
        or not hmac.compare_digest(state, expected)
    ):
        return _auth_error(request)
    try:
        profile = app.oauth.exchange_profile(
            provider, code, redirect_uri=_redirect_uri(request, provider)
        )
    except Exception:
        _logger.exception("oauth token exchange failed for provider=%s", provider)
        return _auth_error(request)
    session_id = secrets.token_hex(16)
    app.sessions.put(
        session_id, {"provider": provider, "nickname": profile.get("nickname")}
    )
    response = RedirectResponse("/", status_code=302)
    set_auth_cookie(
        response,
        SESSION_COOKIE_NAME,
        make_session_cookie_value(session_id, app.settings.session_secret),
        app,
    )
    return response


@router.get("/me")
def me(request: Request) -> dict:
    session = current_session(request)
    if session is None:
        return {"loggedIn": False}
    return {
        "loggedIn": True,
        "provider": session["provider"],
        "nickname": session.get("nickname"),
    }


@router.post("/logout")
def logout(request: Request):
    app = container(request)
    session_id = verify_session_cookie_value(
        request.cookies.get(SESSION_COOKIE_NAME), app.settings.session_secret
    )
    if session_id:
        app.sessions.delete(session_id)
    response = JSONResponse({"ok": True})
    set_auth_cookie(response, SESSION_COOKIE_NAME, "", app, max_age=0)
    return response


@router.get("/dev-login")
def dev_login(request: Request):
    app = container(request)
    if not app.settings.dev_login:
        return JSONResponse({"detail": "Not Found"}, status_code=404)
    session_id = secrets.token_hex(16)
    app.sessions.put(session_id, {"provider": "dev", "nickname": "하늘이"})
    response = RedirectResponse("/", status_code=302)
    set_auth_cookie(
        response,
        SESSION_COOKIE_NAME,
        make_session_cookie_value(session_id, app.settings.session_secret),
        app,
    )
    return response
