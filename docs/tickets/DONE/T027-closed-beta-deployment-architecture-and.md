---
id: T027
title: Closed beta deployment architecture and staging rehearsal
status: done
safe: false
priority: P0
persona: planner
estimate: M
depends_on: []
blocks: []
labels: ["infra", "deploy", "db", "security", "docs"]
created: 2026-07-15
spec_ref: docs/master-spec.md
---

# T027 — Closed beta deployment architecture and staging rehearsal

## 1. 목표 (한 줄)
> 오늘신당의 클로즈드 베타 배포 아키텍처와 staging 리허설 계약을 확정해, 인프라·DNS·live DB를 추측 없이 별도 구현 티켓으로 넘길 수 있게 한다.

## 2. 현재 확인된 상태

- 작업 시작 시 `master`와 `remote/master`의 parity와 clean tree를 확인했다.
- 실제 앱 gate는 frontend typecheck/build, Python dependency consistency, pytest, Node, Bats 회귀를 포함한다.
- 저장소에 GitHub Actions, Dockerfile, IaC 또는 확정된 hosting provider가 없다.
- backend는 FastAPI same-origin 정적 서빙을 지원하지만 `DATABASE_URL` 소비자와 DB 드라이버가 없다.
- `.env.local` 대상 DB는 001~002 applied, 003~005 pending이다.
- DB 접속 role과 ledger owner는 `postgres` superuser이며 별도 non-superuser login role은 없다.

## 3. 변경 범위 (Scope)

**포함**
- `docs/decisions/`에 클로즈드 베타 배포 ADR 작성:
  - hosting provider/region과 same-origin FE+BE 배포 형태
  - HTTPS/domain/OAuth redirect 경계
  - secret manager와 로컬 `.env.local` 분리
  - dedicated non-superuser runtime DB role과 migration owner의 분리 계약
  - staging DB/서비스를 먼저 사용하는 순서와 rollback 기준
- `docs/research/production-readiness.md`의 현재 코드와 어긋난 상태(FastAPI, rate limit, DB migration, test gate)를 현행화.
- 후속 구현 티켓을 독립 단위로 설계:
  1. 컨테이너/CI-CD 및 hosting 배선
  2. backend DB adapter + session/profile persistence
  3. staging role/DB 생성과 003~005 migration rehearsal
  4. prod apply와 runtime/browser verification
- 배포 전후의 기계 검증 명령, 관찰 지표, rollback 명령을 runbook 형태로 명시.

**제외**
- cloud 계정 또는 hosting resource 생성/변경
- DNS, TLS, OAuth provider 설정 변경
- live/staging DB role·schema·data 쓰기
- 003~005 migration 적용
- `.env.local` 또는 실제 credential의 문서/커밋 포함
- backend DB integration 구현

## 4. 수용 기준 (Acceptance Criteria)

- [x] hosting provider와 same-origin topology가 하나의 승인 가능한 ADR로 확정된다.
- [x] migration owner와 runtime app role이 분리되고 최소권한 GRANT/REVOKE 계획이 명시된다.
- [x] staging-first 순서가 `read-only preflight → staging apply → app smoke → prod approval → prod apply → runtime verification`으로 고정된다.
- [x] production-readiness 문서가 현재 구현과 일치하며 미완료 P0를 과장 없이 구분한다.
- [x] 후속 구현 티켓들이 외부 변경 단위별로 분리되고 live DB apply가 독립 승인 단계로 남는다.
- [x] secret 값, DB password, API key, 개인 데이터가 어떤 산출물에도 포함되지 않는다.

## 5. 테스트 계획

```bash
./scripts/lint_external_docs.sh
./scripts/run_checks.sh --full
PATH="/usr/local/opt/postgresql@16/bin:$PATH" ENV_FILE=.env.local ./scripts/db_migrate.sh --status  # read-only only
```

## 6. 롤백 방법 (Reversibility)

```bash
git revert <T027 documentation commit>
```

이 티켓은 문서·계획만 변경한다. 외부 인프라와 DB를 변경하지 않으므로 Git revert로 완전 복구 가능하다.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| hosting 결정을 구현과 섞어 rollback 경계가 흐려짐 | M | H | ADR과 후속 구현 티켓을 분리 |
| `postgres`를 runtime role로 잘못 승인 | M | H | dedicated non-superuser role을 수용 기준으로 강제 |
| staging 없이 prod migration 적용 | L | H | staging rehearsal과 prod approval을 독립 단계로 고정 |
| credential가 문서에 유출 | L | H | 키 이름만 기록하고 secret scan/run_checks 적용 |

## 8. 승인 경계

- 본 티켓 자체가 `safe:false`이므로 `docs/approvals/T027.md`가 없으면 실행하지 않는다.
- T027 승인도 cloud resource 생성이나 live DB apply를 승인하지 않는다. 해당 작업은 후속 티켓별 승인 마커가 필요하다.

## 9. 완료 결과 (2026-07-15)

- ADR-0005에서 AWS EC2 `ap-northeast-2`, Docker Compose + Caddy + FastAPI
  same-origin topology와 Secrets Manager/IAM 경계를 확정했다.
- `docs/research/closed-beta-deployment-runbook.md`에 read-only preflight부터 production
  verification까지의 명령, 중단 조건, rollback packet을 고정했다.
- `docs/research/production-readiness.md`를 FastAPI, 인메모리 rate limit, migration
  001~005, 실제 앱 gate와 아직 남은 P0 기준으로 현행화했다.
- T028(container/hosting), T029(DB persistence), T030(staging rehearsal),
  T031(production apply/verification)을 모두 safe:false 독립 티켓으로 분리했다.
- 이 작업에서는 cloud, DNS, OAuth provider, staging/live DB에 쓰지 않았고 credential
  값이나 개인 데이터를 산출물에 포함하지 않았다.
