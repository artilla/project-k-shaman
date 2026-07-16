"""환경변수를 한 번 검증해 불변 설정 객체로 만드는 구성 경계."""

from __future__ import annotations

import os
import secrets
from dataclasses import dataclass, field
from pathlib import Path
from urllib.parse import urlparse

DEPLOYED_ENVIRONMENTS = {"staging", "production"}
VALID_ENVIRONMENTS = {"development", "test", *DEPLOYED_ENVIRONMENTS}


def _discover_root() -> Path:
    configured = os.getenv("SHINDANG_ROOT")
    if configured:
        return Path(configured).expanduser().resolve()
    current = Path.cwd().resolve()
    for candidate in (current, *current.parents):
        if (candidate / "pyproject.toml").is_file() and (
            candidate / "frontend"
        ).is_dir():
            return candidate
    return current


@dataclass(frozen=True)
class Settings:
    environment: str
    session_secret: str = field(repr=False)
    tts_backend: str
    dev_login: bool
    trust_proxy: bool
    database_url: str | None = field(repr=False)
    public_base_url: str | None
    project_root: Path
    state_dir: Path
    frontend_dist_dir: Path
    frontend_public_dir: Path

    @property
    def secure_cookie(self) -> bool:
        return self.environment in DEPLOYED_ENVIRONMENTS

    @property
    def tts_cache_dir(self) -> Path:
        return self.state_dir / "tts_cache"

    @property
    def events_log_path(self) -> Path:
        return self.state_dir / "events" / "playback_events.jsonl"

    @property
    def shared_asset_dir(self) -> Path:
        built = self.frontend_dist_dir / "static"
        return built if built.is_dir() else self.frontend_public_dir / "static"

    @classmethod
    def from_env(cls, *, tts_backend: str | None = None) -> "Settings":
        environment = os.getenv("SHINDANG_ENV", "development").strip().lower()
        if environment not in VALID_ENVIRONMENTS:
            raise RuntimeError(
                "SHINDANG_ENV must be development|test|staging|production"
            )

        backend = (tts_backend or os.getenv("TTS_BACKEND", "mock")).strip().lower()
        if backend not in {"mock", "openai"}:
            raise RuntimeError("TTS_BACKEND must be mock or openai")

        session_secret = os.getenv("SESSION_SECRET", "")
        dev_login = os.getenv("SHINDANG_DEV_LOGIN") == "1"
        if environment in DEPLOYED_ENVIRONMENTS:
            if not session_secret:
                raise RuntimeError(
                    f"SESSION_SECRET is required when SHINDANG_ENV={environment}"
                )
            if len(session_secret) < 32:
                raise RuntimeError(
                    f"SESSION_SECRET must be at least 32 characters when SHINDANG_ENV={environment}"
                )
            if dev_login:
                raise RuntimeError(
                    f"SHINDANG_DEV_LOGIN=1 is forbidden when SHINDANG_ENV={environment}"
                )
        if not session_secret:
            session_secret = secrets.token_hex(32)
        if backend == "openai" and not os.getenv("OPENAI_API_KEY"):
            raise RuntimeError(
                "TTS_BACKEND=openai requires OPENAI_API_KEY — refusing to start"
            )

        public_base_url = (os.getenv("SHINDANG_PUBLIC_BASE_URL") or "").rstrip(
            "/"
        ) or None
        if public_base_url:
            parsed = urlparse(public_base_url)
            if parsed.scheme not in {"http", "https"} or not parsed.netloc:
                raise RuntimeError(
                    "SHINDANG_PUBLIC_BASE_URL must be an absolute http(s) URL"
                )
        if environment in DEPLOYED_ENVIRONMENTS and (
            not public_base_url or not public_base_url.startswith("https://")
        ):
            raise RuntimeError(
                "SHINDANG_PUBLIC_BASE_URL=https://... is required in staging and production"
            )

        root = _discover_root()
        state_dir = (
            Path(os.getenv("SHINDANG_STATE_DIR", root / "state")).expanduser().resolve()
        )
        dist = Path(
            os.getenv("SHINDANG_FRONTEND_DIST", root / "frontend" / "dist")
        ).resolve()
        public = Path(
            os.getenv("SHINDANG_FRONTEND_PUBLIC", root / "frontend" / "public")
        ).resolve()
        return cls(
            environment=environment,
            session_secret=session_secret,
            tts_backend=backend,
            dev_login=dev_login,
            trust_proxy=os.getenv("TRUST_PROXY") == "1",
            database_url=os.getenv("DATABASE_URL") or None,
            public_base_url=public_base_url,
            project_root=root,
            state_dir=state_dir,
            frontend_dist_dir=dist,
            frontend_public_dir=public,
        )
