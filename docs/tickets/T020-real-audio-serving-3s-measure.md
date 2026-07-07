---
id: T020
title: 실 TTS 오디오 서빙 + 3초 재생 경로 실측 — E2E 베타 데모 실경로 완성
status: open
priority: P1
safe: false              # 실 프로바이더 과금 호출 경로 (T018과 동일, master-spec §3 hold) — 실행엔 승인 마커 필요.
persona: implementer
estimate: M
depends_on: ["T018", "T019"]
blocks: []
labels: ["feature", "playback", "tts", "metrics", "cost"]
created: 2026-07-07
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T020 — 실 TTS 오디오 서빙 + 3초 경로 실측

## 1. 목표 (한 줄)
> T019 스켈레톤의 mock 톤을 실 TTS 오디오로 교체 가능하게 하고(옵트인), §1.6-② "탭→첫 재생 3초" 경로를 실경로에서 실측해 기록한다 — 마일스톤 ③ E2E 베타 데모의 소리가 진짜가 된다.

## 2. 컨텍스트

- T018: `tts_adapter`에 OpenAI `gpt-4o-mini-tts(coral)` 실백엔드 구현 완료 (명시적 `backend=` 주입, 캐시 miss에서만 신규합성).
- T019: 재생 프론트 스켈레톤 — 단 서버(`fortune-engine/web/server.py`)는 **항상 mock**이고, 오디오는 재생 확인용 사인파 톤. server.py 주석에 "실 TTS 오디오 스트리밍은 별도 티켓" 명시 — 이 티켓이 그것.
- 3초 실측 훅(`first_text_visible`·`first_audio_play`·`tts_generate_*`·`cache_hit/miss`)은 T019에 있음. mock 경로 지연은 무의미 — 실합성/실캐시 경로 실측이 남았다.

## 3. 변경 범위 (Scope)

**포함**
- `fortune-engine/web/server.py`: `--backend openai` **명시 옵트인 플래그** (기본은 지금처럼 mock 고정).
  옵트인 + `OPENAI_API_KEY` 존재 시에만 T018 실백엔드 주입, 합성 산출물을 `state/tts_cache/`에서
  `/audio/real/<key>.mp3`(또는 wav)로 서빙. 키 원문·응답 원문 로그 금지 (runbook §4) 유지.
- presynth: 서버 기동 시(또는 첫 요청 전) 당일 seed 사전합성 옵션 — cache_hit 경로로 3초 목표 달성이 설계 전제(v3 §13).
- 실측 리포트: 세션 이벤트 로그(`state/events/playback_events.jsonl`)에서 `tap→first_text_visible`·`tap→first_audio_play` 지연 + cache_hit/miss + 신규합성 비용 추정을 요약하는 스크립트(또는 서버 endpoint) — §1.6-② 실측치와 베타 임계값(캐시 히트율 70%, ≤$0.01/세션) 대비 기록.
- 테스트: 키 없는 환경 전부 GREEN(실호출 계약 테스트는 skip, T018 관례), mock 경로 무회귀. 실백엔드 주입 분기는 mock backend 주입으로 단위 검증.

**제외 (Non-goals)**
- T006 공유카드 프론트 연결(후속 티켓), 캐릭터 모션/연출, PWA·배포(§3 hold), 오디오 스트리밍 최적화(범위는 파일 서빙까지).

## 4. 수용 기준 (Acceptance Criteria)
- [ ] 기본 실행(`python3 fortune-engine/web/server.py`)은 기존과 완전 동일 (mock 고정, 과금 0)
- [ ] `--backend openai` + 키 존재: 탭 1회 → 텍스트 즉시 → **실 합성 음성** 재생, 이벤트 타임라인 완비
- [ ] 같은 seed 재방문: `cache_hit` 경로 재생 (신규합성 0회) — 실 오디오 파일 재서빙
- [ ] 실측 요약 1회 산출: `tap→first_audio_play` ms (presynth/cache_hit 경로), 신규합성 시 비용 추정 — 티켓 완료 노트 또는 `docs/`에 기록
- [ ] 키·응답 원문이 코드/로그/픽스처에 없음, `python3 -m pytest tests/` GREEN (키 없는 환경)

## 5. 테스트 계획

```bash
python3 -m pytest tests/                      # 키 없는 환경 GREEN (계약 테스트 skip)
python3 fortune-engine/web/server.py          # mock 무회귀 (curl 스모크)
# 실경로는 로컬 수동: OPENAI_API_KEY=... python3 fortune-engine/web/server.py --backend openai
```

## 6. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 서버 플래그·서빙 경로·스크립트만. 기본 경로가 mock 고정이라 revert 시 T019 상태로 복귀.
# 과금은 실행 시점 옵트인에서만 발생 — 코드 잔존 리스크 없음 (T018과 동일 논거).
```

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| 옵트인 분기 실수로 기본 경로 과금 | L | H | 기본 mock 고정 단위 테스트 + 키 없으면 기동 거부(옵트인 시) |
| 실 오디오 포맷/디코드 브라우저 편차 | M | M | mp3/wav 중 decodeAudioData 호환 포맷, 수용 기준에 실재생 포함 |
| 캐시 키 경로 노출 | L | M | T019의 `_KEY_RE` 해시 서빙 관례 유지 (HMAC 해시만) |

## 8. 메모 / 결정 이력

- 2026-07-07 기안: T019 검증(스위트 215 GREEN·E2E 스모크) 직후. 마일스톤 ③ 잔여분 중 "소리가 진짜"가 최우선이라 판단 — 공유카드(T006 연결)는 후속.
