# T028 AWS staging infrastructure

`infra/cloudformation/staging.yaml` is the versioned staging definition. It uses
AWS CloudFormation, Amazon Linux 2023 ARM64, Docker Compose `v2.23.3`, and a
`t4g.micro` default. It deliberately creates no database resource and runs no
migration.

## Security boundary

- EC2 has no SSH ingress or static AWS key. Operations use SSM.
- Only Caddy ports 80/443 are public; app port 8000 is Compose-network-only.
- Runtime access is limited to one ECR repository, one deployment-bundle prefix,
  one Secrets Manager secret, and one CloudWatch Logs group.
- GitHub deploys assume a dedicated role through an existing GitHub OIDC provider.
- The ECR repository, bundle bucket, and app secret are retained on stack deletion.
  Review and explicitly delete retained resources separately.

## Validate and preview

Use a working AWS CLI profile. Never put account IDs, ARNs, secret values, or a
credential-bearing profile name into committed files.

```bash
aws cloudformation validate-template \
  --region ap-northeast-2 \
  --template-body file://infra/cloudformation/staging.yaml

aws cloudformation deploy \
  --region ap-northeast-2 \
  --stack-name shindang-staging \
  --template-file infra/cloudformation/staging.yaml \
  --capabilities CAPABILITY_NAMED_IAM \
  --no-execute-changeset \
  --parameter-overrides \
    VpcId=vpc-REPLACE \
    SubnetId=subnet-REPLACE \
    GitHubOidcProviderArn=arn:aws:iam::REPLACE:oidc-provider/token.actions.githubusercontent.com
```

Actual apply requires the T028 approval marker and a confirmed staging hostname.
After apply, populate only OAuth values that exist for staging in the generated
secret; do not copy production callback credentials by default.
