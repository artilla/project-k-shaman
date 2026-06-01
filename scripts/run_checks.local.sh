#!/usr/bin/env bash
# run_checks.local.sh — 이 프로젝트의 검증 명령 (init_new_project.sh 위저드 생성: stack=python).
# run_checks.sh가 존재 시 자동 실행한다. 비-0 exit면 전체 검증 실패.
# 자유롭게 수정하세요. 도구가 없으면 건너뛰도록 가드되어 있습니다.
set -euo pipefail
has_python_project() {
  [ -f pyproject.toml ] || [ -f setup.py ] || [ -f requirements.txt ] && return 0
  find . -path ./.git -prune -o -path ./.ralph -prune -o -name "*.py" -print -quit | grep -q .
}
has_python_tests() {
  [ -d tests ] || return 1
  find tests -name "test_*.py" -o -name "*_test.py" | grep -q .
}
if has_python_project; then
  if command -v ruff >/dev/null 2>&1; then ruff check .; else echo "ruff 없음 — skip"; fi
  if has_python_tests; then
    if command -v pytest >/dev/null 2>&1; then pytest -q; else echo "pytest 없음 — skip"; fi
  else
    echo "python 테스트 파일 없음 — pytest skip"
  fi
else
  echo "python 프로젝트 파일 없음 — skip"
fi
