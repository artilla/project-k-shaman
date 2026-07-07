"""T019: web/server.py 스모크 테스트 — 브라우저 없이 검증 가능한 HTTP 계약만 확인한다.

수용 기준 매핑:
- 탭 이후 흐름(텍스트→오디오)은 브라우저 스크립트(static/app.js) 영역이라 여기서 다루지 않는다.
- 이 파일은 서버가 내보내는 계약(JSON 엔벨로프, 재생 가능한 오디오 응답, 이벤트 수집 엔드포인트,
  정적 페이지 서빙)이 실제로 성립하는지를 검증한다.
"""
import importlib.util
import json
import threading
import urllib.error
import urllib.request
from pathlib import Path

ROOT = Path(__file__).parent.parent
SERVER_PATH = ROOT / "fortune-engine" / "web" / "server.py"

_spec = importlib.util.spec_from_file_location("t019_web_server", SERVER_PATH)
web_server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(web_server)


def _start_server():
    httpd = web_server.make_server(("127.0.0.1", 0))
    thread = threading.Thread(target=httpd.serve_forever, daemon=True)
    thread.start()
    return httpd, thread


def _url(httpd, path):
    port = httpd.server_address[1]
    return f"http://127.0.0.1:{port}{path}"


def _stop(httpd, thread):
    httpd.shutdown()
    thread.join(timeout=2)
    httpd.server_close()


class TestFortuneEndpoint:
    def test_returns_json_envelope_with_playable_audio_url(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                assert resp.status == 200
                data = json.loads(resp.read())
            for key in ("fortuneId", "script", "audioUrl", "durationSec", "events"):
                assert key in data, f"'{key}' 키 누락"
            assert data["audioUrl"].startswith("/audio/mock/"), (
                f"audioUrl이 재생 가능한 로컬 경로가 아님: {data['audioUrl']!r}"
            )
        finally:
            _stop(httpd, thread)

    def test_revisit_same_seed_reuses_audio_url_and_skips_new_synthesis(self):
        httpd, thread = _start_server()
        try:
            path = "/api/fortune/today?topic=love&date=2026-07-07&character_id=hongyeon"
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                first = json.loads(resp.read())
            with urllib.request.urlopen(_url(httpd, path)) as resp:
                second = json.loads(resp.read())

            assert first["audioUrl"] == second["audioUrl"]
            second_names = [e["event"] for e in second["events"]]
            assert "tts_generate_start" not in second_names, "재방문인데 신규 합성 발생"
            assert "cache_hit" in second_names
        finally:
            _stop(httpd, thread)


class TestAudioEndpoint:
    def test_audio_endpoint_serves_playable_wav(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())
            with urllib.request.urlopen(_url(httpd, data["audioUrl"])) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type") == "audio/wav"
                body = resp.read()
            assert body[:4] == b"RIFF", "유효한 WAV 헤더가 아님"
            assert len(body) > 44
        finally:
            _stop(httpd, thread)

    def test_invalid_audio_key_rejected(self):
        httpd, thread = _start_server()
        try:
            try:
                urllib.request.urlopen(_url(httpd, "/audio/mock/../../etc-passwd.wav"))
                raised = False
            except urllib.error.HTTPError as e:
                raised = True
                assert e.code == 404
            assert raised
        finally:
            _stop(httpd, thread)


class TestEventEndpoint:
    def test_post_event_round_trip(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/api/fortune/today?topic=love&date=2026-07-07")) as resp:
                data = json.loads(resp.read())

            payload = json.dumps({
                "fortuneId": data["fortuneId"],
                "sessionStartMs": 0,
                "clientEvents": [
                    {"event": "first_text_visible", "clientTs": 100},
                    {"event": "first_audio_play", "clientTs": 300},
                ],
                "serverEvents": data["events"],
            }).encode("utf-8")
            req = urllib.request.Request(
                _url(httpd, "/api/event"), data=payload,
                headers={"Content-Type": "application/json"}, method="POST",
            )
            with urllib.request.urlopen(req) as resp:
                assert resp.status == 200
                result = json.loads(resp.read())
            assert result["missing"] == []
            assert result["summary"]["textLatencyMs"] == 100
            assert result["summary"]["audioLatencyMs"] == 300
        finally:
            _stop(httpd, thread)


class TestStaticPage:
    def test_index_html_served_at_root(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/")) as resp:
                assert resp.status == 200
                assert resp.headers.get("Content-Type", "").startswith("text/html")
                body = resp.read().decode("utf-8")
            assert "<html" in body.lower()
            assert "start-btn" in body
        finally:
            _stop(httpd, thread)

    def test_app_js_served(self):
        httpd, thread = _start_server()
        try:
            with urllib.request.urlopen(_url(httpd, "/static/app.js")) as resp:
                assert resp.status == 200
                assert "javascript" in resp.headers.get("Content-Type", "")
        finally:
            _stop(httpd, thread)
