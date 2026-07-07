# 재생 프론트 스켈레톤 (T019)

홍연 운세 1회를 "탭 → 텍스트 먼저 → 음성 재생"으로 끝까지 체험하는 최소 모바일 웹 페이지.

## 실행

```bash
python3 fortune-engine/web/server.py
```

`http://127.0.0.1:8787`를 모바일 뷰포트(또는 브라우저 개발자 도구의 모바일 에뮬레이션)로 연다.
`--port <N>`으로 포트를 바꿀 수 있다.

## 구성

- `server.py` — 표준 라이브러리 `http.server`만 사용하는 로컬 서버. 정적 페이지, `/api/fortune/today`
  (mock 파이프라인), `/api/event`(3초 경로 실측 훅), `/audio/mock/*.wav`(재생 확인용 플레이스홀더
  톤)를 제공한다.
- `pipeline.py` — `fortune_api_mock.get_today_fortune`(seed_builder→narration composer→
  tts_adapter→cache_layer, T012/T014/T016/T018 기연결)을 호출하고 서버 이벤트
  (`tts_generate_start/complete`, `cache_hit/miss`)를 캡처해 함께 반환한다.
- `event_timeline.py` — 서버 이벤트 + 클라이언트 이벤트(`first_text_visible`, `first_audio_play`)를
  합친 세션 타임라인의 스키마 검증과 지연 요약 로그.
- `static/` — 모바일 페이지(`index.html`/`app.js`/`styles.css`). 탭 시 오디오 컨텍스트를 열고
  (자동 재생 금지 전제), 텍스트를 즉시 표시한 뒤 오디오가 준비되는 대로 재생한다.

이 서버는 항상 mock TTS 백엔드만 쓴다 (`OPENAI_API_KEY` 유무와 무관 — T019는 과금 경로 없는
`safe:true` 스켈레톤). 실 프로바이더 연결은 T018에서 별도로 구현되어 있다.
