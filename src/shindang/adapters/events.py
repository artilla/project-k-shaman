"""JSONL 이벤트 저장 어댑터."""

from __future__ import annotations

import json
import threading
from pathlib import Path


class JsonlEventRepository:
    def __init__(self, path: Path) -> None:
        self.path = path
        self._guard = threading.Lock()

    def append(self, record: dict) -> None:
        line = json.dumps(record, ensure_ascii=False) + "\n"
        with self._guard:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as handle:
                handle.write(line)
