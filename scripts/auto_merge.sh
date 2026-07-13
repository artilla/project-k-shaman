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
# 리뷰 8차 P1: 파일 자체 symlink 거부 + regular file 강제 — 디렉터리 containment만으로는
# tickets/ 안의 symlink가 외부 파일을 끌어오는 우회를 막지 못했다. tickets 디렉터리
# 자체의 symlink 여부도 검사한다 (pwd -P containment는 링크된 실경로끼리 비교돼 통과했다).
if [ -h "$TICKET_PATH" ] || [ ! -f "$TICKET_PATH" ]; then
  echo "[FAIL] ticket '${TICKET_PATH}' is a symlink or not a regular file — refusing" >&2
  exit 2
fi
if [ -h "$TICKETS_DIR" ] || { [ -d "$TICKETS_DIR/DONE" ] && [ -h "$TICKETS_DIR/DONE" ]; }; then
  echo "[FAIL] tickets directory '${TICKETS_DIR}' (or DONE/) is a symlink — refusing" >&2
  exit 2
fi
# 리뷰 9차 P1: 중간 조상 symlink(예: $ROOT/docs → 외부 디렉터리)도 차단 — 기본
# TICKETS_DIR일 때 물리 경로가 ROOT 물리 경로 + /docs/tickets 그대로여야 한다.
if [ "$TICKETS_DIR" = "$ROOT/docs/tickets" ]; then
  _root_real="$(cd "$ROOT" && pwd -P)"
  _td_real="$(cd "$TICKETS_DIR" 2>/dev/null && pwd -P || true)"
  if [ "$_td_real" != "$_root_real/docs/tickets" ]; then
    echo "[FAIL] tickets path resolves outside canonical ROOT (docs 체인에 symlink?) — refusing" >&2
    exit 2
  fi
fi
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
          # 리뷰 7차 P2: inline 주석 제거(선행 공백 필수) + quoted scalar 허용.
          # 리뷰 8차 P1: 따옴표는 "같은 종류의 쌍"일 때만 제거 — 독립 strip은
          # 닫히지 않은 `id: "T908`을 T908로 승격시켰다.
          _fm_id="$(printf '%s' "$_fmline" | sed 's/^id:[[:space:]]*//; s/[[:space:]][[:space:]]*#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
          case "$_fm_id" in
            \"*\") _fm_id="${_fm_id#\"}"; _fm_id="${_fm_id%\"}" ;;
            \'*\') _fm_id="${_fm_id#\'}"; _fm_id="${_fm_id%\'}" ;;
          esac
          ;;
      esac
      # 리뷰 5차 P1: safe 선언 횟수 집계 — 중복(false→true, true→false 어느 순서든)은
      # 셸/서버 파서가 서로 다른 값을 읽는 주입 벡터라 fail-closed로 거부한다.
      case "$_fmline" in
        safe:*) _fm_safe_count=$((_fm_safe_count + 1)) ;;
      esac
      # 리뷰 6차 P2: quoted scalar("true"/'true') 허용 — 셸 field_of·서버 파서와 동일 계약.
      # 리뷰 8차 P1: 주석은 선행 공백 필수 — `true#suffix`는 malformed지 safe:true가 아니다.
      if printf '%s\n' "$_fmline" | grep -qE "^safe:[[:space:]]*(\"true\"|'true'|true)([[:space:]]+#.*)?[[:space:]]*$"; then
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

# 리뷰 10차 P1: clean 판정 공용 helper —
#   (a) --untracked-files=all: status.showUntrackedFiles=no 설정과 무관하게 미추적 검출
#   (b) 자기 자신의 산출물(lock·감사 로그)만 정확한 상대 경로로 제외
# 리뷰 11차 P1: substring grep은 같은 문자열이 든 일반 파일 변경까지 숨겼다 —
# repo-상대 정확 경로(prefix) 매칭으로 교체. in-repo STATE_DIR의 감사 로그도
# clean 검사 후 생성돼 최종 dirty를 만들었으므로 제외 목록에 포함.
# git 실패는 rc로 전파 (fail-closed).
# 상대화 기준은 스크립트 ROOT가 아니라 "지금 검사하는 git 저장소"의 top-level —
# in-repo custom STATE_DIR(예: <repo>/state2)도 정확히 제외돼야 한다 (리뷰 11차).
_GIT_TOP="$(git rev-parse --show-toplevel 2>/dev/null || true)"
# macOS: --show-toplevel은 물리 경로를 주지만 STATE_DIR 인자는 /var 같은 symlink
# 경로일 수 있다 — 부모 디렉터리를 pwd -P로 물리화한 뒤 상대화한다. 경로가 아직
# 없으면(첫 실행) status에도 안 나오므로 빈 값이어도 무해.
_phys_of() {
  local d
  d="$(cd "$(dirname "$1")" 2>/dev/null && pwd -P)" || { printf '%s' "$1"; return; }
  printf '%s/%s' "$d" "$(basename "$1")"
}
_rel_of() {
  case "$1" in
    "$_GIT_TOP"/*) [ -n "$_GIT_TOP" ] && printf '%s' "${1#"$_GIT_TOP"/}" ;;
    /*) printf '' ;;    # repo 밖 절대 경로 — status에 나타나지 않음
    *) printf '%s' "$1" ;;
  esac
}
_wt_status_or_fail() {
  local out lock_rel log_rel trash_rel
  lock_rel="$(_rel_of "$(_phys_of "$STATE_DIR/auto_merge.lock.d")")"
  log_rel="$(_rel_of "$(_phys_of "$STATE_DIR/auto_merge.log")")"
  # 리뷰 16차 P1(4차): quarantine은 STATE_DIR 아래(워크트리와 같은 파일시스템) —
  # 자기 산출물이므로 clean 판정에서 제외한다 (lock·log와 동일 계약).
  trash_rel="$(_rel_of "$(_phys_of "$STATE_DIR/auto_merge.trash.d")")"
  out="$(git status --porcelain --untracked-files=all)" || return 1
  printf '%s' "$out" | awk -v lock="$lock_rel" -v log_f="$log_rel" -v trash="$trash_rel" '
    {
      p = substr($0, 4)
      if (lock != "" && (p == lock || p == lock "/" || index(p, lock "/") == 1)) next
      if (lock != "" && index(p, lock ".reclaim.") == 1) next
      if (log_f != "" && p == log_f) next
      if (trash != "" && (p == trash || p == trash "/" || index(p, trash "/") == 1)) next
      print
    }'
}


# ── --execute 전제조건 검사 ──────────────────────────────────────────────────────
# (eval-only 기본 경로에는 도달하지 않음 — git mutation 0 구조 보장)
if [ "$EXECUTE" -eq 1 ]; then
  # 리뷰 11차: 전제조건도 자기 STATE_DIR 산출물(lock·감사 로그)을 제외한 clean 판정 사용.
  if ! _wt_dirty="$(_wt_status_or_fail)"; then
    echo "[FAIL] git status failed — refusing"
    exit 1
  fi
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

  # 리뷰 11차 P1: 감사 기록 실패를 조용히 넘기지 않는다 — stderr 경고 + 플래그.
  # EXECUTED 확정은 감사 기록 성공을 전제로 한다 (감사 없는 성공 금지).
  AM_AUDIT_FAILED=0
  _am_log() {
    if ! printf '%s\t%s\t%s\t%s\t%s\n' \
      "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$TICKET_ID" "$BRANCH_ARG" "$1" "$2" \
      >> "$STATE_DIR/auto_merge.log" 2>/dev/null; then
      echo "[AUDIT-FAIL] ${2} (${1}) — ${STATE_DIR}/auto_merge.log 기록 실패 (경로/권한 확인)" >&2
      AM_AUDIT_FAILED=1
    fi
  }

  # 리뷰 8차 P1: 저장소 단위 lock. 리뷰 10차 P1: 소유는 pid가 아니라 고유 token으로
  # 판정하고(다른 live owner가 lock을 교체해도 남의 lock을 rm하지 않음), stale 회수는
  # 원자적 rename으로 한다 (확인-후-삭제 경합 제거).
  AM_LOCK="$STATE_DIR/auto_merge.lock.d"
  AM_LOCK_TOKEN="$$-$RANDOM-$(date +%s)"
  # 재재리뷰 P1(#9): lock 획득 "이전"에 정리 trap을 설치한다 — 종전에는 획득(~500행)
  # 과 cleanup trap 설치(~1032행) 사이의 신호에서 pid/token 없는(또는 있는) lock이
  # 남아 이후 실행이 영구 거부됐다 (실측: 'pid unknown'). 이 trap은 아래에서 전체
  # trap(감사 로그 포함)으로 교체될 때까지의 임시 방어선이며, token이 내 것일 때만
  # lock을 치운다 (남의 lock 무접촉).
  trap '[ "$(cat "$AM_LOCK/token" 2>/dev/null)" = "$AM_LOCK_TOKEN" ] && rm -rf "$AM_LOCK" 2>/dev/null; rm -rf "$AM_LOCK.acq.$$" 2>/dev/null || true' EXIT
  trap '[ "$(cat "$AM_LOCK/token" 2>/dev/null)" = "$AM_LOCK_TOKEN" ] && rm -rf "$AM_LOCK" 2>/dev/null; rm -rf "$AM_LOCK.acq.$$" 2>/dev/null; exit 143' TERM INT HUP
  # 리뷰 11차 P1: token/pid 기록 실패를 획득 성공으로 처리하지 않는다 (rc=2로 구분,
  # 부분 생성물은 회수).
  # 재재리뷰 P1(#9): 획득은 pid·token이 "이미 담긴" 사전 구성 디렉터리의 원자
  # rename — canonical 경로에 반쪽(token/pid 없는) lock이 존재하는 순간이 없다.
  _am_acquire_lock() {
    local _pre="$AM_LOCK.acq.$$"
    rm -rf "$_pre" 2>/dev/null || true
    mkdir "$_pre" 2>/dev/null || return 2
    if ! printf '%s' "$AM_LOCK_TOKEN" > "$_pre/token" 2>/dev/null \
       || ! echo "$$" > "$_pre/pid" 2>/dev/null; then
      rm -rf "$_pre" 2>/dev/null || true
      return 2
    fi
    if [ ! -e "$AM_LOCK" ] && mv "$_pre" "$AM_LOCK" 2>/dev/null; then
      # rename 경합으로 기존 lock "안"에 중첩됐을 수 있다 — 소유는 경로가 아니라
      # 내용(token)과 비중첩으로만 확정한다.
      if [ "$(cat "$AM_LOCK/token" 2>/dev/null)" = "$AM_LOCK_TOKEN" ] \
         && [ ! -d "$AM_LOCK/${_pre##*/}" ]; then
        return 0
      fi
      rm -rf "$AM_LOCK/${_pre##*/}" 2>/dev/null || true
      return 1
    fi
    rm -rf "$_pre" 2>/dev/null || true
    return 1
  }
  _acq_rc=0; _am_acquire_lock || _acq_rc=$?
  if [ "$_acq_rc" -eq 2 ]; then
    echo "[FAIL] lock 기록 실패 (권한/공간?) — 획득으로 처리하지 않음"
    exit 1
  fi
  if [ "$_acq_rc" -eq 1 ]; then
    _old_pid="$(cat "$AM_LOCK/pid" 2>/dev/null || true)"
    # 재재리뷰 P1(#9): pid 파일이 없는 lock(구 형식/반쪽 잔존)은 영구 거부의
    # 원인이었다 — 원자 rename 획득에서는 정상 lock에 항상 pid·token이 있으므로,
    # pid 부재도 stale로 간주해 원자 회수한다 (회수 검증은 관찰값 결속 그대로).
    if [ -z "$_old_pid" ] || ! kill -0 "$_old_pid" 2>/dev/null; then
      echo "[WARN] stale auto-merge lock (pid ${_old_pid:-none} dead) — reclaiming atomically"
      _stale_dir="${AM_LOCK}.reclaim.$$"
      if mv "$AM_LOCK" "$_stale_dir" 2>/dev/null; then
        # 리뷰 11차 P1: 회수를 "관찰한 그 lock"에 결속 — rename된 디렉터리의 pid가
        # 관찰값과 다르면(그 사이 새 owner로 교체) 원복하고 거부한다.
        _moved_pid="$(cat "$_stale_dir/pid" 2>/dev/null || true)"
        if [ "$_moved_pid" != "$_old_pid" ]; then
          mv "$_stale_dir" "$AM_LOCK" 2>/dev/null || true
          echo "[FAIL] lock owner changed during reclaim — refusing"
          exit 1
        fi
        rm -rf "$_stale_dir"
        _acq_rc=0; _am_acquire_lock || _acq_rc=$?
        if [ "$_acq_rc" -ne 0 ]; then echo "[FAIL] lock reclaim raced — retry later"; exit 1; fi
      else
        echo "[FAIL] lock reclaim raced — retry later"
        exit 1
      fi
    else
      echo "[FAIL] another auto-merge is in progress (lock: ${AM_LOCK}, pid ${_old_pid:-unknown})"
      exit 1
    fi
  fi
  # 리뷰 13차 P1: 이전 실행이 RECOVERY_REQUIRED로 끝났으면(미검증 merge/불명 상태
  # 잔존 가능) 새 auto-merge를 시작하지 않는다 — 수동 복구 후 marker를 제거해야 한다.
  # (검사 자체는 리뷰 14차 P2에 따라 EXIT trap 설치 "이후"로 이동 — 거부 경로가
  # trap 설치 전에 종료해 auto_merge.lock.d를 남기던 문제 수정.)
  AM_RECOVERY="$STATE_DIR/auto_merge.recovery"
  _am_mark_recovery() {
    : > "$AM_RECOVERY" 2>/dev/null || echo "[WARN] recovery marker 기록 실패: ${AM_RECOVERY}" >&2
  }

  # 리뷰 14차 P1: 워크트리 writer들과 동일한 write lock — 복원 창 동안 시스템
  # writer(rename-publish)의 개입을 배제한다 (arbitrary in-place 변경은 아래
  # hardlink 백업 결속이 잡는다). 실패는 복원 포기(REF_ONLY, 보존)로 이어진다.
  _TW_LOCK="state/ticket_write.lock.d"
  # 리뷰 16차 P1-8(7차): held 판정을 셸 플래그 설정 시점이 아니라 "파일시스템의
  # 소유 증거"에 결속한다. 종전에는 acquire가 mkdir·pid 기록을 마치고 반환한 뒤
  # "다음 명령"에서야 _AM_TW_HELD=1이 되어, 그 사이 신호가 오면 cleanup이 소유하지
  # 않은 것으로 판단해 lock을 남겼다. 이제 pid가 "이미 담긴" 사전 구성 디렉터리를
  # 원자적 rename으로 획득한다 — 성공한 순간 $_TW_LOCK/pid == $$ 가 파일시스템에
  # 성립하므로, 어느 시점에 신호가 와도 cleanup(_am_tw_release)은 내용(pid) 기준
  # 으로 정확히 판정한다. 셸 플래그 창 자체가 사라진다 (lock 형식은 기존 프로토콜
  # 그대로: 디렉터리 + pid 파일 — ticket_*.sh writer들과 호환).
  _am_tw_acquire() {
    local _i=0 _p _mp _pre
    mkdir -p state 2>/dev/null || true
    _pre="$_TW_LOCK.acq.$$"
    # 리뷰 16차 8라운드 후속 P1: 획득마다 "세션 고유 token"을 lock 안에 담는다 —
    # release는 이 token이 일치하는 lock에만 손을 댄다 (pid 재사용·lock 교체와
    # 무관한 유일 소유 증거). token 파일이 없는 lock(다른 writer 계열)은 release가
    # 관찰만 하고 절대 치우지 않는다.
    # 8라운드 후속 재리뷰 P1(#8): token 대입을 rename "이후"에 하면 그 사이의 TERM
    # 에서 cleanup이 소유를 인지하지 못해 canonical lock이 잔존했다 (실측). 소유
    # 증거는 rename이 성공하는 "순간"부터 cleanup이 확인할 수 있어야 한다 — token은
    # 사전 구성(mkpre) 시점에 파일과 셸 변수에 "동시에" 심는다. rename이 성공하면
    # 그 즉시 $_TW_LOCK/token == $_AM_TW_TOKEN 이 성립하므로, 어느 시점의 신호에서도
    # release가 정확히 판정한다. rename이 실패했다면 canonical의 token은 남의 것이라
    # release는 손대지 않는다 (무접촉).
    _am_tw_mkpre() {
      rm -rf "$_pre" 2>/dev/null || true
      mkdir "$_pre" 2>/dev/null || return 1
      _AM_TW_TOKEN="tw.$$.${RANDOM}${RANDOM}${RANDOM}"
      echo "$$" > "$_pre/pid" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
      printf '%s' "$_AM_TW_TOKEN" > "$_pre/token" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
    }
    _am_tw_mkpre || return 1
    while :; do
      if [ ! -e "$_TW_LOCK" ] && mv "$_pre" "$_TW_LOCK" 2>/dev/null; then
        # rename 경합으로 기존 lock "안"에 중첩됐을 수 있다 — 소유는 경로가 아니라
        # 내용(pid==$$ + token + 비중첩)으로만 확정한다.
        if [ "$(cat "$_TW_LOCK/pid" 2>/dev/null || true)" = "$$" ] \
           && [ "$(cat "$_TW_LOCK/token" 2>/dev/null || true)" = "$_AM_TW_TOKEN" ] \
           && [ ! -d "$_TW_LOCK/${_pre##*/}" ]; then
          _AM_TW_HELD=1
          return 0
        fi
        rm -rf "$_TW_LOCK/${_pre##*/}" 2>/dev/null || true
        _am_tw_mkpre || return 1
      fi
      _p="$(cat "$_TW_LOCK/pid" 2>/dev/null || true)"
      if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
        if mv "$_TW_LOCK" "$_TW_LOCK.reclaim.$$" 2>/dev/null; then
          _mp="$(cat "$_TW_LOCK.reclaim.$$/pid" 2>/dev/null || true)"
          if [ "$_mp" = "$_p" ]; then
            rm -rf "$_TW_LOCK.reclaim.$$" 2>/dev/null || true
            continue
          fi
          mv "$_TW_LOCK.reclaim.$$" "$_TW_LOCK" 2>/dev/null || { rm -rf "$_pre" 2>/dev/null || true; return 1; }
        fi
      fi
      _i=$((_i+1))
      if [ "$_i" -ge 100 ]; then rm -rf "$_pre" 2>/dev/null || true; return 1; fi
      sleep 0.1
    done
  }
  # 리뷰 16차 P1(8차 2회, #8) → 8라운드 후속 P1: 해제는 "내 token이 담긴 lock"
  # 에만 손을 댄다. 8차 2회의 rename-먼저 방식은 소유 확인 "전"에 canonical
  # lock을 들어냈다 — cleanup은 획득 여부와 무관하게 release를 호출하므로, 살아
  # 있는 foreign lock이 빈 창 동안 canonical 경로에서 사라져 제3 writer가
  # 획득했고 상호배제가 깨졌다 (실측: canonical=third, displaced=live foreign).
  # 이제 (1) 획득하지 않았으면(token 없음) 아무것도 하지 않고, (2) 치우기 전에
  # canonical lock의 token을 먼저 읽어 내 것일 때만 rename하며, (3) rename 후
  # 재확인해 어긋나면 원복한다 — 알려진 foreign lock은 한순간도 canonical
  # 경로를 떠나지 않는다.
  _am_tw_release() {
    local _rel="$_TW_LOCK.rel.$$" _t
    [ -n "${_AM_TW_TOKEN:-}" ] || return 0          # 획득한 적 없음 — 무접촉
    [ -d "$_TW_LOCK" ] || return 0
    _t="$(cat "$_TW_LOCK/token" 2>/dev/null || true)"
    [ "$_t" = "$_AM_TW_TOKEN" ] || return 0          # foreign lock — 무접촉
    mv "$_TW_LOCK" "$_rel" 2>/dev/null || return 0   # 이미 사라졌거나 남이 들고 있음
    if [ "$(cat "$_rel/token" 2>/dev/null || true)" = "$_AM_TW_TOKEN" ]; then
      rm -rf "$_rel" 2>/dev/null || true
      _AM_TW_TOKEN=""
      return 0
    fi
    # 읽기~rename 사이에 교체됨(프로토콜 밖 개입) — 덮지 않고 원복한다.
    if [ -e "$_TW_LOCK" ] || ! mv "$_rel" "$_TW_LOCK" 2>/dev/null; then
      echo "[WARN] writer lock 원복 실패 — 확인 필요: ${_rel}" >&2
    fi
    return 0
  }

  # 리뷰 13차 P1 + 14차 P1: CAS 후 워크트리 동기화. 모든 dirty 항목이 "정확히 merge
  # 잔상"(내용이 MERGE_COMMIT blob과 일치)인지 검증한 뒤, 전역 `reset --hard` 대신
  # 검증된 경로만 개별 복원한다. 검증~복원 TOCTOU는 복원 시점에 파괴를 내용에
  # 결속해 제거한다:
  #   - 수정/추가 항목: 기존 inode를 hardlink 백업 → rename 교체 → 백업 내용이
  #     여전히 merge blob인지 재확인. 다르면(그 사이 in-place 동시 변경) 백업을
  #     되돌려 보존하고 REF_ONLY로 격하.
  #   - 삭제 항목 복원: ln(no-clobber, 원자적)으로만 생성 — 그 사이 생긴 파일을
  #     덮지 않는다.
  # 반환: 0=완전 복구(최종 clean), 1=ref-only(잔여 변경 보존).
  #
  # 리뷰 16차 P1(open-FD late write): blob 대조를 통과한 캡처본이라도, 그 inode에
  # 열린 FD가 남아 있으면 폐기(rm) 후의 늦은 write가 orphan inode로 사라진다 —
  # 폐기 직전 열린 FD를 검사해, 열려 있으면 원복·보존하고 REF_ONLY로 격하한다.
  # 판별 도구(lsof/fuser)가 없으면 열린 것으로 간주한다 (fail-closed).
  _fd_busy() {
    if command -v lsof >/dev/null 2>&1; then
      lsof -t -- "$1" >/dev/null 2>&1
    elif command -v fuser >/dev/null 2>&1; then
      fuser -s -- "$1" 2>/dev/null
    else
      return 0
    fi
  }
  # 리뷰 16차 P1(재수정, open-FD 경합 창): _fd_busy 검사 "직후" 열린 FD는 여전히
  # 다음 unlink에서 늦은 write를 잃는다 — 검사-후-삭제는 원자화가 불가능하므로
  # "삭제하지 않는다". 폐기 = 격리 디렉터리로 rename(원자, inode 보존).
  # 리뷰 16차 P1(4차): git-dir는 linked worktree에서 워크트리와 "다른 파일시스템/
  # 볼륨"일 수 있고(mv가 copy+unlink로 강등 → 늦은 write 유실), per-worktree
  # gitdir는 `git worktree remove`와 함께 삭제된다 — 격리 위치를 STATE_DIR
  # (워크트리 내 state/, 워크트리와 같은 볼륨)로 옮기고, rename 전에 실제로
  # 같은 device인지 검증한다. 다르면 폐기하지 않는다 (호출자가 원복·보존).
  _AM_GITDIR="$(git rev-parse --git-dir 2>/dev/null)"
  # 리뷰 16차 P1-9(6차): 격리 위치는 common git dir 하나뿐 — STATE_DIR(워크트리 내)
  # fallback은 `git worktree remove`와 함께 소실되므로 "격리"가 아니었다. common
  # git dir는 linked worktree remove에도 살아남고 clean -fd가 절대 닿지 않는다.
  # 파일과 device가 다르면(cross-volume rename은 copy+unlink 강등 — 늦은 write
  # 유실) 폐기하지 않는다 — 호출자가 원복·보존하고 REF_ONLY로 격하한다.
  _AM_COMMON_TRASH="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null || git rev-parse --git-common-dir 2>/dev/null)/auto_merge.trash.d"
  _dev_of() { stat -c '%d' "$1" 2>/dev/null || stat -f '%d' "$1" 2>/dev/null; }
  _am_trash_init() {  # $1=trash dir
    mkdir -p "$1" 2>/dev/null || return 1
    # 재재리뷰 P2: README는 "항상" 현행 계약으로 갱신한다 — 구 버전 README가 낡은
    # 복구 절차를 안내하던 문제 제거. 갱신은 temp+rename(원자)으로.
    local _rmd="$1/.README.md.$$"
    if {
        echo "# auto_merge quarantine"
        echo "rollback이 폐기한 merge 잔상. unlink 대신 rename으로 보존해 열린 FD의"
        echo "늦은 write도 이 inode에 남는다 (리뷰 16차 P1)."
        echo "- 복구: manifest.tsv(시각, merge OID, 원경로, 격리 경로, worktree toplevel)에서"
        echo "  찾아 mv로 복원 — 원경로는 5열의 worktree 기준 상대 경로다 (공유 trash 식별)."
        echo "- 불변식: manifest에 행이 있으면 그 격리 파일은 반드시 존재한다 (기록은 rename 후)."
        echo "- '*.intent'는 원본을 건드리기 '전'에 기록된다 (time/merge/src/worktree/capture/dst)."
        echo "  복구 절차: dst에 payload가 있으면 그것을, 없고 capture에 있으면 그것을"
        echo "  <worktree>/<src>로 되돌린다 (no-clobber). 둘 다 없으면 원본은 원위치에 있다."
        echo "- intent는 payload가 원위치(원복 성공) 또는 manifest 행(격리 완료)으로 확정된"
        echo "  뒤에만 삭제된다 — capture 경로에 payload가 남아 있으면 intent도 남는다."
        echo "- capture 경로는 파일별 고유(.amrb-bak.<pid>.<seq>.<rand>)다 — 같은 실행의"
        echo "  다른 파일이 재사용하지 않는다."
        echo "- 행이 없고 intent만 있는 격리본 = 기록 전 중단 — 위 절차로 복원 후 intent 삭제."
        echo "- 보존: 해당 rollback의 감사 로그(ROLLED_BACK) 확인 후 수동 삭제 가능 (자동 삭제 없음)."
        echo "- rename 실패 시에는 행을 남기지 않는다 — 그 파일은 격리되지 않고 원위치에 있다."
      } > "$_rmd" 2>/dev/null; then
      mv -f "$_rmd" "$1/README.md" 2>/dev/null || rm -f "$_rmd" 2>/dev/null || true
    else
      rm -f "$_rmd" 2>/dev/null || true
    fi
    return 0
  }
  # 재재리뷰 P2: 기록의 내구성 — manifest/intent는 복구의 유일한 근거이므로 기록
  # 직후 디스크 반영을 시도한다 (sync <file> 미지원 환경은 전체 sync로 폴백,
  # 실패해도 기록 자체는 유효 — best effort).
  _am_fsync() { sync "$1" 2>/dev/null || sync 2>/dev/null || true; }
  # 재재리뷰 P1(#10-b): capture(백업) 경로는 "파일별 고유"다 — 종전의 .amrb-bak.$$
  # 하나를 같은 디렉터리의 모든 경로가 재사용해, 첫 파일에서 보존된 capture를 두
  # 번째 파일의 mv가 덮어 내용이 유실됐다 (실측). pid+실행 내 시퀀스+RANDOM으로
  # 자기충돌을 제거하고, 존재 검사로 외부 충돌도 회피한다.
  _AM_BAK=""
  _AM_BAK_SEQ=0
  _am_bak_path() {  # $1=원경로 → _AM_BAK에 고유 capture 경로 설정
    local _d _i=0
    _d="$(dirname "$1")"
    while :; do
      _AM_BAK_SEQ=$((_AM_BAK_SEQ+1))
      _AM_BAK="$_d/.amrb-bak.$$.${_AM_BAK_SEQ}.${RANDOM}"
      [ -e "$_AM_BAK" ] || return 0
      _i=$((_i+1))
      [ "$_i" -ge 10 ] && { _AM_BAK=""; return 1; }
    done
  }
  # ── quarantine 계약 (8라운드 후속 재리뷰 P1 #9·#10) ────────────────────────────
  # 순서: intent 기록 → 원본 capture(rename) → trash 격리(rename) → manifest → intent 제거
  #
  # #9: 종전에는 원본을 .amrb-bak.<pid>로 옮긴 "뒤" _am_discard가 intent를 썼다 —
  #     그 사이 KILL되면 원본은 원경로에서 사라지고 hidden backup만 남으며
  #     intent·manifest는 없어 결정적 복구가 불가능했다 (실측). intent는 원본을
  #     건드리기 "전"에 기록한다: 어느 지점에서 KILL돼도 intent가 payload의 현재
  #     위치(capture 또는 dst)를 가리킨다.
  # 불변식: manifest에 행이 있으면 그 격리 파일이 존재한다 (기록은 격리 rename 후).
  _AM_Q_DST=""
  _AM_Q_INTENT=""
  _am_intent_begin() {  # $1=capture(bak) 예정 경로, $2=원경로(worktree 상대)
    local _dir _wt _ts _i _d1 _d2 _cap
    _dir="$_AM_COMMON_TRASH"
    _AM_Q_DST=""; _AM_Q_INTENT=""
    _am_trash_init "$_dir" || return 1
    # 리뷰 16차 P1-9(7차): device 검사는 fail-closed — stat이 한쪽이라도 실패하면
    # 빈 문자열끼리 "같다"로 판정되어 cross-volume mv(copy+unlink 강등, 늦은
    # write 유실)를 진행했다. 양쪽 device 값이 모두 non-empty일 때만 비교를 허용한다
    # (capture는 원본과 같은 디렉터리 — 그 디렉터리와 trash의 device를 비교).
    _d1="$(_dev_of "$(dirname "$1")")"; _d2="$(_dev_of "$_dir")"
    [ -n "$_d1" ] && [ -n "$_d2" ] && [ "$_d1" = "$_d2" ] || return 1
    _wt="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
    # capture는 절대 경로로 기록한다 — 복구자가 cwd에 의존하지 않도록.
    case "$1" in /*) _cap="$1" ;; *) _cap="${_wt}/$1" ;; esac
    _i=0
    while :; do
      _AM_Q_DST="$_dir/$(date +%s).$$.${RANDOM}.$(basename "$2")"
      _AM_Q_INTENT="${_AM_Q_DST}.intent"
      # noclobber 생성으로 목적지를 예약하고 동시에 복구 metadata를 기록한다.
      if (set -C; printf 'time\t%s\nmerge\t%s\nsrc\t%s\nworktree\t%s\ncapture\t%s\ndst\t%s\npid\t%s\nphase\tintent\n' \
            "$_ts" "${MERGE_COMMIT:-unknown}" "$2" "$_wt" "$_cap" "$_AM_Q_DST" "$$" > "$_AM_Q_INTENT") 2>/dev/null; then
        _am_fsync "$_AM_Q_INTENT"   # 재재리뷰 P2: intent는 복구의 유일 근거 — 내구성 확보
        return 0
      fi
      _i=$((_i+1))
      [ "$_i" -ge 10 ] && { _AM_Q_DST=""; _AM_Q_INTENT=""; return 1; }
    done
  }
  _am_intent_abort() {  # 원본을 원위치로 되돌린 뒤 호출 — 예약·복구 기록 해제
    [ -n "$_AM_Q_INTENT" ] && rm -f "$_AM_Q_INTENT" 2>/dev/null
    _AM_Q_DST=""; _AM_Q_INTENT=""
    return 0
  }
  _am_discard() {  # $1=캡처 파일, $2=원경로(기록용) — _am_intent_begin이 선행돼야 한다
    local _dir _dst _ts _wt
    _dir="$_AM_COMMON_TRASH"
    _dst="$_AM_Q_DST"
    [ -n "$_dst" ] || return 1
    if ! mv "$1" "$_dst" 2>/dev/null; then
      return 1   # 파일은 capture 경로 그대로 — 호출자가 원복·보존 (intent 유지)
    fi
    _ts="$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)"
    _wt="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if ! printf '%s\t%s\t%s\t%s\t%s\n' "$_ts" \
        "${MERGE_COMMIT:-unknown}" "$2" "$_dst" "$_wt" >> "$_dir/manifest.tsv" 2>/dev/null; then
      # #10: 기록 실패의 되돌리기는 no-clobber여야 한다 — mv -f는 그 사이 capture
      # 경로에 생긴 동시 파일을 덮어 실제 내용을 유실시켰다 (실측). ln(목적지 존재
      # 시 실패)로 되돌리고, 불가하면 격리본을 intent와 함께 남겨 복구 근거를 보존한다.
      # 어느 쪽이든 "기록 실패 = 실패"다 (rollback 성공으로 취급하지 않는다).
      if ln "$_dst" "$1" 2>/dev/null; then
        rm -f "$_dst" 2>/dev/null || true
        return 1   # payload는 capture 경로로 복귀 — 호출자가 원경로로 원복한다
      fi
      # capture 경로가 동시 파일에 선점됐다 — 그 파일은 우리 것이 아니므로 손대지
      # 않는다(덮지도, 원경로로 옮기지도 않는다). payload는 trash에 intent와 함께
      # 남아 결정적 복구가 가능하다. rc=2로 "capture에서 원복하지 말 것"을 알린다.
      echo "[WARN] quarantine manifest 기록 실패 — capture 경로(${1})가 동시 파일에 선점되어 되돌리지 않았습니다. 격리본을 intent와 함께 보존합니다: ${_dst} (${_dst}.intent 참조)" >&2
      return 2
    fi
    _am_fsync "$_dir/manifest.tsv"   # 재재리뷰 P2: manifest 내구성 (기록 후, intent 제거 전)
    # committed 전환: manifest 행 기록 완료 후 intent 제거 — intent가 남고 행이 없는
    # 격리본 = 기록 전 중단(intent로 복구), 행이 있는 격리본 = committed.
    rm -f "${_dst}.intent" 2>/dev/null || true
    _AM_Q_DST=""; _AM_Q_INTENT=""
    return 0
  }
  # 리뷰 16차 P1-10(6차): 원복은 no-clobber — 캡처(rename)~원복 사이에 다른
  # 프로세스가 원경로에 만든 "새 파일"을 mv -f가 덮어썼다. ln(하드링크, 목적지
  # 존재 시 실패)으로 inode를 보존한 채 복원하고(캡처본에 열린 FD의 늦은 write도
  # 유지), 실패하면 새 파일을 덮지 않고 캡처본을 남겨 경고한다.
  _am_restore() {  # $1=캡처 파일, $2=원경로
    if ln "$1" "$2" 2>/dev/null; then rm -f "$1" 2>/dev/null || true; return 0; fi
    echo "⚠️  원복 생략: ${2}에 그 사이 새 파일이 생성됨 — 덮지 않고 캡처본을 ${1}에 보존합니다." >&2
    return 1
  }
  # 리뷰 16차 P1(4차): index CAS 임계구역 중 신호/종료 시 잔여물(.git/index.lock·
  # index.amrb.*·writer lock)을 반드시 정리한다 — Git 수동 복구까지 막던 고착 제거.
  _AM_ILOCK_PATH=""
  _AM_ILOCK_TOKEN=""
  _AM_LTMP_PATH=""
  _AM_ITMP_PATH=""
  _AM_TW_HELD=0
  _AM_TW_TOKEN=""
  _am_release_transients() {
    [ -n "${_AM_ITMP_PATH:-}" ] && { rm -f "$_AM_ITMP_PATH" 2>/dev/null || true; _AM_ITMP_PATH=""; }
    [ -n "${_AM_LTMP_PATH:-}" ] && { rm -f "$_AM_LTMP_PATH" 2>/dev/null || true; _AM_LTMP_PATH=""; }
    if [ -n "${_AM_ILOCK_PATH:-}" ]; then
      # 리뷰 16차 P1-8(6차): 소유 판정은 경로가 아니라 "내용 토큰" — 내 토큰과
      # 일치할 때만 삭제한다. 획득 실패 직후 신호가 와도 남의 index.lock(git
      # 자신의 lock 포함)은 내용이 다르므로 절대 지우지 않는다.
      if [ -n "${_AM_ILOCK_TOKEN:-}" ] \
         && [ "$(cat "$_AM_ILOCK_PATH" 2>/dev/null || true)" = "$_AM_ILOCK_TOKEN" ]; then
        rm -f "$_AM_ILOCK_PATH" 2>/dev/null || true
      fi
      _AM_ILOCK_PATH=""
      _AM_ILOCK_TOKEN=""
    fi
    # 리뷰 16차 P1-8(7차): held 플래그가 아니라 lock의 "내용"(pid==$$)으로 판정
    # 하는 release를 무조건 호출한다 — acquire 성공 직후 신호가 와도 정확히
    # 해제된다. 획득 전 단계의 사전 구성 디렉터리(.acq.$$)도 함께 정리.
    _am_tw_release 2>/dev/null || true
    rm -rf "$_TW_LOCK.acq.$$" 2>/dev/null || true
    _AM_TW_HELD=0
    return 0
  }
  # 리뷰 16차 P1(index 원자성): 비교와 reset을 git 규약의 index.lock 아래에서
  # 수행한다 — lock 획득(noclobber) → canonical index 재검증 → 임시 index에
  # 경로 단위 reset → rename publish. lock을 쥔 동안 다른 git writer는 git 자신의
  # 규약대로 실패하므로, 검증~publish 사이에 같은 경로가 stage될 수 없다.
  # 비교는 blob OID만이 아니라 "mode OID stage" 전체 identity로 한다.
  # $1=path, $2/$3=허용 index 항목("mode oid stage", ""=부재; $3 생략 가능)
  _am_index_reset_path() {
    local _p="$1" _e1="$2" _e2="${3-__none__}" _ilock _itmp _cur _ltmp
    _ilock="${_AM_GITDIR}/index.lock"
    # 리뷰 16차 P1-8(6차): 5차의 "획득 전 경로 등록"은 획득 실패(타 프로세스의
    # lock 존재) 직후 신호가 오면 핸들러의 rm -f가 "남의" index.lock을 지웠다.
    # 소유는 경로가 아니라 "내용 토큰"으로 판정한다: 고유 토큰을 담은 임시 파일을
    # ln(원자, 목적지 존재 시 실패)으로 index.lock에 걸고, 핸들러·해제는 내용이
    # 내 토큰과 일치할 때만 삭제한다. git 자신의 lock(내용=index 바이너리)이나
    # 다른 인스턴스의 lock(다른 토큰)은 어느 시점의 신호에서도 지워지지 않는다.
    _AM_ILOCK_TOKEN="amrb.$$.${RANDOM}${RANDOM}.${RANDOM}"
    _ltmp="${_AM_GITDIR}/index.amrb-lock.$$"
    _AM_LTMP_PATH="$_ltmp"
    if ! printf '%s' "$_AM_ILOCK_TOKEN" > "$_ltmp" 2>/dev/null; then
      rm -f "$_ltmp" 2>/dev/null || true
      _AM_LTMP_PATH=""; _AM_ILOCK_TOKEN=""
      return 1
    fi
    _AM_ILOCK_PATH="$_ilock"
    if ! ln "$_ltmp" "$_ilock" 2>/dev/null; then
      rm -f "$_ltmp"
      _AM_LTMP_PATH=""; _AM_ILOCK_PATH=""; _AM_ILOCK_TOKEN=""
      return 1
    fi
    rm -f "$_ltmp"
    _AM_LTMP_PATH=""
    _itmp="${_AM_GITDIR}/index.amrb.$$"
    _AM_ITMP_PATH="$_itmp"
    if ! cp "${_AM_GITDIR}/index" "$_itmp" 2>/dev/null; then rm -f "$_ilock" "$_itmp"; _AM_ILOCK_PATH=""; _AM_ILOCK_TOKEN=""; _AM_ITMP_PATH=""; return 1; fi
    _cur="$(git ls-files -s -- "$_p" 2>/dev/null | awk '{print $1" "$2" "$3; exit}')"
    if [ "$_cur" != "$_e1" ] && [ "$_cur" != "$_e2" ]; then
      rm -f "$_itmp" "$_ilock"; _AM_ILOCK_PATH=""; _AM_ILOCK_TOKEN=""; _AM_ITMP_PATH=""; return 1
    fi
    if ! GIT_INDEX_FILE="$_itmp" git reset -q "HEAD" -- "$_p" >/dev/null 2>&1; then
      rm -f "$_itmp" "$_ilock"; _AM_ILOCK_PATH=""; _AM_ILOCK_TOKEN=""; _AM_ITMP_PATH=""; return 1
    fi
    if ! mv -f "$_itmp" "${_AM_GITDIR}/index"; then
      rm -f "$_itmp" "$_ilock"; _AM_ILOCK_PATH=""; _AM_ILOCK_TOKEN=""; _AM_ITMP_PATH=""; return 1
    fi
    _AM_ITMP_PATH=""
    rm -f "$_ilock"
    _AM_ILOCK_PATH=""
    _AM_ILOCK_TOKEN=""
  }
  _sync_worktree_after_cas() {
    [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" = "$BASE_BRANCH" ] || return 1
    local _now _line _st _p _want _have _tmp _bak _mode _perm _mmode _hent _dq _rc=0
    _now="$(_wt_status_or_fail 2>/dev/null)" || return 1
    [ -z "$_now" ] && return 0
    case "$_now" in *'"'*) return 1 ;; esac
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _st="${_line%"${_line#??}"}"
      _p="${_line#???}"
      case "$_st" in
        'M '|'A ')
          _want="$(git rev-parse -q --verify "${MERGE_COMMIT}:${_p}" 2>/dev/null)" || return 1
          _have="$(git hash-object -- "$_p" 2>/dev/null)" || return 1
          [ "$_want" = "$_have" ] || return 1
          ;;
        'D ')
          git rev-parse -q --verify "${MERGE_COMMIT}:${_p}" >/dev/null 2>&1 && return 1
          [ -e "$_p" ] && return 1
          ;;
        *) return 1 ;;
      esac
    done <<EOF
$_now
EOF
    # 7차 P1-8: held 상태는 acquire "내부"에서 성공 확정과 함께 설정된다 —
    # 반환 후 별도 플래그 설정 없음 (그 사이 신호 창 제거).
    _am_tw_acquire || return 1
    while IFS= read -r _line; do
      [ -z "$_line" ] && continue
      _st="${_line%"${_line#??}"}"
      _p="${_line#???}"
      # 리뷰 15차 P1 + 16차 P1(재수정): index 동기화는 경로 단위이며, 비교와
      # reset을 index.lock 아래에서 원자적으로 결속한다(_am_index_reset_path) —
      # 허용 항목은 "mode OID stage" 전체 identity로, 정확히 merge 잔상 또는
      # 이미 HEAD와 일치할 때만. 그 외(그 사이 누가 stage·conflict stage 포함)는
      # 보존하고 REF_ONLY로 격하.
      _want=""
      case "$_st" in
        'M '|'A ') _want="$(git rev-parse -q --verify "${MERGE_COMMIT}:${_p}" 2>/dev/null)" || { _rc=1; continue; } ;;
      esac
      case "$_st" in
        'M ')
          _mmode="$(git ls-tree "$MERGE_COMMIT" -- "$_p" 2>/dev/null | awk '{print $1; exit}')"
          _hent="$(git ls-tree "HEAD" -- "$_p" 2>/dev/null | awk '{print $1" "$3" 0"; exit}')"
          _am_index_reset_path "$_p" "${_mmode} ${_want} 0" "$_hent" || { _rc=1; continue; }
          ;;
        'A ')
          _mmode="$(git ls-tree "$MERGE_COMMIT" -- "$_p" 2>/dev/null | awk '{print $1; exit}')"
          _am_index_reset_path "$_p" "${_mmode} ${_want} 0" "" || { _rc=1; continue; }
          ;;
        'D ')
          _am_index_reset_path "$_p" "" || { _rc=1; continue; }
          ;;
      esac
      case "$_st" in
        'M ')
          # 리뷰 15차 P1: 파괴를 "지금 그 inode"에 원자 결속 — hardlink 후 교체(ln~mv
          # 창의 atomic replace를 덮음)가 아니라 rename으로 현재 파일을 먼저 캡처하고,
          # 내용이 merge blob일 때만 폐기한다. 다르면(동시 교체 캡처) 원복·보존.
          _want="$(git rev-parse -q --verify "${MERGE_COMMIT}:${_p}" 2>/dev/null)" || { _rc=1; continue; }
          _tmp="$(mktemp "$(dirname "$_p")/.amrb.XXXXXX" 2>/dev/null)" || { _rc=1; continue; }
          if ! git cat-file blob "HEAD:${_p}" > "$_tmp" 2>/dev/null; then rm -f "$_tmp"; _rc=1; continue; fi
          _perm="$(stat -c '%a' "$_p" 2>/dev/null || stat -f '%Lp' "$_p" 2>/dev/null || true)"
          if [ -z "$_perm" ] || ! chmod "$_perm" "$_tmp" 2>/dev/null; then rm -f "$_tmp"; _rc=1; continue; fi
          # 재재리뷰 P1(#10-b): capture 경로는 파일별 고유 — .amrb-bak.$$ 재사용이
          # 첫 파일의 보존 capture를 두 번째 파일의 mv로 덮던 유실 제거.
          if ! _am_bak_path "$_p"; then rm -f "$_tmp"; _rc=1; continue; fi
          _bak="$_AM_BAK"
          # 8라운드 후속 재리뷰 P1(#9): 원본을 건드리기 "전"에 intent를 기록한다 —
          # capture 직후 KILL돼도 payload 위치를 가리키는 복구 근거가 디스크에 남는다.
          # (device 검사도 여기서 — 폐기 불가능한 상황이면 원본을 옮기지 않는다.)
          if ! _am_intent_begin "$_bak" "$_p"; then rm -f "$_tmp"; _rc=1; continue; fi
          if ! mv "$_p" "$_bak" 2>/dev/null; then _am_intent_abort; rm -f "$_tmp"; _rc=1; continue; fi
          if [ "$(git hash-object -- "$_bak" 2>/dev/null)" != "$_want" ]; then
            # 재재리뷰 P1(#10-a): intent 해제는 원복이 "실제로 성공"했을 때만 —
            # 실패 시 payload가 capture 경로에 남으므로 intent가 그 위치를 계속
            # 가리켜야 결정적 복구가 가능하다.
            if _am_restore "$_bak" "$_p"; then _am_intent_abort; fi   # 동시 교체 캡처 — 원복·보존 (no-clobber)
            rm -f "$_tmp"; _rc=1; continue
          fi
          # 리뷰 16차 P1: 폐기 직전 open-FD 검사 — 열린 FD의 늦은 write를 orphan
          # inode로 잃지 않는다. 열려 있으면 원복·보존 (REF_ONLY 격하).
          if _fd_busy "$_bak"; then
            if _am_restore "$_bak" "$_p"; then _am_intent_abort; fi   # #10-a: 실패 시 intent 유지
            rm -f "$_tmp"; _rc=1; continue
          fi
          # unlink 금지 — 검사 직후 열린 FD의 늦은 write도 격리 inode에 보존된다.
          _dq=0; _am_discard "$_bak" "$_p" || _dq=$?
          if [ "$_dq" -ne 0 ]; then
            # rc=2: capture 경로가 동시 파일에 선점됨 — 그 파일은 우리 것이 아니므로
            # 원경로로 옮기지 않는다 (payload는 trash에 intent와 함께 보존).
            [ "$_dq" -ne 2 ] && { _am_restore "$_bak" "$_p" && _am_intent_abort; }
            rm -f "$_tmp"; _rc=1; continue
          fi
          # 캡처~복원 사이 새로 생긴 파일은 덮지 않는다 (ln no-clobber) — 실패 시 보존.
          if ! ln "$_tmp" "$_p" 2>/dev/null; then _rc=1; fi
          rm -f "$_tmp"
          ;;
        'A ')
          # merge가 추가한 파일 — rename으로 원자 캡처 후, 내용이 merge blob일 때만
          # 폐기 (리뷰 15차 P1: ln~rm 창의 동시 atomic replace 삭제 제거).
          _want="$(git rev-parse -q --verify "${MERGE_COMMIT}:${_p}" 2>/dev/null)" || { _rc=1; continue; }
          # #10-b: capture 경로는 파일별 고유
          if ! _am_bak_path "$_p"; then _rc=1; continue; fi
          _bak="$_AM_BAK"
          # #9: intent를 원본 capture 전에 (device 검사 포함)
          if ! _am_intent_begin "$_bak" "$_p"; then _rc=1; continue; fi
          if ! mv "$_p" "$_bak" 2>/dev/null; then _am_intent_abort; _rc=1; continue; fi
          if [ "$(git hash-object -- "$_bak" 2>/dev/null)" != "$_want" ]; then
            # #10-a: 원복 성공 시에만 intent 해제 — 실패 시 capture payload의 복구
            # 매핑(intent)을 보존한다.
            if _am_restore "$_bak" "$_p"; then _am_intent_abort; fi   # 동시 교체 캡처 — 원복·보존 (no-clobber)
            _rc=1
          elif _fd_busy "$_bak"; then
            # 리뷰 16차 P1: 열린 FD 감지 — 늦은 write 유실 방지, 원복·보존.
            if _am_restore "$_bak" "$_p"; then _am_intent_abort; fi   # #10-a: 실패 시 intent 유지
            _rc=1
          else
            _dq=0; _am_discard "$_bak" "$_p" || _dq=$?
            if [ "$_dq" -ne 0 ]; then
              # rc=2: capture 경로 선점 — 동시 파일을 건드리지 않는다 (위 참조)
              [ "$_dq" -ne 2 ] && { _am_restore "$_bak" "$_p" && _am_intent_abort; }
              _rc=1
            fi
          fi
          ;;
        'D ')
          # merge가 삭제한 파일 — base 내용으로 복원 (ln no-clobber: 그 사이 생긴 파일 보호)
          _mode="$(git ls-tree "HEAD" -- "$_p" 2>/dev/null | awk '{print $1; exit}')"
          case "$_mode" in
            100755) _perm=755 ;;
            100644) _perm=644 ;;
            *) _rc=1; continue ;;   # symlink 등은 자동 복원하지 않음 (보존적)
          esac
          _tmp="$(mktemp "$(dirname "$_p")/.amrb.XXXXXX" 2>/dev/null)" || { _rc=1; continue; }
          if ! git cat-file blob "HEAD:${_p}" > "$_tmp" 2>/dev/null; then rm -f "$_tmp"; _rc=1; continue; fi
          chmod "$_perm" "$_tmp" 2>/dev/null || { rm -f "$_tmp"; _rc=1; continue; }
          if ! ln "$_tmp" "$_p" 2>/dev/null; then _rc=1; fi
          rm -f "$_tmp"
          ;;
      esac
    done <<EOF
$_now
EOF
    _am_tw_release
    _AM_TW_HELD=0
    # 최종 판정: clean일 때만 완전 복구 — 잔여(보존된 동시 변경 포함)는 REF_ONLY.
    [ "$_rc" -eq 0 ] || return 1
    _now="$(_wt_status_or_fail 2>/dev/null)" || return 1
    [ -z "$_now" ]
  }

  # 리뷰 13차 P1: 신호 시점에 이미 merge 커밋이 존재하면(merged, 또는 merging 중
  # 훅 단계에서 커밋 생성) 미검증 결과를 base에 남기지 않는다 — CAS 롤백을 시도하고,
  # 불가능하면 recovery marker를 남겨 다음 실행을 차단한다.
  _am_signal_rollback() {
    local _mc="$1"
    if git update-ref -m "auto-merge signal rollback ${TICKET_ID}"          "refs/heads/${BASE_BRANCH}" "$BASE_OID" "$_mc" 2>/dev/null; then
      if MERGE_COMMIT="$_mc" _sync_worktree_after_cas; then
        _am_log "$BASE_OID" "INTERRUPTED_ROLLED_BACK"
      else
        _am_log "$BASE_OID" "INTERRUPTED_ROLLED_BACK_REF_ONLY"
        _am_mark_recovery
      fi
    else
      _am_log "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "RECOVERY_REQUIRED:signal"
      _am_mark_recovery
    fi
  }

  # 리뷰 9차 P1: phase-aware 감사 — EXECUTED/ROLLED_BACK 확정 전에 종료(SIGTERM 등)되면
  # INTERRUPTED:<phase>를 남겨 병합 잔존 여부를 감사 로그에서 알 수 있게 한다.
  # 리뷰 10차 P1: lock 해제는 token이 자신일 때만 (남의 lock 삭제 금지).
  AM_PHASE="pre-merge"
  trap '_am_release_transients; [ "$AM_PHASE" != "done" ] && _am_log "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "INTERRUPTED:${AM_PHASE}"; [ "$(cat "$AM_LOCK/token" 2>/dev/null)" = "$AM_LOCK_TOKEN" ] && rm -rf "$AM_LOCK" 2>/dev/null; rm -rf "$AM_LOCK.acq.$$" 2>/dev/null || true' EXIT
  # 리뷰 11차 P1: TERM/INT/HUP 시 실행 중인 post-check 자식 그룹을 먼저 종료·reap한
  # 뒤에야 EXIT trap이 lock을 해제한다 (자식이 lock 해제 후에도 실행되던 문제).
  AM_CHECK_PID=""
  # 리뷰 12차 P1: 그룹 기준 생존 판정 — leader가 먼저 죽어도 그룹의 잔존 자손을
  # 회수한다 (kill -0 -- -PGID). 신호 시 진행 중이던 merge 잔여도 abort 시도.
  _am_on_signal() {
    _am_release_transients
    if [ -n "${AM_CHECK_PID:-}" ]; then
      kill -TERM -- "-${AM_CHECK_PID}" 2>/dev/null || kill -TERM "${AM_CHECK_PID}" 2>/dev/null || true
      local _i=0
      while kill -0 -- "-${AM_CHECK_PID}" 2>/dev/null && [ "$_i" -lt 10 ]; do sleep 0.5; _i=$((_i+1)); done
      kill -KILL -- "-${AM_CHECK_PID}" 2>/dev/null || true
      wait "${AM_CHECK_PID}" 2>/dev/null || true
    fi
    # 리뷰 12차 P1 + 13차 P1 + 14차 P1: merge 도중 신호면 abort 시도. abort의 rc는
    # 믿지 않는다 — 커밋이 이미 만들어진 뒤 MERGE_HEAD만 남은 창에서는 abort가
    # '성공'(rc=0, git reset --merge)해도 HEAD를 옮기지 않아 2-parent merge가 base에
    # 남는다. 판정은 항상 "최종 HEAD 상태"로 한다.
    if [ "${AM_PHASE:-}" = "merging" ]; then
      git merge --abort >/dev/null 2>&1 || true
      local _h
      _h="$(git rev-parse HEAD 2>/dev/null || true)"
      if [ -z "$_h" ]; then
        _am_mark_recovery
      elif [ "$_h" != "$BASE_OID" ]; then
        if [ "$(git rev-parse -q --verify "${_h}^1" 2>/dev/null)" = "$BASE_OID" ] \
           && [ "$(git rev-parse -q --verify "${_h}^2" 2>/dev/null)" = "$BRANCH_OID" ]; then
          _am_signal_rollback "$_h"
        else
          _am_log "$_h" "RECOVERY_REQUIRED:signal"
          _am_mark_recovery
        fi
      fi
      if [ -e "$(git rev-parse --git-dir 2>/dev/null)/MERGE_HEAD" ]; then
        _am_mark_recovery
      fi
    fi
    # 리뷰 13차 P1: merge 커밋 확정 후(post-check 창) 신호 — 미검증 merge를 그대로
    # 두지 않고 CAS 롤백한다. 실패 시 recovery marker로 다음 실행을 차단.
    if [ "${AM_PHASE:-}" = "merged" ] && [ -n "${MERGE_COMMIT:-}" ]; then
      _am_signal_rollback "$MERGE_COMMIT"
    fi
    exit 143
  }
  trap _am_on_signal TERM INT HUP

  # 리뷰 13차 P1(검사) + 14차 P2(위치): recovery marker 거부는 EXIT trap 설치 "이후"에
  # 수행 — 과거에는 trap 설치 전에 exit해 획득한 auto_merge.lock.d가 잔존했다.
  if [ -e "$AM_RECOVERY" ]; then
    AM_PHASE="done"
    _am_log "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "REFUSED:recovery-pending"
    echo "[FAIL] 이전 auto-merge가 RECOVERY_REQUIRED 상태입니다 — 수동 복구 후 ${AM_RECOVERY} 를 제거하세요. 새 병합을 거부합니다 (fail-closed)."
    exit 1
  fi

  # 자식(merge/post-check)을 자체 프로세스 그룹으로 실행 — 신호 회수 가능 + 그룹
  # 잔존 자손 검출.
  # 리뷰 12차 P1: leader가 rc=0으로 끝나도 백그라운드 자손이 그룹에 남아 있으면
  # 신뢰 불가(rc=97) — 이후 자손이 파일을 바꾸는 시나리오 차단.
  _run_in_group() {
    local rc=0 _i
    set -m
    "$@" &
    AM_CHECK_PID=$!
    set +m
    wait "$AM_CHECK_PID" || rc=$?
    if kill -0 -- "-${AM_CHECK_PID}" 2>/dev/null; then
      echo "[WARN] 자식 그룹에 잔존 프로세스 감지 — 회수 후 실패 처리"
      kill -TERM -- "-${AM_CHECK_PID}" 2>/dev/null || true
      _i=0
      while kill -0 -- "-${AM_CHECK_PID}" 2>/dev/null && [ "$_i" -lt 10 ]; do sleep 0.5; _i=$((_i+1)); done
      kill -KILL -- "-${AM_CHECK_PID}" 2>/dev/null || true
      AM_CHECK_PID=""
      return 97
    fi
    AM_CHECK_PID=""
    return "$rc"
  }
  _run_post_checks() {
    _run_in_group bash -c '"$1" >/dev/null 2>&1' _ "$RUN_CHECKS_CMD"
  }

  # 리뷰 7차 P1: 병합 직전 base 재검증 — 검사(조건 3·4) 중 현재 브랜치 HEAD가
  # 움직였거나(dirty 포함) 브랜치가 바뀌었으면 병합을 거부한다 (base 측 TOCTOU).
  # 리뷰 8차 P1: git status 실패도 fail-closed (빈 출력으로 오인 금지).
  PRE_MERGE_HEAD="$(git rev-parse HEAD)" || exit 1
  if ! _wt_status2="$(_wt_status_or_fail)"; then
    echo "[FAIL] git status failed before merge — refusing"
    AM_PHASE="done"; _am_log "$PRE_MERGE_HEAD" "REFUSED:status-failed"
    exit 1
  fi
  if [ "$PRE_MERGE_HEAD" != "$BASE_OID" ] \
     || [ "$(git rev-parse --abbrev-ref HEAD 2>/dev/null)" != "$BASE_BRANCH" ] \
     || [ -n "$_wt_status2" ]; then
    echo "[FAIL] base '${BASE_BRANCH}' moved or dirtied since checks (HEAD=${PRE_MERGE_HEAD} expected=${BASE_OID}) — merge refused (TOCTOU)"
    AM_PHASE="done"; _am_log "$PRE_MERGE_HEAD" "REFUSED:toctou"
    exit 1
  fi
  # 리뷰 12차 P1: merge 자체도 신호 handler 관리 하에 실행 — merge 중 TERM 시
  # 자식이 회수되고 잔여 merge 상태는 abort된다 (감사 없는 2-parent 잔존 방지).
  AM_PHASE="merging"
  if ! _run_in_group git merge --no-ff "$BRANCH_OID" -m "auto-merge: ${TICKET_ID} (ELIGIBLE)"; then
    AM_PHASE="merge-failed"
    # 리뷰 9차 P1: 복구 실패를 성공(ROLLED_BACK)으로 위장하지 않는다.
    # 리뷰 11차 P1: 비-CAS reset fallback 제거 — abort 실패면 워크트리 상태를
    # 추정으로 덮지 않고 RECOVERY_REQUIRED로 중단한다.
    if git merge --abort >/dev/null 2>&1; then
      # 리뷰 12차 P1: abort 후 산출물이 남았으면 ROLLED_BACK으로 위장하지 않는다.
      _ab_left="$(_wt_status_or_fail 2>/dev/null || echo '__STATUS_FAILED__')"
      if [ -z "$_ab_left" ]; then
        AM_PHASE="done"; _am_log "$BASE_OID" "ROLLED_BACK"
        echo "[FAIL] git merge failed — aborted cleanly"
      else
        AM_PHASE="done"; _am_log "$BASE_OID" "ROLLED_BACK_DIRTY"
        echo "[FAIL] git merge failed — aborted, 그러나 산출물이 남음 (수동 정리 필요):"
        printf '%s\n' "$_ab_left"
      fi
    else
      AM_PHASE="done"; _am_mark_recovery; _am_log "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "RECOVERY_REQUIRED"
      echo "[FAIL] git merge failed AND abort failed — RECOVERY_REQUIRED (수동 확인 필요)"
    fi
    exit 1
  fi
  AM_PHASE="merged"
  MERGE_COMMIT="$(git rev-parse HEAD)"

  # 리뷰 8차 P1 + 9차 P1: merge 결과 소유권 검증(CAS) — HEAD 커밋의 부모가 정확히
  # (BASE_OID, BRANCH_OID)일 때만 "우리가 만든 병합"이다. 아니면 다른 프로세스의
  # 커밋일 수 있으므로 reset하지 않고 RECOVERY_REQUIRED로 중단한다 (남의 커밋 삭제 금지).
  _p1="$(git rev-parse "${MERGE_COMMIT}^1" 2>/dev/null || true)"
  _p2="$(git rev-parse "${MERGE_COMMIT}^2" 2>/dev/null || true)"
  if [ "$_p1" != "$BASE_OID" ] || [ "$_p2" != "$BRANCH_OID" ]; then
    AM_PHASE="done"; _am_mark_recovery; _am_log "$MERGE_COMMIT" "RECOVERY_REQUIRED"
    echo "[FAIL] HEAD(${MERGE_COMMIT}) is not our merge of (${BASE_OID}, ${BRANCH_OID}) — ownership lost, NOT resetting. RECOVERY_REQUIRED."
    exit 1
  fi

  if _run_post_checks; then
    # 리뷰 9차 P1: 성공 확정 전 최종 상태 재검증 — post-check가 HEAD를 움직였거나
    # 브랜치를 바꿨거나 산출물(untracked 포함)을 남겼으면 EXECUTED가 아니다.
    _final_head="$(git rev-parse HEAD 2>/dev/null || echo unknown)"
    _final_branch="$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
    # 리뷰 10차 P1: 사용자 설정(status.showUntrackedFiles=no)과 독립적인 clean 판정.
    if ! _final_status="$(_wt_status_or_fail)"; then _final_status="__STATUS_FAILED__"; fi
    if [ "$_final_head" != "$MERGE_COMMIT" ] || [ "$_final_branch" != "$BASE_BRANCH" ] || [ -n "$_final_status" ]; then
      AM_PHASE="done"; _am_mark_recovery; _am_log "$_final_head" "RECOVERY_REQUIRED"
      echo "[FAIL] post-check 후 최종 상태 불일치 (HEAD=${_final_head} expected=${MERGE_COMMIT}, branch=${_final_branch}, dirty=$([ -n "$_final_status" ] && echo yes || echo no)) — RECOVERY_REQUIRED, 자동 복구하지 않음"
      exit 1
    fi
    _am_log "$MERGE_COMMIT" "EXECUTED"
    # 리뷰 11차 P1: 감사 기록이 실패했으면 성공으로 끝내지 않는다 — 병합은 남아
    # 있으므로 수동 확인을 요구한다 (감사 없는 EXECUTED 금지).
    if [ "$AM_AUDIT_FAILED" -ne 0 ]; then
      AM_PHASE="done"
      _am_mark_recovery
      echo "[FAIL] merge는 완료됐으나 감사 로그 기록 실패 — RECOVERY_REQUIRED(감사 경로 복구 후 수동 기록 필요): ${MERGE_COMMIT}"
      exit 1
    fi
    AM_PHASE="done"
    echo "[PASS] auto-merge executed: ${MERGE_COMMIT}"
    exit 0
  else
    # 리뷰 8차 P1: 가변 ORIG_HEAD가 아니라 고정 BASE_OID로 복구.
    # 리뷰 9차/10차 P1: 복구는 "정확한 base ref"에 대한 CAS(update-ref <ref> <new> <old>)로
    # 수행한다 — HEAD/현재 브랜치가 post-check에 의해 바뀌었어도 base ref가 여전히
    # 우리의 MERGE_COMMIT일 때만 원자적으로 BASE_OID로 되돌리고, 아니면(다른 프로세스
    # 커밋) 건드리지 않고 RECOVERY_REQUIRED. HEAD-확인-후-reset 경합도 CAS가 제거한다.
    # 리뷰 12차 P1 + 13차 P1: CAS 후 워크트리 동기화는 "각 dirty 항목의 내용이
    # 정확히 merge 잔상(MERGE_COMMIT blob과 일치)"일 때만 수행 — 스냅샷과 reset
    # 사이에 끼어든 동시 변경은 항목 단위 blob 대조가 잡아내 보존한다(REF_ONLY).
    if git update-ref -m "auto-merge rollback ${TICKET_ID}" \
         "refs/heads/${BASE_BRANCH}" "$BASE_OID" "$MERGE_COMMIT" 2>/dev/null; then
      _ref_only=1
      if _sync_worktree_after_cas; then
        _ref_only=0
      else
        echo "[WARN] merge 잔상 외 변경/산출물 또는 검증 실패 — reset 생략, worktree 보존 (수동으로 git reset --hard ${BASE_OID} 검토)"
      fi
      AM_PHASE="done"
      if [ "$_ref_only" -eq 0 ]; then
        _am_log "$MERGE_COMMIT" "ROLLED_BACK"
      else
        _am_log "$MERGE_COMMIT" "ROLLED_BACK_REF_ONLY"
      fi
      echo "[FAIL] post-merge run_checks 실패 — rollback (ref CAS$([ "$_ref_only" -eq 1 ] && echo ', worktree 미동기화'))"
      _leftover="$(_wt_status_or_fail 2>/dev/null || true)"
      if [ -n "$_leftover" ]; then
        echo "[WARN] rollback 후 미추적/변경 산출물이 남아 있습니다 (수동 정리 필요):"
        printf '%s\n' "$_leftover"
      fi
    else
      AM_PHASE="done"; _am_mark_recovery; _am_log "$(git rev-parse HEAD 2>/dev/null || echo unknown)" "RECOVERY_REQUIRED"
      echo "[FAIL] post-merge run_checks 실패 + base ref CAS 실패(다른 프로세스의 커밋?) — RECOVERY_REQUIRED (자동 복구 안 함)"
    fi
    exit 1
  fi
else
  echo "VERDICT: NOT ELIGIBLE"
  exit 1
fi
