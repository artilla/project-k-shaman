import datetime as dt

from fastapi import APIRouter, Request, Response
from fastapi.responses import JSONResponse

from shindang.domain import dream
from shindang.domain.dream_card import render_dream_card_svg

from ..dependencies import container, daily_gate, login_gate, rate_gate
from ..validation import json_object

router = APIRouter(tags=["dream"])


@router.post("/api/dream/interpret")
async def dream_interpret(request: Request):
    gate = (
        login_gate(request)
        or rate_gate(request, "dream")
        or daily_gate(request, "dream-daily")
    )
    if gate:
        return gate
    payload, error = await json_object(request)
    if error:
        return error
    text = payload.get("text", "")
    selected = payload.get("symbols", [])
    if (
        not isinstance(text, str)
        or not isinstance(selected, list)
        or any(not isinstance(symbol, str) for symbol in selected)
    ):
        return JSONResponse({"error": "invalid body"}, status_code=400)
    if not text.strip() and not selected:
        return JSONResponse({"error": "text or symbols required"}, status_code=400)
    result = dream.interpret(text, selected)
    result["audioUrl"] = container(request).audio.url_for("dream:" + result["dreamId"])
    return result


@router.get("/api/dream/share-card")
def dream_share_card(request: Request):
    gate = login_gate(request)
    if gate:
        return gate
    raw = request.query_params.get("symbols", "")
    symbols = [
        symbol
        for symbol in (part.strip() for part in raw.split(","))
        if symbol in dream.SYMBOLS
    ]
    if not symbols:
        return JSONResponse({"error": "valid symbols required"}, status_code=400)
    svg = render_dream_card_svg(
        symbols[: dream.MAX_SYMBOLS], date=dt.date.today(), nickname="손님"
    )
    return Response(svg, media_type="image/svg+xml; charset=utf-8")
