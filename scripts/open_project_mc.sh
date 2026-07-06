#!/usr/bin/env bash
# scripts/open_project_mc.sh — 새 프로젝트(타깃)의 Mission Control 시작 + URL 출력
# T303 (ADR-0207): 완료 화면 "다음 단계"를 웹에서 이어가기 위한 단일 실행 경로.
#
# 사용법:
#   ./scripts/open_project_mc.sh <target-dir> [--port <n>]
#
# 안전 규칙:
#   - 대상은 SOURCE(이 저장소) 밖이어야 한다 (init_new_project와 동일 불변).
#   - 대상에 하네스 마커(mission-control/server.mjs + scripts/mission_control.sh)가
#     없으면 거부 — 임의 폴더에서 임의 코드를 실행하지 않는다.
#   - 이미 실행 중이면 재시작하지 않고 기존 포트의 URL만 출력 (멱등).
#   - SOURCE는 어떤 것도 쓰지 않는다. 쓰기는 대상의 state/ 뿐 (pid·log).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() { echo "사용법: ./scripts/open_project_mc.sh <target-dir> [--port <n>]"; }

TARGET_ARG="${1:-}"
if [ -z "$TARGET_ARG" ] || [ "$TARGET_ARG" = "--help" ] || [ "$TARGET_ARG" = "-h" ]; then
  usage; [ -n "$TARGET_ARG" ] && exit 0 || exit 1
fi
shift || true

PORT=""
while [ $# -gt 0 ]; do
  case "$1" in
    --port) PORT="${2:-}"; shift 2 ;;
    *) echo "오류: 알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
  esac
done
if [ -n "$PORT" ] && ! [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1024 && "$PORT" -le 65535 ]]; then
  echo "오류: 잘못된 포트: $PORT (1024-65535)" >&2; exit 1
fi

TGT="$(cd "$TARGET_ARG" 2>/dev/null && pwd)" || { echo "오류: 대상 폴더가 없습니다: $TARGET_ARG" >&2; exit 1; }
case "$TGT" in
  "$ROOT"|"$ROOT"/*) echo "오류: 대상이 SOURCE(이 저장소) 안입니다 — 밖의 프로젝트만 열 수 있습니다" >&2; exit 1 ;;
esac
if [ ! -f "$TGT/mission-control/server.mjs" ]; then
  echo "오류: 하네스 마커 없음 — $TGT/mission-control/server.mjs 가 없습니다." >&2
  echo "      (T303 이전 하네스로 만든 프로젝트라면 하네스를 다시 적용하세요: ./scripts/init_new_project.sh --diff-manifest 로 확인 후 적용)" >&2
  exit 1
fi
if [ ! -f "$TGT/scripts/mission_control.sh" ]; then
  echo "오류: 하네스 마커 없음 — $TGT/scripts/mission_control.sh 가 없습니다." >&2; exit 1
fi

# node 해석: exec 경유 시 서버가 NODE_BIN(자기 자신의 node)을 넘겨준다.
# 수동 실행 시엔 PATH에서 찾는다. 둘 다 없으면 명확히 실패 (nohup 뒤 조용한 죽음 방지).
NODE_BIN="${NODE_BIN:-$(command -v node || true)}"
if [ -z "$NODE_BIN" ] || [ ! -x "$NODE_BIN" ]; then
  echo "오류: node 실행 파일을 찾을 수 없습니다 — PATH에 node를 추가하거나 NODE_BIN=/path/to/node 로 지정하세요" >&2
  exit 1
fi

mkdir -p "$TGT/state"
PID_FILE="$TGT/state/mission-control.pid"
LOG_FILE="$TGT/state/mission-control.log"

# 멱등: 이미 실행 중이면 로그에서 포트를 찾아 URL만 출력
if [ -f "$PID_FILE" ] && kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
  RUN_PORT="$(grep -o 'listening on http://127\.0\.0\.1:[0-9]*' "$LOG_FILE" 2>/dev/null | tail -1 | grep -o '[0-9]*$' || true)"
  if [ -z "$RUN_PORT" ]; then
    echo "오류: 이미 실행 중(pid $(cat "$PID_FILE"))이지만 포트를 알 수 없습니다 — $LOG_FILE 확인" >&2; exit 1
  fi
  echo "[open-project-mc] already running (pid $(cat "$PID_FILE"))"
  echo "URL: http://127.0.0.1:$RUN_PORT/"
  exit 0
fi
rm -f "$PID_FILE"

# 포트 자동 선택 (7475-7499에서 첫 빈 포트) — SOURCE MC 기본 7474와 충돌 회피
if [ -z "$PORT" ]; then
  for p in $(seq 7475 7499); do
    if ! (exec 3<>"/dev/tcp/127.0.0.1/$p") 2>/dev/null; then PORT="$p"; break; fi
  done
fi
if [ -z "$PORT" ]; then echo "오류: 사용 가능한 포트가 없습니다 (7475-7499)" >&2; exit 1; fi

# 타깃 MC가 다시 자식(run_loop → claude CLI 등)을 spawn할 때 도구를 찾을 수 있도록
# PATH를 보강해 물려준다. MC 프로세스의 PATH가 빈약한 환경(GUI/launchd 기동)에서
# 'node/claude not found'(rc=127)를 방지:
#   1) node의 bin 디렉터리 (npm 글로벌 CLI는 보통 같은 디렉터리)
#   2) claude CLI 표준 설치 위치 중 실재하는 곳 (네이티브 설치 ~/.local/bin 등)
EXTRA_PATH="$(dirname "$NODE_BIN")"
if ! PATH="$EXTRA_PATH:$PATH" command -v claude >/dev/null 2>&1; then
  for d in "$HOME/.local/bin" "$HOME/.claude/local" /opt/homebrew/bin /usr/local/bin; do
    if [ -x "$d/claude" ]; then EXTRA_PATH="$EXTRA_PATH:$d"; break; fi
  done
fi
(
  cd "$TGT"
  # 타깃의 .env.local(gitignore 대상)이 있으면 타깃 MC env로 로드 — 루프 자식(claude·
  # 어댑터의 OPENAI_API_KEY 등)에 전파된다. 값은 절대 echo/로그하지 않는다 (runbook §4).
  if [ -f "$TGT/.env.local" ]; then
    set -a
    # shellcheck disable=SC1091
    . "$TGT/.env.local"
    set +a
  fi
  PATH="$EXTRA_PATH:$PATH" nohup "$NODE_BIN" mission-control/server.mjs --port "$PORT" >> "$LOG_FILE" 2>&1 &
  echo $! > "$PID_FILE"
)

# 기동 대기 (최대 10초)
for _ in $(seq 1 40); do
  if grep -q "listening on http://127\.0\.0\.1:$PORT" "$LOG_FILE" 2>/dev/null; then
    echo "[open-project-mc] started (pid $(cat "$PID_FILE"), port $PORT)"
    echo "URL: http://127.0.0.1:$PORT/"
    exit 0
  fi
  if [ -f "$PID_FILE" ] && ! kill -0 "$(cat "$PID_FILE")" 2>/dev/null; then
    echo "오류: 서버가 곧바로 종료됐습니다 — $LOG_FILE 확인" >&2; exit 1
  fi
  sleep 0.25
done
echo "오류: 서버 기동 대기 시간 초과 — $LOG_FILE 확인" >&2
exit 1
