#!/usr/bin/env bash
# Runs on the staging EC2 host through SSM. No credential value is printed.
set -euo pipefail

required=(DEPLOY_BUCKET BUNDLE_KEY DEPLOYMENT_ID APP_IMAGE SITE_ADDRESS APP_SECRET_ID AWS_REGION LOG_GROUP)
for name in "${required[@]}"; do
  [ -n "${!name:-}" ] || { echo "missing required environment: $name" >&2; exit 2; }
done

case "$DEPLOYMENT_ID" in *[!A-Za-z0-9._-]*|'') echo "invalid DEPLOYMENT_ID" >&2; exit 2 ;; esac
[[ "$APP_IMAGE" =~ @sha256:[0-9a-f]{64}$ ]] || {
  echo "APP_IMAGE must use an immutable sha256 digest" >&2
  exit 2
}
case "$SITE_ADDRESS" in https://*) : ;; *) echo "SITE_ADDRESS must be https" >&2; exit 2 ;; esac

ROOT=/opt/shindang
RELEASES="$ROOT/releases"
RELEASE="$RELEASES/$DEPLOYMENT_ID"
CURRENT="$ROOT/current"
mkdir -p "$RELEASES"
exec 9>"$ROOT/deploy.lock"
flock -n 9 || { echo "another deployment is active" >&2; exit 1; }
[ ! -e "$RELEASE" ] || { echo "deployment ID already exists" >&2; exit 2; }

WORK="$(mktemp -d /tmp/shindang-deploy.XXXXXX)"
umask 077
switched=0
release_created=0

finish() {
  rc=$?
  trap - EXIT ERR
  set +e
  if [ "$rc" -ne 0 ] && [ "$switched" = "1" ] && declare -F rollback >/dev/null; then
    rollback
  fi
  if [ "$rc" -ne 0 ] && [ "$release_created" = "1" ]; then
    current_target="$(readlink "$CURRENT" 2>/dev/null || true)"
    if [ "$current_target" != "$RELEASE" ]; then
      rm -rf "$RELEASE"
    fi
  fi
  rm -rf "$WORK"
  exit "$rc"
}
trap finish EXIT

mkdir "$RELEASE"
release_created=1
aws s3 cp "s3://$DEPLOY_BUCKET/$BUNDLE_KEY" "$WORK/bundle.tgz" --only-show-errors

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

APP_IMAGE="$APP_IMAGE" SITE_ADDRESS="$SITE_ADDRESS" AWS_REGION="$AWS_REGION" LOG_GROUP="$LOG_GROUP" \
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

registry="${APP_IMAGE%%/*}"
aws ecr get-login-password --region "$AWS_REGION" \
  | docker login --username AWS --password-stdin "$registry" >/dev/null

previous=""
if [ -L "$CURRENT" ]; then
  previous="$(readlink "$CURRENT")"
fi

compose() {
  docker compose --project-name shindang --env-file "$CURRENT/.env" -f "$CURRENT/compose.aws.yaml" "$@"
}

rollback() {
  if [ -n "$previous" ] && [ -d "$previous" ]; then
    rm -f "$ROOT/current.rollback"
    ln -s "$previous" "$ROOT/current.rollback"
    mv -Tf "$ROOT/current.rollback" "$CURRENT"
    compose up -d --remove-orphans >/dev/null 2>&1 || true
  else
    compose down >/dev/null 2>&1 || true
    rm -f "$CURRENT"
  fi
}

rm -f "$ROOT/current.next" "$ROOT/current.rollback"
ln -s "$RELEASE" "$ROOT/current.next"
mv -Tf "$ROOT/current.next" "$CURRENT"
switched=1

compose config --quiet
compose pull --quiet
compose up -d --remove-orphans

ready=0
for _ in $(seq 1 30); do
  if compose exec -T app python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=2)" \
    >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 2
done
[ "$ready" = "1" ] || { echo "application health check failed" >&2; exit 1; }

image_digest="${APP_IMAGE##*@}"
printf 'deployment_id=%s\nimage_digest=%s\nsite_address=%s\ndeployed_at=%s\n' \
  "$DEPLOYMENT_ID" "$image_digest" "$SITE_ADDRESS" "$(date -Iseconds)" > "$RELEASE/deployment.record"
chmod 600 "$RELEASE/deployment.record"
switched=0

echo "deployment healthy: id=$DEPLOYMENT_ID digest=$image_digest"
