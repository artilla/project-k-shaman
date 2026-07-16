from __future__ import annotations

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from shindang.adapters.audio import KEY_RE
from shindang.domain.fortune_card import render_share_card_svg

from ..dependencies import container, daily_gate, login_gate, rate_gate
from ..validation import fortune_request, json_object

router = APIRouter(tags=["fortune"])


def _fortune_response(request: Request, parsed: dict) -> dict:
    app = container(request)
    result = app.playback.build(parsed, include_tts=False)
    app.fortunes.put(result["fortuneId"], result["fortune"])
    return {**result, "audioUrl": app.audio.url_for(result["tts"]["cacheKey"])}


@router.get("/api/fortune/today")
def fortune_today_get(request: Request):
    gate = rate_gate(request, "fortune") or daily_gate(request, "fortune-daily")
    if gate:
        return gate
    params = {
        key: value
        for key, value in request.query_params.items()
        if not key.startswith("birth_")
    }
    parsed, error = fortune_request(params)
    if error is not None:
        return error
    return _fortune_response(request, parsed)


@router.post("/api/fortune/today")
async def fortune_today_post(request: Request):
    gate = rate_gate(request, "fortune") or daily_gate(request, "fortune-daily")
    if gate:
        return gate
    payload, error = await json_object(request)
    if error:
        return error
    parsed, error = fortune_request(payload)
    if error is not None:
        return error
    return _fortune_response(request, parsed)


@router.post("/api/tts/prepare")
async def tts_prepare(request: Request):
    gate = login_gate(request) or rate_gate(request, "tts")
    if gate:
        return gate
    payload, error = await json_object(request)
    if error:
        return error
    parsed, error = fortune_request(payload)
    if error:
        return error
    app = container(request)
    result = app.playback.build(
        parsed, include_tts=app.settings.tts_backend == "openai"
    )
    return {
        "audioUrl": app.audio.url_for(result["tts"]["cacheKey"]),
        "durationSec": result.get("durationSec"),
    }


@router.get("/api/share-card")
def share_card(request: Request):
    gate = login_gate(request)
    if gate:
        return gate
    app = container(request)
    fortune_id = request.query_params.get("fortuneId")
    fortune = app.fortunes.get(fortune_id) if fortune_id else None
    if fortune is None:
        return JSONResponse({"error": "fortune not found"}, status_code=404)
    illustration_path = (
        app.settings.shared_asset_dir / "assets" / "hongyeon-share-card.webp"
    )
    illustration = (
        illustration_path.read_bytes() if illustration_path.is_file() else None
    )
    svg = render_share_card_svg(fortune, nickname="손님", illustration=illustration)
    return Response(svg, media_type="image/svg+xml; charset=utf-8")


@router.get("/audio/mock/{key_hash}.wav")
def audio_mock(key_hash: str, request: Request):
    gate = login_gate(request)
    if gate:
        return gate
    if not KEY_RE.fullmatch(key_hash):
        return JSONResponse({"error": "invalid audio key"}, status_code=404)
    return Response(container(request).audio.mock_wav(), media_type="audio/wav")


@router.get("/audio/real/{key_hash}.mp3")
def audio_real(key_hash: str, request: Request):
    gate = login_gate(request)
    if gate:
        return gate
    if not KEY_RE.fullmatch(key_hash):
        return JSONResponse({"error": "invalid audio key"}, status_code=404)
    path = container(request).audio.real_path(key_hash)
    if not path.is_file():
        return JSONResponse({"error": "audio not found"}, status_code=404)
    return Response(path.read_bytes(), media_type="audio/mpeg")
