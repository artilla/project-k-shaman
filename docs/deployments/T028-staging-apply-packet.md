# T028 staging apply packet

> 상태: 외부 입력 대기 · 실행 전용 체크리스트
>
> 이 문서는 T028의 AWS hosting, HTTPS, OAuth, app rollback만 다룬다. DB role/schema/data와
> migration 003~005는 T030 승인 범위이므로 여기서 실행하지 않는다. 실제 값은 repository에
> 기록하지 않고 승인된 operator shell, AWS, GitHub environment에만 둔다.

## 1. 실행 전 중단 조건

다음 중 하나라도 참이면 change set을 생성하거나 workflow를 승인하지 않는다.

- `node ralph/mission-control/approval.mjs "$PWD" T028`이 `ok`가 아니다.
- 배포할 revision이 remote branch에 없거나 GitHub Actions run의 `headSha`와 다르다.
- worktree가 깨끗하지 않다. 현재 보류 중인 root PDF 삭제도 push 전에 복원 또는 별도
  commit 중 하나로 결정해야 한다.
- staging hostname, DNS operator, VPC/subnet, GitHub OIDC provider 확인 주체 중 하나가 없다.
- Google/Kakao staging app의 callback URI가 확정되지 않았다.
- GitHub `staging` environment reviewer와 아래 non-secret variable이 준비되지 않았다.
- 새 change set이 `CREATE_COMPLETE`와 `AVAILABLE`이 아니거나 예상하지 않은 replacement,
  broad IAM, 8000/22 ingress, DB resource가 포함된다.
- `awscli-cloudformation-package-deploy-1784078378` change set을 실행 대상으로 선택했다.
  이 change set은 현재 template보다 오래된 superseded artifact다.
- secret 값, account ID, full ARN, 개인 test identity가 로그나 deployment record에 들어간다.

## 2. 외부 입력 확인표

값은 이 표에 적지 않고 준비 여부와 책임자만 실제 deployment record에 남긴다.

| 입력 | 필요한 계약 | 준비 |
|---|---|:---:|
| staging hostname | `https://<host>`, trailing slash 없음 | [ ] |
| DNS operator | stack EIP로 A record를 연결하고 TTL/전파를 확인 | [ ] |
| VPC / public subnet | Seoul `ap-northeast-2`, 인터넷 egress와 80/443 ingress 가능 | [ ] |
| GitHub OIDC provider | `token.actions.githubusercontent.com`, audience `sts.amazonaws.com` | [ ] |
| IAM operator | OIDC provider와 change-set IAM diff를 확인 | [ ] |
| Google staging app | callback `https://<host>/api/auth/callback/google` | [ ] |
| Kakao staging app | callback `https://<host>/api/auth/callback/kakao` | [ ] |
| GitHub environment reviewer | `staging` job의 외부 write 직전 승인 담당 | [ ] |

## 3. immutable repository preflight

push는 별도 사용자 승인 뒤에만 한다. push가 완료된 실행 시점에 아래 값을 새로 산정한다.

```bash
export DEPLOY_BRANCH=master
export DEPLOY_REV="$(git rev-parse HEAD)"

node ralph/mission-control/approval.mjs "$PWD" T028
git status --short --branch
git fetch remote
test "$(git rev-parse "remote/$DEPLOY_BRANCH")" = "$DEPLOY_REV"
./ralph/scripts/run_checks.sh --full
```

필수 증거:

- exact `DEPLOY_REV`
- gate 종료 코드 0
- PG16 migration contract `1..70` 전체 pass인 CI 로그
- Docker `buildx build --push`가 SSM 단계보다 먼저 성공한 run
- workflow run의 `headSha == DEPLOY_REV`

## 4. fresh CloudFormation change set

아래 명령은 operator가 외부 값을 환경변수로 주입한 뒤 실행한다. `validate-template`은
read-only지만 `create-change-set`부터 AWS 상태를 변경한다. 이전 change set은 실행하지 않는다.

```bash
export AWS_REGION=ap-northeast-2
export STACK_NAME=shindang-staging
export CHANGE_SET="shindang-staging-$(date -u +%Y%m%dT%H%M%SZ)"
export TEMPLATE_SHA256="$(shasum -a 256 infra/cloudformation/staging.yaml | awk '{print $1}')"

aws cloudformation validate-template \
  --region "$AWS_REGION" \
  --template-body file://infra/cloudformation/staging.yaml >/dev/null

aws cloudformation create-change-set \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET" \
  --change-set-type CREATE \
  --template-body file://infra/cloudformation/staging.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --parameters \
    ParameterKey=Environment,ParameterValue=staging \
    ParameterKey=GitHubRepository,ParameterValue="$GITHUB_REPOSITORY" \
    ParameterKey=GitHubOidcProviderArn,ParameterValue="$GITHUB_OIDC_PROVIDER_ARN" \
    ParameterKey=VpcId,ParameterValue="$VPC_ID" \
    ParameterKey=SubnetId,ParameterValue="$SUBNET_ID"

aws cloudformation wait change-set-create-complete \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET"

aws cloudformation describe-change-set \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET" \
  --query '{Status:Status,ExecutionStatus:ExecutionStatus,Changes:Changes[*].ResourceChange.{Action:Action,LogicalResourceId:LogicalResourceId,ResourceType:ResourceType,Replacement:Replacement}}'
```

현재 stack이 첫 CREATE를 이미 완료한 상태라면 change-set type은 `UPDATE`로 바꾼다.
`REVIEW_IN_PROGRESS`인 미실행 create stack에는 `CREATE`를 사용한다. reviewer는 CLI 출력과
`TEMPLATE_SHA256`만 기록하고 parameter 값, ARN, account ID는 deployment record에 복사하지
않는다.

review가 승인된 뒤에만 실행한다.

```bash
aws cloudformation execute-change-set \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME" \
  --change-set-name "$CHANGE_SET"
aws cloudformation wait stack-create-complete \
  --region "$AWS_REGION" \
  --stack-name "$STACK_NAME"
```

UPDATE change set이면 마지막 wait는 `stack-update-complete`를 사용한다. 실패하면 반복 execute하지
않고 stack event를 읽어 실패 resource를 확정한 뒤 중단한다.

## 5. stack 이후 wiring

stack output은 operator shell에서만 읽어 다음 GitHub `staging` environment variable로
설정한다. 값 자체를 문서나 채팅에 붙이지 않는다.

| GitHub variable | CloudFormation output / 고정값 |
|---|---|
| `AWS_DEPLOY_ROLE_ARN` | `GitHubDeployRoleArn` |
| `ECR_REPOSITORY_URI` | `EcrRepositoryUri` |
| `DEPLOYMENT_BUCKET` | `DeploymentBucketName` |
| `APP_SECRET_ID` | `AppSecretId` |
| `STAGING_INSTANCE_ID` | `InstanceId` |
| `STAGING_LOG_GROUP` | `LogGroupName` |
| `SHINDANG_ENV` | literal `staging` |

필수 순서:

1. stack의 `PublicIp`로 staging hostname A record를 연결한다.
2. `dig +short "$STAGING_HOSTNAME"`이 해당 EIP로 수렴할 때까지 기다린다.
3. SSM managed instance가 `Online`인지 확인한다. SSH/22를 열지 않는다.
4. Secrets Manager 값은 0600 임시 JSON 또는 승인된 secret UI로 넣는다. CLI argument나
   shell history에 secret literal을 넣지 않는다.
5. 최소 `SESSION_SECRET` 32자 이상과 `TTS_BACKEND=mock`을 유지한다. OAuth를 검증할
   provider의 client ID/secret만 추가한다.
6. Google/Kakao console의 callback URI를 §2의 exact HTTPS URL로 확정한다.
7. GitHub `staging` environment에 required reviewer와 위 변수를 설정한다.

## 6. staging workflow

GitHub Actions에서 `deploy-staging.yml`을 `DEPLOY_BRANCH`로 dispatch하고
`site_address=https://<staging-host>`를 입력한다. environment approval 전에 run의
`headSha`가 `DEPLOY_REV`인지 확인한다.

필수 성공 순서:

```text
input validation
  -> PostgreSQL 16 migration contract 1..70
  -> full repository gate
  -> buildx ARM64 build + immutable ECR push
  -> versioned S3 bundle upload
  -> SSM deploy + internal health/readiness/providers smoke
  -> public HTTPS smoke
  -> deployment evidence upload
```

artifact의 `deployment-evidence/staging.json`에서 다음만 dated staging record로 옮긴다.

- revision, image digest
- bundle key, exact VersionId, bundle SHA-256
- SSM command ID
- previous release/digest
- deployment timestamp와 remote status

run이 실패하면 artifact가 있더라도 `status=healthy`, expected digest, exact VersionId와
bundle SHA-256이 모두 일치하지 않는 한 배포 성공으로 기록하지 않는다.

## 7. HTTPS와 OAuth smoke

```bash
export SITE_ADDRESS="https://$STAGING_HOSTNAME"
curl --fail --silent --show-error "$SITE_ADDRESS/healthz" | jq -e '.status == "ok"'
curl --fail --silent --show-error "$SITE_ADDRESS/readyz" | jq -e '.status == "ready"'
curl --fail --silent --show-error "$SITE_ADDRESS/api/auth/providers" \
  | jq -e '.providers.google == true and .providers.kakao == true'
curl --fail --silent --show-error "$SITE_ADDRESS/api/auth/me" \
  | jq -e '.loggedIn == false'
```

각 provider는 새 private browser profile에서 별도로 검증한다.

1. `$SITE_ADDRESS/api/auth/login/<provider>`가 provider domain으로 redirect되는지 확인한다.
2. provider에 표시된 callback이 exact staging origin인지 확인하고 승인된 test identity로
   로그인한다. 개인 email/ID/token은 증거에 남기지 않는다.
3. callback 뒤 URL이 `/`이고 `auth_error=1`, authorization code, access token이 남지 않는지
   확인한다.
4. `/api/auth/me`가 `loggedIn=true`와 올바른 provider를 반환하는지 확인한다.
5. session cookie가 `Secure`, `HttpOnly`, `SameSite=Lax`이고 OAuth state cookie가 제거됐는지
   browser storage에서 확인한다.
6. logout 후 `/api/auth/me`가 `loggedIn=false`인지 확인한다.
7. app/Caddy log에 code, token, secret, email, provider subject가 없는지 확인한다.

provider 하나가 준비되지 않았다면 결과를 `not-configured`로 기록할 수는 있지만 T028의
두-provider OAuth acceptance는 완료로 표시하지 않는다.

## 8. rollback drill

첫 배포에서 `previous_release=none`이면 rollback drill을 실행할 수 없으며 T028 rollback
acceptance를 완료로 표시하지 않는다. `previous_digest`가 candidate digest와 같아도 image
rollback 증거로 인정하지 않는다. 서로 다른 이전 정상 digest가 있는 다음 healthy deployment에서
아래를 수행한다.

1. staging evidence의 `previous_release`와 `previous_digest`를 승인한다.
2. SSM `AWS-RunShellScript`로 현재 release의 `remote_rollback.sh`를 실행하되
   `ROLLBACK_RELEASE=<previous_release>`만 전달한다.
3. invocation status가 `Success`이고 stdout의 `rollback healthy` digest가 승인한
   `previous_digest`와 정확히 같은지 확인한다.
4. §7의 health/readiness/providers와 OAuth smoke를 다시 실행한다.
5. candidate digest, restored digest, 시작/종료 시각, command ID를 record에 남긴다.

중단 조건:

- release ID가 `[A-Za-z0-9._-]+`가 아니다.
- previous release/digest가 evidence와 다르거나 release가 `none`이다.
- rollback 내부 smoke 또는 public HTTPS/OAuth smoke가 실패한다.
- 실패한 manual rollback이 자동으로 직전 active release를 복원하지 못한다.

## 9. 완료 판정

다음을 모두 만족해야 T028을 DONE으로 이동할 수 있다.

- exact remote revision의 workflow와 immutable digest evidence
- stack, SSM, 80/443-only, no-static-credential 증거
- clean `buildx --push`와 public HTTPS smoke
- Google/Kakao 각각의 OAuth browser smoke
- 서로 다른 이전 정상 digest로의 rollback drill과 post-rollback smoke
- `docs/deployments/T028-staging-template.md`를 복사한 dated record
- migration/DB write `no`, secret/account/personal identity 기록 `no`
