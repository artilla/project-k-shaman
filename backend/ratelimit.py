"""인메모리 rate limiter — P0 비용 방어 (Plan.md 백로그 "rate limit과 하루 1회 무료 사용 제한").

고정 윈도우 카운터. 단일 인스턴스 전제 — 다중 인스턴스/재시작 내구성이 필요해지면
Redis로 이전한다 (docs/research/production-readiness.md §3).

식별자 정책: 로그인 세션이 있으면 session_id, 없으면 클라이언트 IP.
프록시 뒤에서는 TRUST_PROXY=1일 때만 X-Forwarded-For 첫 홉을 신뢰한다.
"""
from __future__ import annotations

import os
import time

# 엔드포인트별 기본 한도 — env로 조정 가능 (테스트·운영 튜닝)
def _int_env(name: str, default: int) -> int:
    try:
        return int(os.getenv(name, str(default)))
    except ValueError:
        return default


LIMITS = {
    # (요청 수, 윈도우 초). 운세·꿈은 LLM 도입 시 최대 비용 엔드포인트.
    "fortune": (_int_env("RL_FORTUNE_PER_HOUR", 30), 3600),
    "dream": (_int_env("RL_DREAM_PER_HOUR", 10), 3600),
    "login": (_int_env("RL_LOGIN_PER_10MIN", 10), 600),
    "event": (_int_env("RL_EVENT_PER_HOUR", 120), 3600),
}

# 일일 사용 상한 (UTC 자정 기준 고정 윈도우) — "하루 N회" 제품 정책.
# 운세는 주제 5종 탐색을 허용하는 수준, 꿈 해몽은 "하루 여러 번" 카피와 일관되게 여유 있게.
DAILY_LIMITS = {
    "fortune-daily": _int_env("FORTUNE_DAILY_LIMIT", 5),
    "dream-daily": _int_env("DREAM_DAILY_LIMIT", 10),
}

EVENT_BODY_MAX_BYTES = _int_env("EVENT_BODY_MAX_BYTES", 32 * 1024)


class MemoryRateLimiter:
    """고정 윈도우 카운터. key = (scope, identity, window_start)."""

    def __init__(self) -> None:
        self._buckets: dict[tuple, int] = {}
        self._last_sweep = 0.0

    def _sweep(self, now: float) -> None:
        # 기회적 정리 — 만료 윈도우 버킷 제거 (메모리 상한 유지)
        if now - self._last_sweep < 60:
            return
        self._last_sweep = now
        expired = [k for k in self._buckets if k[3] < now]
        for k in expired:
            self._buckets.pop(k, None)

    def check(self, scope: str, identity: str, limit: int, window_sec: int) -> tuple[bool, int]:
        """(허용 여부, Retry-After 초). 허용 시 카운트를 증가시킨다."""
        now = time.time()
        self._sweep(now)
        window_start = int(now // window_sec) * window_sec
        window_end = window_start + window_sec
        key = (scope, identity, window_start, window_end)
        count = self._buckets.get(key, 0)
        if count >= limit:
            return False, max(1, int(window_end - now))
        self._buckets[key] = count + 1
        return True, 0


def client_identity(request, session_id: str | None) -> str:
    """세션 우선, 없으면 IP. 프록시 신뢰는 TRUST_PROXY=1 옵트인."""
    if session_id:
        return "s:" + session_id
    if os.getenv("TRUST_PROXY") == "1":
        forwarded = request.headers.get("x-forwarded-for")
        if forwarded:
            return "ip:" + forwarded.split(",")[0].strip()
    client = getattr(request, "client", None)
    return "ip:" + (client.host if client else "unknown")
