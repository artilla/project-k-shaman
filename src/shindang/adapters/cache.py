"""캐시 포트의 로컬 메모리·파일 구현."""

from __future__ import annotations

import hashlib
import json
import os
import tempfile
import threading
from pathlib import Path
from typing import Generic, TypeVar

T = TypeVar("T")


class InMemoryCacheStore(Generic[T]):
    def __init__(self) -> None:
        self._data: dict[str, T] = {}
        self._guard = threading.RLock()
        self.hits = 0
        self.misses = 0

    def get(self, key: str) -> T | None:
        with self._guard:
            if key in self._data:
                self.hits += 1
                return self._data[key]
            self.misses += 1
            return None

    def set(self, key: str, value: T) -> None:
        with self._guard:
            self._data[key] = value


class FileCacheStore:
    """단일 호스트 개발용 JSON 캐시. 쓰기는 같은 파일시스템에서 원자적이다."""

    def __init__(self, base_dir: str | Path) -> None:
        self._base_dir = Path(base_dir)
        self._base_dir.mkdir(parents=True, exist_ok=True)
        self.hits = 0
        self.misses = 0

    def _file_path(self, key: str) -> Path:
        return self._base_dir / f"{hashlib.sha256(key.encode()).hexdigest()}.json"

    def get(self, key: str):
        path = self._file_path(key)
        if not path.exists():
            self.misses += 1
            return None
        self.hits += 1
        return json.loads(path.read_text(encoding="utf-8"))

    def set(self, key: str, value) -> None:
        path = self._file_path(key)
        fd, temporary = tempfile.mkstemp(prefix=path.name, dir=path.parent)
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(value, handle, ensure_ascii=False)
                handle.flush()
                os.fsync(handle.fileno())
            os.replace(temporary, path)
        finally:
            if os.path.exists(temporary):
                os.unlink(temporary)
