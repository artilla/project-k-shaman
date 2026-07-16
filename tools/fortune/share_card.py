"""계약 샘플에서 정적 운세 공유 카드를 생성하는 CLI."""

from __future__ import annotations

import argparse
import json
from pathlib import Path

from shindang.domain.fortune_card import render_share_card_svg

ROOT = Path(__file__).resolve().parents[2]
DEFAULT_SAMPLES = ROOT / "contracts" / "fortune" / "fortune-samples.v1.1.json"
DEFAULT_ILLUSTRATION = (
    ROOT / "frontend" / "public" / "static" / "assets" / "hongyeon-share-card.webp"
)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="홍연 정적 부적 공유 카드 SVG 생성기")
    parser.add_argument("--sample", required=True, help="fortune sample meta.seed_hash")
    parser.add_argument("--nickname")
    parser.add_argument("--out", type=Path)
    parser.add_argument("--samples", type=Path, default=DEFAULT_SAMPLES)
    args = parser.parse_args(argv)

    samples = json.loads(args.samples.read_text(encoding="utf-8"))["samples"]
    fortune = next(
        (
            item
            for item in samples
            if item.get("meta", {}).get("seed_hash") == args.sample
        ),
        None,
    )
    if fortune is None:
        parser.error(f"seed_hash를 찾을 수 없습니다: {args.sample}")
    target = args.out or Path(f"share-{args.sample}.svg")
    illustration = (
        DEFAULT_ILLUSTRATION.read_bytes() if DEFAULT_ILLUSTRATION.is_file() else None
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(
        render_share_card_svg(
            fortune, nickname=args.nickname, illustration=illustration
        ),
        encoding="utf-8",
    )
    print(target)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
