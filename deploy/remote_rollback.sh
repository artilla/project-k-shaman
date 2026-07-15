#!/usr/bin/env bash
# Runs on the EC2 host. ROLLBACK_RELEASE is a prior deployment ID, never an image tag.
set -euo pipefail

[ -n "${ROLLBACK_RELEASE:-}" ] || { echo "ROLLBACK_RELEASE is required" >&2; exit 2; }
case "$ROLLBACK_RELEASE" in *[!A-Za-z0-9._-]*|'') echo "invalid ROLLBACK_RELEASE" >&2; exit 2 ;; esac

ROOT=/opt/shindang
RELEASES="$ROOT/releases"
TARGET="$RELEASES/$ROLLBACK_RELEASE"
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
  previous="$(readlink -f "$CURRENT")"
  case "$previous" in
    "$RELEASES"/*) : ;;
    *) echo "current release points outside the release root" >&2; exit 2 ;;
  esac
  if [ ! -d "$previous" ] || [ ! -f "$previous/.env" ] || [ ! -f "$previous/compose.aws.yaml" ]; then
    echo "current release is incomplete" >&2
    exit 2
  fi
fi

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
  echo "rollback health/readiness smoke failed" >&2
  return 1
}

restore_previous() {
  local rc
  rc=$?
  trap - EXIT
  if [ "$rc" -ne 0 ] && [ -n "$previous" ]; then
    rm -f "$ROOT/current.failed"
    ln -s "$previous" "$ROOT/current.failed"
    mv -Tf "$ROOT/current.failed" "$CURRENT"
    if ! compose up -d --remove-orphans || ! wait_for_smoke; then
      echo "failed to restore the release active before manual rollback" >&2
      exit 70
    fi
  elif [ "$rc" -ne 0 ]; then
    if ! compose down; then
      echo "failed to stop the unhealthy rollback target" >&2
      exit 70
    fi
    rm -f "$CURRENT"
  fi
  exit "$rc"
}
trap restore_previous EXIT

rm -f "$ROOT/current.rollback"
ln -s "$TARGET" "$ROOT/current.rollback"
mv -Tf "$ROOT/current.rollback" "$CURRENT"
compose up -d --remove-orphans
wait_for_smoke

digest="$(awk -F= '$1 == "APP_IMAGE" { sub(/^.*@/, "", $2); print $2; exit }' "$TARGET/.env")"
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || { echo "rollback release has an invalid image digest" >&2; exit 2; }
trap - EXIT
echo "rollback healthy: release=$ROLLBACK_RELEASE digest=$digest"
