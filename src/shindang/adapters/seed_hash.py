"""개인화 seed를 평문 복원이 불가능한 HMAC으로 만드는 어댑터."""

from __future__ import annotations

import hashlib
import hmac
from collections.abc import Callable

_KEY_DERIVATION_CONTEXT = b"shindang/profile-hash-key/v1"


def profile_hash_fn(secret: str) -> Callable[[str], str]:
    """세션 secret에서 용도 분리된 키를 파생해 문자열 HMAC 함수를 반환한다."""
    key = hmac.new(
        secret.encode("utf-8"), _KEY_DERIVATION_CONTEXT, hashlib.sha256
    ).digest()

    def digest(value: str) -> str:
        return hmac.new(key, value.encode("utf-8"), hashlib.sha256).hexdigest()

    return digest
