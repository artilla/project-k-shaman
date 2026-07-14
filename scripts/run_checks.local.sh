#!/usr/bin/env bash
# run_checks.local.sh — 오늘신당 앱 전용 검증.
# run_checks.sh가 Python pytest/ruff와 하네스 회귀를 담당하고, 이 훅은 루트의
# auto-detect가 보지 못하는 frontend/와 Python 환경 정합성을 fail-closed로 확인한다.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "❌ project check 필수 도구가 없습니다: $1" >&2
    return 1
  }
}

require_cmd npm
require_cmd python3
test -f "$ROOT/frontend/package.json"
test -f "$ROOT/frontend/package-lock.json"

echo "── [project] frontend typecheck"
npm --prefix "$ROOT/frontend" run --silent typecheck

echo "── [project] frontend production build"
npm --prefix "$ROOT/frontend" run --silent build

echo "── [project] Python dependency consistency"
python3 -m pip check
