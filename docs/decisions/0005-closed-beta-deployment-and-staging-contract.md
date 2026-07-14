# ADR-0005: 클로즈드 베타 배포와 staging-first 릴리스 계약

- 상태: 승인 (2026-07-15, T027 승인 범위)
- 결정자: 이훈
- 관련: ADR-0003, ADR-0004, `docs/research/production-readiness.md`, `docs/research/closed-beta-deployment-runbook.md`

## 맥락

현재 애플리케이션은 FastAPI가 `frontend/dist`를 정적으로 서빙하는 same-origin 형태를
지원하지만, 컨테이너·CI/CD·호스팅 대상은 없다. DB에는 001~002만 적용돼 있고
003~005는 pending이며, 현재 접속 role과 migration ledger owner가 `postgres`
superuser다. backend에는 아직 `DATABASE_URL` 소비자와 DB driver가 없으므로 지금
운영 DB에 migration만 먼저 적용하면 최소권한 runtime 계약을 검증할 애플리케이션이 없다.

클로즈드 베타에서 필요한 것은 대규모 오케스트레이션보다 다음 경계를 명확히 하는 것이다.

1. 브라우저에는 하나의 HTTPS origin만 노출한다.
2. 앱 배포와 DB schema 변경을 서로 독립적으로 승인·롤백한다.
3. staging에서 같은 image와 같은 migration runner를 먼저 검증한다.
4. runtime app role이 migration owner나 superuser 권한을 얻지 않는다.
5. 장기 credential을 VM이나 저장소에 두지 않는다.

## 결정

### 1. 호스팅과 region

- 호스팅 provider는 **AWS**, compute는 **EC2 단일 인스턴스**, region은
  **Asia Pacific (Seoul), `ap-northeast-2`**로 정한다.
- 이 선택은 현재 저장소의 AWS region 구성 단서, 국내 클로즈드 베타 사용자, 단일
  FastAPI 프로세스 전제에 맞춘 첫 운영 단계다. 고가용성이나 자동 확장이 필요해지면
  ECS/Fargate 또는 동등한 managed runtime을 별도 ADR로 재평가한다.
- AWS는 `ap-northeast-2`를 EC2 Seoul region으로 문서화한다.
  ([AWS EC2 region 문서](https://docs.aws.amazon.com/ec2/latest/instancetypes/ec2-instance-regions.html))

이 ADR은 provider와 topology만 결정한다. EC2/VPC/ECR/IAM/DNS 등 실제 resource 생성은
후속 safe:false 티켓의 별도 승인을 받아야 한다.

### 2. same-origin topology

```text
Browser
  -> HTTPS :443
Caddy (TLS termination, HTTP -> HTTPS redirect)
  -> private Docker network :8000
FastAPI + Uvicorn
  -> /api/*, /audio/*
  -> frontend/dist SPA and /static assets
  -> PostgreSQL over TLS
```

- 하나의 multi-stage image가 frontend를 build하고 Python runtime에 `frontend/dist`를
  포함한다. FastAPI가 API와 SPA를 함께 서빙해 ADR-0003의 same-origin 계약을 유지한다.
- Docker Compose는 `caddy`와 `app` 두 service만 공개 배포한다. 외부 publish는 Caddy의
  80/443뿐이며 app의 8000 포트는 내부 network에만 둔다.
- Caddy는 domain이 준비된 뒤 인증서 발급·갱신과 HTTP→HTTPS redirect를 담당한다.
  Caddy의 공식 reverse proxy 문서도 hostname과 80/443 접근이 준비되면 자동 HTTPS를
  제공하는 계약을 설명한다.
  ([Caddy reverse proxy 문서](https://caddyserver.com/docs/quick-starts/reverse-proxy))
- FastAPI는 Caddy 한 홉만 trusted proxy로 취급한다. `TRUST_PROXY=1`은 Caddy가 직접
  연결하는 배포에서만 켜며, security group은 app 포트를 인터넷에 열지 않는다.
- OAuth callback은 `https://<domain>/api/auth/callback/{provider}`로 고정한다. provider
  console의 redirect URI 변경과 domain/DNS 변경은 T028 승인 범위에서만 수행한다.

### 3. image와 배포 단위

- CI는 전체 gate를 통과한 commit에서 immutable image를 build하고 ECR에 commit SHA
  tag와 digest를 기록한다. `latest`만으로 배포하지 않는다.
- staging과 production은 같은 image digest를 사용한다. 환경 차이는 secret/config와
  연결 대상뿐이다.
- 애플리케이션 배포는 이전 정상 image digest를 보존하고, smoke 실패 시 Compose의
  image digest를 직전 값으로 되돌린다.
- DB migration은 app container 시작 명령에 넣지 않는다. migration job은 명시 승인된
  별도 단계에서 한 번 실행한다.

### 4. secret과 AWS identity

- `DATABASE_URL`, session signing secret, OAuth client secret, OpenAI key는
  **AWS Secrets Manager**에 환경별로 분리한다. 문서·image·Compose 파일에는 secret
  이름의 논리적 용도만 남기고 값과 ARN은 남기지 않는다.
- EC2에는 static AWS access key를 배치하지 않는다. instance profile의 IAM role이
  필요한 secret만 `GetSecretValue`할 수 있게 resource 단위로 허용한다. AWS는 EC2
  application에 IAM role의 임시 credential을 제공하는 방식을 문서화하고 있다.
  ([EC2 IAM role 문서](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/iam-roles-for-amazon-ec2.html),
  [Secrets Manager IAM 정책 문서](https://docs.aws.amazon.com/secretsmanager/latest/userguide/auth-and-access_iam-policies.html))
- runtime instance role은 secret read와 image pull/log write의 최소 범위만 가진다.
  infrastructure 변경 권한과 DB migration credential은 갖지 않는다.
- 로컬 `.env.local`은 개발·read-only 조사 용도다. 운영 secret의 원본이나 복사본으로
  승격하지 않는다.

### 5. PostgreSQL role 계약

환경별로 다음 identity를 분리한다.

| role | LOGIN | 목적 | 금지 |
|---|:---:|---|---|
| `shindang_deploy` | O | migration 실행 및 schema object owner | app traffic, superuser, app role membership |
| `shindang_app` | O | FastAPI runtime의 제한된 DML·함수 실행 | object ownership, CREATEROLE/CREATEDB, owner role 전환 |
| `shaman_softdelete` | X | 005가 관리하는 SECURITY DEFINER 함수 owner | 직접 로그인, 일반 membership |
| admin/bootstrap identity | O | 최초 role 생성·owner 이전·복구 | 상시 app 연결 |

구체 계약은 다음과 같다.

- 두 LOGIN role 모두 `NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION`이다.
- `shindang_app`에는 `shindang_deploy`에 대한 `SET`, `INHERIT`, `ADMIN` 능력을 주지 않는다.
- runtime의 `DATABASE_URL`은 `shindang_app`만 사용한다.
- migration job은 `shindang_deploy`로 연결하고
  `MIGRATION_OWNER=shindang_deploy`, `MIGRATION_APP_ROLES=shindang_app`을 명시한다.
- 현재 DB의 ledger와 기존 protected object가 `postgres` 소유이므로 003~005 적용 전에
  admin이 owner를 `shindang_deploy`로 이전하는 별도 변경이 필요하다. runner는 owner
  이전을 대신하지 않으며, owner anchor가 다르면 pending apply를 fail-closed로 거부한다.
- runtime GRANT는 필요한 schema USAGE, table/sequence DML, 허용 함수 EXECUTE만 열거한다.
  PUBLIC broad grant와 `GRANT ALL`은 사용하지 않는다. soft-delete는 ADR-0004의
  `app_soft_delete_user` 진입점만 허용한다.

staging과 production은 동일한 role 이름을 쓸 수 있지만 서로 다른 DB와 credential을
사용한다. production data를 staging에 복사할 때는 승인된 비식별 fixture 또는 별도
익명화 절차가 없으면 복사하지 않는다.

### 6. staging-first 릴리스 순서

순서는 예외 없이 아래로 고정한다.

```text
read-only preflight
  -> staging apply
  -> staging app smoke
  -> production approval
  -> production apply
  -> runtime/browser verification
```

1. **read-only preflight**: 현재 migration status, role 속성, owner anchor, backup 상태,
   image digest와 gate 결과를 수집한다.
2. **staging apply**: staging role/DB에 001~005 전체를 fresh apply하고, 별도 rehearsal에서
   001~002 상태로부터 003~005 upgrade도 실행한다.
3. **staging app smoke**: `shindang_app`으로 session/profile/streak 흐름, OAuth callback
   URL, rate limit, 재시작 후 session 유지, soft-delete 진입점을 검증한다.
4. **production approval**: staging 증거, 예상 SQL 변경, backup/restore 식별자, app image
   digest, rollback owner를 첨부한 독립 승인 마커를 받는다.
5. **production apply**: drain/maintenance 경계에서 owner 전환과 003~005를 한 번 실행한다.
6. **runtime/browser verification**: API smoke, 실제 브라우저 로그인/프로필/재시작,
   error/latency/DB connection 지표를 확인한다.

각 단계의 명령과 중단 조건은
`docs/research/closed-beta-deployment-runbook.md`를 정본으로 삼는다.

### 7. rollback 계약

- **app/image 실패**: 직전 정상 image digest로 되돌리고 Caddy/app smoke를 재실행한다.
- **migration 시작 전 실패**: DB를 변경하지 않고 중단한다.
- **migration 중/후 실패**: 003~005는 destructive down migration으로 되돌리지 않는다.
  승인 시점의 backup/snapshot에서 새 DB를 복구하고 app `DATABASE_URL`을 복구 DB로
  전환하거나, 영향이 제한되고 검증 가능한 경우에만 별도 forward-fix migration을 쓴다.
- **owner/GRANT 실패**: app을 이전 image로 내린 뒤 bootstrap admin만으로 복구한다.
  runtime role에 임시 superuser나 owner membership을 주는 우회는 금지한다.
- DNS TTL, backup 식별자, 이전 image digest, rollback 실행자는 production approval에
  값이 채워져야 한다. 빈 placeholder 상태로 production apply를 시작하지 않는다.

## 대안 검토

- **ECS/Fargate 즉시 도입**: 다중 인스턴스와 managed scheduling은 유리하지만 현재
  인메모리 session/rate limit 계약과 맞지 않고, 첫 배포에서 IAM·network·task 정의
  변경면이 커진다. DB persistence와 운영 부하 지표가 생긴 뒤 재평가한다.
- **FE/BE 분리 호스팅**: CDN 이점은 있으나 OAuth cookie/CORS 경계를 늘린다.
  ADR-0003의 same-origin을 유지한다.
- **migration을 app startup에 포함**: 재시작·scale-out 때 중복 실행과 권한 혼합이
  발생한다. 독립 migration job으로 분리한다.
- **현재 `postgres`를 runtime으로 사용**: 최소권한과 ADR-0004 owner guard를 모두
  무력화하므로 기각한다.

## 결과와 재검토 조건

- 클로즈드 베타의 첫 운영 topology와 승인 경계가 하나로 고정된다.
- 단일 EC2는 장애 시 서비스가 중단되는 의도적 trade-off다. 자동 복구 요구, 동시 사용자
  증가, memory limiter 불일치가 관찰되면 managed multi-instance 구조를 재검토한다.
- T027은 문서 결정만 수행한다. cloud/DNS/OAuth/DB/backend 변경은 T028~T031의 각각의
  승인 없이는 실행하지 않는다.
