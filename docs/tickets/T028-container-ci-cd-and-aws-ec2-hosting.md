---
id: T028
title: Container CI/CD and AWS EC2 hosting
status: open
safe: false
priority: P0
persona: implementer
estimate: L
depends_on: ["T027"]
blocks: ["T030", "T031"]
labels: ["infra", "deploy", "aws", "security", "ci"]
created: 2026-07-15
spec_ref: docs/decisions/0005-closed-beta-deployment-and-staging-contract.md
---

# T028 — Container CI/CD and AWS EC2 hosting

## 1. 목표 (한 줄)

> ADR-0005의 FastAPI same-origin image를 재현 가능하게 build하고, AWS EC2
> `ap-northeast-2`에 staging HTTPS endpoint를 배포하며, 같은 digest를 production으로
> 승격할 수 있는 CI/CD와 rollback 경계를 만든다.

## 2. 선행조건과 승인 경계

- T027/ADR-0005가 완료돼 있어야 한다.
- 이 티켓은 safe:false다. repo artifact 작성과 local validation은 가역적이지만,
  AWS/VPC/EC2/ECR/IAM/Secrets Manager/DNS/OAuth provider 변경은 외부 상태를 바꾸므로
  실행 전에 `docs/approvals/T028.md`가 필요하다.
- T028 승인은 DB role/schema/data write나 003~005 migration apply를 승인하지 않는다.

## 3. 변경 범위 (Scope)

**포함**

- multi-stage `Dockerfile`과 `.dockerignore`:
  - Node stage에서 locked install, typecheck, production build
  - Python runtime stage에 pinned dependency와 `frontend/dist` 포함
  - non-root user, read-only 가능한 filesystem, explicit Uvicorn command
- Docker Compose + Caddy:
  - 외부 publish는 80/443만, app 8000은 private network
  - automatic HTTPS, HTTP redirect, forwarded header 신뢰 경계
  - named volume/보존 정책이 필요한 local TTS cache를 명시
- FastAPI `/healthz`와 `/readyz`:
  - liveness와 DB readiness를 분리
  - response에 secret, DSN, host, 개인 데이터 비노출
- environment-aware cookie policy:
  - HTTPS production/staging에서 `Secure`, `HttpOnly`, `SameSite=Lax`
  - `SHINDANG_DEV_LOGIN` production fail-closed
- GitHub Actions:
  - 전체 `./ralph/scripts/run_checks.sh --full` 통과 후에만 image build
  - commit SHA tag와 immutable digest 기록, ECR push
  - environment approval을 거치는 staging deploy와 production promotion job 분리
  - migration을 app startup/deploy job에 포함하지 않음
- versioned infrastructure definition(`infra/`):
  - EC2, ECR, least-privilege instance profile, security group, logging/retention,
    Secrets Manager logical entries, SSM 기반 운영 접근
  - 실제 tool(Terraform/OpenTofu/CloudFormation)과 version을 repo에 고정
  - credential 값/secret ARN/account ID를 fixture나 문서에 포함하지 않음
- staging domain/TLS와 Google/Kakao staging callback URI wiring, HTTPS smoke
- image digest, 이전 digest, IaC plan/apply, HTTPS/OAuth smoke를 남기는 deployment record template

**제외**

- backend DB adapter/session/profile 구현(T029)
- staging DB/role 생성과 migration apply(T030)
- production DB owner/role/schema 변경과 production browser verification(T031)
- 실 LLM, 결제, PWA, object storage 전환

## 4. 수용 기준 (Acceptance Criteria)

- [ ] fresh clone에서 하나의 명령으로 image build가 되고 container가 SPA와 API를 same-origin으로 서빙한다.
- [ ] app port는 외부 publish되지 않고 Caddy의 80/443만 공개된다.
- [ ] `/healthz`와 `/readyz`가 구분되고 failure response에 내부 연결 정보가 없다.
- [ ] CI는 전체 gate 실패 시 image push/deploy를 하지 않고, 성공 시 SHA/digest를 남긴다.
- [ ] EC2는 static AWS access key 없이 instance profile로 필요한 ECR/secret/log resource만 접근한다.
- [ ] staging HTTPS와 OAuth callback URL이 실제 browser/API smoke로 확인된다.
- [ ] migration job은 app startup과 배포 job 어디에도 암묵적으로 포함되지 않는다.
- [ ] 이전 정상 digest로 app만 되돌리는 rollback이 staging에서 검증된다.
- [ ] secret 값, account identifier, DB host/password, 개인 데이터가 commit/CI log/deployment record에 없다.

## 5. 테스트 계획

```bash
./ralph/scripts/run_checks.sh --full
docker build --tag shindang:test .
docker compose config --quiet
docker compose up -d --build
curl --fail --silent --show-error http://127.0.0.1/healthz
curl --fail --silent --show-error http://127.0.0.1/api/auth/providers
```

외부 resource apply 전에는 IaC format/validate/plan만 실행한다. 실제 apply와 staging HTTPS
smoke는 승인 마커와 target 확인 후 별도 로그로 보존한다.

## 6. 롤백 방법 (Reversibility)

- repo 변경: `git revert <T028 implementation commit>`
- app: 이전 정상 image digest로 Compose를 되돌린 뒤 health/API smoke
- IaC: plan으로 제거 대상과 retained data를 확인한 뒤 승인된 destroy/revert만 수행
- DNS/OAuth: 이전 record/callback set을 deployment record에서 복원

DB에는 손대지 않으므로 DB rollback을 이 티켓에 섞지 않는다.

## 7. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| CI가 secret을 log에 노출 | L | H | OIDC/instance role, masking, 값 없는 fixture, secret scan |
| app port가 인터넷에 노출 | M | H | security group + Compose publish 검증 |
| DNS/TLS 전환 중 callback 장애 | M | H | staging-first, 이전 record/callback 기록, TTL 관찰 |
| deploy와 migration 결합 | M | H | workflow에서 migration job 자체를 분리하고 테스트로 금지 |

## 8. 완료 증거

T030/T031이 참조할 수 있도록 image digest, infra revision, staging host smoke 시각,
이전 digest rollback 결과를 비밀값 없이 durable artifact로 남긴다.
