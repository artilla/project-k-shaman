"""HTTP 운세 입력을 기존 400 응답 계약으로 정규화한다."""

from __future__ import annotations

import datetime as dt
import json
import re

from fastapi import Request
from fastapi.responses import JSONResponse

DEFAULT_DATE = "2026-01-01"
DEFAULT_TOPIC = "total"
DEFAULT_CHARACTER_ID = "hongyeon"
VALID_TOPICS = {"total", "love", "money", "work", "relationship"}
VALID_CHARACTERS = {"hongyeon"}
DATE_RE = re.compile(r"^\d{4}-\d{2}-\d{2}$")
BIRTH_RANGES = {
    "birth_year": (1900, 2100),
    "birth_month": (1, 12),
    "birth_day": (1, 31),
    "birth_hour": (0, 23),
}


async def json_object(request: Request) -> tuple[dict | None, JSONResponse | None]:
    try:
        payload = json.loads(await request.body() or b"{}")
    except json.JSONDecodeError:
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
        try:
            number = int(value)
        except (TypeError, ValueError):
            return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
        if not lower <= number <= upper:
            return None, JSONResponse({"error": f"invalid {field}"}, status_code=400)
        result[field] = number
    return result, None
