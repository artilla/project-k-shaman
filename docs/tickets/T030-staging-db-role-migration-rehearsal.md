---
id: T030
title: Staging DB role and migration rehearsal
status: open
safe: false
priority: P0
persona: implementer
estimate: L
depends_on: ["T028", "T029"]
blocks: ["T031"]
labels: ["staging", "db", "migration", "security", "verification"]
created: 2026-07-15
spec_ref: docs/research/closed-beta-deployment-runbook.md
---

# T030 — Staging DB role and migration rehearsal

## 1. 목표 (한 줄)

> production과 분리된 staging에서 deploy/runtime role을 만들고 fresh 001~005와
> 001~002→003~005 upgrade를 모두 리허설한 뒤, 같은 app image로 권한·영속화·삭제
> 계약을 증명해 production 승인 패킷을 만든다.

## 2. 선행조건과 승인 경계

- T028의 staging HTTPS/image digest/hosting 증거와 T029의 restricted-role integration
  결과가 있어야 한다.
- `docs/approvals/T030.md`는 staging resource/role/schema/data write만 승인한다.
- production DB, production DNS, production app에는 어떤 write도 하지 않는다.
- staging에는 합성 fixture만 사용한다. production data 복제는 별도 익명화 승인 없이는 금지한다.

## 3. 변경 범위 (Scope)

**포함**

- staging 전용 DB와 credential 확인/생성, backup/restore rehearsal
- admin/bootstrap identity로 다음 role 생성:
  - `shindang_deploy`: LOGIN, non-superuser, migration/object owner
  - `shindang_app`: LOGIN, non-superuser, 최소 DML/function ACL
  - 005가 관리하는 `shaman_softdelete`: NOLOGIN/정의자 계약 검증
- role membership에서 app→deploy와 예상치 못한 softdelete membership의
  SET/INHERIT/ADMIN 능력이 0인지 기계 검증
- 서로 다른 staging DB에서 두 경로 실행:
  1. 빈 DB에 001~005 fresh apply
  2. production과 같은 001~002 기준 상태 + owner 전환 + 003~005 upgrade
- `MIGRATION_OWNER=shindang_deploy`, `MIGRATION_APP_ROLES=shindang_app` 고정
- failure rehearsal:
  - app role 미지정/미존재, owner mismatch, owner membership drift가 apply 전에 실패
  - runner 재실행 시 migration ledger가 중복되지 않음
- T028의 production 후보 image digest를 staging에 배포하고 T029의 session/profile/streak,
  restart persistence, soft-delete/rejoin, health/readiness, rate limit smoke
- apply 전후 role/object/ledger/ACL diff, migration log, app/browser smoke, backup restore 결과를
  secret/PII 없이 deployment record로 보존

**제외**

- production role/owner/schema/data/app 변경(T031)
- migration 파일 001~005 수정
- runtime role에 임시 owner/superuser 권한 부여
- production data를 staging으로 복사
- 공개 사용자 traffic 전환

## 4. 수용 기준 (Acceptance Criteria)

- [ ] fresh와 upgrade rehearsal이 서로 다른 staging DB에서 001~005 ledger로 완료된다.
- [ ] protected object/ledger owner가 `shindang_deploy`로 일치한다.
- [ ] `shindang_app`은 non-superuser이고 deploy owner 전환·상속·재부여 능력이 없다.
- [ ] runtime role의 직접 hard-delete는 실패하고 승인 soft-delete 함수만 성공한다.
- [ ] 잘못된 app role/owner/membership 입력은 schema write 전에 fail-closed다.
- [ ] 같은 image digest에서 OAuth/session/profile/streak/restart/soft-delete smoke가 통과한다.
- [ ] backup을 새 staging DB로 restore하고 read/app smoke를 반복해 복구 가능성을 증명한다.
- [ ] 기록에 secret, DB host/password, 실제 provider subject, 개인 데이터가 없다.
- [ ] T031 승인에 필요한 증거 항목이 runbook §6 형식으로 완성된다.

## 5. 테스트 계획

```bash
./ralph/scripts/run_checks.sh --full
ENV_FILE="$STAGING_MIGRATION_ENV" ./scripts/db_migrate.sh --status
ENV_FILE="$STAGING_MIGRATION_ENV" MIGRATION_OWNER=shindang_deploy MIGRATION_APP_ROLES=shindang_app ./scripts/db_migrate.sh
ENV_FILE="$STAGING_MIGRATION_ENV" ./scripts/db_migrate.sh --status
```

위 apply 명령은 T030 승인 후 staging target을 사람이 확인한 세션에서만 실행한다.
browser smoke는 DOM/API/cookie/DB evidence를 함께 남긴다.

## 6. 롤백 방법 (Reversibility)

- app: 이전 staging image digest로 rollback
- DB: rehearsal DB를 폐기하고 사전 snapshot/fixture에서 새 staging DB로 복구
- role/IaC: plan과 deployment record를 기준으로 staging resource만 제거
- repo 기록: `git revert <T030 evidence commit>`

production에는 변화가 없어야 한다. staging을 되돌리기 위해 production credential을
사용하는 순간 fail-closed로 중단한다.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| target 혼동으로 production write | L | H | DB name/account/role 2인 확인에 준하는 명시 확인, production deny guard |
| owner 이전 누락으로 partial apply | M | H | preflight anchor, 별도 upgrade DB, fail-closed runner |
| 실제 개인정보가 staging에 유입 | L | H | synthetic-only, dump import 금지, evidence scan |
| smoke가 privileged role로 통과 | M | H | runtime process current_user/ACL 증거, admin credential 미주입 |

## 8. 완료 증거

production apply를 정당화하는 것은 "staging에서 됨"이라는 문장이 아니라 image digest,
fresh/upgrade ledger, role/owner/ACL diff, restore 결과, app/browser smoke의 durable artifact다.
