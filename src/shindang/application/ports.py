"""애플리케이션 코어가 외부 기술에 요구하는 최소 포트."""

from __future__ import annotations

from typing import Generic, Protocol, TypeVar

T = TypeVar("T")


class CacheStore(Protocol, Generic[T]):
    def get(self, key: str) -> T | None: ...

    def set(self, key: str, value: T) -> None: ...


class SpeechSynthesizer(Protocol):
    mode: str

    def cache_key(self, script: list[dict] | str) -> str: ...

    def synthesize(self, script: list[dict] | str, *, event_sink=None) -> dict: ...


class EventRepository(Protocol):
    def append(self, record: dict) -> None: ...


class SessionStore(Protocol):
    def put(self, session_id: str, session: dict) -> None: ...

    def get(self, session_id: str) -> dict | None: ...

    def delete(self, session_id: str) -> None: ...

    def contains(self, session_id: str) -> bool: ...

    def __len__(self) -> int: ...


class FortuneRepository(Protocol):
    def put(self, fortune_id: str, fortune: dict) -> None: ...

    def get(self, fortune_id: str) -> dict | None: ...

    def __len__(self) -> int: ...


class RateLimiter(Protocol):
    def check(
        self, scope: str, identity: str, limit: int, window_sec: int
    ) -> tuple[bool, int]: ...


class OAuthGateway(Protocol):
    def has_provider(self, provider: str) -> bool: ...

    def provider_status(self) -> dict[str, bool]: ...

    def authorize_url(
        self, provider: str, *, redirect_uri: str, state: str
    ) -> str | None: ...

    def exchange_profile(
        self, provider: str, code: str, *, redirect_uri: str
    ) -> dict: ...
