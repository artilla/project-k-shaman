---
id: T018
title: TTS 실경로 연결 — gpt-4o-mini-tts(coral) 어댑터 실구현 + presynth·캐시·이벤트 계측
status: done
priority: P1
safe: false              # 실 프로바이더 API 키·과금 호출 경로 (master-spec §3 hold) — 실행엔 승인 마커 필요.
persona: implementer
estimate: M
depends_on: []
blocks: []
labels: ["feature", "tts", "engine", "cost"]
created: 2026-07-06
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T018 — TTS 실경로 연결 (mock → OpenAI gpt-4o-mini-tts)

## 1. 목표 (한 줄)
> mock까지 통합된 파이프라인(T016)을 ADR-0001 확정 프로바이더 실경로로 연결하고, 3초 재생·원가 임계값을 실측 가능하게 만든다 (master-spec §1.6-①②).

## 2. 변경 범위 (Scope)

**포함**
- `fortune-engine/tts_adapter.py`: OpenAI `gpt-4o-mini-tts` + `coral` 실구현 (ADR-0001).
  키는 환경변수(`OPENAI_API_KEY`) 주입 — 코드·로그·픽스처에 키 원문 금지 (runbook §4).
  `bright + energetic` 감정 파라미터 매핑 (캐릭터 시트 §4).
- presynth 경로: 사전합성 세그먼트 우선 + cache_layer(HMAC 키, T015) 연결 — cache miss에서만 신규합성.
- 이벤트 계측 (v3 §17 / master-spec §1.6-②): `tts_generate_start/complete`, `cache_hit/miss` —
  베타 계측 훅이 소비할 수 있는 구조화 로그로.
- 테스트: 실호출은 **계약 테스트로 격리**(키 없으면 skip, CI 기본 skip). 나머지는 기존 mock
  (T013)으로 회귀 — `tests/test_tts_adapter.py` 확장.

**제외 (Non-goals)**
- 커스텀 보이스·캐릭터 2종 (master-spec §1.5), 프론트 재생 UX(사용자 탭 오디오 컨텍스트 — 별도 티켓),
  단위경제 임계값 변경(v3 §13은 실측 입력만).

## 3. 수용 기준
- [ ] `OPENAI_API_KEY` 있는 로컬 실행에서: narration 1건 실합성 → 오디오 산출 + `tts_generate_start/complete` 이벤트 기록
- [ ] 동일 seed 재요청 → `cache_hit` (신규합성 0회), 변경 seed → `cache_miss` 1회
- [ ] 신규합성 실측 비용 로그 산출 (≤ $0.01/세션 목표 대비 실측치 기록 — ADR-0001 $0.0078 재검증)
- [ ] 키 부재 환경: 계약 테스트 skip, 그 외 전부 mock으로 GREEN (`./scripts/run_checks.sh` 0 exit)
- [ ] 키·응답 원문이 코드/로그/픽스처에 남지 않음

## 4. 롤백
`git revert <commit>` — 어댑터는 mock 폴백 유지라 revert 시 T016 상태로 복귀. 과금 발생은 실행 시점뿐(코드 잔존 리스크 없음).
