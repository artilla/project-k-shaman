from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from ..dependencies import container

router = APIRouter(tags=["runtime"])


@router.get("/healthz")
def healthz() -> dict:
    return {"status": "ok"}


@router.get("/readyz")
def readyz(request: Request):
    if container(request).settings.database_url:
        return JSONResponse(
            {"status": "not_ready", "checks": {"database": "adapter-unavailable"}},
            status_code=503,
        )
    return {"status": "ready", "checks": {"database": "not-configured"}}
