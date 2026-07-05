#!/usr/bin/env bash
# run_checks.sh — 프로젝트 검증 진입점.
# Implementer/Reviewer/run_loop이 이 스크립트가 0 exit이면 PASS로 간주한다.
#
# 사용법:
#   ./scripts/run_checks.sh           # 전체 검증
#   ./scripts/run_checks.sh --fast    # lint 등 가벼운 것만
#
# 각 프로젝트는 이 파일의 CHECKS 배열을 자기 도구로 교체한다.
# 도구가 아직 없으면 placeholder를 echo해서 0 exit한다 (루프가 막히지 않게).

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

MODE="${1:-full}"

run() {
  local label="$1"; shift
  echo "── [check] $label"
  if "$@"; then
    echo "   ✓ $label"
  else
    echo "   ✗ $label (exit $?)" >&2
    return 1
  fi
}

# ─────────────────────────────────────────────────────────
# 1. 기본 위생 (어떤 프로젝트든 적용)
# ─────────────────────────────────────────────────────────

IS_GIT=0
git rev-parse --is-inside-work-tree >/dev/null 2>&1 && IS_GIT=1

if [ "$IS_GIT" = "1" ]; then
  run "git status clean (or only tracked)" bash -c '
    if [ -n "$(git status --porcelain | grep "^??" || true)" ]; then
      echo "untracked files present (not blocking, just noting)"
    fi
    true
  '
else
  echo "── [check] git status clean — SKIP (not a git repo)"
fi

run "no merge conflict markers" bash -c '
  ! grep -RIn --exclude-dir=.git --exclude-dir=.ralph -E "^(<<<<<<<|=======|>>>>>>>) " . 2>/dev/null
'

if [ "$IS_GIT" = "1" ]; then
  run "no obvious secrets in tracked files" bash -c '
    ! git ls-files | xargs grep -lE "(AKIA[0-9A-Z]{16}|-----BEGIN (RSA|OPENSSH) PRIVATE KEY-----|sk-[A-Za-z0-9]{20,})" 2>/dev/null
  '
else
  echo "── [check] secret scan — SKIP (not a git repo)"
fi

# ─────────────────────────────────────────────────────────
# 2. 프로젝트별 검증 (auto-detect, 없으면 skip)
# ─────────────────────────────────────────────────────────

# 헬퍼: package.json 안에 특정 npm script가 정의되어 있는지 확인
npm_has_script() {
  local key="$1"
  [ -f package.json ] || return 1
  if command -v node >/dev/null 2>&1; then
    node -e "const p=require('./package.json');process.exit(p.scripts&&p.scripts['$key']?0:1)" 2>/dev/null
  else
    # node가 없으면 보수적으로 grep — false positive 가능하지만 false negative보다 안전
    grep -qE "\"$key\"\\s*:" package.json
  fi
}

if [ -f package.json ]; then
  if npm_has_script lint; then
    run "npm lint" npm run --silent lint
  else
    echo "── [check] npm lint — SKIP (no 'lint' script in package.json)"
  fi
  if [ "$MODE" != "--fast" ]; then
    if npm_has_script test; then
      run "npm test" npm test --silent
    else
      echo "── [check] npm test — SKIP (no 'test' script in package.json)"
    fi
  fi
fi

if [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ]; then
  if command -v ruff >/dev/null 2>&1; then
    run "ruff" ruff check .
  else
    echo "── [check] ruff — SKIP (ruff not installed)"
  fi
  if [ "$MODE" != "--fast" ]; then
    if command -v pytest >/dev/null 2>&1; then
      run "pytest" bash -c '
        pytest -q
        rc=$?
        if [ "$rc" -eq 5 ]; then
          echo "pytest found no tests — skip"
          exit 0
        fi
        exit "$rc"
      '
    else
      echo "── [check] pytest — SKIP (pytest not installed)"
    fi
  fi
fi

if [ -f go.mod ]; then
  run "go vet" go vet ./...
  if [ "$MODE" != "--fast" ]; then
    run "go test" go test ./...
  fi
fi

if [ -f Cargo.toml ]; then
  run "cargo check" cargo check --quiet
  if [ "$MODE" != "--fast" ]; then
    run "cargo test" cargo test --quiet
  fi
fi

# ─────────────────────────────────────────────────────────
# 2.5 프로젝트별 로컬 검증 훅 (init_new_project.sh 위저드가 생성)
#     scripts/run_checks.local.sh 가 있으면 실행한다. 없으면 no-op.
#     → 각 프로젝트는 큰 run_checks.sh를 건드리지 않고 이 한 파일만 편집하면 된다.
# ─────────────────────────────────────────────────────────

if [ -f scripts/run_checks.local.sh ]; then
  run "project local checks" bash scripts/run_checks.local.sh
else
  echo "── [check] project local checks — SKIP (scripts/run_checks.local.sh 없음)"
fi

# ─────────────────────────────────────────────────────────
# 3. 문서 일관성 (master-spec / tickets)
# ─────────────────────────────────────────────────────────

run "master-spec exists" test -f docs/master-spec.md
run "tickets dir exists" test -d docs/tickets
run "external docs lint" ./scripts/lint_external_docs.sh
# Mission Control UI 검사는 mission-control/ 가 있는 레포에서만 (clean-extract된
# 하네스에는 mission-control/ 가 없다 — check_ui_requirements.sh 는 서버를 띄우므로 가드).
if [ -d mission-control ] && [ -x ./scripts/check_ui_requirements.sh ]; then
  run "Mission Control UI requirements R1-R5" ./scripts/check_ui_requirements.sh
fi
if ls mission-control/*.test.mjs >/dev/null 2>&1; then
  run "Mission Control UI unit tests" node --test mission-control/*.test.mjs
fi

# ─────────────────────────────────────────────────────────
# 4. bats 회귀 테스트 (설치된 경우에만 실행)
# ─────────────────────────────────────────────────────────

if command -v bats >/dev/null 2>&1; then
  if ls tests/*.bats >/dev/null 2>&1; then
    run "bats regression tests" env -u RALPH_ROOT -u RALPH_STATE_ROOT -u CLAUDE_TIMEOUT_SECONDS bats tests/*.bats
  else
    echo "── [check] bats tests — SKIP (tests/*.bats not found)"
  fi
else
  echo "── [check] bats tests — SKIP (bats not installed)"
fi

echo ""
echo "✅ all checks passed (mode: $MODE)"
