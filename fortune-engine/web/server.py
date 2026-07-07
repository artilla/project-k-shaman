#!/usr/bin/env python3
"""T019/T020: 재생 프론트 스켈레톤 로컬 서버.

정적 모바일 페이지(static/) + /api/fortune/today(pipeline.py) +
/api/event(3초 경로 실측 훅, event_timeline.py) + /audio/mock/*(재생 가능한 플레이스홀더 오디오) +
/audio/real/*(T020: 실 TTS 합성 오디오 서빙)를 표준 라이브러리 http.server만으로 제공한다
(신규 의존성 없음, 로컬 전용).

실행:
  python3 fortune-engine/web/server.py                       # 기본: mock 고정, 과금 0
  OPENAI_API_KEY=... python3 fortune-engine/web/server.py --backend openai [--presynth]

T020: `--backend openai` 명시 옵트인 + OPENAI_API_KEY 존재 시에만 T018 실백엔드를 주입한다.
기본 실행 경로(플래그 없음)는 T019와 완전히 동일 — mock 고정, 과금 0.
"""
from __future__ import annotations  # T026 fix: `str | None` 주석을 3.9(anaconda 실행 환경)에서도 허용

import argparse
import hashlib
import hmac
import importlib.util
import json
import logging
import math
import os
import re
import secrets
import struct
import sys
import urllib.request
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlencode, urlparse

_WEB_DIR = Path(__file__).resolve().parent
_ENGINE_DIR = _WEB_DIR.parent
sys.path.insert(0, str(_WEB_DIR))
from pipeline import build_playback_response  # noqa: E402
from event_timeline import summarize_latency, validate_timeline  # noqa: E402


def _load_engine_module(name: str):
    spec = importlib.util.spec_from_file_location(name, _ENGINE_DIR / f"{name}.py")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


# T021: T006 정적 부적 렌더러를 실 재생 흐름(GET /api/share-card)에 연결한다.
_share_card = _load_engine_module("share_card")

_STATIC_DIR = _WEB_DIR / "static"
_STATE_DIR = _WEB_DIR.parent.parent / "state"
_EVENTS_LOG_PATH = _STATE_DIR / "events" / "playback_events.jsonl"
_TTS_REAL_CACHE_DIR = _STATE_DIR / "tts_cache"  # tts_adapter.openai_backend와 동일 경로 (T018)

_logger = logging.getLogger("fortune_engine.web.server")

_SAMPLE_RATE = 22050
_TONE_DURATION_SEC = 2.5
_TONE_FREQ_HZ = 660.0
_KEY_RE = re.compile(r"^[0-9a-f]{16,64}$")

_DEFAULT_DATE = "2026-01-01"
_DEFAULT_TOPIC = "total"
_DEFAULT_CHARACTER_ID = "hongyeon"

# T021: 공유 카드는 닉네임을 받지 않는다 (개인정보 최소화) — 항상 이 기본값으로 렌더링한다.
_SHARE_CARD_NICKNAME = "손님"
# fortuneId→fortune 매핑의 세션 범위 상한 — 초과 시 가장 오래된 항목부터 제거 (메모리 누수 방지).
_FORTUNE_CACHE_MAX = 500

# T026: 소셜 로그인 스캐폴드 — 키는 env만, 코드/로그에 원문 금지 (runbook §4).
_OAUTH_PROVIDERS = {
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
_SESSION_COOKIE_NAME = "shindang_session"
_OAUTH_STATE_COOKIE_NAME = "shindang_oauth_state"

_STATIC_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
    ".webp": "image/webp",
    # T025: Live2D 모델 서빙 (model3.json·moc3·텍스처)
    ".json": "application/json; charset=utf-8",
    ".moc3": "application/octet-stream",
    ".png": "image/png",
}

_tone_cache_bytes = None  # 결정적 톤이라 프로세스당 한 번만 생성해 재사용


def _mock_placeholder_wav() -> bytes:
    """짧은 결정적 사인파 톤 WAV — mock 오디오 경로에서 실제로 재생을 확인하기 위한 플레이스홀더.

    실 audioUrl(mock://<cacheKey>)은 재생 불가능한 스킴이므로, 브라우저가 실제로 소리를
    받아 재생할 수 있도록 이 서버가 대신 서빙한다. §3 hold: 실 TTS 오디오 스트리밍은
    별도 티켓(OPENAI_API_KEY 실백엔드 연결 시 file:// 서빙)에서 다룬다.
    """
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
        sample = amp * math.sin(2 * math.pi * _TONE_FREQ_HZ * t)
        frames += struct.pack("<h", int(sample * 32767))

    buf = BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(_SAMPLE_RATE)
        w.writeframes(bytes(frames))
    _tone_cache_bytes = buf.getvalue()
    return _tone_cache_bytes


def _mock_audio_url_for(cache_key: str) -> str:
    key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()[:16]
    return f"/audio/mock/{key_hash}.wav"


def _real_audio_url_for(cache_key: str) -> str:
    """tts_adapter.openai_backend가 state/tts_cache/에 쓰는 파일명과 동일한 해시 규칙(T018)."""
    key_hash = hashlib.sha256(cache_key.encode("utf-8")).hexdigest()
    return f"/audio/real/{key_hash}.mp3"


def _provider_client_id(provider: str) -> str | None:
    cfg = _OAUTH_PROVIDERS.get(provider)
    if not cfg:
        return None
    return os.getenv(cfg["client_id_env"])


def oauth_provider_status() -> dict:
    """provider별 env 키 존재 여부만 반환한다 — 원문 키 값은 응답에 절대 포함하지 않는다."""
    return {name: bool(_provider_client_id(name)) for name in _OAUTH_PROVIDERS}


def build_oauth_authorize_url(provider: str, *, redirect_uri: str, state: str) -> str | None:
    """순수 함수 — 네트워크 호출 없이 리다이렉트 URL 문자열만 조립한다.

    client_id가 없으면(env 미설정) None을 반환한다 — 호출부가 400으로 막는다.
    """
    cfg = _OAUTH_PROVIDERS.get(provider)
    if not cfg:
        return None
    client_id = _provider_client_id(provider)
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


def _extract_profile(provider: str, profile_data: dict) -> dict:
    """provider별 원시 userinfo 응답에서 subject/nickname만 뽑아낸다 (순수 함수, 네트워크 없음)."""
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


def _oauth_token_and_profile(provider: str, code: str, *, redirect_uri: str) -> dict:
    """실 네트워크 2단 호출(토큰 교환→프로필 조회).

    §4 3요소 카브아웃 근거: 미신뢰 입력(code) + 인터넷 접근 + 기밀 데이터(client_secret)가
    동시에 겹치는 유일한 지점이라, 자율 루프는 이 함수를 스스로 호출하지 않는다 — 실행은
    사람이 실 키를 배치한 뒤 실제 브라우저 리다이렉트로만 도달한다. 테스트는 항상 이 함수를
    monkeypatch로 대체한다(runbook §4, T026 위험 완화).
    """
    cfg = _OAUTH_PROVIDERS[provider]
    client_id = _provider_client_id(provider)
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
    with urllib.request.urlopen(profile_req, timeout=10) as resp:  # noqa: S310 — provider 도메인 고정
        profile_data = json.loads(resp.read())

    return _extract_profile(provider, profile_data)


def _parse_cookie_header(header: str) -> dict:
    cookies = {}
    if not header:
        return cookies
    for part in header.split(";"):
        part = part.strip()
        if not part or "=" not in part:
            continue
        key, _, value = part.partition("=")
        cookies[key.strip()] = value.strip()
    return cookies


def _sign_value(value: str, secret: str) -> str:
    return hmac.new(secret.encode("utf-8"), value.encode("utf-8"), hashlib.sha256).hexdigest()


def _make_session_cookie_value(session_id: str, secret: str) -> str:
    return f"{session_id}.{_sign_value(session_id, secret)}"


def _verify_session_cookie_value(cookie_value, secret) -> str | None:
    if not cookie_value or "." not in cookie_value:
        return None
    session_id, _, sig = cookie_value.rpartition(".")
    if not session_id or not sig:
        return None
    if not hmac.compare_digest(_sign_value(session_id, secret), sig):
        return None
    return session_id


def validate_backend_startup(backend: str, *, has_api_key: bool) -> None:
    """`--backend openai` 옵트인인데 키가 없으면 기동 자체를 거부한다 (실수 과금 방지).

    mock(기본값)은 항상 통과한다 — 이 함수는 실백엔드 옵트인 경로에만 관여한다.
    """
    if backend == "openai" and not has_api_key:
        raise RuntimeError(
            "--backend openai requires OPENAI_API_KEY to be set — refusing to start "
            "(no accidental billing on startup)"
        )


def _append_event_log(record: dict) -> None:
    _EVENTS_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with _EVENTS_LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


def _remember_fortune(cache: dict, fortune_id: str, fortune: dict) -> None:
    """fortuneId→fortune 매핑을 세션 범위 상한(_FORTUNE_CACHE_MAX) 안에서 유지한다."""
    cache[fortune_id] = fortune
    if len(cache) > _FORTUNE_CACHE_MAX:
        oldest_key = next(iter(cache))
        del cache[oldest_key]


class _Handler(BaseHTTPRequestHandler):
    server_version = "FortuneWebSkeleton/0.1"

    def log_message(self, fmt, *args):  # noqa: A003
        _logger.info("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, payload: dict, *, extra_headers: dict | None = None) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        for key, value in (extra_headers or {}).items():
            self.send_header(key, value)
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, rel_path: str) -> None:
        # T025: percent-encoded 경로 복원 — Live2D 모델의 비ASCII 파일명(모션/표정)이
        # %XX 인코딩으로 요청된다. 복원 후에도 아래 resolve() 경로 탈출 검사는 그대로 적용.
        rel_path = unquote(rel_path).lstrip("/") or "index.html"
        candidate = (_STATIC_DIR / rel_path).resolve()
        if _STATIC_DIR not in candidate.parents and candidate != _STATIC_DIR:
            self._send_json(404, {"error": "not found"})
            return
        if not candidate.is_file():
            self._send_json(404, {"error": "not found"})
            return
        content_type = _STATIC_CONTENT_TYPES.get(candidate.suffix, "application/octet-stream")
        self._send_bytes(200, content_type, candidate.read_bytes())

    def _handle_fortune_today(self, query: dict) -> None:
        request = {
            "date": query.get("date", [_DEFAULT_DATE])[0],
            "topic": query.get("topic", [_DEFAULT_TOPIC])[0],
            "character_id": query.get("character_id", [_DEFAULT_CHARACTER_ID])[0],
        }
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            if field in query:
                request[field] = int(query[field][0])

        backend_mode = getattr(self.server, "tts_backend_mode", "mock")
        tts_backend = "openai" if backend_mode == "openai" else None
        result = build_playback_response(request, tts_backend=tts_backend)
        cache_key = result["tts"]["cacheKey"]
        audio_url = _real_audio_url_for(cache_key) if backend_mode == "openai" else _mock_audio_url_for(cache_key)
        _remember_fortune(self.server.fortune_cache_by_id, result["fortuneId"], result["fortune"])
        self._send_json(200, {**result, "audioUrl": audio_url})

    def _handle_share_card(self, query: dict) -> None:
        fortune_id = query.get("fortuneId", [None])[0]
        fortune = self.server.fortune_cache_by_id.get(fortune_id) if fortune_id else None
        if fortune is None:
            self._send_json(404, {"error": "fortune not found"})
            return
        svg = _share_card.render_share_card_svg(fortune, nickname=_SHARE_CARD_NICKNAME)
        self._send_bytes(200, "image/svg+xml; charset=utf-8", svg.encode("utf-8"))

    def _handle_auth_providers(self) -> None:
        self._send_json(200, {"providers": oauth_provider_status()})

    def _oauth_redirect_uri(self, provider: str) -> str:
        host = self.headers.get("Host", "127.0.0.1")
        return f"http://{host}/api/auth/callback/{provider}"

    def _handle_auth_login(self, provider: str) -> None:
        if provider not in _OAUTH_PROVIDERS:
            self._send_json(404, {"error": "unknown provider"})
            return
        state = secrets.token_hex(16)
        url = build_oauth_authorize_url(provider, redirect_uri=self._oauth_redirect_uri(provider), state=state)
        if url is None:
            self._send_json(400, {"error": "provider not configured"})
            return
        self.send_response(302)
        self.send_header("Location", url)
        self.send_header(
            "Set-Cookie",
            f"{_OAUTH_STATE_COOKIE_NAME}={state}; Path=/; HttpOnly; SameSite=Lax; Max-Age=600",
        )
        self.end_headers()

    def _handle_auth_callback(self, provider: str, query: dict) -> None:
        if provider not in _OAUTH_PROVIDERS:
            self._send_json(404, {"error": "unknown provider"})
            return
        code = query.get("code", [None])[0]
        if not code:
            self._send_json(400, {"error": "missing code"})
            return
        state = query.get("state", [None])[0]
        expected_state = _parse_cookie_header(self.headers.get("Cookie", "")).get(_OAUTH_STATE_COOKIE_NAME)
        if not state or not expected_state or not hmac.compare_digest(state, expected_state):
            self._send_json(400, {"error": "invalid state"})
            return
        try:
            profile = _oauth_token_and_profile(provider, code, redirect_uri=self._oauth_redirect_uri(provider))
        except Exception:
            _logger.exception("oauth token exchange failed for provider=%s", provider)
            self._send_json(502, {"error": "oauth exchange failed"})
            return
        session_id = secrets.token_hex(16)
        self.server.sessions[session_id] = {"provider": provider, "nickname": profile.get("nickname")}
        cookie_value = _make_session_cookie_value(session_id, self.server.session_secret)
        self.send_response(302)
        self.send_header("Location", "/")
        self.send_header("Set-Cookie", f"{_SESSION_COOKIE_NAME}={cookie_value}; Path=/; HttpOnly; SameSite=Lax")
        self.end_headers()

    def _current_session(self):
        raw = _parse_cookie_header(self.headers.get("Cookie", "")).get(_SESSION_COOKIE_NAME)
        if not raw:
            return None
        session_id = _verify_session_cookie_value(raw, self.server.session_secret)
        if session_id is None:
            return None
        return self.server.sessions.get(session_id)

    def _handle_auth_me(self) -> None:
        session = self._current_session()
        if session is None:
            self._send_json(200, {"loggedIn": False})
            return
        self._send_json(200, {"loggedIn": True, "provider": session["provider"], "nickname": session.get("nickname")})

    def _handle_auth_logout(self) -> None:
        raw = _parse_cookie_header(self.headers.get("Cookie", "")).get(_SESSION_COOKIE_NAME)
        if raw:
            session_id = _verify_session_cookie_value(raw, self.server.session_secret)
            if session_id is not None:
                self.server.sessions.pop(session_id, None)
        self._send_json(
            200, {"ok": True},
            extra_headers={"Set-Cookie": f"{_SESSION_COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Lax; Max-Age=0"},
        )

    def _handle_audio_mock(self, key_hash: str) -> None:
        if not _KEY_RE.match(key_hash):
            self._send_json(404, {"error": "invalid audio key"})
            return
        self._send_bytes(200, "audio/wav", _mock_placeholder_wav())

    def _handle_audio_real(self, key_hash: str) -> None:
        if not _KEY_RE.match(key_hash):
            self._send_json(404, {"error": "invalid audio key"})
            return
        path = _TTS_REAL_CACHE_DIR / f"{key_hash}.mp3"
        if not path.is_file():
            self._send_json(404, {"error": "audio not found"})
            return
        self._send_bytes(200, "audio/mpeg", path.read_bytes())

    def _handle_event(self) -> None:
        length = int(self.headers.get("Content-Length", "0"))
        raw = self.rfile.read(length) if length else b"{}"
        try:
            payload = json.loads(raw)
        except json.JSONDecodeError:
            self._send_json(400, {"error": "invalid JSON body"})
            return

        client_events = payload.get("clientEvents", [])
        server_events = payload.get("serverEvents", [])
        merged = [*server_events, *client_events]

        missing = validate_timeline(merged)
        summary = summarize_latency(merged, session_start_ms=payload.get("sessionStartMs", 0))
        _append_event_log({
            "fortuneId": payload.get("fortuneId"),
            "events": merged,
            "summary": summary,
        })
        self._send_json(200, {"ok": True, "missing": missing, "summary": summary})

    def do_GET(self):  # noqa: N802
        parsed = urlparse(self.path)
        query = parse_qs(parsed.query)

        if parsed.path == "/api/fortune/today":
            self._handle_fortune_today(query)
        elif parsed.path == "/api/share-card":
            self._handle_share_card(query)
        elif parsed.path == "/api/auth/providers":
            self._handle_auth_providers()
        elif parsed.path.startswith("/api/auth/login/"):
            self._handle_auth_login(parsed.path[len("/api/auth/login/"):])
        elif parsed.path.startswith("/api/auth/callback/"):
            self._handle_auth_callback(parsed.path[len("/api/auth/callback/"):], query)
        elif parsed.path == "/api/auth/me":
            self._handle_auth_me()
        elif parsed.path.startswith("/audio/mock/") and parsed.path.endswith(".wav"):
            key_hash = parsed.path[len("/audio/mock/"):-len(".wav")]
            self._handle_audio_mock(key_hash)
        elif parsed.path.startswith("/audio/real/") and parsed.path.endswith(".mp3"):
            key_hash = parsed.path[len("/audio/real/"):-len(".mp3")]
            self._handle_audio_real(key_hash)
        elif parsed.path == "/" or parsed.path.startswith("/static/") or parsed.path == "/index.html":
            rel = "index.html" if parsed.path in ("/", "/index.html") else parsed.path[len("/static/"):]
            self._serve_static(rel)
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/event":
            self._handle_event()
        elif parsed.path == "/api/auth/logout":
            self._handle_auth_logout()
        else:
            self._send_json(404, {"error": "not found"})


def make_server(address=("127.0.0.1", 8787), *, backend: str = "mock") -> ThreadingHTTPServer:
    """(host, port) bind만 하고 serve_forever는 호출하지 않는다 — 테스트/CLI 공용 팩토리.

    backend: "mock"(기본값) | "openai" (T020 옵트인 실백엔드 — 호출 전 validate_backend_startup 권장).
    """
    httpd = ThreadingHTTPServer(address, _Handler)
    httpd.tts_backend_mode = backend
    httpd.fortune_cache_by_id = {}
    # T026: 세션은 서버 메모리 + 서명 쿠키만 사용한다(DB 없음, §3 hold) — 프로세스 재시작 시
    # session_secret이 새로 생성되므로 이전 쿠키는 자동으로 무효화된다(잔존물 없음).
    httpd.sessions = {}
    httpd.session_secret = secrets.token_hex(32)
    return httpd


def _presynth_default_seed() -> None:
    """당일 기본 seed(무쿼리 탭 경로와 동일)를 미리 합성해 cache_hit 경로로 3초 목표를 노린다 (T020)."""
    default_request = {
        "date": _DEFAULT_DATE,
        "topic": _DEFAULT_TOPIC,
        "character_id": _DEFAULT_CHARACTER_ID,
    }
    print("presynth: warming default seed cache (real synthesis call, billed)...")
    result = build_playback_response(default_request, tts_backend="openai")
    synth_events = [e for e in result["events"] if e.get("event") == "tts_generate_complete"]
    if synth_events:
        print(f"presynth: new synthesis cost estimate ${synth_events[0]['costUsd']}")
    else:
        print("presynth: cache already warm — no new synthesis")
    print("presynth: done")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    parser.add_argument(
        "--backend", choices=("mock", "openai"), default="mock",
        help="TTS 합성 백엔드. 기본값 mock(과금 0). 'openai'는 명시 옵트인 + OPENAI_API_KEY 필요 (T020).",
    )
    parser.add_argument(
        "--presynth", action="store_true",
        help="--backend openai와 함께 사용 시, 기동 시 기본 seed를 미리 합성해 cache_hit 경로를 준비한다.",
    )
    args = parser.parse_args()

    try:
        validate_backend_startup(args.backend, has_api_key=bool(os.getenv("OPENAI_API_KEY")))
    except RuntimeError as exc:
        print(f"error: {exc}", file=sys.stderr)
        sys.exit(1)

    if args.backend == "openai" and args.presynth:
        _presynth_default_seed()

    httpd = make_server(("127.0.0.1", args.port), backend=args.backend)
    print(f"fortune-engine web skeleton: http://127.0.0.1:{args.port} (backend={args.backend})")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
