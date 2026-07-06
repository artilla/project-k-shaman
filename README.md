# ProjectK-Shaman

Project Hephaestus 운영 하네스에서 `init_new_project.sh`로 클린 추출한 프로젝트입니다 (추출일: 2026-07-06).
Ralph Loop(명세 → 분할 → 헤드리스 실행 → 검증 → 복구 → 인간 승인) 방식으로 운영합니다.

## 빠른 시작

```bash
$EDITOR docs/master-spec.md            # 1) 명세 (Office Hours 6질문)
$EDITOR scripts/run_checks.local.sh    # 2) 검증 명령 확인/수정
./scripts/run_checks.sh                # 3) 0 exit 확인
cp docs/tickets/TEMPLATE.md docs/tickets/T001-first.md
$EDITOR docs/tickets/T001-first.md     # 4) 첫 티켓
./scripts/run_loop.sh T001-first --dry-run   # 5) 프롬프트 미리보기
```

## 구조

| 경로 | 역할 |
|---|---|
| `docs/master-spec.md` | 제품 명세 (Step 1) |
| `docs/runbook.md` | Ralph Loop 운영 규칙 |
| `docs/tickets/` | 작업 단위 (`TEMPLATE.md` 복사) |
| `docs/decisions/` | ADR (의사결정 기록) |
| `skills/` | AI 페르소나 4종 |
| `scripts/` | 루프 실행 도구 (`run_checks.local.sh`에 프로젝트 검증) |
| `mission-control/` | 이 프로젝트 전용 Mission Control 웹 (`./scripts/mission_control.sh start`) |
| `state/`, `.ralph/` | 런타임 상태 (git 무시) |

운영 규칙 전체: [`docs/runbook.md`](docs/runbook.md)
