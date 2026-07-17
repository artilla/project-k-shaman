#!/usr/bin/env bash
# T028 static contract: immutable/non-root image, private app port, and no implicit migration.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

require_file() {
  test -f "$1" || { echo "missing deployment artifact: $1" >&2; exit 1; }
}

for file in \
  Dockerfile .dockerignore compose.yaml requirements-build.lock \
  deploy/Caddyfile deploy/compose.aws.yaml \
  deploy/remote_deploy.sh deploy/remote_rollback.sh \
  infra/cloudformation/staging.yaml \
  .github/workflows/app-ci.yml \
  .github/workflows/deploy-staging.yml \
  .github/workflows/promote-production.yml; do
  require_file "$file"
done

test "$(grep -Ec '^FROM [^ ]+@sha256:[0-9a-f]{64}' Dockerfile)" -ge 2
grep -Eq '^USER (10001(:10001)?|app)$' Dockerfile
grep -Eq '^HEALTHCHECK ' Dockerfile
if ! awk '
  /^[[:space:]]*#/ { next }
  /^[[:space:]]*FROM[[:space:]]/ {
    asset_mode_set = 0
    runtime_user_seen = 0
    next
  }
  /^[[:space:]]*RUN[[:space:]]+chmod[[:space:]]+-R[[:space:]]+a\+rX[[:space:]]+frontend\/dist([[:space:]]|\\$)/ {
    if (runtime_user_seen) exit 1
    asset_mode_set = 1
  }
  /^[[:space:]]*USER[[:space:]]+(10001(:10001)?|app)[[:space:]]*$/ {
    runtime_user_seen = 1
    if (!asset_mode_set) exit 1
  }
  END { if (!asset_mode_set || !runtime_user_seen) exit 1 }
' Dockerfile; then
  echo "runtime assets must be made world-readable by an active RUN before the non-root USER" >&2
  exit 1
fi
bash -n deploy/remote_deploy.sh deploy/remote_rollback.sh

if ! command -v docker >/dev/null 2>&1; then
  echo "docker is required to validate the Compose publish boundary" >&2
  exit 1
fi

docker compose config --quiet
APP_IMAGE='example.invalid/shindang@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
SESSION_SECRET='test-only-session-secret-at-least-32-bytes' \
DEPLOY_ENV='staging' \
SITE_ADDRESS='https://staging.example.invalid' \
AWS_REGION='ap-northeast-2' \
LOG_GROUP='/shindang/test/app' \
  docker compose -f deploy/compose.aws.yaml config --quiet

for deploy_env in staging production; do
  APP_IMAGE='example.invalid/shindang@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  SESSION_SECRET='test-only-session-secret-at-least-32-bytes' \
  DEPLOY_ENV="$deploy_env" \
  SITE_ADDRESS="https://$deploy_env.example.invalid" \
  AWS_REGION='ap-northeast-2' \
  LOG_GROUP="/shindang/$deploy_env/app" \
    docker compose -f deploy/compose.aws.yaml config --format json |
    DEPLOY_ENV="$deploy_env" python3 -c '
import json, os, sys
config = json.load(sys.stdin)
actual = config["services"]["app"]["environment"]["SHINDANG_ENV"]
expected = os.environ["DEPLOY_ENV"]
if actual != expected:
    raise SystemExit(f"SHINDANG_ENV mismatch: expected {expected!r}, got {actual!r}")
'
done

docker compose config --format json | python3 -c '
import json, sys
config = json.load(sys.stdin)
app = config["services"]["app"]
if app.get("ports"):
    raise SystemExit("app service must not publish a host port")
caddy = config["services"]["caddy"]
published = {(str(item["published"]), str(item["target"])) for item in caddy.get("ports", [])}
if not published or any(source not in {"80", "443"} or target not in {"80", "443"} for source, target in published):
    raise SystemExit(f"unexpected Caddy publish boundary: {sorted(published)}")
'

if grep -REn --include='*.yml' --include='*.yaml' --include='*.sh' \
  '(db_migrate[.]sh|alembic[[:space:]]+upgrade|prisma[[:space:]]+migrate|psql[^#]*(003|004|005))' \
  .github/workflows deploy Dockerfile compose.yaml; then
  echo "deployment path must not run migrations" >&2
  exit 1
fi

grep -q 'workflow_dispatch' .github/workflows/deploy-staging.yml
grep -q 'environment: staging' .github/workflows/deploy-staging.yml
grep -q 'workflow_dispatch' .github/workflows/promote-production.yml
grep -q 'environment: production' .github/workflows/promote-production.yml
grep -Fq 'header_up X-Forwarded-For {client_ip}' deploy/Caddyfile

build_step_line="$(grep -nF 'name: Build and push immutable ARM64 image' .github/workflows/deploy-staging.yml | cut -d: -f1)"
deploy_step_line="$(grep -nF 'name: Deploy through SSM' .github/workflows/deploy-staging.yml | cut -d: -f1)"
test -n "$build_step_line"
test -n "$deploy_step_line"
test "$build_step_line" -lt "$deploy_step_line"
grep -Fq 'docker buildx build \' .github/workflows/deploy-staging.yml
grep -Fq -- '--platform linux/arm64 \' .github/workflows/deploy-staging.yml
grep -Fq -- '--push \' .github/workflows/deploy-staging.yml
grep -Fq -- '--metadata-file image-metadata.json \' .github/workflows/deploy-staging.yml

if awk '
  /^[[:space:]]*- uses:/ {
    ref = $0
    sub(/^.*@/, "", ref)
    sub(/[[:space:]#].*$/, "", ref)
    if (ref !~ /^[0-9a-f]{40}$/) {
      print "action is not pinned to a full commit SHA: " $0 > "/dev/stderr"
      failed = 1
    }
  }
  END { exit failed }
' .github/workflows/*.yml; then
  :
else
  exit 1
fi

if grep -REn --include='*.yml' --include='*.yaml' --include='*.sh' \
  'aws[[:space:]]+s3[[:space:]]+cp' .github/workflows deploy; then
  echo "deployment bundles must be fetched with an exact S3 VersionId" >&2
  exit 1
fi

grep -q -- '--version-id' .github/workflows/deploy-staging.yml
grep -q -- '--version-id' .github/workflows/promote-production.yml
grep -q -- '--version-id' deploy/remote_deploy.sh
grep -q 's3:GetObjectVersion' infra/cloudformation/staging.yaml
grep -q 'DOCKER_CONFIG=' deploy/remote_deploy.sh
grep -q 'ECR_REPOSITORY_URI@sha256:<64hex>' deploy/remote_deploy.sh
compose_env_contract="SHINDANG_ENV: \${DEPLOY_ENV:?"
public_origin_contract="SHINDANG_PUBLIC_BASE_URL: \${SITE_ADDRESS:?"
github_env_contract="DEPLOY_ENV: \${{ vars.SHINDANG_ENV }}"
grep -Fq "$compose_env_contract" deploy/compose.aws.yaml
grep -Fq "$public_origin_contract" deploy/compose.aws.yaml
grep -Fq "$github_env_contract" .github/workflows/deploy-staging.yml
grep -Fq "$github_env_contract" .github/workflows/promote-production.yml

if grep -nF '|| true' deploy/remote_deploy.sh deploy/remote_rollback.sh; then
  echo "deployment and rollback failures must not be masked" >&2
  exit 1
fi

echo "container/deployment contract: ok"
