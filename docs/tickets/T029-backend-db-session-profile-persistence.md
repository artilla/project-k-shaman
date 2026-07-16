---
id: T029
title: Backend DB session and profile persistence
status: open
safe: false
priority: P0
persona: implementer
estimate: L
depends_on: ["T027"]
blocks: ["T030", "T031"]
labels: ["backend", "db", "auth", "privacy", "test"]
created: 2026-07-15
spec_ref: docs/decisions/0005-closed-beta-deployment-and-staging-contract.md
---

# T029 — Backend DB session and profile persistence

## 1. 목표 (한 줄)

> FastAPI가 Postgres를 `shindang_app` 최소권한으로 사용해 OAuth user, session,
> 동의한 profile과 streak를 영속화하고, 비동의 guest의 local-first 계약과 ADR-0004
> soft-delete 계약을 유지한다.

## 2. 선행조건과 승인 경계

- T027/ADR-0005가 완료돼 있어야 한다. T028과 repo 구현은 병렬 가능하지만 T030 app
  smoke 전에는 둘 다 완료돼야 한다.
- 모든 integration test는 disposable local Postgres에서 실행한다. staging/live DB write,
  role/owner 변경, migration apply는 이 티켓 범위가 아니다.
- safe:false 승인 마커는 DB credential 취급과 개인정보 계약을 확인하기 위한 것이다.

## 3. 변경 범위 (Scope)

**포함**

- Psycopg 3와 explicit connection pool lifecycle을 사용한 DB adapter. FastAPI lifespan에서
  pool을 open/close하고 startup readiness를 제공한다.
  ([Psycopg pool/FastAPI 문서](https://www.psycopg.org/psycopg3/docs/advanced/pool.html))
- `DATABASE_URL`이 있으면 Postgres repository, 없으면 test/dev용 memory repository를
  명시적으로 선택한다. production profile에서 memory fallback은 fail-closed다.
- transaction/repository 계층:
  - OAuth `(provider, provider_subject)` user upsert와 `last_login_at`
  - opaque session ID의 server-side 저장·조회·만료·logout
  - session token 원문은 DB/log에 저장하지 않고 단방향 digest만 cookie lookup key로 사용
  - 동의한 nickname/birth encrypted blob/HMAC hash/last topic/character 저장·철회
  - streak의 UTC/KST 제품 기준을 하나로 결정하고 atomic update
- API 계약:
  - `/api/auth/callback`, `/api/auth/me`, `/api/auth/logout`이 persistent repository 사용
  - profile read/update/consent withdrawal와 account soft-delete endpoint
  - guest profile은 localStorage 우선이며 동의 전 birth 원문을 서버에 저장하지 않음
- 개인정보 암호화/HMAC secret은 env/secret manager에서만 주입하고 key version을 기록한다.
  값, birth 원문, provider token은 log/event/error에 남기지 않는다.
- ADR-0004에 따라 삭제는 `app_soft_delete_user()` 진입점만 사용하고 직접
  `UPDATE users.deleted_at` 우회는 코드와 권한 테스트에서 거부한다.
- disposable PostgreSQL 16 integration fixture에서 migration 001~005 fresh apply 후
  repository/API/transaction/concurrency/rollback 테스트

**제외**

- staging/live DB 접속 또는 data migration
- role 생성, owner 이전, GRANT/REVOKE 변경(T030/T031)
- hosting/CI/DNS/OAuth provider console(T028)
- purchase, payment, push, raw dream text persistence
- production data backfill

## 4. 수용 기준 (Acceptance Criteria)

- [ ] OAuth callback 후 user/session이 DB에 저장되고 app 재시작 후 `/api/auth/me`가 유지된다.
- [ ] logout/expiry/invalid digest는 session을 재사용하지 못하며 cookie 원문이 DB/log에 없다.
- [ ] 비동의 guest와 사용자는 birth 원문/hash/최근 선택을 server DB에 남기지 않는다.
- [ ] 동의 profile은 encryption/HMAC 경계를 거쳐 저장되고 철회 시 schema constraint와 함께 scrub된다.
- [ ] streak update가 동시 요청에서도 lost update 없이 계약한 날짜 기준을 지킨다.
- [ ] soft-delete는 승인 함수로만 수행되고 event/session/streak/rejoin 불변식이 ADR-0004와 일치한다.
- [ ] runtime repository 테스트는 superuser/owner가 아닌 제한 role로 통과한다.
- [ ] `DATABASE_URL` 없는 production mode는 memory로 조용히 fallback하지 않고 기동 실패한다.
- [ ] 전체 gate와 disposable PG16 integration suite가 통과한다.

## 5. 테스트 계획

```bash
./ralph/scripts/run_checks.sh --full
python3 -m pytest tests/test_backend_db.py tests/test_backend_app.py
bats tests/db-migrate.bats
```

CI integration DB는 합성 fixture만 사용한다. external DB address나 password가 필요한 테스트는
설계 실패로 본다.

## 6. 롤백 방법 (Reversibility)

```bash
git revert <T029 implementation commit>
```

이 티켓은 external DB를 쓰지 않는다. migration/schema rollback은 없다. repo rollback 뒤
dev/test memory repository로 돌아갈 수 있지만 production의 silent fallback은 허용하지 않는다.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| session token/birth 원문 노출 | L | H | digest/encryption, redaction, negative tests |
| sync DB 호출로 event loop block | M | M | sync endpoint/threadpool 계약 또는 async pool을 명시하고 부하 smoke |
| 동시 streak/profile update 유실 | M | M | transaction/row lock/upsert concurrency tests |
| memory fallback이 운영 장애를 숨김 | M | H | production startup fail-closed |
| direct delete가 ADR-0004를 우회 | L | H | function-only repository + restricted-role integration test |

## 8. 완료 증거

T030이 같은 image와 제한 role로 재실행할 수 있도록 dependency lock, schema version,
integration fixture 명령, expected DB privileges를 durable 문서로 남긴다.
