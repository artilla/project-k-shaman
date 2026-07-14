---
id: T031
title: Production migration and runtime verification
status: open
safe: false
priority: P0
persona: implementer
estimate: L
depends_on: ["T028", "T029", "T030"]
blocks: []
labels: ["production", "db", "deploy", "security", "browser-qa"]
created: 2026-07-15
spec_ref: docs/research/closed-beta-deployment-runbook.md
---

# T031 — Production migration and runtime verification

## 1. 목표 (한 줄)

> T028~T030의 동일 image/migration 증거를 바탕으로 production의 deploy/runtime role과
> 003~005를 적용하고, 실제 runtime·브라우저·DB에서 클로즈드 베타 계약을 검증한다.

## 2. 선행조건과 승인 경계

- T028, T029, T030이 DONE이고 runbook §6 production approval packet이 완성돼야 한다.
- T031 전용 `docs/approvals/T031.md`가 필요하다. T027/T028/T030 승인은 재사용하지 않는다.
- 승인 마커에는 정확한 scope, backup/snapshot ID, 이전 image digest, maintenance window,
  rollback 실행자, staging 증거 위치가 있어야 한다.
- 결제, production data backfill, 실 LLM, 대량 사용자 초대는 이 승인에 포함되지 않는다.

## 3. 변경 범위 (Scope)

**포함**

- production read-only preflight 재실행:
  - git/image digest, migration 001~002/pending 003~005
  - current role, ledger/protected object owner, role membership, backup/restore 상태
- write drain/maintenance 경계와 검증된 backup/snapshot 생성
- bootstrap admin으로 `shindang_deploy`/`shindang_app` 생성·검증 및 기존
  `postgres` 소유 ledger/protected object를 deploy owner로 이전
- deploy role 연결에서 003~005 한 번 적용:
  - `MIGRATION_OWNER=shindang_deploy`
  - `MIGRATION_APP_ROLES=shindang_app`
- T028/T030에서 검증한 immutable image digest 배포, runtime에는 app credential만 주입
- 기계 검증:
  - migration ledger/owner/ACL/current_user
  - `/healthz`, `/readyz`, auth providers, guest fortune, rate-limit response
  - error rate, p95 latency, DB connection, OAuth failure, 429 비율
- 승인된 production test account를 사용한 실제 browser 검증:
  - guest→OAuth→profile consent→fortune/audio/share
  - app restart 후 session/profile 유지
  - soft-delete→개인정보 scrub→같은 OAuth subject 재가입 시 새 user
- 결과와 redacted 관찰값을 durable deployment record로 남기고 write drain 해제 여부 결정

**제외**

- migration 001~005 수정 또는 역방향 SQL 작성
- runtime role에 superuser/owner membership 부여
- production 전체 사용자 data backfill/삭제
- 실 LLM/결제/웹푸시/PWA 공개
- 실패를 숨기기 위한 health/readiness bypass

## 4. 수용 기준 (Acceptance Criteria)

- [ ] apply 직전 preflight가 approval packet의 target/image/owner/backup과 정확히 일치한다.
- [ ] 003~005가 deploy role로 한 번 적용되고 ledger/protected object owner가 일치한다.
- [ ] runtime `current_user`는 `shindang_app`이고 superuser/owner 전환·상속·재부여 능력이 없다.
- [ ] runtime/API/browser smoke가 same-origin HTTPS에서 통과하고 secure cookie가 확인된다.
- [ ] restart 후 session/profile이 유지되고 비동의 birth 원문이 DB/log/event에 없다.
- [ ] soft-delete/rejoin이 ADR-0004를 지키며 direct hard-delete는 runtime role에서 실패한다.
- [ ] 관찰 window 동안 합의된 error/latency/DB/429/OAuth 임계치를 넘지 않는다.
- [ ] 실패 시 app rollback 또는 DB restore/forward-fix 중 사전 승인된 경로가 실제로 실행 가능하다.
- [ ] 모든 기록은 secret/PII/account identifier를 마스킹한다.

## 5. 테스트 계획

```bash
./scripts/run_checks.sh --full
ENV_FILE="$PRODUCTION_MIGRATION_ENV" ./scripts/db_migrate.sh --status
ENV_FILE="$PRODUCTION_MIGRATION_ENV" MIGRATION_OWNER=shindang_deploy MIGRATION_APP_ROLES=shindang_app ./scripts/db_migrate.sh
ENV_FILE="$PRODUCTION_MIGRATION_ENV" ./scripts/db_migrate.sh --status
curl --fail --silent --show-error "https://$PRODUCTION_HOST/healthz"
curl --fail --silent --show-error "https://$PRODUCTION_HOST/readyz"
curl --fail --silent --show-error "https://$PRODUCTION_HOST/api/auth/providers"
```

apply 명령은 T031 승인·target 재확인·backup 완료 후 한 번만 실행한다. browser 결과는
screenshot에 더해 DOM/API/cookie/DB/runtime log 증거를 남긴다.

## 6. 롤백 방법 (Reversibility)

- app failure: 즉시 이전 image digest로 rollback하고 health/API smoke
- migration 전 failure: DB write 없이 중단
- migration 후 schema/data/ACL failure: write를 재개하지 않고 승인된 snapshot에서 새 DB를
  복구해 endpoint를 전환하거나 staging에서 검증한 forward-fix migration 적용
- DNS/OAuth failure: T028 deployment record의 이전 record/callback set 복원
- repo evidence: `git revert <T031 evidence commit>`은 기록만 되돌릴 뿐 외부 상태 rollback을
  대신하지 않으므로, external rollback 완료 후에만 사용

기존 migration 파일 수정, ledger 수동 삭제, runtime role 임시 superuser 부여는 rollback이 아니다.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| owner 전환/003~005가 production write를 중단 | M | H | maintenance, staging upgrade, backup/restore, 즉시 중단 기준 |
| privileged credential이 runtime에 잔존 | L | H | separate secret/IAM, current_user와 env inventory 검증 |
| browser smoke 중 실제 사용자 정보 노출 | L | H | 승인 test account, 최소 fixture, redacted evidence |
| app rollback이 schema와 불호환 | M | H | backward-compatible T029 계약, 동일 digest staging rehearsal |
| OAuth/DNS 전환과 DB apply가 동시에 실패 | L | H | T028 선완료, production apply 시점에는 endpoint 안정 상태 고정 |

## 8. 완료 판단

production URL이 열렸다는 사실만으로 완료하지 않는다. DB role/owner/ledger, runtime identity,
restart persistence, soft-delete/rejoin, 실제 browser, 관찰 지표와 rollback readiness가 모두
수용 기준을 충족해야 write drain을 해제하고 DONE으로 이동한다.
