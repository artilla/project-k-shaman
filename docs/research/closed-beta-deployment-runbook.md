# 클로즈드 베타 staging-first 배포 runbook

> 작성일: 2026-07-15 · 결정: ADR-0005 · 소유 티켓: T027
>
> 이 문서는 실행 계약이다. T027에서는 아래 명령을 설계·검증만 하며 cloud, DNS,
> OAuth provider, staging/live DB에는 쓰지 않는다. 각 쓰기 단계는 해당 후속 티켓의
> 승인 마커와 rollback 값이 채워진 뒤에만 실행한다.

## 1. 역할과 산출물

| 단계 | 변경 여부 | 필수 승인 | 증거 |
|---|:---:|---|---|
| read-only preflight | 없음 | T027 결정 | gate 로그, migration/role/owner status |
| container/hosting | cloud/DNS/OAuth | T028 | image digest, IaC plan/apply, HTTPS smoke |
| backend persistence | repo code + test DB | T029 | adapter 계약, integration tests |
| staging rehearsal | staging DB | T030 | fresh/upgrade logs, ACL smoke, app/browser smoke |
| production apply | production DB/app | T031 | backup ID, approval, apply log, runtime/browser 증거 |

각 단계는 이전 단계의 증거를 링크한다. 채팅 요약만으로 다음 단계를 승인하지 않는다.

## 2. 공통 fail-closed 조건

다음 중 하나라도 참이면 즉시 중단한다.

- 승인 마커가 없거나 `ralph/mission-control/approval.mjs`가 `ok`가 아니다.
- target environment, DB name, current role, image digest 중 하나가 불명확하다.
- production과 staging `DATABASE_URL`을 사람이 구분해 확인하지 못했다.
- `shindang_app`이 superuser이거나 `shindang_deploy`로 전환·상속·재부여할 수 있다.
- pending migration이 있는데 current role과 owner anchor가 다르다.
- backup/snapshot 식별자와 restore 검증 결과가 없다.
- git gate, container smoke, staging upgrade/ACL smoke 중 하나가 실패했다.
- 문서나 로그에 password, token, API key, 개인 데이터가 포함됐다.

## 3. read-only preflight

### 3.1 저장소와 gate

```bash
git status --short --branch
git fetch remote
git rev-list --left-right --count HEAD...remote/HEAD
./ralph/scripts/run_checks.sh --full
```

`run_checks.sh`가 모두 통과하고, 배포할 commit이 remote에 존재하며, unrelated WIP가
없는 상태를 증거로 저장한다.

### 3.2 migration status

PostgreSQL 16 client를 사용한다. 아래 명령은 `--status`이므로 schema/data를 쓰지 않는다.

```bash
ENV_FILE="$TARGET_ENV_FILE" ./scripts/db_migrate.sh --status
```

출력에는 applied/pending version만 보존한다. URL, host, user, password는 보존하지 않는다.

### 3.3 role과 owner 확인

credential 값은 shell history에 직접 입력하지 않고 승인된 secret injection으로 제공한다.

```bash
psql "$DATABASE_URL" -X -v ON_ERROR_STOP=1 -P pager=off <<'SQL'
SELECT current_database(), current_user;
SELECT rolname, rolsuper, rolcreaterole, rolcreatedb, rolcanlogin
FROM pg_roles
WHERE rolname IN ('shindang_deploy', 'shindang_app', 'shaman_softdelete')
ORDER BY rolname;
SELECT schemaname, tablename, tableowner
FROM pg_tables
WHERE schemaname = current_schema()
ORDER BY tablename;
SQL
```

결과에서 production host/password와 계정 식별자는 마스킹한다. T030/T031은 별도 쿼리로
role membership의 SET/INHERIT/ADMIN 능력도 0인지 검증한다.

## 4. image와 app 배포 검증

T028 이후 CI가 산출한 **digest**를 기록한다. mutable tag만 기록하면 실패다.

```bash
export IMAGE_DIGEST="sha256:<approved-digest>"
docker compose config --quiet
docker compose pull app
docker compose up -d --no-deps app
docker compose ps
curl --fail --silent --show-error "https://$TARGET_HOST/healthz"
curl --fail --silent --show-error "https://$TARGET_HOST/api/auth/providers"
```

검증 항목:

- HTTP가 HTTPS로 redirect되고 최종 인증서 hostname이 일치한다.
- `/healthz`는 process liveness, `/readyz`는 DB dependency readiness를 구분한다.
- app의 8000 포트는 외부에서 접근되지 않고 80/443만 공개된다.
- OAuth callback URL이 정확히 `https://<host>/api/auth/callback/{provider}`다.
- `SHINDANG_DEV_LOGIN`은 production에서 설정되지 않는다.
- session/state cookie는 HTTPS에서 `Secure`, `HttpOnly`, `SameSite=Lax`다.

## 5. staging migration rehearsal

이 절은 **T030 승인 후 staging에서만** 실행한다.

### 5.1 fresh rehearsal

빈 staging DB와 전용 role을 만든 뒤 001~005 전체를 실행한다.

```bash
ENV_FILE="$STAGING_MIGRATION_ENV" \
MIGRATION_OWNER=shindang_deploy \
MIGRATION_APP_ROLES=shindang_app \
./scripts/db_migrate.sh

ENV_FILE="$STAGING_MIGRATION_ENV" ./scripts/db_migrate.sh --status
```

### 5.2 upgrade rehearsal

production과 같은 001~002 기준 상태를 별도 staging DB에 만들고, owner 전환을 명시적으로
리허설한 다음 003~005를 적용한다. fresh와 upgrade는 서로 다른 DB에서 수행해 ledger를
재사용하지 않는다.

필수 검증:

- migration ledger가 001~005를 각 1회 기록한다.
- protected object와 ledger owner가 `shindang_deploy`로 일치한다.
- `shindang_app`의 owner membership 능력이 없다.
- `MIGRATION_APP_ROLES` 미지정/존재하지 않는 role/owner 불일치 apply가 실패한다.
- `shindang_app`으로 직접 hard-delete는 실패하고 승인된 soft-delete 함수만 성공한다.
- 삭제 후 ADR-0004의 익명화·event scrub·재가입 계약이 유지된다.

### 5.3 staging app smoke

같은 production 후보 image digest를 staging에 배포하고 다음을 확인한다.

1. guest fortune → OAuth login(mock provider 계약 또는 승인된 staging provider) → profile 저장
2. session 재조회와 app 재시작 후 session 유지
3. profile/streak read/write와 daily limit
4. soft-delete 후 직접 DML 우회 실패, 재가입은 새 사용자
5. `/readyz`, error log, DB connection 수, p95 latency

T030 결과에는 secret이나 실제 개인정보 대신 합성 fixture ID만 남긴다.

## 6. production 승인 패킷

T031 승인 마커를 만들기 전에 아래가 모두 채워져야 한다.

- 배포 commit과 image digest
- T028 HTTPS/hosting smoke 링크
- T029 DB adapter integration 결과
- T030 fresh/upgrade/app/ACL smoke 링크
- production read-only migration/role/owner status 시각
- backup/snapshot 식별자, restore 검증 시각, rollback 실행자
- maintenance/drain 시작·종료 조건
- 이전 정상 image digest와 DNS TTL
- 변경할 object/GRANT 목록과 예상 migration version

T027 승인 마커를 T031의 승인으로 재사용하지 않는다.

## 7. production apply와 verification

이 절은 **T031 승인 후에만** 실행한다.

1. write 유입을 drain하고 backup을 생성·검증한다.
2. admin/bootstrap identity로 전용 role 생성과 기존 object/ledger owner 이전을 수행한다.
3. `shindang_deploy` 연결에서 read-only preflight를 다시 실행한다.
4. 다음 migration job을 한 번 실행한다.

```bash
ENV_FILE="$PRODUCTION_MIGRATION_ENV" \
MIGRATION_OWNER=shindang_deploy \
MIGRATION_APP_ROLES=shindang_app \
./scripts/db_migrate.sh
```

5. 승인된 image digest를 배포하고 runtime은 `shindang_app` credential만 받는다.
6. API smoke 후 실제 브라우저에서 guest, login, profile, restart persistence,
   soft-delete/rejoin의 승인된 test account 경로를 확인한다.
7. error rate, p95 latency, DB connection, 429 비율, OAuth failure를 관찰한다.

## 8. rollback과 중단 기준

### app rollback

```bash
export IMAGE_DIGEST="$PREVIOUS_IMAGE_DIGEST"
docker compose pull app
docker compose up -d --no-deps app
curl --fail --silent --show-error "https://$TARGET_HOST/healthz"
```

### DB rollback

003~005를 역방향 SQL로 되돌리지 않는다. migration 후 schema/ACL/데이터 불변식이 깨지면
write를 재개하지 않고 다음 중 승인 패킷에 정한 한 경로만 사용한다.

1. backup/snapshot을 새 DB로 복구하고 runtime endpoint를 복구 DB로 전환
2. 영향이 제한되고 staging에서 재현·검증된 forward-fix migration 적용

runtime role에 임시 superuser를 부여하거나 기존 migration 파일을 수정해 ledger를
속이는 복구는 금지한다.

즉시 rollback 기준:

- health/readiness가 5분 안에 안정화되지 않음
- OAuth callback loop 또는 session persistence 실패
- DB permission/owner guard 오류
- error rate가 사전 합의한 임계치를 5분 이상 초과
- 개인 데이터·secret 로그 노출
- ADR-0004 soft-delete 불변식 실패
