---
id: T009
title: watchdog sleep 종료 job-control 노이즈 제거 (disown)
status: done
priority: P2
safe: true
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: ["infra", "headless", "logging", "diagnostic"]
created: 2026-06-02
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T009 — watchdog sleep 종료 job-control 노이즈 제거 (disown)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

bash-watchdog 경로에서 claude가 timeout **전에** 끝날 때 셸 job-control이 남기는 `Terminated: 15 ... sleep "$CLAUDE_TIMEOUT_SECONDS"` 노이즈를 없앤다. 동작(타임아웃 강제)은 그대로. (T008.log line 18에서 관측)

## 2. 변경 범위 (Scope)

**포함**
- `scripts/run_headless.sh`의 watchdog watcher 정리 보강 — watcher `sleep` 백그라운드 잡을 `disown`(또는 그 구간만 monitor-mode off)하여 종료 시 job-control 알림이 찍히지 않게.
- bats 테스트로 "watchdog 정상 동작 + 노이즈 없음" 고정.

**제외**
- `timeout`/`gtimeout` 경로, 타임아웃 **값·정책** 변경.
- run_loop 로그 캡처(T007에서 완료) 변경.

## 3. 수용 기준 (Acceptance Criteria)

- [ ] bash-watchdog 경로(`timeout`·`gtimeout` 둘 다 없을 때)에서 claude가 빠르게 끝나면 stderr/로그에 **`Terminated` job-control 노이즈가 남지 않는다**.
- [ ] **타임아웃 강제는 그대로** — 초과 시 여전히 rc=5 + 프로세스 트리 종료(기존 `run-headless` 타임아웃 bats **무회귀**).
- [ ] `./scripts/run_checks.sh` 0 exit (bats 포함).

## 4. 테스트 계획

```bash
# fake CLAUDE_CMD(빠른 종료) + timeout/gtimeout 마스킹으로 watchdog 경로 강제 → stderr에 "Terminated" 없음 단언
bats tests/run-headless-*.bats
./scripts/run_checks.sh
```

## 5. 롤백 방법 (Reversibility)

```bash
git revert <commit>   # 한 줄 변경이라 즉시 원복
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| `disown`이 타임아웃 종료 보장을 약화 | L | H | 기존 타임아웃 bats(초과 시 rc=5·트리 종료)로 보존 확인 — 통과해야 머지 |
| 코어 실행 경로(run_headless) 수정 중 루프 사용 | L | M | 변경은 **다음 실행부터** 적용 — 현재 사이클엔 영향 없음; 단일 커밋·즉시 revert 가능 |
| 비대화 셸에서 job-control 동작 차이 | M | L | 테스트로 실제 stderr를 단언(구현 가정이 아니라 관측 기반) |

## 7. 메모 / 결정 이력

- 출처: `run_headless.sh`의 `run_claude_bash_watchdog`가 띄운 `sleep "$CLAUDE_TIMEOUT_SECONDS" &` watcher를 claude 조기 종료 시 kill → 셸이 `Terminated: 15` 출력. `disown`으로 잡 테이블에서 제거하면 침묵.
- **Hephaestus 원본 `run_headless.sh`에도 동일 코드 → back-port 후보**(T007 로깅과 같은 패턴).
- 통과 후 Sprint 2(긴 AI/TTS 사이클)에서 로그 S/N비가 올라가 실제 신호(지연·재시도·비용)가 또렷해진다.
