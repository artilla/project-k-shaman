"""Documentation links and unambiguous repository paths stay resolvable."""

from __future__ import annotations

import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

import pytest


ROOT = Path(__file__).parent.parent

MARKDOWN_LINK = re.compile(r"!?\[[^\]]*\]\((?P<target><[^>]+>|[^\s)]+)")
REFERENCE_LINK = re.compile(r"^\s*\[[^\]]+\]:\s*(?P<target><[^>]+>|\S+)")
INLINE_CODE = re.compile(r"(?<!`)`([^`\n]+)`(?!`)")
REPOSITORY_PATH = re.compile(
    r"(?<![A-Za-z0-9_./-])"
    r"(?:\./)?(?:"
    r"Plan\.md|today-shindang-service-plan(?:-v[23])?\.md|docs/runbook\.md|"
    r"(?:mission-control|scripts|skills|tests|backend|fortune-engine)/"
    r"[A-Za-z0-9_./{}*?-]+"
    r")"
)

DOCUMENT_ROOTS = (
    ROOT / "README.md",
    ROOT / "AGENTS.md",
    ROOT / "docs",
    ROOT / "ralph" / "docs",
    ROOT / "ralph" / "skills",
)

# Refactors that changed both a directory and a module name cannot be inferred by
# basename.  Keep the small, reviewed set explicit; directory-preserving moves are
# resolved below from the filesystem.
RENAMED_PRODUCT_PATHS = {
    "backend/app.py": "src/shindang/web/app.py",
    "backend/dream_card.py": "src/shindang/domain/dream_card.py",
    "backend/ratelimit.py": "src/shindang/adapters/rate_limit.py",
    "fortune-engine/cache_layer.py": "src/shindang/application/cache.py",
    "fortune-engine/fortune_api_mock.py": "src/shindang/domain/fortune.py",
    "fortune-engine/seed_builder.py": "src/shindang/domain/seed.py",
    "fortune-engine/share_card.py": "src/shindang/domain/fortune_card.py",
    "fortune-engine/tts_adapter.py": "src/shindang/adapters/tts.py",
    "fortune-engine/validate_fortune.py": "tools/fortune/validate.py",
    "fortune-engine/web/measure_playback.py": "tools/analytics/measure_playback.py",
}

HISTORICAL_PRODUCT_PATH_DOCS = (
    Path("docs/decisions/0003-frontend-backend-separation.md"),
    Path("docs/reports/문서-분석-리포트-2026-05-29.md"),
    Path("docs/tickets/DONE"),
)


def _markdown_files() -> list[Path]:
    files: set[Path] = set()
    for root in DOCUMENT_ROOTS:
        if root.is_file():
            files.add(root)
        elif root.is_dir():
            files.update(root.rglob("*.md"))
    return sorted(files)


def _is_external_or_runtime_target(target: str) -> bool:
    if target.startswith(("#", "/", "//")):
        return True
    parsed = urlsplit(target)
    return bool(parsed.scheme or parsed.netloc)


def _local_link(path: Path, raw_target: str) -> Path | None:
    target = raw_target.strip("<>")
    if _is_external_or_runtime_target(target):
        return None
    target = unquote(target.split("#", 1)[0].split("?", 1)[0])
    if not target:
        return None
    return path.parent / target


def _inline_code(path: Path) -> list[tuple[int, str]]:
    spans: list[tuple[int, str]] = []
    in_fence = False
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if in_fence:
            continue
        spans.extend(
            (line_number, match.group(1)) for match in INLINE_CODE.finditer(line)
        )
    return spans


def _prose_lines(path: Path) -> list[tuple[int, str]]:
    """Return Markdown prose with fenced and inline code removed."""
    lines: list[tuple[int, str]] = []
    in_fence = False
    for line_number, line in enumerate(
        path.read_text(encoding="utf-8").splitlines(), 1
    ):
        if line.lstrip().startswith(("```", "~~~")):
            in_fence = not in_fence
            continue
        if not in_fence:
            lines.append((line_number, INLINE_CODE.sub("", line)))
    return lines


def _is_historical_product_reference(path: Path) -> bool:
    relative = path.relative_to(ROOT)
    return any(
        relative == item or item in relative.parents
        for item in HISTORICAL_PRODUCT_PATH_DOCS
    )


def _relocated_destination(
    reference: str, *, historical_product_path: bool
) -> str | None:
    reference = reference.removeprefix("./").rstrip(".,:;")

    fixed = {
        "Plan.md": "docs/planning/Plan.md",
        "today-shindang-service-plan.md": "docs/planning/today-shindang-service-plan.md",
        "today-shindang-service-plan-v2.md": "docs/planning/today-shindang-service-plan-v2.md",
        "today-shindang-service-plan-v3.md": "docs/planning/today-shindang-service-plan-v3.md",
        "docs/runbook.md": "ralph/docs/runbook.md",
    }
    destination = fixed.get(reference)
    if (
        destination
        and not (ROOT / reference).exists()
        and (ROOT / destination).exists()
    ):
        return destination

    for prefix in ("mission-control/", "scripts/", "skills/", "tests/"):
        if not reference.startswith(prefix):
            continue
        destination = f"ralph/{reference}"
        # `scripts/` and `tests/` also contain product files.  An existing root
        # path always wins, and absent historical Ralph tests remain prose rather
        # than being guessed into a path that does not exist.
        if not (ROOT / reference).exists() and (ROOT / destination).exists():
            return destination

    if historical_product_path:
        return None

    destination = RENAMED_PRODUCT_PATHS.get(reference)
    if (
        destination
        and not (ROOT / reference).exists()
        and (ROOT / destination).exists()
    ):
        return destination

    if reference.startswith("fortune-engine/"):
        suffix = reference.removeprefix("fortune-engine/")
        directory_moves = (
            "contracts/fortune/",
            "docs/product/",
            "docs/prompts/",
            "docs/reports/",
        )
        for directory in directory_moves:
            candidate = f"{directory}{Path(suffix).name}"
            if (ROOT / candidate).exists():
                return candidate

        static_prefix = "web/static/"
        if suffix.startswith(static_prefix):
            candidate = f"frontend/public/static/{suffix.removeprefix(static_prefix)}"
            if (ROOT / candidate).exists():
                return candidate

    return None


def test_markdown_links_and_unambiguous_repository_paths_resolve():
    broken_links: list[str] = []
    stale_paths: list[str] = []

    for path in _markdown_files():
        relative = path.relative_to(ROOT)

        for line_number, line in _prose_lines(path):
            matches = list(MARKDOWN_LINK.finditer(line))
            reference_match = REFERENCE_LINK.match(line)
            if reference_match:
                matches.append(reference_match)
            for match in matches:
                target = match.group("target")
                local = _local_link(path, target)
                if local is not None and not local.exists():
                    broken_links.append(f"{relative}:{line_number} -> {target}")

        historical = _is_historical_product_reference(path)
        for line_number, span in _inline_code(path):
            for match in REPOSITORY_PATH.finditer(span):
                reference = match.group(0)
                destination = _relocated_destination(
                    reference, historical_product_path=historical
                )
                if destination:
                    stale_paths.append(
                        f"{relative}:{line_number} -> {reference} (use {destination})"
                    )

    assert broken_links == [], "broken Markdown links:\n" + "\n".join(broken_links)
    assert stale_paths == [], "stale repository paths:\n" + "\n".join(stale_paths)


@pytest.mark.parametrize(
    ("legacy", "current"),
    (
        ("Plan.md", "docs/planning/Plan.md"),
        ("docs/runbook.md", "ralph/docs/runbook.md"),
        ("mission-control/server.mjs", "ralph/mission-control/server.mjs"),
        ("scripts/run_loop.sh", "ralph/scripts/run_loop.sh"),
        ("skills/reviewer.md", "ralph/skills/reviewer.md"),
        ("tests/smoke.bats", "ralph/tests/smoke.bats"),
        ("backend/app.py", "src/shindang/web/app.py"),
        (
            "fortune-engine/fortune-schema.v1.1.json",
            "contracts/fortune/fortune-schema.v1.1.json",
        ),
    ),
)
def test_known_relocations_are_fail_closed(legacy: str, current: str):
    assert _relocated_destination(legacy, historical_product_path=False) == current


def test_product_script_is_not_misclassified_as_ralph_harness():
    assert (
        _relocated_destination("scripts/db_migrate.sh", historical_product_path=False)
        is None
    )


def test_absent_historical_test_is_not_guessed_as_a_live_path():
    assert (
        _relocated_destination(
            "tests/mission_control_board.bats", historical_product_path=False
        )
        is None
    )
