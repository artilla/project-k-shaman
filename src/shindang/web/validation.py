"""HTTP 운세 입력을 기존 400 응답 계약으로 정규화한다."""

from __future__ import annotations

import datetime as dt
import json
import math
import re

from fastapi import Request
from fastapi.responses import JSONResponse

DEFAULT_DATE = "2026-01-01"
DEFAULT_TOPIC = "total"
DEFAULT_CHARACTER_ID = "hongyeon"
VALID_TOPICS = {"total", "love", "money", "work", "relationship"}
VALID_CHARACTERS = {"hongyeon"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
AUDIO_KEY_RE = re.compile(r"^[0-9a-f]{16,64}$")
BIRTH_RANGES = {
    "birth_year": (1900, 2100),
    "birth_month": (1, 12),
    "birth_day": (1, 31),
    "birth_hour": (0, 23),
}


def _reject_json_constant(value: str):
    raise ValueError(f"invalid numeric constant: {value}")


async def json_object(request: Request) -> tuple[dict | None, JSONResponse | None]:
    try:
        payload = json.loads(
            await request.body() or b"{}",
            parse_constant=_reject_json_constant,
        )
    except (json.JSONDecodeError, ValueError):
        return None, JSONResponse({"error": "invalid JSON body"}, status_code=400)
    if not isinstance(payload, dict):
        return None, JSONResponse({"error": "invalid body"}, status_code=400)
    return payload, None


def fortune_request(params: dict) -> tuple[dict | None, JSONResponse | None]:
    topic = str(params.get("topic", DEFAULT_TOPIC))
    if topic not in VALID_TOPICS:
        return None, JSONResponse({"error": "invalid topic"}, status_code=400)
    date = str(params.get("date", DEFAULT_DATE))
    if not DATE_RE.match(date):
        return None, JSONResponse({"error": "invalid date"}, status_code=400)
    try:
        dt.date.fromisoformat(date)
    except ValueError:
        return None, JSONResponse({"error": "invalid date"}, status_code=400)
    character_id = str(params.get("character_id", DEFAULT_CHARACTER_ID))
    if character_id not in VALID_CHARACTERS:
        return None, JSONResponse({"error": "invalid character_id"}, status_code=400)

    result = {"date": date, "topic": topic, "character_id": character_id}
    for field, (lower, upper) in BIRTH_RANGES.items():
        value = params.get(field)
        if value is None or value == "":
            continue
        if isinstance(value, bool) or not isinstance(value, (int, str)):
            return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
        try:
            number = int(value)
        except ValueError:
            return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
        if not lower <= number <= upper:
            return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
        result[field] = number
    birth_parts = tuple(
        result.get(name) for name in BIRTH_RANGES if name != "birth_hour"
    )
    if any(field in result for field in BIRTH_RANGES):
        if any(value is None for value in birth_parts):
            return None, JSONResponse(
                {"error": "birth date must include year, month, and day"},
                status_code=400,
            )
        try:
            dt.date(*birth_parts)
        except ValueError:
            return None, JSONResponse({"error": "invalid birth date"}, status_code=400)
    return result, None


def _finite_number(value: object) -> bool:
    return (
        isinstance(value, (int, float))
        and not isinstance(value, bool)
        and math.isfinite(value)
    )


def timeline_request(
    payload: dict,
) -> tuple[tuple[list[dict], int | float | None] | None, JSONResponse | None]:
    """브라우저 계측 payload를 수학·JSONL 처리 전에 fail-closed로 검증한다."""
    server_events = payload.get("serverEvents", [])
    client_events = payload.get("clientEvents", [])
    if not isinstance(server_events, list) or not isinstance(client_events, list):
        return None, JSONResponse({"error": "invalid body"}, status_code=400)

    events = [*server_events, *client_events]
    if any(
        not isinstance(event, dict)
        or not isinstance(event.get("event"), str)
        or not event["event"]
        for event in events
    ):
        return None, JSONResponse({"error": "invalid event"}, status_code=400)

    session_start_ms = payload.get("sessionStartMs")
    if session_start_ms is not None and not _finite_number(session_start_ms):
        return None, JSONResponse(
            {"error": "invalid sessionStartMs"}, status_code=400
        )

    for event in client_events:
        if event["event"] in {
            "first_text_visible",
            "first_audio_play",
        } and not _finite_number(event.get("clientTs")):
            return None, JSONResponse({"error": "invalid clientTs"}, status_code=400)

    return (events, session_start_ms), None
