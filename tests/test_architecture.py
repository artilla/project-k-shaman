"""모듈러 모놀리스 의존성 방향과 composition root 보안 계약."""

from __future__ import annotations

import ast
import hashlib
import hmac
import tomllib
from dataclasses import FrozenInstanceError
from pathlib import Path

import pytest

from shindang.adapters.seed_hash import profile_hash_fn
from shindang.config import Settings

ROOT = Path(__file__).parent.parent
PACKAGE_ROOT = ROOT / "src" / "shindang"

FORBIDDEN_IMPORTS = {
    "domain": (
        "shindang.application",
        "shindang.adapters",
        "shindang.web",
        "shindang.bootstrap",
        "shindang.config",
    ),
    "application": ("shindang.adapters", "shindang.web", "shindang.bootstrap"),
    "adapters": ("shindang.web", "shindang.bootstrap"),
}

DOMAIN_FORBIDDEN_IMPORTS = (
    # Environment and filesystem access.
    "os",
    "pathlib",
    # Network clients and protocols.  Pure URL parsing (urllib.parse) is not I/O.
    "aiohttp",
    "boto3",
    "botocore",
    "ftplib",
    "grpc",
    "http.client",
    "httpx",
    "imaplib",
    "openai",
    "poplib",
    "redis",
    "requests",
    "smtplib",
    "socket",
    "telnetlib",
    "urllib.request",
    "websockets",
    # HTTP and persistence frameworks belong outside the domain.
    "django",
    "fastapi",
    "flask",
    "psycopg",
    "sqlalchemy",
    "starlette",
)

FORBIDDEN_CLOCK_REFERENCES = {
    "datetime.date.today",
    "datetime.datetime.now",
    "datetime.datetime.today",
    "datetime.datetime.utcnow",
    "time.monotonic",
    "time.monotonic_ns",
    "time.perf_counter",
    "time.perf_counter_ns",
    "time.sleep",
    "time.time",
    "time.time_ns",
}


def _syntax_tree(path: Path) -> ast.Module:
    return ast.parse(path.read_text(encoding="utf-8"), filename=str(path))


def _module_name(path: Path) -> str:
    relative = path.relative_to(PACKAGE_ROOT).with_suffix("")
    parts = ["shindang", *relative.parts]
    if parts[-1] == "__init__":
        parts.pop()
    return ".".join(parts)


def _package_name(path: Path) -> str:
    module = _module_name(path)
    return module if path.name == "__init__.py" else module.rpartition(".")[0]


def _from_import_base(path: Path, node: ast.ImportFrom) -> str:
    if node.level == 0:
        return node.module or ""

    package_parts = _package_name(path).split(".")
    parents = node.level - 1
    if parents >= len(package_parts):
        return ""
    base_parts = package_parts[: len(package_parts) - parents]
    if node.module:
        base_parts.extend(node.module.split("."))
    return ".".join(base_parts)


def _imports(path: Path, tree: ast.Module | None = None) -> set[str]:
    tree = tree or _syntax_tree(path)
    names: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            names.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom):
            base = _from_import_base(path, node)
            if not base:
                continue
            names.add(base)
            names.update(
                f"{base}.{alias.name}" for alias in node.names if alias.name != "*"
            )
    return names


def _matches_module(imported: str, forbidden: str) -> bool:
    return imported == forbidden or imported.startswith(f"{forbidden}.")


def _import_bindings(path: Path, tree: ast.Module) -> dict[str, str]:
    bindings: dict[str, str] = {}
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            for alias in node.names:
                if alias.asname:
                    bindings[alias.asname] = alias.name
                else:
                    root = alias.name.partition(".")[0]
                    bindings[root] = root
        elif isinstance(node, ast.ImportFrom):
            base = _from_import_base(path, node)
            if not base:
                continue
            for alias in node.names:
                if alias.name == "*":
                    continue
                bindings[alias.asname or alias.name] = f"{base}.{alias.name}"
    return bindings


def _dotted_name(node: ast.expr) -> str | None:
    parts: list[str] = []
    while isinstance(node, ast.Attribute):
        parts.append(node.attr)
        node = node.value
    if not isinstance(node, ast.Name):
        return None
    parts.append(node.id)
    return ".".join(reversed(parts))


def _qualified_name(node: ast.expr, bindings: dict[str, str]) -> str | None:
    dotted = _dotted_name(node)
    if dotted is None:
        return None
    first, separator, remainder = dotted.partition(".")
    resolved = bindings.get(first)
    if resolved is None:
        return None
    return resolved + (separator + remainder if separator else "")


def _adapter_classes() -> set[str]:
    classes: set[str] = set()
    for path in (PACKAGE_ROOT / "adapters").rglob("*.py"):
        module = _module_name(path)
        for node in _syntax_tree(path).body:
            if isinstance(node, ast.ClassDef):
                classes.add(f"{module}.{node.name}")
    return classes


@pytest.mark.parametrize("layer,forbidden", FORBIDDEN_IMPORTS.items())
def test_dependencies_point_inward(layer: str, forbidden: tuple[str, ...]):
    violations: list[str] = []
    for path in (PACKAGE_ROOT / layer).rglob("*.py"):
        for imported in _imports(path):
            if any(_matches_module(imported, name) for name in forbidden):
                violations.append(f"{path.relative_to(ROOT)} -> {imported}")
    assert violations == []


def test_domain_does_not_depend_on_environment_filesystem_network_or_frameworks():
    violations: list[str] = []
    for path in (PACKAGE_ROOT / "domain").rglob("*.py"):
        for imported in _imports(path):
            if any(
                _matches_module(imported, forbidden)
                for forbidden in DOMAIN_FORBIDDEN_IMPORTS
            ):
                violations.append(f"{path.relative_to(ROOT)} -> {imported}")
    assert violations == []


def test_domain_does_not_read_the_clock_directly():
    violations: list[str] = []
    for path in (PACKAGE_ROOT / "domain").rglob("*.py"):
        tree = _syntax_tree(path)
        bindings = _import_bindings(path, tree)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Attribute):
                continue
            reference = _qualified_name(node, bindings)
            if reference in FORBIDDEN_CLOCK_REFERENCES:
                violations.append(
                    f"{path.relative_to(ROOT)}:{node.lineno} -> {reference}"
                )
    assert violations == []


def test_only_bootstrap_wires_concrete_adapters():
    concrete_classes = _adapter_classes()
    violations: list[str] = []
    for path in PACKAGE_ROOT.rglob("*.py"):
        if path == PACKAGE_ROOT / "bootstrap.py":
            continue

        tree = _syntax_tree(path)
        bindings = _import_bindings(path, tree)
        source_module = _module_name(path)
        for node in ast.walk(tree):
            if not isinstance(node, ast.Call):
                continue
            target = _qualified_name(node.func, bindings)
            if target is None:
                continue
            concrete = next(
                (
                    name
                    for name in concrete_classes
                    if target == name or target.startswith(f"{name}.")
                ),
                None,
            )
            if concrete is None:
                continue
            # An adapter may use its own implementation internally; connecting a
            # concrete adapter to another layer or adapter is composition wiring.
            if source_module == concrete.rpartition(".")[0]:
                continue
            violations.append(f"{path.relative_to(ROOT)}:{node.lineno} -> {target}")
    assert violations == []


def test_runtime_package_uses_src_layout():
    assert PACKAGE_ROOT.is_dir()
    assert not (ROOT / "backend").joinpath("app.py").exists()
    assert not (ROOT / "fortune-engine").joinpath("fortune_api_mock.py").exists()


def test_runtime_lock_matches_pyproject_direct_dependencies():
    project = tomllib.loads((ROOT / "pyproject.toml").read_text(encoding="utf-8"))[
        "project"
    ]
    direct = {}
    for requirement in project["dependencies"]:
        name, version = requirement.split("==", 1)
        direct[name.lower().replace("_", "-")] = version

    locked = {}
    for line in (ROOT / "requirements.lock").read_text(encoding="utf-8").splitlines():
        if line and not line.startswith((" ", "#", "-")) and "==" in line:
            name, remainder = line.split("==", 1)
            locked[name.lower().replace("_", "-")] = remainder.split()[0].rstrip(" \\")

    assert {name: locked.get(name) for name in direct} == direct


def test_profile_hash_is_keyed_and_domain_separated():
    first = profile_hash_fn("a" * 32)("1990-03-15:morning")
    second = profile_hash_fn("b" * 32)("1990-03-15:morning")
    plain = hashlib.sha256(b"1990-03-15:morning").hexdigest()
    session_hmac = hmac.new(
        b"a" * 32, b"1990-03-15:morning", hashlib.sha256
    ).hexdigest()
    assert first != second
    assert first not in {plain, session_hmac}


def test_settings_are_immutable_and_hide_secrets(monkeypatch):
    monkeypatch.setenv("SHINDANG_ENV", "test")
    monkeypatch.setenv("SESSION_SECRET", "do-not-leak-this-secret")
    monkeypatch.setenv("DATABASE_URL", "postgresql://user:password@example.invalid/db")
    settings = Settings.from_env(tts_backend="mock")
    assert "do-not-leak-this-secret" not in repr(settings)
    assert "password" not in repr(settings)
    with pytest.raises(FrozenInstanceError):
        settings.environment = "production"


def test_deployed_session_secret_requires_256_bits_worth_of_text(monkeypatch):
    monkeypatch.setenv("SHINDANG_ENV", "production")
    monkeypatch.setenv("SHINDANG_PUBLIC_BASE_URL", "https://example.invalid")
    monkeypatch.setenv("SESSION_SECRET", "too-short")
    with pytest.raises(RuntimeError, match="at least 32"):
        Settings.from_env(tts_backend="mock")
