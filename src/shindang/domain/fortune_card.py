# -*- coding: utf-8 -*-
"""홍연 운세를 정적 SVG 공유 카드로 바꾸는 순수 렌더러."""

from __future__ import annotations

import base64
import textwrap
from html import escape
from typing import Any

DEFAULT_WIDTH = 1080
DEFAULT_HEIGHT = 1350

_SHARE_CARD_ILLUSTRATION_BOX = {"x": 700, "y": 64, "size": 280}

TOPIC_LABELS = {
    "total": "총운",
    "love": "연애운",
    "money": "금전운",
    "work": "일/학업운",
    "relationship": "인간관계운",
}

PALETTE = {
    "코랄 핑크": "#ff6f91",
    "진홍": "#c9184a",
    "자수정 보라": "#7b2cbf",
    "청록": "#168aad",
    "살구색": "#ffb38a",
    "금빛": "#f2b705",
    "먹색": "#1f2933",
    "은백": "#f4f6f8",
}

SCORE_LABELS = {
    "love": "연애",
    "money": "금전",
    "work": "일",
    "relationship": "관계",
    "condition": "컨디션",
}


def render_share_card_svg(
    fortune: dict[str, Any],
    *,
    nickname: str | None = None,
    width: int = DEFAULT_WIDTH,
    height: int = DEFAULT_HEIGHT,
    illustration: bytes | None = None,
) -> str:
    meta = fortune.get("meta", {})
    lucky = fortune.get("lucky", {})
    scores = fortune.get("scores", {})

    color_name = str(lucky.get("color", "")).strip()
    if color_name not in PALETTE:
        raise ValueError(f"허용되지 않은 lucky.color: {color_name!r}")

    topic = str(meta.get("topic", "")).strip()
    topic_label = TOPIC_LABELS.get(topic)
    if topic_label is None:
        raise ValueError(f"알 수 없는 topic: {topic!r}")

    date = str(meta.get("date", "")).strip()
    summary = fortune.get("summary", [])
    if not isinstance(summary, list) or not summary:
        raise ValueError("fortune.summary가 필요합니다")

    accent = PALETTE[color_name]
    dark = "#24151b"
    muted = "#6b4b58"
    bg = "#fff7f3"
    panel = "#ffffff"

    plain_description = " · ".join(
        item
        for item in (
            "오늘신당",
            "홍연",
            date,
            topic_label,
            str(summary[0]),
            str(fortune["scores_line"]),
            color_name,
            str(lucky["item"]),
            str(fortune["avoid"]),
            f"{nickname}님의 오늘 운세" if nickname else "",
        )
        if item
    )

    parts = [
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{width}" height="{height}" '
        f'viewBox="0 0 {width} {height}" role="img" aria-label="오늘신당 홍연 공유 카드">',
        f"<desc>{escape(plain_description)}</desc>",
        "<defs>",
        '  <linearGradient id="card-bg" x1="0" y1="0" x2="1" y2="1">',
        f'    <stop offset="0%" stop-color="{bg}"/>',
        '    <stop offset="55%" stop-color="#fffdfb"/>',
        f'    <stop offset="100%" stop-color="{_tint(accent)}"/>',
        "  </linearGradient>",
        "</defs>",
        f'<rect width="{width}" height="{height}" fill="url(#card-bg)"/>',
        f'<rect x="56" y="56" width="{width - 112}" height="{height - 112}" rx="44" fill="{panel}" '
        f'stroke="{accent}" stroke-width="6"/>',
        f'<circle cx="900" cy="160" r="92" fill="{accent}" opacity="0.16"/>',
        f'<circle cx="172" cy="1120" r="128" fill="{accent}" opacity="0.12"/>',
    ]

    if illustration:
        parts.extend(_illustration_block(illustration))

    y = 132
    parts.extend(
        _text("오늘신당", 94, y, size=34, fill=muted, weight=700)
        + _text("홍연", 94, y + 88, size=96, fill=accent, weight=800)
        + _text(f"{date} · {topic_label}", 96, y + 140, size=34, fill=muted, weight=600)
    )
    if nickname:
        parts.extend(
            _text(
                f"{nickname}님의 오늘 운세", 96, y + 198, size=38, fill=dark, weight=700
            )
        )

    parts.extend(_section_label("오늘의 불씨", 96, 404, accent))
    parts.extend(
        _wrapped_text(
            str(summary[0]),
            96,
            466,
            max_chars=24,
            size=50,
            line_gap=66,
            fill=dark,
            weight=800,
        )
    )

    parts.extend(_section_label("운세 흐름", 96, 636, accent))
    parts.extend(
        _wrapped_text(
            str(fortune["scores_line"]),
            96,
            694,
            max_chars=31,
            size=34,
            line_gap=48,
            fill=dark,
        )
    )
    parts.extend(_score_bars(scores, 96, 824, accent))

    parts.extend(_section_label("행운 부적", 96, 1012, accent))
    parts.extend(
        _text(f"행운색 · {color_name}", 96, 1074, size=38, fill=dark, weight=700)
    )
    parts.extend(
        _text(f"행운템 · {lucky['item']}", 96, 1132, size=38, fill=dark, weight=700)
    )
    parts.extend(
        _wrapped_text(
            f"피하면 좋아요 · {fortune['avoid']}",
            96,
            1204,
            max_chars=32,
            size=30,
            line_gap=42,
            fill=muted,
        )
    )

    parts.extend(
        [
            f'<rect x="742" y="1048" width="188" height="188" rx="36" fill="{accent}" opacity="0.92"/>',
            '<text x="836" y="1162" text-anchor="middle" '
            'font-family="Apple SD Gothic Neo, Noto Sans KR, sans-serif" '
            'font-size="86" font-weight="800" fill="#ffffff">符</text>',
            f'<text x="540" y="1286" text-anchor="middle" '
            f'font-family="Apple SD Gothic Neo, Noto Sans KR, sans-serif" '
            f'font-size="26" font-weight="700" fill="{muted}">오늘신당 · 홍연의 부적 카드</text>',
            "</svg>",
        ]
    )
    return "\n".join(parts) + "\n"


def _text(
    content: str,
    x: int,
    y: int,
    *,
    size: int,
    fill: str,
    weight: int = 500,
) -> list[str]:
    return [
        f'<text x="{x}" y="{y}" font-family="Apple SD Gothic Neo, Noto Sans KR, sans-serif" '
        f'font-size="{size}" font-weight="{weight}" fill="{fill}">{escape(content)}</text>'
    ]


def _wrapped_text(
    content: str,
    x: int,
    y: int,
    *,
    max_chars: int,
    size: int,
    line_gap: int,
    fill: str,
    weight: int = 500,
) -> list[str]:
    lines = textwrap.wrap(content, width=max_chars, break_long_words=True) or [content]
    out: list[str] = []
    for index, line in enumerate(lines[:3]):
        out.extend(
            _text(line, x, y + index * line_gap, size=size, fill=fill, weight=weight)
        )
    return out


def _section_label(content: str, x: int, y: int, accent: str) -> list[str]:
    return [
        f'<rect x="{x}" y="{y - 34}" width="16" height="44" rx="8" fill="{accent}"/>',
        *_text(content, x + 28, y, size=32, fill="#7a2f48", weight=800),
    ]


def _score_bars(scores: dict[str, Any], x: int, y: int, accent: str) -> list[str]:
    out: list[str] = []
    for index, (key, label) in enumerate(SCORE_LABELS.items()):
        value = int(scores[key])
        value = max(0, min(100, value))
        row_y = y + index * 42
        bar_width = int(360 * value / 100)
        out.extend(_text(label, x, row_y, size=25, fill="#6b4b58", weight=700))
        out.append(
            f'<rect x="{x + 112}" y="{row_y - 24}" width="360" height="20" rx="10" fill="#f1dfe6"/>'
        )
        out.append(
            f'<rect x="{x + 112}" y="{row_y - 24}" width="{bar_width}" height="20" rx="10" fill="{accent}"/>'
        )
        out.extend(
            _text(str(value), x + 500, row_y, size=25, fill="#6b4b58", weight=700)
        )
    return out


def _illustration_block(data: bytes) -> list[str]:
    """선정된 일러스트를 카드 우상단에 base64로 임베드한다."""
    box = _SHARE_CARD_ILLUSTRATION_BOX
    clip_id = "share-illustration-clip"
    data_uri = _webp_data_uri(data)
    return [
        "<defs>",
        f'  <clipPath id="{clip_id}">',
        f'    <rect x="{box["x"]}" y="{box["y"]}" width="{box["size"]}" height="{box["size"]}" rx="28"/>',
        "  </clipPath>",
        "</defs>",
        f'<image href="{data_uri}" x="{box["x"]}" y="{box["y"]}" width="{box["size"]}" height="{box["size"]}" '
        f'preserveAspectRatio="xMidYMid slice" clip-path="url(#{clip_id})"/>',
    ]


def _webp_data_uri(data: bytes) -> str:
    encoded = base64.b64encode(data).decode("ascii")
    return f"data:image/webp;base64,{encoded}"


def _tint(hex_color: str) -> str:
    # Keep backgrounds pale while preserving the selected lucky color family.
    if hex_color in {"#1f2933", "#7b2cbf", "#168aad", "#c9184a"}:
        return "#f3e7ef"
    return "#fff0e7"
