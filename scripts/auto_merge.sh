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

# ── 리뷰 7차 P1: 티켓 경로는 canonical tickets 디렉터리 하위만 허용 ────────────────
# 외부 경로(/tmp/T999-*.md)의 위조 티켓으로 병합 자격을 얻는 우회 차단.
# TICKETS_DIR은 테스트 격리용 오버라이드(기존 REVIEWS_DIR/STATE_DIR과 동일 패턴).
TICKETS_DIR="${TICKETS_DIR:-$ROOT/docs/tickets}"
_ticket_dir_real="$(cd "$(dirname "$TICKET_PATH")" 2>/dev/null && pwd -P || true)"
_tickets_real="$(cd "$TICKETS_DIR" 2>/dev/null && pwd -P || true)"
if [ -z "$_tickets_real" ] || { [ "$_ticket_dir_real" != "$_tickets_real" ] && [ "$_ticket_dir_real" != "$_tickets_real/DONE" ]; }; then
  echo "[FAIL] ticket path '${TICKET_PATH}' is outside canonical ${TICKETS_DIR} (or DONE/) — refusing" >&2
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
# 리뷰 7차 P1: 파일명은 정확히 `T<숫자>.md` 또는 `T<숫자>-*.md` — 과거 T-prefix
# grep은 'T999evil.md'에서 T999를 추출해 통과시켰다.
_ticket_bn="$(basename "$TICKET_PATH")"
_fn_id=""
if printf '%s\n' "$_ticket_bn" | grep -qE '^T[0-9]+(-[^/]*)?\.md$'; then
  _fn_id="$(printf '%s' "$_ticket_bn" | grep -oE '^T[0-9]+')"
fi

_fm_id=""
_fm_id_count=0
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
          _fm_id_count=$((_fm_id_count + 1))
          # 리뷰 7차 P2: inline 주석 제거 + quoted scalar 허용 — field_of와 동일 계약.
          # 앞뒤 공백만 제거(내부 공백은 보존) — 'T 9 9 9'가 압축돼 T999로 통과하는 위조 차단.
          _fm_id="$(printf '%s' "$_fmline" | sed 's/^id:[[:space:]]*//; s/[[:space:]][[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
          _fm_id="${_fm_id%\"}"; _fm_id="${_fm_id#\"}"
          ;;
      esac
      # 리뷰 5차 P1: safe 선언 횟수 집계 — 중복(false→true, true→false 어느 순서든)은
      # 셸/서버 파서가 서로 다른 값을 읽는 주입 벡터라 fail-closed로 거부한다.
      case "$_fmline" in
        safe:*) _fm_safe_count=$((_fm_safe_count + 1)) ;;
      esac
      # 리뷰 6차 P2: quoted scalar("true"/'true') 허용 — 셸 field_of·서버 파서와 동일 계약.
      if printf '%s\n' "$_fmline" | grep -qE "^safe:[[:space:]]*(\"true\"|'true'|true)[[:space:]]*(#.*)?$"; then
        _fm_safe=1
      fi
      ;;
  esac
done < "$TICKET_PATH"

# 리뷰 7차 P1: id 계약 — 파일명 형식 유효 + frontmatter id 정확히 1회 + 형식 + 일치.
# (과거: id 누락 허용·중복 last-wins·공백 낀 'T 9 9 9'가 tr -d로 T999로 압축돼 통과)
if [ -z "$_fn_id" ]; then
  echo "[FAIL] ticket filename '${_ticket_bn}' does not match ^T<digits>(-…)?.md — refusing" >&2
  exit 2
fi
if [ "$_fm_id_count" -ne 1 ] || ! printf '%s\n' "$_fm_id" | grep -qE '^T[0-9]+$' || [ "$_fm_id" != "$_fn_id" ]; then
  echo "[FAIL] id contract violated (frontmatter id='${_fm_id}' count=${_fm_id_count}, filename id='${_fn_id}') — refusing" >&2
  exit 2
fi
TICKET_ID="$_fn_id"

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

  # 리뷰 6차 P1 + 7차 P1: 티켓-브랜치 연결 — basename 매치만으로는 refs/tags/T999나
  # attacker/T999 같은 임의 namespace도 통과했다. 정확히 ralph/<TICKET_ID>[-*] 이름의
  # "브랜치"(refs/heads/ 하위)만 허용한다.
  case "$BRANCH_ARG" in
    ralph/"$TICKET_ID"|ralph/"$TICKET_ID"-*) ;;
    *)
      echo "[FAIL] branch '${BRANCH_ARG}' is not linked to ticket ${TICKET_ID} (expected ralph/${TICKET_ID} or ralph/${TICKET_ID}-*)"
      exit 1
      ;;
  esac
  if ! git show-ref --verify --quiet "refs/heads/${BRANCH_ARG}"; then
    echo "[FAIL] '${BRANCH_ARG}' is not a local branch (refs/heads/) — tags/remote refs are not mergeable"
    exit 1
  fi
fi

# ── 리뷰 6차 P1: base/branch commit OID 고정 (TOCTOU 차단) ────────────────────────
# 검사(조건 2·4)와 병합 사이에 브랜치 ref가 이동하면 검사받지 않은 커밋이 병합됐다.
# 시작 시점에 OID를 고정하고 diff·commit-count·merge 전부 이 OID만 사용한다.
BASE_OID=""
BRANCH_OID=""
if [ -z "$CHANGED_FILES_ARG" ]; then
  BASE_OID="$(git rev-parse --verify "${BASE_BRANCH}^{commit}" 2>/dev/null || true)"
  if [ "$EXECUTE" -eq 1 ]; then
    # 리뷰 7차 P1: refs/heads/ 정확 경로로만 해석 — 같은 이름의 tag가 브랜치를 가리는 것 방지.
    BRANCH_OID="$(git rev-parse --verify "refs/heads/${BRANCH_ARG}^{commit}" 2>/dev/null || true)"
  else
    BRANCH_OID="$(git rev-parse --verify "HEAD^{commit}" 2>/dev/null || true)"
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
# 리뷰 6차 P2: -z(NUL 구분)로 파싱 — 텍스트 출력은 비ASCII 경로(docs/한글.md)를
# C-quote해 docs/ 밖 경로로 오인, 정당한 병합을 거부했다.
_diff_paths() {
  git diff --name-status -M -C --find-copies-harder -l0 -z "$1" | {
    st=""
    p=""
    while IFS= read -r -d '' st; do
      case "$st" in
        R*|C*)
          IFS= read -r -d '' p && printf '%s\n' "$p"
          IFS= read -r -d '' p && printf '%s\n' "$p"
          ;;
        *)
          IFS= read -r -d '' p && printf '%s\n' "$p"
          ;;
      esac
    done
  }
}

# 리뷰 3차 P1: diff 실패(잘못된 base/branch 등)를 `|| true`로 삼키면 빈 변경 목록이
# 되어 조건 2가 공허하게 PASS했다 — diff 실패는 조건 2 실패로 처리한다(fail-closed).
# 리뷰 6차 P1: diff는 고정 OID만 사용 (ref 이동 무시).
TMPCHANGED="$(mktemp)"
DIFF_FAILED=0
if [ -n "$CHANGED_FILES_ARG" ]; then
  cp "$CHANGED_FILES_ARG" "$TMPCHANGED"
elif [ -z "$BASE_OID" ] || [ -z "$BRANCH_OID" ]; then
  DIFF_FAILED=1
else
  _diff_paths "${BASE_OID}...${BRANCH_OID}" > "$TMPCHANGED" || DIFF_FAILED=1
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
  # 리뷰 6차 P1: count·merge 모두 시작 시 고정한 OID 사용 — 검사 후 ref가 이동해도
  # 검사받은 커밋만 병합된다(TOCTOU 차단).
  COMMIT_COUNT="$(git rev-list --count "${BASE_OID}..${BRANCH_OID}")"
  if [ "$COMMIT_COUNT" -ne 1 ]; then
    echo "[FAIL] (c) single-commit 위반: ${COMMIT_COUNT} commits"
    exit 1
  fi

  mkdir -p "$STATE_DIR"
  # 리뷰 7차 P1: 병합 직전 base 재검증 — 검사(조건 3·4) 중 현재 브랜치 HEAD가
  # 움직였거나(dirty 포함) 브랜치가 바뀌었으면 병합을 거부한다 (base 측 TOCTOU).
  PRE_MERGE_HEAD="$(git rev-parse HEAD)"
  if [ "$PRE_MERGE_HEAD" != "$BASE_OID" ] \
     || [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$BASE_BRANCH" ] \
     || [ -n "$(git status --porcelain)" ]; then
    echo "[FAIL] base '${BASE_BRANCH}' moved or dirtied since checks (HEAD=${PRE_MERGE_HEAD} expected=${BASE_OID}) — merge refused (TOCTOU)"
    exit 1
  fi
  if ! git merge --no-ff "$BRANCH_OID" -m "auto-merge: ${TICKET_ID} (ELIGIBLE)"; then
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
