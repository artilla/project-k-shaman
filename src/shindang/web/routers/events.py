from fastapi import APIRouter, Request
from fastapi.responses import JSONResponse

from shindang.application.telemetry import summarize_latency, validate_timeline

from ..dependencies import container, rate_gate
from ..validation import json_object, timeline_request

router = APIRouter(tags=["telemetry"])


@router.post("/api/event")
async def event(request: Request):
    gate = rate_gate(request, "event")
    if gate:
        return gate
    app = container(request)
    body = await request.body()
    if len(body) > app.rate_limits.event_body_max_bytes:
        return JSONResponse({"error": "payload too large"}, status_code=413)
    payload, error = await json_object(request)
    if error:
        return error
    parsed, error = timeline_request(payload)
    if error:
        return error
    events, session_start_ms = parsed
    missing = validate_timeline(events)
    summary = summarize_latency(events, session_start_ms=session_start_ms)
    app.events.append(
        {"fortuneId": payload.get("fortuneId"), "events": events, "summary": summary}
    )
    return {"ok": True, "missing": missing, "summary": summary}
