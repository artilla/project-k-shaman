#!/usr/bin/env bash
# ralph/scripts/lib/base_branch.sh — BASE_BRANCH 자동 검출 라이브러리
#
# Usage (source):
#   source "$ROOT/ralph/scripts/lib/base_branch.sh"
#   BASE_BRANCH="${BASE_BRANCH:-$(detect_base_branch)}"
#
# Usage (direct):
#   BASE_BRANCH=$(./ralph/scripts/lib/base_branch.sh)
#
# Detection priority (first match wins):
#   1. git symbolic-ref refs/remotes/origin/HEAD  (stale 가능 — git remote set-head origin -a 로 갱신 권장)
#   2. git config init.defaultBranch
#   3. refs/heads/main
#   4. refs/heads/master
#   5. refs/heads/trunk
#   6. exit 1 + stderr diagnostic

detect_base_branch() {
  local branch

  # 1. origin/HEAD symbolic ref
  if branch=$(git symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null); then
    branch=$(echo "$branch" | sed 's|^origin/||')
    if [ -n "$branch" ]; then
      echo "$branch"
      return 0
    fi
  fi

  # 2. init.defaultBranch config
  if branch=$(git config --get init.defaultBranch 2>/dev/null); then
    if [ -n "$branch" ]; then
      echo "$branch"
      return 0
    fi
  fi

  # 3. refs/heads/main
  if git show-ref --verify --quiet refs/heads/main 2>/dev/null; then
    echo "main"
    return 0
  fi

  # 4. refs/heads/master
  if git show-ref --verify --quiet refs/heads/master 2>/dev/null; then
    echo "master"
    return 0
  fi

  # 5. refs/heads/trunk
  if git show-ref --verify --quiet refs/heads/trunk 2>/dev/null; then
    echo "trunk"
    return 0
  fi

  # 6. All detection methods failed
  echo "ERROR: BASE_BRANCH를 자동 검출할 수 없습니다. 'export BASE_BRANCH=main' 으로 직접 설정하거나 'git remote set-head origin -a' 를 실행하세요." >&2
  return 1
}

# Direct execution support: BASE_BRANCH=$(./ralph/scripts/lib/base_branch.sh)
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  detect_base_branch
fi
