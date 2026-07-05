#!/usr/bin/env bash
# run_checks.local.sh — 이 프로젝트의 검증 명령 (init_new_project.sh 위저드 생성: stack=none).
# run_checks.sh가 존재 시 자동 실행한다. 비-0 exit면 전체 검증 실패.
# 자유롭게 수정하세요. 도구가 없으면 건너뛰도록 가드되어 있습니다.
set -euo pipefail
# 이 프로젝트의 lint/test/build 명령을 여기에 넣으세요.
# 도구가 없을 때 0 exit 하도록 command -v 가드를 권장합니다.
echo "(아직 프로젝트별 검증 미설정 — run_checks.local.sh를 편집하세요)"
