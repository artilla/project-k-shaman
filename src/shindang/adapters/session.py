"""인메모리 세션 저장소."""

from __future__ import annotations

import threading
from dataclasses import dataclass, field


@dataclass
class InMemorySessionStore:
    _data: dict[str, dict] = field(default_factory=dict)
    _guard: threading.RLock = field(default_factory=threading.RLock)

    def put(self, session_id: str, session: dict) -> None:
        with self._guard:
            self._data[session_id] = session

    def get(self, session_id: str) -> dict | None:
        with self._guard:
            return self._data.get(session_id)

    def delete(self, session_id: str) -> None:
        with self._guard:
            self._data.pop(session_id, None)

    def contains(self, session_id: str) -> bool:
        with self._guard:
            return session_id in self._data

    def clear(self) -> None:
        with self._guard:
            self._data.clear()

    def __len__(self) -> int:
        with self._guard:
            return len(self._data)
