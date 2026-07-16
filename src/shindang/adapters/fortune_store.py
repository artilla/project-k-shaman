"""최근 운세를 공유 카드 요청과 연결하는 bounded 메모리 어댑터."""

from __future__ import annotations

from collections import OrderedDict
import threading


class RecentFortuneStore:
    def __init__(self, max_items: int = 500) -> None:
        self.max_items = max_items
        self._data: OrderedDict[str, dict] = OrderedDict()
        self._guard = threading.RLock()

    def put(self, fortune_id: str, fortune: dict) -> None:
        with self._guard:
            self._data[fortune_id] = fortune
            self._data.move_to_end(fortune_id)
            while len(self._data) > self.max_items:
                self._data.popitem(last=False)

    def get(self, fortune_id: str) -> dict | None:
        with self._guard:
            return self._data.get(fortune_id)

    def __len__(self) -> int:
        with self._guard:
            return len(self._data)
