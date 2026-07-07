#!/usr/bin/env python3
"""T019: 재생 프론트 스켈레톤 로컬 서버.

정적 모바일 페이지(static/) + /api/fortune/today(mock 파이프라인, pipeline.py) +
/api/event(3초 경로 실측 훅, event_timeline.py) + /audio/mock/*(재생 가능한 플레이스홀더 오디오)를
표준 라이브러리 http.server만으로 제공한다 (신규 의존성 없음, 로컬 전용).

실행: python3 fortune-engine/web/server.py [--port 8787]

§3 hold: 이 서버는 항상 mock TTS 백엔드만 사용한다 (OPENAI_API_KEY 유무와 무관) — 티켓
T019은 safe:true(과금 경로 없음)로 선언되어 있으므로, 실 프로바이더 백엔드 선택은 여기서
다루지 않는다(T018에서 이미 구현된 명시적 backend=openai_backend 주입 경로는 그대로 둔다).
"""
import argparse
import hashlib
import json
import logging
import math
import re
import struct
import sys
import wave
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from io import BytesIO
from pathlib import Path
from urllib.parse import parse_qs, urlparse

_WEB_DIR = Path(__file__).resolve().parent
sys.path.insert(0, str(_WEB_DIR))
from pipeline import build_playback_response  # noqa: E402
from event_timeline import summarize_latency, validate_timeline  # noqa: E402

_STATIC_DIR = _WEB_DIR / "static"
_STATE_DIR = _WEB_DIR.parent.parent / "state"
_EVENTS_LOG_PATH = _STATE_DIR / "events" / "playback_events.jsonl"

_logger = logging.getLogger("fortune_engine.web.server")

_SAMPLE_RATE = 22050
_TONE_DURATION_SEC = 2.5
_TONE_FREQ_HZ = 660.0
_KEY_RE = re.compile(r"^[0-9a-f]{16,64}$")

_STATIC_CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8",
    ".js": "application/javascript; charset=utf-8",
    ".css": "text/css; charset=utf-8",
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


def _append_event_log(record: dict) -> None:
    _EVENTS_LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    with _EVENTS_LOG_PATH.open("a", encoding="utf-8") as f:
        f.write(json.dumps(record, ensure_ascii=False) + "\n")


class _Handler(BaseHTTPRequestHandler):
    server_version = "FortuneWebSkeleton/0.1"

    def log_message(self, fmt, *args):  # noqa: A003
        _logger.info("%s - %s", self.address_string(), fmt % args)

    def _send_json(self, status: int, payload: dict) -> None:
        body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _send_bytes(self, status: int, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def _serve_static(self, rel_path: str) -> None:
        rel_path = rel_path.lstrip("/") or "index.html"
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
            "date": query.get("date", ["2026-01-01"])[0],
            "topic": query.get("topic", ["total"])[0],
            "character_id": query.get("character_id", ["hongyeon"])[0],
        }
        for field in ("birth_year", "birth_month", "birth_day", "birth_hour"):
            if field in query:
                request[field] = int(query[field][0])

        result = build_playback_response(request)
        audio_url = _mock_audio_url_for(result["tts"]["cacheKey"])
        self._send_json(200, {**result, "audioUrl": audio_url})

    def _handle_audio_mock(self, key_hash: str) -> None:
        if not _KEY_RE.match(key_hash):
            self._send_json(404, {"error": "invalid audio key"})
            return
        self._send_bytes(200, "audio/wav", _mock_placeholder_wav())

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
        elif parsed.path.startswith("/audio/mock/") and parsed.path.endswith(".wav"):
            key_hash = parsed.path[len("/audio/mock/"):-len(".wav")]
            self._handle_audio_mock(key_hash)
        elif parsed.path == "/" or parsed.path.startswith("/static/") or parsed.path == "/index.html":
            rel = "index.html" if parsed.path in ("/", "/index.html") else parsed.path[len("/static/"):]
            self._serve_static(rel)
        else:
            self._send_json(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/event":
            self._handle_event()
        else:
            self._send_json(404, {"error": "not found"})


def make_server(address=("127.0.0.1", 8787)) -> ThreadingHTTPServer:
    """(host, port) bind만 하고 serve_forever는 호출하지 않는다 — 테스트/CLI 공용 팩토리."""
    return ThreadingHTTPServer(address, _Handler)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8787)
    args = parser.parse_args()

    httpd = make_server(("127.0.0.1", args.port))
    print(f"fortune-engine web skeleton: http://127.0.0.1:{args.port}")
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        httpd.server_close()


if __name__ == "__main__":
    main()
