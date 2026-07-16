"""오늘신당 same-origin FastAPI 입력 어댑터."""

from __future__ import annotations

from fastapi import FastAPI
from fastapi.staticfiles import StaticFiles

from shindang.bootstrap import AppContainer, build_container
from shindang.config import Settings

from .routers import auth, dream, events, fortune, health


def create_app(
    *,
    settings: Settings | None = None,
    app_container: AppContainer | None = None,
    tts_backend: str | None = None,
) -> FastAPI:
    resolved_settings = settings or (
        app_container.settings
        if app_container is not None
        else Settings.from_env(tts_backend=tts_backend)
    )
    resolved_container = app_container or build_container(resolved_settings)
    if resolved_container.settings != resolved_settings:
        raise ValueError("app_container.settings must match settings")

    application = FastAPI(title="오늘신당 backend", docs_url=None, redoc_url=None)
    application.state.container = resolved_container
    application.include_router(health.router)
    application.include_router(fortune.router)
    application.include_router(dream.router)
    application.include_router(auth.router)
    application.include_router(events.router)

    if resolved_settings.frontend_dist_dir.is_dir():
        application.mount(
            "/",
            StaticFiles(directory=str(resolved_settings.frontend_dist_dir), html=True),
            name="spa",
        )
    return application


app = create_app()
