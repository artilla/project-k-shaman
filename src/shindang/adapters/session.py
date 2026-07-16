"""서명 쿠키와 인메모리 세션 저장소."""

from __future__ import annotations

import hashlib
import hmac
import threading
from dataclasses import dataclass, field

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


@dataclass
class InMemorySessionStore:
    _data: dict[str, dict] = field(default_factory=dict)
    _guard: threading.RLock = field(default_factory=threading.RLock)

    def put(self, session_id: str, session: dict) -> None:
        with self._guard:
            self._data[session_id] = session

    def get(self, session_id: str) -> dict | None:
        with self._guard:
            return self._data.get(session_id)

    def delete(self, session_id: str) -> None:
        with self._guard:
            self._data.pop(session_id, None)

    def contains(self, session_id: str) -> bool:
        with self._guard:
            return session_id in self._data

    def clear(self) -> None:
        with self._guard:
            self._data.clear()

    def __len__(self) -> int:
        with self._guard:
            return len(self._data)
