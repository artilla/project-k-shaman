#!/usr/bin/env bash
# Runs on the deployment EC2 host through SSM. No credential value is printed.
set -euo pipefail

required=(
  DEPLOY_BUCKET BUNDLE_KEY BUNDLE_VERSION_ID BUNDLE_SHA256 DEPLOYMENT_ID
  APP_IMAGE ECR_REPOSITORY_URI DEPLOY_ENV SITE_ADDRESS APP_SECRET_ID AWS_REGION LOG_GROUP
)
for name in "${required[@]}"; do
  [ -n "${!name:-}" ] || { echo "missing required environment: $name" >&2; exit 2; }
done

case "$DEPLOYMENT_ID" in *[!A-Za-z0-9._-]*|'') echo "invalid DEPLOYMENT_ID" >&2; exit 2 ;; esac
[[ "$AWS_REGION" =~ ^[a-z]{2}(-gov)?-[a-z0-9-]+-[0-9]+$ ]] || {
  echo "invalid AWS_REGION" >&2
  exit 2
}
case "$DEPLOY_ENV" in staging|production) : ;; *) echo "invalid DEPLOY_ENV" >&2; exit 2 ;; esac
if [[ ! "$BUNDLE_KEY" =~ ^deployments/[A-Za-z0-9._/-]+[.]tgz$ ]] || [[ "$BUNDLE_KEY" == *".."* ]]; then
  echo "invalid BUNDLE_KEY" >&2
  exit 2
fi
if [[ ! "$BUNDLE_VERSION_ID" =~ ^[-A-Za-z0-9._~+/=]+$ ]] || [ "${#BUNDLE_VERSION_ID}" -gt 1024 ]; then
  echo "invalid BUNDLE_VERSION_ID" >&2
  exit 2
fi
[ "$BUNDLE_VERSION_ID" != null ] || { echo "null S3 VersionId is not immutable" >&2; exit 2; }
[[ "$BUNDLE_SHA256" =~ ^[0-9a-f]{64}$ ]] || {
  echo "invalid BUNDLE_SHA256" >&2
  exit 2
}
case "$SITE_ADDRESS" in https://*) : ;; *) echo "SITE_ADDRESS must be https" >&2; exit 2 ;; esac

registry="${ECR_REPOSITORY_URI%%/*}"
[[ "$ECR_REPOSITORY_URI" == "$registry/"* ]] || {
  echo "ECR_REPOSITORY_URI must include a repository path" >&2
  exit 2
}
repository="${ECR_REPOSITORY_URI#"$registry/"}"
registry_pattern="^[0-9]{12}[.]dkr[.]ecr[.]${AWS_REGION}[.]amazonaws[.]com$"
[[ "$registry" =~ $registry_pattern ]] || {
  echo "ECR registry does not match the configured AWS account/region form" >&2
  exit 2
}
[[ "$repository" =~ ^[a-z0-9]+([._/-][a-z0-9]+)*$ ]] || {
  echo "invalid ECR repository path" >&2
  exit 2
}
image_prefix="$ECR_REPOSITORY_URI@sha256:"
image_digest="${APP_IMAGE#"$image_prefix"}"
if [[ "$APP_IMAGE" != "$image_prefix$image_digest" ]] || [[ ! "$image_digest" =~ ^[0-9a-f]{64}$ ]]; then
  echo "APP_IMAGE must exactly match ECR_REPOSITORY_URI@sha256:<64hex>" >&2
  exit 2
fi

ROOT=/opt/shindang
RELEASES="$ROOT/releases"
RECORDS="$ROOT/deployment-records"
RELEASE="$RELEASES/$DEPLOYMENT_ID"
CURRENT="$ROOT/current"
mkdir -p "$RELEASES" "$RECORDS"
exec 9>"$ROOT/deploy.lock"
flock -n 9 || { echo "another deployment is active" >&2; exit 1; }
[ ! -e "$RELEASE" ] || { echo "deployment ID already exists" >&2; exit 2; }

previous=""
previous_release="none"
previous_digest="none"
if [ -L "$CURRENT" ]; then
  previous="$(readlink -f "$CURRENT")"
  case "$previous" in
    "$RELEASES"/*) : ;;
    *) echo "current release points outside the release root" >&2; exit 2 ;;
  esac
  if [ ! -d "$previous" ] || [ ! -f "$previous/.env" ] || [ ! -f "$previous/compose.aws.yaml" ]; then
    echo "current release is incomplete" >&2
    exit 2
  fi
  previous_release="${previous##*/}"
  previous_image="$(awk -F= '$1 == "APP_IMAGE" { print substr($0, index($0, "=") + 1); exit }' "$previous/.env")"
  previous_image_digest="${previous_image#"$image_prefix"}"
  if [[ "$previous_image" != "$image_prefix$previous_image_digest" ]] || [[ ! "$previous_image_digest" =~ ^[0-9a-f]{64}$ ]]; then
    echo "current release image is outside the trusted ECR repository" >&2
    exit 2
  fi
  previous_digest="sha256:$previous_image_digest"
fi

record_file="$RECORDS/$DEPLOYMENT_ID.record"
record_status=deploying
rollback_status=not-started
started_at="$(date -Iseconds)"
finished_at=""

write_record() {
  local temporary
  temporary="$(mktemp "$RECORDS/.${DEPLOYMENT_ID}.XXXXXX")"
  printf '%s\n' \
    "deployment_id=$DEPLOYMENT_ID" \
    "candidate_digest=sha256:$image_digest" \
    "previous_release=$previous_release" \
    "previous_digest=$previous_digest" \
    "bundle_key=$BUNDLE_KEY" \
    "bundle_version_id=$BUNDLE_VERSION_ID" \
    "bundle_sha256=$BUNDLE_SHA256" \
    "site_address=$SITE_ADDRESS" \
    "deploy_env=$DEPLOY_ENV" \
    "status=$record_status" \
    "rollback_status=$rollback_status" \
    "started_at=$started_at" \
    "finished_at=$finished_at" > "$temporary"
  chmod 600 "$temporary"
  mv -f "$temporary" "$record_file"
}

emit_result() {
  RESULT_STATUS="$record_status" ROLLBACK_STATUS="$rollback_status" \
  PREVIOUS_RELEASE="$previous_release" PREVIOUS_DIGEST="$previous_digest" \
  IMAGE_DIGEST="sha256:$image_digest" DEPLOY_ENV_RESULT="$DEPLOY_ENV" \
  BUNDLE_VERSION_ID_RESULT="$BUNDLE_VERSION_ID" BUNDLE_SHA256_RESULT="$BUNDLE_SHA256" \
  python3 - <<'PY'
import json
import os

result = {
    "status": os.environ["RESULT_STATUS"],
    "rollback_status": os.environ["ROLLBACK_STATUS"],
    "previous_release": os.environ["PREVIOUS_RELEASE"],
    "previous_digest": os.environ["PREVIOUS_DIGEST"],
    "image_digest": os.environ["IMAGE_DIGEST"],
    "bundle_version_id": os.environ["BUNDLE_VERSION_ID_RESULT"],
    "bundle_sha256": os.environ["BUNDLE_SHA256_RESULT"],
    "deploy_env": os.environ["DEPLOY_ENV_RESULT"],
}
print("SHINDANG_DEPLOY_RESULT=" + json.dumps(result, separators=(",", ":"), sort_keys=True))
PY
}

WORK=""
switched=0
release_created=0

compose() {
  docker compose --project-name shindang --env-file "$CURRENT/.env" -f "$CURRENT/compose.aws.yaml" "$@"
}

wait_for_smoke() {
  local path ready
  ready=0
  for _ in $(seq 1 30); do
    ready=1
    for path in healthz readyz api/auth/providers; do
      if ! compose exec -T app python -c \
        "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/$path', timeout=2)" \
        >/dev/null 2>&1; then
        ready=0
        break
      fi
    done
    [ "$ready" = "1" ] && return 0
    sleep 2
  done
  echo "application health/readiness smoke failed" >&2
  return 1
}

rollback() {
  if [ -n "$previous" ]; then
    rm -f "$ROOT/current.rollback"
    ln -s "$previous" "$ROOT/current.rollback"
    mv -Tf "$ROOT/current.rollback" "$CURRENT"
    compose config --quiet
    compose pull --quiet
    compose up -d --remove-orphans
    wait_for_smoke
  else
    compose down
    rm -f "$CURRENT"
  fi
}

finish() {
  local rc current_target
  rc=$?
  trap - EXIT
  set +e
  if [ "$rc" -ne 0 ]; then
    record_status=failed
    rollback_status=not-required
    if [ "$switched" = "1" ]; then
      if rollback; then
        rollback_status=healthy
      else
        rollback_status=failed
        rc=70
        echo "automatic rollback health/readiness smoke failed" >&2
      fi
    fi
  fi
  if [ "$rc" -ne 0 ] && [ "$release_created" = "1" ]; then
    current_target=""
    if [ -L "$CURRENT" ]; then
      current_target="$(readlink -f "$CURRENT")"
    fi
    if [ "$current_target" != "$RELEASE" ]; then
      if ! rm -rf "$RELEASE"; then
        echo "failed to remove incomplete release" >&2
        rc=73
      fi
    fi
  fi
  if [ -n "$WORK" ] && ! rm -rf "$WORK"; then
    echo "failed to remove temporary deployment credentials" >&2
    record_status=failed
    [ "$rc" -ne 0 ] || rc=72
  fi
  finished_at="$(date -Iseconds)"
  if ! write_record; then
    echo "failed to persist deployment record" >&2
    [ "$rc" -ne 0 ] || rc=71
  fi
  emit_result
  exit "$rc"
}
trap finish EXIT

write_record

WORK="$(mktemp -d /tmp/shindang-deploy.XXXXXX)"
umask 077
DOCKER_CONFIG="$WORK/docker-config"
export DOCKER_CONFIG
install -d -m 0700 "$DOCKER_CONFIG"

mkdir "$RELEASE"
release_created=1
aws s3api get-object \
  --bucket "$DEPLOY_BUCKET" \
  --key "$BUNDLE_KEY" \
  --version-id "$BUNDLE_VERSION_ID" \
  "$WORK/bundle.tgz" >/dev/null
printf '%s  %s\n' "$BUNDLE_SHA256" "$WORK/bundle.tgz" | sha256sum --check --status

while IFS= read -r path; do
  case "$path" in /*|../*|*/../*|*/..) echo "unsafe bundle path" >&2; exit 2 ;; esac
done < <(tar -tzf "$WORK/bundle.tgz")
if tar -tvzf "$WORK/bundle.tgz" | awk '$1 ~ /^l/ { found=1 } END { exit found ? 0 : 1 }'; then
  echo "bundle symlinks are forbidden" >&2
  exit 2
fi
tar -xzf "$WORK/bundle.tgz" -C "$RELEASE"
chmod 700 "$RELEASE/remote_deploy.sh" "$RELEASE/remote_rollback.sh"

aws secretsmanager get-secret-value \
  --secret-id "$APP_SECRET_ID" \
  --query SecretString \
  --output text > "$WORK/secret.json"
chmod 600 "$WORK/secret.json"

APP_IMAGE="$APP_IMAGE" DEPLOY_ENV="$DEPLOY_ENV" SITE_ADDRESS="$SITE_ADDRESS" \
AWS_REGION="$AWS_REGION" LOG_GROUP="$LOG_GROUP" \
python3 - "$WORK/secret.json" "$RELEASE/.env" <<'PY'
import json
import os
import re
import sys

source, target = sys.argv[1:]
with open(source, encoding="utf-8") as handle:
    secret = json.load(handle)
if not isinstance(secret, dict):
    raise SystemExit("secret must be a JSON object")

allowed = (
    "SESSION_SECRET",
    "GOOGLE_CLIENT_ID",
    "GOOGLE_CLIENT_SECRET",
    "KAKAO_REST_API_KEY",
    "KAKAO_CLIENT_SECRET",
    "OPENAI_API_KEY",
)
session_secret = secret.get("SESSION_SECRET", "")
if not isinstance(session_secret, str) or len(session_secret) < 32:
    raise SystemExit("SESSION_SECRET must be at least 32 characters")

values = {
    "APP_IMAGE": os.environ["APP_IMAGE"],
    "DEPLOY_ENV": os.environ["DEPLOY_ENV"],
    "SITE_ADDRESS": os.environ["SITE_ADDRESS"],
    "AWS_REGION": os.environ["AWS_REGION"],
    "LOG_GROUP": os.environ["LOG_GROUP"],
    "TTS_BACKEND": "mock",
}
for key in allowed:
    value = secret.get(key)
    if value is None:
        continue
    if not isinstance(value, str) or not re.fullmatch(r"[A-Za-z0-9._~+/=@:-]+", value):
        raise SystemExit(f"{key} contains unsupported dotenv characters")
    values[key] = value

with open(target, "w", encoding="utf-8") as handle:
    for key, value in values.items():
        handle.write(f"{key}={value}\n")
PY
chmod 600 "$RELEASE/.env"
rm -f "$WORK/secret.json"

aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null

rm -f "$ROOT/current.next" "$ROOT/current.rollback"
ln -s "$RELEASE" "$ROOT/current.next"
mv -Tf "$ROOT/current.next" "$CURRENT"
switched=1

compose config --quiet
compose pull --quiet
printf '%s  %s\n' "$BUNDLE_SHA256" "$WORK/bundle.tgz" | sha256sum --check --status
compose up -d --remove-orphans
wait_for_smoke
rm -rf "$DOCKER_CONFIG"
unset DOCKER_CONFIG

record_status=healthy
rollback_status=not-required
finished_at="$(date -Iseconds)"
write_record
cp "$record_file" "$RELEASE/deployment.record"
chmod 600 "$RELEASE/deployment.record"
switched=0

echo "deployment healthy: id=$DEPLOYMENT_ID digest=sha256:$image_digest"
