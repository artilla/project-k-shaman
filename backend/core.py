"""backend 코어 헬퍼 — 레거시 fortune-engine/web/server.py에서 승격 (ADR-0003 마무리).

승격 시점: 2026-07-09, 레거시 HTTP 서버·vanilla UI 제거와 함께.
엔진 계층(pipeline·event_timeline·share_card 등)은 fortune-engine/에 그대로 두고 import만 한다.
"""
from __future__ import annotations

import hashlib
import hmac
import importlib.util
import json
import math
import os
import struct
import sys
import urllib.request
import wave
from io import BytesIO
from pathlib import Path
from urllib.parse import urlencode

_ROOT = Path(__file__).resolve().parent.parent
_ENGINE_DIR = _ROOT / "fortune-engine"
_WEB_DIR = _ENGINE_DIR / "web"  # pipeline·event_timeline·공용 static 에셋 위치
sys.path.insert(0, str(_WEB_DIR))

from pipeline import build_playback_response  # noqa: E402, F401 — 재수출
from event_timeline import summarize_latency, validate_timeline  # noqa: E402, F401 — 재수출


def _load_engine_module(name: str):
    spec = importlib.util.spec_from_file_location(name, _ENGINE_DIR / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# T021: T006 정적 부적 렌더러 (GET /api/share-card)
share_card = _load_engine_module("share_card")

STATIC_DIR = _WEB_DIR / "static"  # 캐릭터 webp·Live2D 벤더 — 공용 에셋
_STATE_DIR = _ROOT / "state"
EVENTS_LOG_PATH = _STATE_DIR / "events" / "playback_events.jsonl"
TTS_REAL_CACHE_DIR = _STATE_DIR / "tts_cache"  # tts_adapter.openai_backend와 동일 경로 (T018)

_SAMPLE_RATE = 22050
_TONE_DURATION_SEC = 2.5
_TONE_FREQ_HZ = 660.0
KEY_RE = __import__("re").compile(r"^[0-9a-f]{16,64}$")

DEFAULT_DATE = "2026-01-01"
DEFAULT_TOPIC = "total"
DEFAULT_CHARACTER_ID = "hongyeon"

# T021: 공유 카드는 닉네임을 받지 않는다 (개인정보 최소화)
SHARE_CARD_NICKNAME = "손님"
# fortuneId→fortune 매핑의 세션 범위 상한 — 초과 시 가장 오래된 항목부터 제거
FORTUNE_CACHE_MAX = 500

# T026: 소셜 로그인 — 키는 env만, 코드/로그에 원문 금지 (runbook §4)
OAUTH_PROVIDERS = {
    "google": {
        "client_id_env": "GOOGLE_CLIENT_ID",
        "client_secret_env": "GOOGLE_CLIENT_SECRET",
        "authorize_url": "https://accounts.google.com/o/oauth2/v2/auth",
        "token_url": "https://oauth2.googleapis.com/token",
        "userinfo_url": "https://openidconnect.googleapis.com/v1/userinfo",
        "scope": "openid email profile",
    },
    "kakao": {
        "client_id_env": "KAKAO_REST_API_KEY",
        "client_secret_env": "KAKAO_CLIENT_SECRET",
        "authorize_url": "https://kauth.kakao.com/oauth/authorize",
        "token_url": "https://kauth.kakao.com/oauth/token",
        "userinfo_url": "https://kapi.kakao.com/v2/user/me",
        "scope": "profile_nickname",
    },
}
SESSION_COOKIE_NAME = "shindang_session"
OAUTH_STATE_COOKIE_NAME = "shindang_oauth_state"

_tone_cache_bytes: bytes | None = None  # 결정적 톤 — 프로세스당 1회 생성


def mock_placeholder_wav() -> bytes:
    """짧은 결정적 사인파 톤 WAV — mock 오디오 경로 플레이스홀더 (§3 hold: 실 TTS는 별도)."""
    global _tone_cache_bytes
    if _tone_cache_bytes is not None:
        return _tone_cache_bytes
    n_samples = int(_SAMPLE_RATE * _TONE_DURATION_SEC)
    fade_samples = int(_SAMPLE_RATE * 0.05)
    frames = bytearray()
    for i in range(n_samples):
        t = i / _SAMPLE_RATE
        amp = 0.15
        if i < fade_samples:
            amp *= i / fade_samples
        elif i > n_samples - fade_samples:
            amp *= (n_samples - i) / fade_samples
        frames += struct.pack("<h", int(amp * math.sin(2 * math.pi * _TONE_FREQ_HZ * t) * 32767))
    buf = BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(_SAMPLE_RATE)
        w.writeframes(bytes(frames))
    _tone_cache_bytes = buf.getvalue()
    return _tone_cache_bytes


def mock_audio_url_for(cache_key: str) -> str:
    key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:16]
    return f"/audio/mock/{key_hash}.wav"


def real_audio_url_for(cache_key: str) -> str:
    """tts_adapter.openai_backend가 state/tts_cache/에 쓰는 파일명과 동일한 해시 규칙 (T018)."""
    key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
    return f"/audio/real/{key_hash}.mp3"


def provider_client_id(provider: str) -> str | None:
    cfg = OAUTH_PROVIDERS.get(provider)
    if not cfg:
        return None
    return os.getenv(cfg["client_id_env"])


def oauth_provider_status() -> dict:
    """provider별 env 키 존재 여부만 반환 — 원문 키 값은 응답에 절대 포함하지 않는다."""
    return {name: bool(provider_client_id(name)) for name in OAUTH_PROVIDERS}


def build_oauth_authorize_url(provider: str, *, redirect_uri: str, state: str) -> str | None:
    """순수 함수 — 네트워크 없이 리다이렉트 URL만 조립. client_id 없으면 None(호출부 400)."""
    cfg = OAUTH_PROVIDERS.get(provider)
    if not cfg:
        return None
    client_id = provider_client_id(provider)
    if not client_id:
        return None
    params = {
        "client_id": client_id,
        "redirect_uri": redirect_uri,
        "response_type": "code",
        "scope": cfg["scope"],
        "state": state,
    }
    return f"{cfg['authorize_url']}?{urlencode(params)}"


def extract_profile(provider: str, profile_data: dict) -> dict:
    """provider별 userinfo에서 subject/nickname만 추출 (순수 함수)."""
    if provider == "google":
        return {
            "subject": profile_data.get("sub"),
            "nickname": profile_data.get("name") or profile_data.get("given_name"),
        }
    if provider == "kakao":
        nickname = profile_data.get("kakao_account", {}).get("profile", {}).get("nickname")
        subject = profile_data.get("id")
        return {"subject": str(subject) if subject is not None else None, "nickname": nickname}
    return {"subject": None, "nickname": None}


def oauth_token_and_profile(provider: str, code: str, *, redirect_uri: str) -> dict:
    """실 네트워크 2단 호출(토큰 교환→프로필 조회).

    §4 3요소 카브아웃: 미신뢰 입력(code)+인터넷+기밀(client_secret)이 겹치는 유일한 지점 —
    자율 루프는 이 함수를 직접 호출하지 않고, 테스트는 항상 monkeypatch로 대체한다 (runbook §4).
    """
    cfg = OAUTH_PROVIDERS[provider]
    client_id = provider_client_id(provider)
    client_secret = os.getenv(cfg["client_secret_env"]) if cfg.get("client_secret_env") else None
    token_body = urlencode({
        "grant_type": "authorization_code",
        "client_id": client_id or "",
        "client_secret": client_secret or "",
        "redirect_uri": redirect_uri,
        "code": code,
    }).encode("utf-8")
    token_req = urllib.request.Request(cfg["token_url"], data=token_body, method="POST")
    with urllib.request.urlopen(token_req, timeout=10) as resp:  # noqa: S310 — provider 도메인 고정
        token_data = json.loads(resp.read())
    profile_req = urllib.request.Request(
        cfg["userinfo_url"],
        headers={"Authorization": f"Bearer {token_data.get('access_token', '')}"},
    )
    with urllib.request.urlopen(profile_req, timeout=10) as resp:  # noqa: S310
        profile_data = json.loads(resp.read())
    return extract_profile(provider, profile_data)


def sign_value(value: str, secret: str) -> str:
    return hmac.new(secret.encode("utf-8"), value.encode("utf-8"), hashlib.sha256).hexdigest()


def make_session_cookie_value(session_id: str, secret: str) -> str:
    return f"{session_id}.{sign_value(session_id, secret)}"


def verify_session_cookie_value(cookie_value, secret) -> str | None:
    if not cookie_value or "." not in cookie_value:
        return None
    session_id, _, sig = cookie_value.rpartition(".")
    if not session_id or not sig:
        return None
    if not hmac.compare_digest(sign_value(session_id, secret), sig):
        return None
    return session_id


def remember_fortune(cache: dict, fortune_id: str, fortune: dict) -> None:
    """fortuneId→fortune 매핑을 상한(FORTUNE_CACHE_MAX) 안에서 유지 (메모리 누수 방지)."""
    cache[fortune_id] = fortune
    while len(cache) > FORTUNE_CACHE_MAX:
        cache.pop(next(iter(cache)))


def append_event_log(record: dict) -> None:
    EVENTS_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with EVENTS_LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def validate_backend_startup(backend: str, *, has_api_key: bool) -> None:
    """`openai` 옵트인인데 키가 없으면 기동 거부 (실수 과금 방지). mock은 항상 통과."""
    if backend == "openai" and not has_api_key:
        raise RuntimeError(
            "TTS_BACKEND=openai requires OPENAI_API_KEY to be set — refusing to start "
            "(no accidental billing on startup)"
        )


def presynth_default_seed() -> None:
    """당일 기본 seed를 미리 합성해 cache_hit 경로로 3초 목표를 노린다 (T020, 과금 주의)."""
    default_request = {
        "date": DEFAULT_DATE,
        "topic": DEFAULT_TOPIC,
        "character_id": DEFAULT_CHARACTER_ID,
    }
    print("presynth: warming default seed cache (real synthesis call, billed)...")
    result = build_playback_response(default_request, tts_backend="openai")
    synth_events = [e for e in result["events"] if e.get("event") == "tts_generate_complete"]
    if synth_events:
        print(f"presynth: new synthesis cost estimate ${synth_events[0]['costUsd']}")
    else:
        print("presynth: cache already warm — no new synthesis")
    print("presynth: done")
