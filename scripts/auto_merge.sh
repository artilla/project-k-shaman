#!/usr/bin/env bash
# scripts/auto_merge.sh — ADR-0014 §5 5조건 eval-only 평가자 (T051)
# --execute 자율 merge 추가 (T060, ADR-0019)
#
# 사용법:
#   ./scripts/auto_merge.sh <ticket-path> [--base <branch>] [--changed-files <file>]
#   ./scripts/auto_merge.sh <ticket-path> --execute --branch <branch> [--base <branch>]
#
# --changed-files 제공 시 git-free 격리 실행 (base 검출 생략).
# --execute 없으면 eval-only (기본). git mutation 0.
# --execute + --changed-files 상호 배타 (exit 2).
#
# exit 0: VERDICT: ELIGIBLE (5조건 모두 PASS) [eval-only]
#         또는 auto-merge 성공 [--execute]
# exit 1: VERDICT: NOT ELIGIBLE (하나 이상 FAIL) 또는 --execute 조건 불충족
# exit 2: 인수 오류

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# 오버라이드 가능한 도구 경로 (테스트용)
LINT_EXTERNAL_DOCS_CMD="${LINT_EXTERNAL_DOCS_CMD:-$ROOT/scripts/lint_external_docs.sh}"
RUN_CHECKS_CMD="${RUN_CHECKS_CMD:-$ROOT/scripts/run_checks.sh}"
CHECK_SCOPE_OMISSION_CMD="${CHECK_SCOPE_OMISSION_CMD:-$ROOT/scripts/check_scope_omission.sh}"
REVIEWS_DIR="${REVIEWS_DIR:-$ROOT/docs/reviews}"
STATE_DIR="${STATE_DIR:-$ROOT/state}"

# ── 인수 파싱 ──────────────────────────────────────────────────────────────────
TICKET_PATH=""
BASE_ARG=""
CHANGED_FILES_ARG=""
EXECUTE=0
BRANCH_ARG=""

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
    --execute)
      EXECUTE=1
      shift
      ;;
    --branch)
      BRANCH_ARG="$2"
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
  echo "       $0 <ticket-path> --execute --branch <branch> [--base <branch>]" >&2
  exit 2
fi

if [ ! -f "$TICKET_PATH" ]; then
  echo "Ticket not found: $TICKET_PATH" >&2
  exit 2
fi

# ── --execute 유효성 검사 ──────────────────────────────────────────────────────
if [ "$EXECUTE" -eq 1 ] && [ -n "$CHANGED_FILES_ARG" ]; then
  echo "[FAIL] --execute and --changed-files are mutually exclusive" >&2
  exit 2
fi

if [ "$EXECUTE" -eq 1 ] && [ -z "$BRANCH_ARG" ]; then
  echo "[FAIL] --execute requires --branch" >&2
  exit 2
fi

# ── ticket ID・frontmatter 파싱 (Fix 1: safe 경계, Fix 3: 파일명 앵커) ──────────
# Fix 3: 파일명 T-prefix → 권위 있는 ID 소스
_fn_id="$(basename "$TICKET_PATH" | grep -oE '^T[0-9]+' || true)"

_fm_id=""
_fm_safe=0
_fm_safe_count=0
_fm_found=0
_fm_closed=0
_fm_state=0
while IFS= read -r _fmline; do
  case "$_fm_state" in
    0)
      if [ "$_fmline" = "---" ]; then
        _fm_state=1
        _fm_found=1
      else
        break
      fi
      ;;
    1)
      if [ "$_fmline" = "---" ]; then
        _fm_closed=1
        break
      fi
      case "$_fmline" in
        id:*)
          _fm_id="$(printf '%s' "$_fmline" | sed 's/^id:[[:space:]]*//' | tr -d '[:space:]')"
          ;;
      esac
      # 리뷰 5차 P1: safe 선언 횟수 집계 — 중복(false→true, true→false 어느 순서든)은
      # 셸/서버 파서가 서로 다른 값을 읽는 주입 벡터라 fail-closed로 거부한다.
      case "$_fmline" in
        safe:*) _fm_safe_count=$((_fm_safe_count + 1)) ;;
      esac
      if printf '%s\n' "$_fmline" | grep -qE '^safe:[[:space:]]*true[[:space:]]*$'; then
        _fm_safe=1
      fi
      ;;
  esac
done < "$TICKET_PATH"

# Fix 3: 파일명에 T-prefix가 있으면 권위 ID; frontmatter id 불일치 시 즉시 FAIL
if [ -n "$_fn_id" ]; then
  TICKET_ID="$_fn_id"
else
  # 파일명 T-prefix 없음 → frontmatter id: 사용 (하위 호환)
  TICKET_ID="$_fm_id"
fi

# ── base 브랜치 결정 ──────────────────────────────────────────────────────────
# --changed-files가 제공되면 base branch를 검출하지 않는다 (T050 §2.1 패턴 계승).
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

# ── --execute 전제조건 검사 ──────────────────────────────────────────────────────
# (eval-only 기본 경로에는 도달하지 않음 — git mutation 0 구조 보장)
if [ "$EXECUTE" -eq 1 ]; then
  _wt_dirty="$(git status --porcelain)"
  _cur_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo 'HEAD')"
  if [ -n "$_wt_dirty" ] || [ "$_cur_branch" != "$BASE_BRANCH" ]; then
    echo "[FAIL] --execute requires clean working tree on ${BASE_BRANCH}"
    exit 1
  fi
fi

# ── changed-files 결정 ────────────────────────────────────────────────────────
# 리뷰 2차 P1-11: --name-only는 rename 감지 시 목적지 경로만 출력해, 소스가 docs/tests
# 밖인 rename(예: src/app.js → docs/app.md)이 조건 2를 우회했다. --name-status로 바꿔
# R(rename)/C(copy)는 소스·목적지 양쪽 경로를 모두 검사 대상에 넣는다.
# -M(rename) + -C --find-copies-harder(copy) 탐지. 리뷰 4차 P1: -C만으로는 "변경되지
# 않은" 파일을 copy 소스 후보로 검사하지 않아 src/app.js → docs/app.md 복사가 A(추가)로만
# 보여 조건 2를 우회했다 — --find-copies-harder로 모든 파일을 소스 후보에 포함한다.
# pipefail(스크립트 상단 set -euo pipefail)이 git 실패를 함수 종료 코드로 전파한다.
# 리뷰 5차 P2: diff.renameLimit이 낮게 설정된 저장소에서는 rename/copy 탐지가 조용히
# 포기되고 `A docs/...`로 위장된다(fail-open) — -l0으로 탐지 한도를 해제한다.
_diff_paths() {
  git diff --name-status -M -C --find-copies-harder -l0 "$1" | awk -F'\t' '
    $1 ~ /^[RC]/ { if ($2 != "") print $2; if ($3 != "") print $3; next }
    { if ($2 != "") print $2 }
  '
}

# 리뷰 3차 P1: diff 실패(잘못된 base/branch 등)를 `|| true`로 삼키면 빈 변경 목록이
# 되어 조건 2가 공허하게 PASS했다 — diff 실패는 조건 2 실패로 처리한다(fail-closed).
TMPCHANGED="$(mktemp)"
DIFF_FAILED=0
if [ -n "$CHANGED_FILES_ARG" ]; then
  cp "$CHANGED_FILES_ARG" "$TMPCHANGED"
elif [ "$EXECUTE" -eq 1 ]; then
  # --execute: synthetic changed-files 불가, 실제 브랜치 diff 사용
  _diff_paths "${BASE_BRANCH}...${BRANCH_ARG}" > "$TMPCHANGED" || DIFF_FAILED=1
else
  _diff_paths "${BASE_BRANCH}...HEAD" > "$TMPCHANGED" || DIFF_FAILED=1
fi

# ── 5조건 평가 ────────────────────────────────────────────────────────────────
ELIGIBLE=0  # 0 = eligible, non-zero = not eligible

# Fix 3: 파일명 T-prefix와 frontmatter id: 불일치 → FAIL
if [ -n "$_fn_id" ] && [ -n "$_fm_id" ] && [ "$_fm_id" != "$_fn_id" ]; then
  echo "[FAIL] id mismatch (frontmatter='${_fm_id}' filename='${_fn_id}') — possible tampering"
  ELIGIBLE=1
fi

# 조건 1: safe:true (Fix 1: frontmatter 블록 한정, 리뷰 5차: 정확히 1회 선언)
if [ "$_fm_found" -eq 1 ] && [ "$_fm_closed" -eq 1 ] && [ "$_fm_safe" -eq 1 ] && [ "$_fm_safe_count" -eq 1 ]; then
  echo "[PASS] condition 1: safe:true"
elif [ "$_fm_safe_count" -gt 1 ]; then
  echo "[FAIL] condition 1: duplicate safe declarations (${_fm_safe_count}) — fail-closed"
  ELIGIBLE=1
else
  echo "[FAIL] condition 1: safe:true not found in ticket frontmatter"
  ELIGIBLE=1
fi

# 조건 2: diff가 docs/ 또는 tests/ 한정 (Fix 2: traversal·절대경로 선거부)
COND2_FAIL=0
if [ "$DIFF_FAILED" -eq 1 ]; then
  echo "[FAIL] condition 2: git diff failed (base='${BASE_BRANCH:-?}') — 변경 목록을 신뢰할 수 없음"
  COND2_FAIL=1
  ELIGIBLE=1
fi
[ "$DIFF_FAILED" -eq 1 ] || while IFS= read -r _f; do
  [ -z "$_f" ] && continue
  # Fix 2: 절대경로 거부 (prefix 검사 전)
  case "$_f" in
    /*)
      echo "[FAIL] condition 2: file '${_f}' is an absolute path"
      COND2_FAIL=1
      ELIGIBLE=1
      break
      ;;
  esac
  # Fix 2: .. 경로 세그먼트 거부 (prefix 검사 전)
  if printf '%s\n' "$_f" | grep -qE '(^|/)\.\.(/|$)'; then
    echo "[FAIL] condition 2: file '${_f}' contains path traversal (..)"
    COND2_FAIL=1
    ELIGIBLE=1
    break
  fi
  # prefix 검사
  case "$_f" in
    docs/*|tests/*) ;;
    *)
      echo "[FAIL] condition 2: file '${_f}' is outside docs/ and tests/"
      COND2_FAIL=1
      ELIGIBLE=1
      break
      ;;
  esac
done < "$TMPCHANGED"
if [ "$COND2_FAIL" -eq 0 ]; then
  echo "[PASS] condition 2: all changed files are under docs/ or tests/"
fi

# 조건 3: lint_external_docs.sh exit 0
if "$LINT_EXTERNAL_DOCS_CMD" >/dev/null 2>&1; then
  echo "[PASS] condition 3: lint_external_docs.sh exit 0"
else
  echo "[FAIL] condition 3: lint_external_docs.sh non-zero exit"
  ELIGIBLE=1
fi

# 조건 4: run_checks.sh exit 0
if "$RUN_CHECKS_CMD" >/dev/null 2>&1; then
  echo "[PASS] condition 4: run_checks.sh exit 0"
else
  echo "[FAIL] condition 4: run_checks.sh non-zero exit"
  ELIGIBLE=1
fi

# 조건 5: reviewer cycle OR docs/decisions/ 미접촉
DECISIONS_TOUCHED=0
while IFS= read -r _f; do
  [ -z "$_f" ] && continue
  case "$_f" in
    docs/decisions/*)
      DECISIONS_TOUCHED=1
      break
      ;;
  esac
done < "$TMPCHANGED"

if [ "$DECISIONS_TOUCHED" -eq 0 ]; then
  echo "[PASS] condition 5: docs/decisions/ not touched (auto-satisfied)"
else
  REVIEW_FILE="$REVIEWS_DIR/${TICKET_ID}-review.md"
  if [ -f "$REVIEW_FILE" ] && grep -qE '^\[[^]]+\] REVIEW: PASS([[:space:]]|$)' "$REVIEW_FILE" 2>/dev/null; then
    echo "[PASS] condition 5: docs/decisions/ touched, review PASS found at ${REVIEW_FILE}"
  else
    if [ ! -f "$REVIEW_FILE" ]; then
      echo "[FAIL] condition 5: docs/decisions/ touched but review file not found (${REVIEW_FILE})"
    else
      echo "[FAIL] condition 5: docs/decisions/ touched but PASS verdict not found in review file"
    fi
    ELIGIBLE=1
  fi
fi

# ── advisory: check_scope_omission (VERDICT에 영향 없음) ──────────────────────
ADVISORY_OUT="$(mktemp)"
ADVISORY_RC=0
"$CHECK_SCOPE_OMISSION_CMD" "$TICKET_PATH" --changed-files "$TMPCHANGED" > "$ADVISORY_OUT" 2>&1 || ADVISORY_RC=$?
if [ "$ADVISORY_RC" -eq 0 ]; then
  echo "ADVISORY: check_scope_omission exit 0"
else
  echo "ADVISORY: check_scope_omission exit ${ADVISORY_RC} (reviewer-assist only — not gate)"
fi
while IFS= read -r _adv; do
  [ -z "$_adv" ] && continue
  echo "ADVISORY: ${_adv}"
done < "$ADVISORY_OUT"
rm -f "$ADVISORY_OUT"

rm -f "$TMPCHANGED"

# ── VERDICT ────────────────────────────────────────────────────────────────────
if [ "$ELIGIBLE" -eq 0 ]; then
  echo "VERDICT: ELIGIBLE"
  if [ "$EXECUTE" -eq 0 ]; then
    exit 0
  fi

  # ── --execute: (c) 단일-commit 검증 + merge + post-merge 검사 ──────────────
  COMMIT_COUNT="$(git rev-list --count "${BASE_BRANCH}..${BRANCH_ARG}")"
  if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "[FAIL] (c) single-commit 위반: ${COMMIT_COUNT} commits"
    exit 1
  fi

  mkdir -p "$STATE_DIR"
  PRE_MERGE_HEAD="$(git rev-parse HEAD)"
  if ! git merge --no-ff "$BRANCH_ARG" -m "auto-merge: ${TICKET_ID} (ELIGIBLE)"; then
    git merge --abort >/dev/null 2>&1 || git reset --hard "$PRE_MERGE_HEAD" >/dev/null 2>&1 || true
    printf '%s\t%s\t%s\t%s\tROLLED_BACK\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TICKET_ID" "$BRANCH_ARG" "$PRE_MERGE_HEAD" \
      >> "$STATE_DIR/auto_merge.log"
    echo "[FAIL] git merge failed — rollback"
    exit 1
  fi
  MERGE_COMMIT="$(git rev-parse HEAD)"

  if "$RUN_CHECKS_CMD" >/dev/null 2>&1; then
    printf '%s\t%s\t%s\t%s\tEXECUTED\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TICKET_ID" "$BRANCH_ARG" "$MERGE_COMMIT" \
      >> "$STATE_DIR/auto_merge.log"
    echo "[PASS] auto-merge executed: ${MERGE_COMMIT}"
    exit 0
  else
    git reset --hard ORIG_HEAD
    printf '%s\t%s\t%s\t%s\tROLLED_BACK\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TICKET_ID" "$BRANCH_ARG" "$MERGE_COMMIT" \
      >> "$STATE_DIR/auto_merge.log"
    echo "[FAIL] post-merge run_checks 실패 — rollback"
    exit 1
  fi
else
  echo "VERDICT: NOT ELIGIBLE"
  exit 1
fi
