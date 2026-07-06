---
id: T017
title: run_checks --fast 멈춤 수정 — run-headless-timeout.bats 업스트림 동기화
status: open
priority: P0
safe: true               # 테스트 파일 1개 교체 — 제품 코드·스크립트 무변경, git revert 즉시 복구.
persona: implementer
estimate: S
depends_on: []
blocks: []
labels: ["bug", "test", "harness"]
created: 2026-07-06
spec_ref: docs/master-spec.md#2-범위--아키텍처-개요
---

# T017 — run_checks --fast 멈춤 수정 (run-headless-timeout.bats 동기화)

## 1. 목표 (한 줄)
> `./scripts/run_checks.sh --fast`가 watchdog fallback 테스트에서 멈추지 않고 완주하게 한다 — 루프의 "통과(GREEN)" 기준 복구.

## 2. 변경 범위 (Scope)

**포함**
- `tests/run-headless-timeout.bats` 1개 파일을 업스트림(Hephaestus `0c9cfb7` 기준) 버전으로 교체.

**제외**
- `scripts/run_headless.sh` — 변경 금지 (업스트림과 이미 바이트 동일 확인).
- 그 외 tests/·제품 코드.

## 3. 원인 진단 (조사 완료 — 구현 전 재확인만)

2026-07-06 하네스 재적용(T303)으로 `scripts/`는 업스트림 최신과 동일해졌지만, 하네스는
`tests/`를 보존하므로 이 테스트는 **구버전**이 남았다 → 신스크립트↔구테스트 불일치.

업스트림 diff 요지 (구버전에 없는 것):
- 제한 PATH 샌드박스에 `tail`·`tr`·`wc`(+가능 시 `perl`)를 `_link_tool`로 추가 링크 —
  현행 `run_headless.sh`가 사용하는 도구들이라, 구테스트의 제한 PATH에선 스크립트가
  도구를 못 찾아 watchdog fallback 케이스가 실패/대기한다.
- process-group fallback 스킵 조건이 `python3` 단독 → `perl` 또는 `python3`로 완화.

재현: ProjectK-Shaman에서 `./scripts/run_checks.sh --fast` → "bash watchdog fallback" 계열
테스트에서 멈춤 (2026-07-06 운영자 재현).

## 4. 수용 기준
- [ ] `tests/run-headless-timeout.bats`가 업스트림 버전과 바이트 동일
- [ ] `bats tests/run-headless-timeout.bats` 전 케이스 통과(또는 명시적 skip) — 멈춤 없음
- [ ] `./scripts/run_checks.sh --fast` 완주 (0 exit)

## 5. 롤백
`git revert <commit>` — 테스트 파일 1개.
