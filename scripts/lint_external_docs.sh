#!/usr/bin/env bash
# scripts/lint_external_docs.sh — 외부 공개 산출물 lint (ADR-0014 §4 사례 2·3)
#
# 목적: 외부 산출물(.md/.html)에서 ADR-0014 §4 위반 패턴을 자동 검출한다.
#
#   Rule A (사례 2): git 명령 컨텍스트의 base 브랜치 하드코딩 감지
#     패턴: git merge main / git checkout main / git rebase main /
#           origin/main / ..main / main..
#     면제: BASE_BRANCH 변수 자체를 branch 인자로 쓰는 경우는 위 패턴에 걸리지 않음
#
#   Rule B (사례 3): BASE_BRANCH=$(...) 직접 대입 감지
#     패턴: BASE_BRANCH=...$(
#     면제: ${BASE_BRANCH:-$(...)} override 보존 형태 (:-를 포함하는 경우)
#
# 적용 범위 (ADR-0021 §4 close):
#   Rule A/B는 ```bash / ```sh / ```shell 코드펜스 블록 안에서만 적용한다.
#   fence 밖(산문·인라인 코드·표·비-shell 펜스)은 Rule A/B를 적용하지 않는다.
#   fence state는 파일별 독립으로 리셋한다.
#
# 한계 (의도적 제외):
#   ADR-0014 사례 2의 하위 요소 중 "placeholder 실행 불가"(#16: T999/T1000 등)는
#   grep으로 신뢰성 있게 검출할 수 없어 이 스크립트의 게이트 exit code에 반영하지 않는다.
#   → #21 후보: "사례 2 YES 주장의 placeholder 하위 요소는 grep 불가. main 하드코딩
#     하위 요소만 §4 YES 근거로 코드화됨"
#
# 사용법:
#   ./scripts/lint_external_docs.sh               # 기본: docs/onboarding docs/decisions
#   LINT_EXTERNAL_TARGET=docs/other ./scripts/lint_external_docs.sh
#   LINT_EXTERNAL_TARGET="path1 path2" ./scripts/lint_external_docs.sh
#
# exit 0: 위반 없음 (게이트 통과)
# exit 1: 위반 발견 (stderr에 <file>:<line>: <Rule> <msg> 형식 진단 출력)

set -euo pipefail

LINT_EXTERNAL_TARGET="${LINT_EXTERNAL_TARGET:-docs/onboarding docs/decisions}"
VIOLATIONS=0

# check_rule_a <file>
# Rule A: shell code fence 안에서 git 명령 컨텍스트의 base 브랜치 'main' 하드코딩 감지.
# fence 밖(산문·표·비-shell 펜스)은 적용하지 않는다.
check_rule_a() {
  local file="$1"
  local line_num=0
  local line matched
  local fence_active=0 shell_fence=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if [ "$fence_active" -eq 1 ]; then
      # 닫는 fence
      if printf '%s' "$line" | grep -qE '^```[[:space:]]*$'; then
        fence_active=0
        shell_fence=0
        continue
      fi
      # 비-shell fence 내부 → skip
      if [ "$shell_fence" -eq 0 ]; then
        continue
      fi
    else
      # shell fence 열기
      if printf '%s' "$line" | grep -qE '^```(bash|sh|shell)([[:space:]].*)?$'; then
        fence_active=1
        shell_fence=1
        continue
      fi
      # 기타 fence 열기
      if printf '%s' "$line" | grep -qE '^```[^[:space:]]'; then
        fence_active=1
        shell_fence=0
        continue
      fi
      # fence 밖 → Rule A 미적용
      continue
    fi

    # shell fence 안에서만 도달
    matched=0
    if printf '%s' "$line" | grep -qE 'git[[:space:]]+(merge|checkout|rebase)([[:space:]]+-[-[:alnum:]]+(=[^[:space:]]+)?)*[[:space:]]+main([^[:alnum:]_/-]|$)'; then
      matched=1
    elif printf '%s' "$line" | grep -qE 'origin/main([^[:alnum:]_/-]|$)'; then
      matched=1
    elif printf '%s' "$line" | grep -qE '\.\.main([^[:alnum:]_/-]|$)'; then
      matched=1
    elif printf '%s' "$line" | grep -qE '(^|[^[:alnum:]_/-])main\.\.'; then
      matched=1
    fi
    if [ "$matched" -eq 1 ]; then
      echo "${file}:${line_num}: Rule-A hardcoded base branch 'main' in git command context (use \$BASE_BRANCH instead)" >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done < "$file"
}

# check_rule_b <file>
# Rule B: shell code fence 안에서 BASE_BRANCH=$(...) 직접 대입 감지.
# 면제: ${BASE_BRANCH:-$(...)} override 보존 형태 (같은 라인에 ':-' 포함).
# fence 밖(산문·표·비-shell 펜스)은 적용하지 않는다.
check_rule_b() {
  local file="$1"
  local line_num=0
  local line
  local fence_active=0 shell_fence=0
  while IFS= read -r line; do
    line_num=$((line_num + 1))

    if [ "$fence_active" -eq 1 ]; then
      # 닫는 fence
      if printf '%s' "$line" | grep -qE '^```[[:space:]]*$'; then
        fence_active=0
        shell_fence=0
        continue
      fi
      # 비-shell fence 내부 → skip
      if [ "$shell_fence" -eq 0 ]; then
        continue
      fi
    else
      # shell fence 열기
      if printf '%s' "$line" | grep -qE '^```(bash|sh|shell)([[:space:]].*)?$'; then
        fence_active=1
        shell_fence=1
        continue
      fi
      # 기타 fence 열기
      if printf '%s' "$line" | grep -qE '^```[^[:space:]]'; then
        fence_active=1
        shell_fence=0
        continue
      fi
      # fence 밖 → Rule B 미적용
      continue
    fi

    # shell fence 안에서만 도달
    # 면제: override 보존 패턴 (:-를 포함하는 라인)
    if printf '%s' "$line" | grep -qE 'BASE_BRANCH[^=]*:-'; then
      continue
    fi
    # Rule B: BASE_BRANCH=...$(  직접 대입 (따옴표 포함 형태도 감지)
    if printf '%s' "$line" | grep -qE 'BASE_BRANCH=["'"'"']?\$\('; then
      echo "${file}:${line_num}: Rule-B direct assignment of BASE_BRANCH overrides operator-set value; use \${BASE_BRANCH:-\$(...)} instead" >&2
      VIOLATIONS=$((VIOLATIONS + 1))
    fi
  done < "$file"
}

# 대상 파일 수집 (.md, .html) — find 결과를 임시 파일에 저장해 while subshell 회피
TMPFILE="$(mktemp)"
for _target in $LINT_EXTERNAL_TARGET; do
  find "$_target" -type f \( -name "*.md" -o -name "*.html" \) 2>/dev/null || true
done | sort -u > "$TMPFILE"

while IFS= read -r f; do
  [ -z "$f" ] && continue
  check_rule_a "$f"
  check_rule_b "$f"
done < "$TMPFILE"

rm -f "$TMPFILE"

if [ "$VIOLATIONS" -gt 0 ]; then
  exit 1
fi
exit 0
