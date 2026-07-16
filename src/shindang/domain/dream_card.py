"""꿈 부적 SVG 렌더러 — D3 '이미지 저장' 실구현.

프라이버시 설계: 꿈 원문은 절대 받지 않는다. 상징 조합(symbols)만 입력으로 받아
build_reading()으로 풀이를 재구성해 렌더링한다 — 서버 무저장 원칙 유지.
스타일: reference/design-prototype-dream D3 카드 (보라 그라데 #1E1233→#3A0E3E, 금선 이중 프레임).
"""

from __future__ import annotations

import datetime
from xml.sax.saxutils import escape

from . import dream

_W, _H = 480, 620
_GOLD = "#C9A24B"
_TEXT = "#F5EEFC"


def _wrap(text: str, limit: int) -> list[str]:
    """한국어 문장을 공백 기준으로 limit자 내외 줄바꿈 (SVG는 자동 줄바꿈이 없다)."""
    words = text.split()
    lines: list[str] = []
    current = ""
    for word in words:
        candidate = (current + " " + word).strip()
        if len(candidate) > limit and current:
            lines.append(current)
            current = word
        else:
            current = candidate
    if current:
        lines.append(current)
    return lines


def render_dream_card_svg(
    symbols: list[str], *, date: datetime.date, nickname: str = "손님"
) -> str:
    """상징 조합 → 꿈 부적 SVG. 유효하지 않은 상징은 호출부에서 걸러 전달한다."""
    reading = dream.build_reading(symbols)
    date_label = f"{date.year} . {date.month:02d} . {date.day:02d}"
    headline = reading["headline"].replace('"', "")
    headline_lines = _wrap(headline, 16)

    parts: list[str] = []
    parts.append(
        f'<svg xmlns="http://www.w3.org/2000/svg" width="{_W}" height="{_H}" viewBox="0 0 {_W} {_H}">'
    )
    parts.append(
        '<defs><linearGradient id="bg" x1="0" y1="0" x2="1" y2="1">'
        '<stop offset="0" stop-color="#1E1233"/><stop offset="0.7" stop-color="#3A0E3E"/>'
        "</linearGradient></defs>"
    )
    # 카드 바탕 + 금선 이중 프레임 (하단 큰 라운드 — 부적 실루엣)
    parts.append(f'<rect width="{_W}" height="{_H}" rx="24" fill="#0A070E"/>')
    parts.append(
        f'<path d="M16 40 a24 24 0 0 1 24-24 h{_W - 80} a24 24 0 0 1 24 24 v{_H - 152} '
        f'a96 96 0 0 1 -96 96 h-{_W - 224} a96 96 0 0 1 -96 -96 z" '
        f'fill="url(#bg)" stroke="{_GOLD}" stroke-opacity="0.65" stroke-width="1.5"/>'
    )
    parts.append(
        f'<path d="M28 48 a18 18 0 0 1 18-18 h{_W - 92} a18 18 0 0 1 18 18 v{_H - 172} '
        f'a86 86 0 0 1 -86 86 h-{_W - 244} a86 86 0 0 1 -86 -86 z" '
        f'fill="none" stroke="{_GOLD}" stroke-opacity="0.28"/>'
    )
    # 헤더: 날짜 · 꿈 해몽
    parts.append(
        f'<text x="52" y="82" font-family="sans-serif" font-size="13" letter-spacing="2.5" '
        f'fill="{_GOLD}" font-weight="700">{escape(date_label)}</text>'
    )
    parts.append(
        f'<text x="{_W - 52}" y="82" text-anchor="end" font-family="sans-serif" font-size="13" '
        f'letter-spacing="2.5" fill="{_GOLD}" font-weight="700">꿈 해몽</text>'
    )
    # 헤드라인 (serif 느낌 강조)
    y = 150
    for line in headline_lines:
        parts.append(
            f'<text x="{_W // 2}" y="{y}" text-anchor="middle" font-family="serif" '
            f'font-size="26" fill="{_TEXT}">{escape(line)}</text>'
        )
        y += 38
    # 수신자
    y += 8
    parts.append(
        f'<text x="{_W // 2}" y="{y}" text-anchor="middle" font-family="sans-serif" '
        f'font-size="14" fill="{_TEXT}" fill-opacity="0.72">{escape(nickname)} 님의 꿈을 풀어낸 홍연의 축원</text>'
    )
    # 칩 (톤 요약 + 상징) — 중앙 정렬 가로 배치
    y += 46
    chips = reading["chips"]
    chip_widths = [len(chip) * 13 + 30 for chip in chips]
    total_width = sum(chip_widths) + (len(chips) - 1) * 10
    x = (_W - total_width) // 2
    for chip, width in zip(chips, chip_widths):
        parts.append(
            f'<rect x="{x}" y="{y - 18}" width="{width}" height="30" rx="15" '
            f'fill="{_GOLD}" fill-opacity="0.12" stroke="{_GOLD}" stroke-opacity="0.5"/>'
        )
        parts.append(
            f'<text x="{x + width / 2}" y="{y + 3}" text-anchor="middle" font-family="sans-serif" '
            f'font-size="13" fill="{_GOLD}" font-weight="700">{escape(chip)}</text>'
        )
        x += width + 10
    # 축원문 (줄바꿈)
    y += 58
    for line in _wrap("“" + reading["blessing"] + "”", 24):
        parts.append(
            f'<text x="{_W // 2}" y="{y}" text-anchor="middle" font-family="sans-serif" '
            f'font-size="14" fill="{_TEXT}" fill-opacity="0.6">{escape(line)}</text>'
        )
        y += 24
    # 브랜드
    parts.append(
        f'<text x="{_W // 2}" y="{_H - 60}" text-anchor="middle" font-family="sans-serif" '
        f'font-size="12" letter-spacing="5" fill="{_GOLD}" fill-opacity="0.6">오늘신당 · 꿈부적</text>'
    )
    parts.append("</svg>")
    return "".join(parts)
