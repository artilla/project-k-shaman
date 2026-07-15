#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  SHA256="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  ECR_REPOSITORY_URI="123456789012.dkr.ecr.ap-northeast-2.amazonaws.com/shindang-staging"
  common_env=(
    "DEPLOY_BUCKET=deployment-bucket"
    "BUNDLE_KEY=deployments/abc/123-1.tgz"
    "BUNDLE_VERSION_ID=version.123_-"
    "BUNDLE_SHA256=$SHA256"
    "DEPLOYMENT_ID=test-123"
    "ECR_REPOSITORY_URI=$ECR_REPOSITORY_URI"
    "DEPLOY_ENV=staging"
    "SITE_ADDRESS=https://staging.example.invalid"
    "APP_SECRET_ID=shindang/staging/app"
    "AWS_REGION=ap-northeast-2"
    "LOG_GROUP=/shindang/staging/app"
  )
}

@test "remote deploy rejects a digest from an arbitrary registry before login" {
  run env "${common_env[@]}" \
    "APP_IMAGE=attacker.example/shindang@sha256:$SHA256" \
    bash "$REPO_ROOT/deploy/remote_deploy.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"APP_IMAGE must exactly match ECR_REPOSITORY_URI"* ]]
}

@test "remote deploy rejects an ECR host outside the configured region" {
  wrong_repository="123456789012.dkr.ecr.us-east-1.amazonaws.com/shindang-staging"
  run env "${common_env[@]}" \
    "ECR_REPOSITORY_URI=$wrong_repository" \
    "APP_IMAGE=$wrong_repository@sha256:$SHA256" \
    bash "$REPO_ROOT/deploy/remote_deploy.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"ECR registry does not match"* ]]
}

@test "remote deploy requires the exact S3 VersionId" {
  run env "${common_env[@]}" \
    BUNDLE_VERSION_ID= \
    "APP_IMAGE=$ECR_REPOSITORY_URI@sha256:$SHA256" \
    bash "$REPO_ROOT/deploy/remote_deploy.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"missing required environment: BUNDLE_VERSION_ID"* ]]
}

@test "remote deploy rejects a non-deployment runtime environment" {
  run env "${common_env[@]}" \
    DEPLOY_ENV=development \
    "APP_IMAGE=$ECR_REPOSITORY_URI@sha256:$SHA256" \
    bash "$REPO_ROOT/deploy/remote_deploy.sh"

  [ "$status" -eq 2 ]
  [[ "$output" == *"invalid DEPLOY_ENV"* ]]
}
