"""HTTP 인증 쿠키의 이름과 서명 형식."""

from __future__ import annotations

import hashlib
import hmac

SESSION_COOKIE_NAME = "shindang_session"
OAUTH_STATE_COOKIE_NAME = "shindang_oauth_state"


def sign_value(value: str, secret: str) -> str:
    return hmac.new(secret.encode(), value.encode(), hashlib.sha256).hexdigest()


def make_session_cookie_value(session_id: str, secret: str) -> str:
    return f"{session_id}.{sign_value(session_id, secret)}"


def verify_session_cookie_value(cookie_value: str | None, secret: str) -> str | None:
    if not cookie_value or "." not in cookie_value:
        return None
    session_id, _, signature = cookie_value.rpartition(".")
    if not session_id or not signature:
        return None
    if not hmac.compare_digest(sign_value(session_id, secret), signature):
        return None
    return session_id
