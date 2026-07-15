#!/usr/bin/env bash
# Runs on the EC2 host. ROLLBACK_RELEASE is a prior deployment ID, never an image tag.
set -euo pipefail

[ -n "${ROLLBACK_RELEASE:-}" ] || { echo "ROLLBACK_RELEASE is required" >&2; exit 2; }
case "$ROLLBACK_RELEASE" in *[!A-Za-z0-9._-]*|'') echo "invalid ROLLBACK_RELEASE" >&2; exit 2 ;; esac

ROOT=/opt/shindang
TARGET="$ROOT/releases/$ROLLBACK_RELEASE"
CURRENT="$ROOT/current"
mkdir -p "$ROOT"
exec 9>"$ROOT/deploy.lock"
flock -n 9 || { echo "another deployment is active" >&2; exit 1; }
[ -d "$TARGET" ] || { echo "rollback release not found" >&2; exit 2; }
if [ ! -f "$TARGET/.env" ] || [ ! -f "$TARGET/compose.aws.yaml" ]; then
  echo "rollback release is incomplete" >&2
  exit 2
fi

previous=""
if [ -L "$CURRENT" ]; then
  previous="$(readlink "$CURRENT")"
fi

restore_previous() {
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "$previous" ] && [ -d "$previous" ]; then
    rm -f "$ROOT/current.failed"
    ln -s "$previous" "$ROOT/current.failed"
    mv -Tf "$ROOT/current.failed" "$CURRENT"
    docker compose --project-name shindang \
      --env-file "$CURRENT/.env" \
      -f "$CURRENT/compose.aws.yaml" \
      up -d --remove-orphans >/dev/null 2>&1 || true
  elif [ "$rc" -ne 0 ]; then
    docker compose --project-name shindang \
      --env-file "$CURRENT/.env" \
      -f "$CURRENT/compose.aws.yaml" \
      down >/dev/null 2>&1 || true
    rm -f "$CURRENT"
  fi
  exit "$rc"
}
trap restore_previous EXIT

rm -f "$ROOT/current.rollback"
ln -s "$TARGET" "$ROOT/current.rollback"
mv -Tf "$ROOT/current.rollback" "$CURRENT"
docker compose --project-name shindang \
  --env-file "$CURRENT/.env" \
  -f "$CURRENT/compose.aws.yaml" \
  up -d --remove-orphans

for path in healthz readyz api/auth/providers; do
  docker compose --project-name shindang \
    --env-file "$CURRENT/.env" \
    -f "$CURRENT/compose.aws.yaml" \
    exec -T app python -c \
    "import urllib.request; urllib.request.urlopen('http://127.0.0.1:8000/$path', timeout=2)"
done

digest="$(awk -F= '$1=="APP_IMAGE" { sub(/^.*@/, "", $2); print $2; exit }' "$TARGET/.env")"
trap - EXIT
echo "rollback healthy: release=$ROLLBACK_RELEASE digest=$digest"
