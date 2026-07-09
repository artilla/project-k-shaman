# fortune-engine/web — 엔진 웹 파이프라인 (레거시 서버 제거됨)

2026-07-09, ADR-0003에 따라 이 디렉터리의 stdlib HTTP 서버(`server.py`)와 vanilla UI
(`static/index.html`·`app.js`·`styles.css`·`live2d-avatar.js`)를 제거했다.
HTTP 계약은 `backend/`(FastAPI)가 계승하고, 헬퍼는 `backend/core.py`로 승격됐다.
프론트엔드는 `frontend/`(Vite + React + TS)가 대체한다.

## 남아 있는 것

| 파일/디렉터리 | 역할 |
|---|---|
| `pipeline.py` | 운세 생성→narration 조립→TTS 캐시 파이프라인 (`build_playback_response`) |
| `event_timeline.py` | 재생 이벤트 타임라인 검증·지연 요약 (`validate_timeline`, `summarize_latency`) |
| `measure_playback.py` | `state/events/playback_events.jsonl` 분석 CLI |
| `static/assets/` | 캐릭터 정지컷(webp)·share-card 에셋 — backend가 `/static/assets/*`로 서빙 |
| `static/live2d/` | Live2D 벤더 런타임 + 모델 (라이선스: `static/live2d/README.md`) |

## 실행 (신 스택)

```bash
# backend (API + 프로덕션 SPA 서빙)
python -m uvicorn backend.app:app --port 8788
# frontend dev
cd frontend && npm run dev   # http://localhost:5173, /api·/audio·/static 프록시
```

테스트: `tests/test_backend_app.py` (HTTP 계약 + 레거시에서 이관한 고유 커버리지),
`tests/test_web_pipeline.py`·`tests/test_web_event_timeline.py` (엔진 계층, 그대로 유지).
