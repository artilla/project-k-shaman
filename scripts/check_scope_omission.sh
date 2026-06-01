#!/usr/bin/env bash
# scripts/check_scope_omission.sh — ADR-0014 §4 사례 1: acceptance criteria 산출물 vs changed-files 대조
#
# 사용법:
#   ./scripts/check_scope_omission.sh <ticket-path> [--base <branch>] [--changed-files <file>]
#
# 목적: acceptance criteria 섹션에서 명시 산출물 경로를 추출하고, changed-files에 없으면 누락으로 진단.
#       per-ticket diff 컨텍스트가 필요한 advisory 도구. run_checks.sh 통합 대상 아님.
#
# exit 0: 모든 명시 산출물이 changed-files에 있거나, 명시 경로 0개 (PARTIAL boundary NOTE 출력)
# exit 1: 하나 이상의 명시 산출물이 누락 (stderr에 Rule-Scope 진단 출력)
# exit 2: 인수 오류

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ── 인수 파싱 ─────────────────────────────────────────────────────────────────
TICKET_PATH=""
BASE_ARG=""
CHANGED_FILES_ARG=""

while [ $# -gt 0 ]; do
  case "$1" in
    --base)
      BASE_ARG="$2"
      shift 2
      ;;
    --changed-files)
      CHANGED_FILES_ARG="$2"
      shift 2
      ;;
    -*)
      echo "Unknown option: $1" >&2
      exit 2
      ;;
    *)
      if [ -z "$TICKET_PATH" ]; then
        TICKET_PATH="$1"
      else
        echo "Unexpected argument: $1" >&2
        exit 2
      fi
      shift
      ;;
  esac
done

if [ -z "$TICKET_PATH" ]; then
  echo "Usage: $0 <ticket-path> [--base <branch>] [--changed-files <file>]" >&2
  exit 2
fi

if [ ! -f "$TICKET_PATH" ]; then
  echo "Ticket not found: $TICKET_PATH" >&2
  exit 2
fi

TICKET_BASENAME="$(basename "$TICKET_PATH" .md)"

# ── base 브랜치 결정 ──────────────────────────────────────────────────────────
# --changed-files가 제공되면 git diff가 필요 없으므로 base branch를 검출하지 않는다.
# 이 경로가 bats와 외부 도구에서 git-free로 격리 실행되는 핵심이다.
BASE_BRANCH=""
if [ -z "$CHANGED_FILES_ARG" ]; then
  if [ -z "$BASE_ARG" ]; then
    # shellcheck source=scripts/lib/base_branch.sh
    . "$ROOT/scripts/lib/base_branch.sh"
    BASE_BRANCH="${BASE_BRANCH:-$(detect_base_branch)}"
  else
    BASE_BRANCH="$BASE_ARG"
  fi
fi

# ── changed files 결정 ────────────────────────────────────────────────────────
TMPCHANGED="$(mktemp)"
if [ -n "$CHANGED_FILES_ARG" ]; then
  cp "$CHANGED_FILES_ARG" "$TMPCHANGED"
else
  git diff --name-only "${BASE_BRANCH}...HEAD" > "$TMPCHANGED" 2>/dev/null || true
fi

# ── acceptance criteria 섹션 추출 ────────────────────────────────────────────
# "수용 기준" 또는 "Acceptance Criteria"를 포함하는 ## 헤더 → 다음 ## 헤더까지
TMPAC="$(mktemp)"
awk '
  /^## / {
    if (in_section) { in_section = 0 }
    if (/수용 기준|Acceptance Criteria/) { in_section = 1; next }
  }
  in_section { print }
' "$TICKET_PATH" > "$TMPAC"

# ── 산출물 경로 추출 ──────────────────────────────────────────────────────────
# 규칙:
#   - 백틱으로 묶인 토큰 중 슬래시(/)가 있는 것 (확장자 불문, 경로 형태)
#   - spec_ref: / 참조 / 참고 문맥 라인은 제외 (오탐 방지)
#   - 중복 제거

TMPPATHS="$(mktemp)"
TMPLINE="$(mktemp)"

while IFS= read -r line; do
  # 제외 라인: spec_ref:, 참조, 참고 키워드 포함 라인
  if printf '%s' "$line" | grep -qE '(spec_ref:|참조|참고)'; then
    continue
  fi
  # 백틱 내 토큰 추출: `token` 형태 → 슬래시 포함 여부 필터
  printf '%s\n' "$line" | grep -oE '`[^`]+`' | sed 's/`//g' > "$TMPLINE" 2>/dev/null || true
  while IFS= read -r tok; do
    [ -z "$tok" ] && continue
    # 슬래시가 있어야 경로로 인정
    case "$tok" in
      */*) printf '%s\n' "$tok" >> "$TMPPATHS" ;;
      *) ;;
    esac
  done < "$TMPLINE"
done < "$TMPAC"

rm -f "$TMPLINE"

# 중복 제거
TMPPATHS_UNIQ="$(mktemp)"
sort -u "$TMPPATHS" > "$TMPPATHS_UNIQ"
rm -f "$TMPPATHS"

# ── 0개 경로 체크 ─────────────────────────────────────────────────────────────
PATH_COUNT="$(wc -l < "$TMPPATHS_UNIQ" | tr -d '[:space:]')"

if [ "$PATH_COUNT" -eq 0 ]; then
  echo "NOTE: no explicit deliverable paths in acceptance criteria — manual reviewer judgment required (PARTIAL boundary)" >&2
  rm -f "$TMPCHANGED" "$TMPAC" "$TMPPATHS_UNIQ"
  exit 0
fi

# ── 대조: missing deliverables 검출 ──────────────────────────────────────────
MISSING=0

while IFS= read -r path; do
  [ -z "$path" ] && continue
  found=0
  case "$path" in
    *"*"*)
      # glob 패턴: * 앞의 prefix로 changed-files 내 매칭
      prefix="${path%%\**}"
      while IFS= read -r changed; do
        case "$changed" in
          "$prefix"*) found=1; break ;;
          *) ;;
        esac
      done < "$TMPCHANGED"
      ;;
    *)
      if grep -qxF "$path" "$TMPCHANGED" 2>/dev/null; then
        found=1
      fi
      ;;
  esac
  if [ "$found" -eq 0 ]; then
    echo "${TICKET_BASENAME}: Rule-Scope missing deliverable '${path}' declared in acceptance criteria" >&2
    MISSING=$((MISSING + 1))
  fi
done < "$TMPPATHS_UNIQ"

rm -f "$TMPCHANGED" "$TMPAC" "$TMPPATHS_UNIQ"

if [ "$MISSING" -gt 0 ]; then
  exit 1
fi
exit 0
