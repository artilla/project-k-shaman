#!/usr/bin/env bash
# init_new_project.sh — Project Hephaestus 운영 하네스를 새 프로젝트로 "클린 추출"한다.
#
# 두 가지 사용 방식:
#   1) 대화형 위저드 (권장): 인수 없이 실행 → 질문에 답하면 끝.
#        ./scripts/init_new_project.sh
#      스택을 고르면 검증을 자동 설정하고, 원하면 에디터로 master-spec을 작성한다.
#      gum(charmbracelet)이 있으면 예쁘게, 없으면 순수 bash 프롬프트로 동작한다(하드 의존성 0).
#   2) 플래그(비대화/스크립트용): 대상 경로를 주면 질문 없이 바로 추출.
#        ./scripts/init_new_project.sh <target-dir> [옵션]
#
# 철학: 이식 가능한 하네스(scripts·skills·TEMPLATE·runbook·.gitignore)만 복사하고,
#       Hephaestus 고유 누적물(ADR·DONE 티켓·PDF·보고서·기존 master-spec·product 테스트)은
#       가져오지 않는다. tests/ 는 빈 스켈레톤 + 통과하는 starter smoke 테스트만 둔다.
# 가역성: SOURCE(현재 Hephaestus 루트)는 절대 수정하지 않는다. 모든 쓰기는 TARGET 안에서만.
#         잘못되면 `rm -rf TARGET` 한 줄로 원복.
#
# 옵션 (플래그 모드):
#   --wizard            TTY가 아니어도 위저드를 강제 실행 (파이프로 답 주입 가능)
#   --name <CODENAME>   master-spec/README 코드명 (기본: 대상 폴더 이름)
#   --stack <s>         node | python | go | rust | none → scripts/run_checks.local.sh 자동 생성
#   --with-glossary     docs/glossary.md 도 복사
#   --with-onboarding   docs/onboarding/quickstart.md|.html 도 복사 (v 스냅샷 제외)
#   --no-git            대상에서 git init + 초기 커밋 생략
#   --force             대상이 비어있지 않아도 진행
#   --dry-run           실제 복사 없이 매니페스트만 출력 (위저드와도 결합 가능)
#   -h, --help          도움말
#
# 종료 코드: 0 성공 / 1 사용법·전제조건 위반

set -euo pipefail

# ─────────────────────────────────────────────────────────
# 0. SOURCE 결정 (이 스크립트 위치 기준 = Hephaestus 루트). 읽기 전용.
# ─────────────────────────────────────────────────────────
SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TODAY="$(date +%Y-%m-%d)"

usage() {
  cat <<'EOF'
init_new_project.sh — Hephaestus 하네스를 새 프로젝트로 클린 추출

대화형 위저드 (권장):
  ./scripts/init_new_project.sh

플래그 모드 (비대화):
  ./scripts/init_new_project.sh <target-dir> [옵션]

옵션:
  --wizard            TTY가 아니어도 위저드 강제 실행
  --name <CODENAME>   코드명 (기본: 대상 폴더 이름)
  --stack <s>         node|python|go|rust|none → run_checks.local.sh 생성
  --with-glossary     glossary.md 복사
  --with-onboarding   quickstart.md|.html 복사
  --no-git            git init 생략
  --force             비어있지 않은 대상 허용
  --dry-run           매니페스트만 출력
  -h, --help          이 도움말
EOF
}

# ─────────────────────────────────────────────────────────
# 0.5 스캔 모드 (ADR-0198 L6): --diff-manifest <target>
#   브라운필드 채택 전 would-overwrite 대조. 읽기 전용 — 어떤 파일도 만들지/바꾸지 않는다.
#   출력(기계 파싱 가능): GIT none|clean|dirty / OVERWRITE <p> [(N files)] / NEW <p> / PRESERVE <note>
# ─────────────────────────────────────────────────────────
if [ "${1:-}" = "--diff-manifest" ]; then
  DM_TARGET="${2:-}"
  if [ -z "$DM_TARGET" ]; then echo "오류: --diff-manifest <target>" >&2; exit 1; fi
  if [ ! -d "$DM_TARGET" ]; then echo "TARGET_MISSING $DM_TARGET"; exit 0; fi
  DM_ABS="$(cd "$DM_TARGET" && pwd)"
  case "$DM_ABS/" in "$SRC"/*) echo "오류: 대상이 SOURCE 안입니다" >&2; exit 1 ;; esac
  # git 상태 — dirty면 채택 차단 근거(커밋이 유일한 복구 수단, final 기획 §3D)
  if [ -d "$DM_ABS/.git" ] && command -v git >/dev/null 2>&1; then
    if [ -n "$(git -C "$DM_ABS" status --porcelain 2>/dev/null)" ]; then echo "GIT dirty"; else echo "GIT clean"; fi
  else
    echo "GIT none"
  fi
  # 복사 대상(HARNESS_PATHS와 동일 목록 — 아래 §5 배열과 동기 유지할 것)
  for p in scripts skills mission-control docs/tickets/TEMPLATE.md docs/runbook.md docs/approvals/README.md .gitignore; do
    if [ -e "$DM_ABS/$p" ]; then
      if [ -d "$SRC/$p" ] && [ -d "$DM_ABS/$p" ]; then
        n=0
        while IFS= read -r f; do rel="${f#"$SRC/$p/"}"; [ -e "$DM_ABS/$p/$rel" ] && n=$((n+1)); done \
          < <(find "$SRC/$p" -type f 2>/dev/null)
        if [ "$n" -gt 0 ]; then echo "OVERWRITE $p ($n files)"; else echo "NEW $p (병합 — 충돌 파일 없음)"; fi
      else
        echo "OVERWRITE $p"
      fi
    else
      echo "NEW $p"
    fi
  done
  # 생성 파일(스크립트가 직접 쓰는 것 — would-overwrite 전체 범위)
  for g in tests/smoke.bats scripts/run_checks.local.sh docs/master-spec.md README.md; do
    if [ -e "$DM_ABS/$g" ]; then echo "OVERWRITE $g (생성 파일)"; else echo "NEW $g (생성)"; fi
  done
  echo "PRESERVE 기존 소스 코드(위 경로 외) — 변경 없음"
  exit 0
fi

# ─────────────────────────────────────────────────────────
# 0.6 스냅샷 커밋 (ADR-0199 L6.5): --snapshot-commit <target>
#   dirty 대상 레포에 고정 메시지 wip 커밋 1개 생성(add -A · push 없음 · 가역: reset --soft HEAD~1).
#   MC가 대상 레포에 쓰는 유일한 경로 — 인자 고정, 임의 명령 없음.
# ─────────────────────────────────────────────────────────
if [ "${1:-}" = "--snapshot-commit" ]; then
  SC_TARGET="${2:-}"
  if [ -z "$SC_TARGET" ]; then echo "오류: --snapshot-commit <target>" >&2; exit 1; fi
  if [ ! -d "$SC_TARGET" ]; then echo "TARGET_MISSING $SC_TARGET"; exit 1; fi
  SC_ABS="$(cd "$SC_TARGET" && pwd)"
  case "$SC_ABS/" in "$SRC"/*) echo "오류: 대상이 SOURCE 안입니다" >&2; exit 1 ;; esac
  if [ ! -d "$SC_ABS/.git" ]; then echo "NOT_GIT"; exit 1; fi
  if [ -z "$(git -C "$SC_ABS" status --porcelain 2>/dev/null)" ]; then echo "ALREADY_CLEAN"; exit 0; fi
  git -C "$SC_ABS" add -A
  if ! git -C "$SC_ABS" commit -m "wip: before harness adopt (Mission Control snapshot)" >/dev/null 2>&1; then
    echo "COMMIT_FAILED (git author 미설정?)"; exit 1
  fi
  echo "COMMITTED $(git -C "$SC_ABS" rev-parse --short HEAD)"
  echo "복구: git -C $SC_ABS reset --soft HEAD~1"
  exit 0
fi

# ─────────────────────────────────────────────────────────
# 1. 인자 파싱
# ─────────────────────────────────────────────────────────
TARGET=""
CODENAME=""
STACK=""
WITH_GLOSSARY=0
WITH_ONBOARDING=0
DO_GIT=1
FORCE=0
DRY_RUN=0
FORCE_WIZARD=0

while [ $# -gt 0 ]; do
  case "$1" in
    --wizard)          FORCE_WIZARD=1; shift ;;
    --name)            CODENAME="${2:?--name 다음에 코드명을 주세요}"; shift 2 ;;
    --stack)           STACK="${2:?--stack 다음에 node|python|go|rust|none}"; shift 2 ;;
    --with-glossary)   WITH_GLOSSARY=1; shift ;;
    --with-onboarding) WITH_ONBOARDING=1; shift ;;
    --no-git)          DO_GIT=0; shift ;;
    --force)           FORCE=1; shift ;;
    --dry-run)         DRY_RUN=1; shift ;;
    -h|--help)         usage; exit 0 ;;
    -*)                echo "알 수 없는 옵션: $1" >&2; usage >&2; exit 1 ;;
    *)
      if [ -z "$TARGET" ]; then TARGET="$1"; else
        echo "대상 디렉터리는 하나만 지정하세요 (추가 인자: $1)" >&2; exit 1
      fi
      shift ;;
  esac
done

# 위저드 진입 결정: --wizard 강제, 또는 (대상 미지정 + 대화형 TTY)
WIZARD=0
if [ "$FORCE_WIZARD" = "1" ]; then
  WIZARD=1
elif [ -z "$TARGET" ]; then
  if [ -t 0 ]; then
    WIZARD=1
  else
    echo "오류: 대상 디렉터리가 필요합니다 (또는 대화형 터미널에서 실행하면 위저드가 안내합니다)." >&2
    echo "사용: $0 <target-dir> [옵션]   |   $0   (위저드)" >&2
    exit 1
  fi
fi

# ─────────────────────────────────────────────────────────
# 2. UI 프롬프트 헬퍼 (gum 있으면 사용, 없으면 순수 bash)
# ─────────────────────────────────────────────────────────
have_gum() { command -v gum >/dev/null 2>&1; }

ui_say()  { printf '%s\n' "$*"; }
ui_head() {
  if have_gum; then gum style --bold --foreground 39 -- "$*" >&2
  else printf '\n\033[1;34m%s\033[0m\n' "$*" >&2; fi
}

# ask_text <prompt> [default] → stdout=answer
ask_text() {
  local p="$1" d="${2:-}" ans
  if have_gum; then
    ans="$(gum input --prompt "$p " --value "$d" --placeholder "${d:-입력}")" || ans="$d"
  else
    if [ -n "$d" ]; then read -r -p "$p [$d]: " ans || ans=""
    else read -r -p "$p: " ans || ans=""; fi
  fi
  printf '%s' "${ans:-$d}"
}

# ask_choice <prompt> <opt1> <opt2> ... → stdout=selected option
ask_choice() {
  local p="$1"; shift
  if have_gum; then
    printf '%s\n' "$@" | gum choose --header "$p"
  else
    ui_say "$p" >&2
    local i=1 opt
    for opt in "$@"; do printf '  %d) %s\n' "$i" "$opt" >&2; i=$((i+1)); done
    local sel; read -r -p "번호 선택 [1]: " sel || sel=1; sel="${sel:-1}"
    if ! printf '%s' "$sel" | grep -qE '^[0-9]+$' || [ "$sel" -lt 1 ] || [ "$sel" -gt "$#" ]; then sel=1; fi
    printf '%s' "${!sel}"
  fi
}

# ask_yesno <prompt> <default y|n> → exit 0=yes 1=no
ask_yesno() {
  local p="$1" d="${2:-y}" ans
  if have_gum; then
    if [ "$d" = "n" ]; then gum confirm "$p" --default=false; return $?
    else gum confirm "$p"; return $?; fi
  fi
  local hint="[Y/n]"; [ "$d" = "n" ] && hint="[y/N]"
  read -r -p "$p $hint: " ans || ans=""
  ans="${ans:-$d}"
  case "$ans" in [Yy]*) return 0 ;; *) return 1 ;; esac
}

# ─────────────────────────────────────────────────────────
# 3. 위저드 — 변수 수집
# ─────────────────────────────────────────────────────────
AUTHOR=""
EDIT_SPEC=0
AI_SPEC=0
SPEC_EDITOR_OPENED=0
OH1=""; OH2=""; OH3=""; OH4=""; OH5=""; OH6=""

run_wizard() {
  ui_head "Project Hephaestus — 새 프로젝트 위저드"
  ui_say "질문에 답하면 하네스를 추출하고 명세까지 채워 드립니다. (Enter = 기본값)" >&2
  have_gum || ui_say "  팁: 'gum'을 설치하면 더 예쁜 화면으로 진행됩니다 (선택 사항)." >&2

  # 대상 경로
  local target_default="${TARGET:-../my-app}"
  while :; do
    TARGET="$(ask_text "새 프로젝트를 만들 경로" "$target_default")"
    [ -n "$TARGET" ] && break
    ui_say "  경로는 비울 수 없습니다." >&2
  done

  # 코드명
  local codename_default="${CODENAME:-$(basename "$TARGET")}"
  CODENAME="$(ask_text "프로젝트 코드명" "$codename_default")"

  # 작성자 (git config 기본)
  local git_name=""; git_name="$(git config user.name 2>/dev/null || true)"
  AUTHOR="$(ask_text "작성자/책임자" "${git_name:-(이름)}")"

  # 검증 스택
  local pick
  pick="$(ask_choice "이 프로젝트의 검증 스택은?" \
      "Node.js (npm lint/test)" \
      "Python (ruff/pytest)" \
      "Go (go vet/test)" \
      "Rust (cargo check/test)" \
      "기타/지금 없음")"
  case "$pick" in
    Node*)   STACK="node" ;;
    Python*) STACK="python" ;;
    Go*)     STACK="go" ;;
    Rust*)   STACK="rust" ;;
    *)       STACK="none" ;;
  esac

  # 추가 reference 문서
  ask_yesno "온보딩 체험 문서(quickstart)도 복사할까요?" n && WITH_ONBOARDING=1 || WITH_ONBOARDING=0
  ask_yesno "프레임워크 용어집(glossary)도 복사할까요?" n && WITH_GLOSSARY=1 || WITH_GLOSSARY=0

  # git
  ask_yesno "git 초기화 + 초기 커밋을 할까요?" y && DO_GIT=1 || DO_GIT=0

  # Office Hours: (선택) AI 초안 → 에디터 검토. 산문을 한 줄 프롬프트로 받지는 않는다.
  if command -v claude >/dev/null 2>&1 && ask_yesno "AI로 명세(Office Hours) 초안을 만들까요? (claude 사용, 검토 후 확정)" n; then
    AI_SPEC=1; EDIT_SPEC=1     # AI 초안은 반드시 사람이 에디터에서 검토·확정
  elif ask_yesno "지금 에디터로 명세(Office Hours 6질문)를 열까요? (나중에 가능)" n; then
    EDIT_SPEC=1
  fi

  # 요약 + 확인
  ui_head "요약"
  cat >&2 <<EOF
  대상      : $TARGET
  코드명    : $CODENAME
  작성자    : $AUTHOR
  검증 스택 : $STACK
  온보딩    : $([ "$WITH_ONBOARDING" = 1 ] && echo 포함 || echo 미포함)   용어집: $([ "$WITH_GLOSSARY" = 1 ] && echo 포함 || echo 미포함)
  git init  : $([ "$DO_GIT" = 1 ] && echo 예 || echo 아니오)
  명세 작성 : $([ "$AI_SPEC" = 1 ] && echo "AI 초안 + 에디터 검토" || { [ "$EDIT_SPEC" = 1 ] && echo "에디터로 열기" || echo 나중에; })
  dry-run   : $([ "$DRY_RUN" = 1 ] && echo 예 || echo 아니오)
EOF
  if ! ask_yesno "이대로 진행할까요?" y; then
    ui_say "취소했습니다." >&2; exit 0
  fi
}

[ "$WIZARD" = "1" ] && run_wizard

# ─────────────────────────────────────────────────────────
# 4. 대상 경로 정규화 + 전제조건
# ─────────────────────────────────────────────────────────
if [ -z "$TARGET" ]; then
  echo "오류: 대상 디렉터리가 필요합니다." >&2; usage >&2; exit 1
fi
target_parent="$(dirname "$TARGET")"
target_base="$(basename "$TARGET")"
[ "$DRY_RUN" -eq 0 ] && mkdir -p "$target_parent"
if target_parent_abs="$(cd "$target_parent" 2>/dev/null && pwd)"; then
  :
elif [ "$DRY_RUN" -eq 1 ]; then
  case "$target_parent" in
    /*) target_parent_abs="$target_parent" ;;
    *)  target_parent_abs="$(pwd)/$target_parent" ;;
  esac
else
  echo "오류: 대상 경로의 부모 디렉터리에 접근할 수 없습니다: $TARGET" >&2
  exit 1
fi
TARGET="$target_parent_abs/$target_base"
[ -z "$CODENAME" ] && CODENAME="$(basename "$TARGET")"
[ -z "$STACK" ] && STACK="none"

if [ "$TARGET" = "$SRC" ]; then
  echo "오류: 대상이 소스(Hephaestus 루트)와 동일합니다." >&2; exit 1
fi
case "$TARGET/" in
  "$SRC"/*) echo "오류: 대상이 소스 내부($SRC)에 있습니다." >&2; exit 1 ;;
esac
if [ -e "$TARGET" ] && [ -n "$(ls -A "$TARGET" 2>/dev/null || true)" ] && [ "$FORCE" -eq 0 ]; then
  echo "오류: 대상 '$TARGET' 이 비어있지 않습니다. --force 로 강제할 수 있습니다." >&2; exit 1
fi

# ─────────────────────────────────────────────────────────
# 5. 복사 매니페스트
# ─────────────────────────────────────────────────────────
say()  { printf '%s\n' "$*"; }
step() { printf '  • %s\n' "$*"; }

# 클린 추출: scripts·skills 등 이식 가능한 하네스만. tests/ 는 통째로 복사하지 않는다 —
# Hephaestus product 테스트(mission-control 등 누적물)는 새 레포에서 통과하지 못하므로
# 빈 스켈레톤 + 통과하는 starter smoke 테스트(아래 [2/6])만 둔다.
HARNESS_PATHS=(
  "scripts" "skills" "mission-control"
  "docs/tickets/TEMPLATE.md" "docs/runbook.md" "docs/approvals/README.md" ".gitignore"
)
SKELETON_DIRS=(
  "docs/tickets/DONE" "docs/tickets/ARCHIVE" "docs/decisions" "docs/reviews"
  "tests" "state" "state/reservations" ".ralph/logs"
)
GITKEEP_DIRS=( "docs/tickets/DONE" "docs/tickets/ARCHIVE" "docs/decisions" "docs/reviews" )

say ""
say "Project Hephaestus — 새 프로젝트 클린 추출"
say "  SOURCE : $SRC   (읽기 전용)"
say "  TARGET : $TARGET"
say "  코드명 : $CODENAME   스택: $STACK"
say "  옵션   : dry-run=$DRY_RUN force=$FORCE git=$DO_GIT glossary=$WITH_GLOSSARY onboarding=$WITH_ONBOARDING"
say ""

copy_path() {
  local rel="$1" srcp="$SRC/$1" dstp="$TARGET/$1"
  if [ ! -e "$srcp" ]; then step "건너뜀(소스 없음): $rel"; return 0; fi
  step "복사: $rel"
  [ "$DRY_RUN" -eq 1 ] && return 0
  if [ -d "$srcp" ]; then
    mkdir -p "$dstp"
    cp -R "$srcp"/. "$dstp"/
  else
    mkdir -p "$(dirname "$dstp")"
    cp "$srcp" "$dstp"
  fi
}

# 토큰 치환(안전): 사용자 입력 텍스트를 셸이 평가하지 않도록 bash 리터럴 치환만 사용
render_tokens() { # stdin template → stdout, @@TOKEN@@ 치환
  local line
  while IFS= read -r line || [ -n "$line" ]; do
    line="${line//@@CODENAME@@/$CODENAME}"
    line="${line//@@DATE@@/$TODAY}"
    line="${line//@@AUTHOR@@/$AUTHOR}"
    line="${line//@@OH1@@/$OH1}"; line="${line//@@OH2@@/$OH2}"; line="${line//@@OH3@@/$OH3}"
    line="${line//@@OH4@@/$OH4}"; line="${line//@@OH5@@/$OH5}"; line="${line//@@OH6@@/$OH6}"
    printf '%s\n' "$line"
  done
}

# ─────────────────────────────────────────────────────────
# 6. 하네스 복사
# ─────────────────────────────────────────────────────────
say "[1/6] 하네스 복사"
for p in "${HARNESS_PATHS[@]}"; do copy_path "$p"; done
[ "$WITH_GLOSSARY" -eq 1 ] && copy_path "docs/glossary.md"
if [ "$WITH_ONBOARDING" -eq 1 ]; then
  copy_path "docs/onboarding/quickstart.md"; copy_path "docs/onboarding/quickstart.html"
fi
if [ "$DRY_RUN" -eq 0 ]; then
  chmod +x "$TARGET"/scripts/*.sh 2>/dev/null || true
  [ -d "$TARGET/scripts/lib" ] && chmod +x "$TARGET"/scripts/lib/*.sh 2>/dev/null || true
  # T303: mission-control은 서버 본체만 이식 — Hephaestus 유닛 테스트는 새 레포 소관이 아님
  rm -f "$TARGET/mission-control/"*.test.mjs 2>/dev/null || true
fi

# ─────────────────────────────────────────────────────────
# 7. 빈 스켈레톤 + .gitkeep
# ─────────────────────────────────────────────────────────
say ""
say "[2/6] 빈 스켈레톤 디렉터리"
for d in "${SKELETON_DIRS[@]}"; do step "mkdir: $d/"; [ "$DRY_RUN" -eq 0 ] && mkdir -p "$TARGET/$d"; done
step "tests/smoke.bats (starter 예시 — Hephaestus product 테스트는 비복사)"
if [ "$DRY_RUN" -eq 0 ]; then
  for d in "${GITKEEP_DIRS[@]}"; do : > "$TARGET/$d/.gitkeep"; done
  cat > "$TARGET/state/.gitkeep" <<'EOF'
# Ralph Loop 런타임 상태 디렉터리. 실제 상태 파일은 .gitignore로 추적되지 않습니다.
EOF
  # 클린 추출: product 테스트는 가져오지 않고, 새 레포에서 통과하는 starter smoke만 둔다.
  cat > "$TARGET/tests/smoke.bats" <<'EOF'
#!/usr/bin/env bats
# smoke.bats — 추출된 하네스 기본 위생(starter). 자유롭게 교체·확장하세요.
ROOT="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"

@test "run_checks.sh is executable" {
  [ -x "$ROOT/scripts/run_checks.sh" ]
}

@test "master-spec exists" {
  [ -f "$ROOT/docs/master-spec.md" ]
}

@test "ticket TEMPLATE exists" {
  [ -f "$ROOT/docs/tickets/TEMPLATE.md" ]
}
EOF
fi

# ─────────────────────────────────────────────────────────
# 8. 검증 스택 → scripts/run_checks.local.sh
# ─────────────────────────────────────────────────────────
say ""
say "[3/6] 검증 스택 설정 (scripts/run_checks.local.sh)"
write_local_checks() {
  local body
  case "$STACK" in
    node)   body='if [ -f package.json ] && command -v npm >/dev/null 2>&1; then
  npm run lint --if-present
  npm test --if-present
else
  echo "node 도구/package.json 없음 — skip"
fi' ;;
    python) body='has_python_project() {
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
fi' ;;
    go)     body='if [ -f go.mod ] && command -v go >/dev/null 2>&1; then
  go vet ./...
  go test ./...
else
  echo "go 도구/go.mod 없음 — skip"
fi' ;;
    rust)   body='if [ -f Cargo.toml ] && command -v cargo >/dev/null 2>&1; then
  cargo check --quiet
  cargo test --quiet
else
  echo "cargo 도구/Cargo.toml 없음 — skip"
fi' ;;
    *)      body='# 이 프로젝트의 lint/test/build 명령을 여기에 넣으세요.
# 도구가 없을 때 0 exit 하도록 command -v 가드를 권장합니다.
echo "(아직 프로젝트별 검증 미설정 — run_checks.local.sh를 편집하세요)"' ;;
  esac
  step "stack=$STACK → run_checks.local.sh"
  [ "$DRY_RUN" -eq 1 ] && return 0
  cat > "$TARGET/scripts/run_checks.local.sh" <<EOF
#!/usr/bin/env bash
# run_checks.local.sh — 이 프로젝트의 검증 명령 (init_new_project.sh 위저드 생성: stack=$STACK).
# run_checks.sh가 존재 시 자동 실행한다. 비-0 exit면 전체 검증 실패.
# 자유롭게 수정하세요. 도구가 없으면 건너뛰도록 가드되어 있습니다.
set -euo pipefail
$body
EOF
  chmod +x "$TARGET/scripts/run_checks.local.sh" 2>/dev/null || true
}
write_local_checks

# AI 초안(선택): claude -p에 planner 프롬프트를 보내 Office Hours OH1~OH6를 채운다.
# 사람이 에디터에서 검토하는 '초안'. 미설치·실패·비대화·dry-run이면 빈 스캐폴드로 폴백.
ai_draft_spec() {
  [ "$AI_SPEC" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then step "AI 초안 (dry-run이라 미실행)"; return 0; fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then step "AI 초안 건너뜀 (비대화 실행)"; AI_SPEC=0; return 0; fi
  if ! command -v claude >/dev/null 2>&1; then step "AI 초안 건너뜀 (claude 미설치)"; AI_SPEC=0; return 0; fi
  local timeout_seconds="${AI_SPEC_TIMEOUT_SECONDS:-180}"
  case "$timeout_seconds" in
    ''|*[!0-9]*) timeout_seconds=180 ;;
  esac
  step "AI로 Office Hours 초안 생성 중… (claude -p, timeout ${timeout_seconds}s)"
  local prompt out n v allempty=1
  prompt="당신은 GStack planner 페르소나입니다. 새 프로젝트 master-spec의 Office Hours 6질문 '초안'을 작성하세요(사람이 검토합니다).
프로젝트 코드명: ${CODENAME}
검증 스택: ${STACK}
작성자: ${AUTHOR}
규칙: 각 답 1~2문장, 구체적·검증 가능하게. 4)성공·6)결과는 숫자/기한 포함. 불확실하면 끝에 ' (확인 필요)'를 붙이세요.
아래 6줄 형식만 출력하고 다른 텍스트는 쓰지 마세요:
OH1: <누가 이것을 원하는가 (1차 사용자)>
OH2: <진짜 풀려는 문제 (Job-to-be-done)>
OH3: <왜 지금 / 왜 우리인가>
OH4: <성공의 정의 (지표 + 임계값)>
OH5: <무엇을 만들지 않는가 (Non-goals)>
OH6: <N주 안 측정 가능한 결과>"
  if command -v timeout >/dev/null 2>&1; then
    out="$(timeout "$timeout_seconds" claude -p "$prompt" 2>/dev/null)" || out=""
  elif command -v gtimeout >/dev/null 2>&1; then
    out="$(gtimeout "$timeout_seconds" claude -p "$prompt" 2>/dev/null)" || out=""
  elif command -v python3 >/dev/null 2>&1; then
    out="$(python3 - "$prompt" "$timeout_seconds" <<'PY' 2>/dev/null
import subprocess
import sys

prompt = sys.argv[1]
timeout_seconds = int(sys.argv[2])
try:
    proc = subprocess.run(
        ["claude", "-p", prompt],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        timeout=timeout_seconds,
    )
except subprocess.TimeoutExpired:
    sys.exit(124)
sys.stdout.write(proc.stdout)
sys.exit(proc.returncode)
PY
)" || out=""
  else
    step "AI 초안 timeout 도구 없음 — claude를 직접 호출"
    out="$(claude -p "$prompt" 2>/dev/null)" || out=""
  fi
  if [ -z "$out" ]; then step "AI 응답 없음/실패 — 빈 스캐폴드로 진행"; AI_SPEC=0; return 0; fi
  for n in 1 2 3 4 5 6; do
    v="$(printf '%s\n' "$out" | sed -n "s/^OH${n}:[[:space:]]*//p" | head -1)"
    printf -v "OH${n}" '%s' "$v"
    [ -n "$v" ] && allempty=0
  done
  if [ "$allempty" -eq 1 ]; then step "AI 응답 형식 불일치 — 빈 스캐폴드로 진행"; AI_SPEC=0; return 0; fi
  step "AI 초안 완료 — master-spec.md §1에 반영(에디터에서 검토)"
}

# ─────────────────────────────────────────────────────────
# 9. master-spec / README stub (토큰 안전 치환)
# ─────────────────────────────────────────────────────────
say ""
say "[4/6] 명세·README 생성"
ai_draft_spec
if [ "$AI_SPEC" -eq 1 ]; then step "master-spec.md (AI 초안 + 에디터 검토 예정)"
elif [ "$EDIT_SPEC" -eq 1 ]; then step "master-spec.md (에디터 작성 예정)"
else step "master-spec.md (빈 스캐폴드)"; fi
[ "$DRY_RUN" -eq 0 ] && render_tokens > "$TARGET/docs/master-spec.md" <<'TPL'
# Master Spec

> **Step 1 (GStack)** — 모든 자동화의 출발점. 비어 있는 채로 루프를 돌리지 마세요.

## 0. 메타

| 항목 | 값 |
|---|---|
| 프로젝트 코드명 | @@CODENAME@@ |
| 작성일 | @@DATE@@ |
| 작성자 / 책임자 | @@AUTHOR@@ |
| 적대적 리뷰 완료 | ☐ CEO/PM ☐ Designer ☐ EM ☐ QA ☐ Security |
| 버전 | v0.1.0 (draft) |

## 1. Office Hours — 6가지 필수 질문

<!--
작성 팁:
- 각 항목은 처음엔 키워드/짧은 문장이어도 됩니다. 나중에 문단으로 다듬으세요.
- 좋은 답은 구체적·검증 가능해야 하며, 4번/6번은 숫자와 기한을 포함하세요.
- 예시는 새_프로젝트_적용_가이드.md "위저드 질문 상세"를 참고하세요.
-->

1. **누가 이것을 원하는가?** (1차 사용자)
   - @@OH1@@
2. **그들이 진짜로 풀고 싶은 문제는?** (Job-to-be-done)
   - @@OH2@@
3. **왜 지금인가? / 왜 우리인가?**
   - @@OH3@@
4. **성공의 정의는?** (지표 + 임계값)
   - @@OH4@@
5. **무엇을 만들지 않을 것인가?** (Non-goals)
   - @@OH5@@
6. **N주 안에 측정 가능한 결과는?**
   - @@OH6@@

## 2. 범위 / 아키텍처 개요

> 시스템 경계·주요 컴포넌트·데이터 흐름. (티켓 spec_ref 앵커 대상)

## 3. 권한 경계 (가역성 기준)

> 자동 허용(loop) vs 인간 승인(hold). 판단 기준: "잘못됐을 때 즉시 되돌릴 수 있는가?"
> 상세는 docs/runbook.md §4 참조.
TPL

open_spec_editor() {
  [ "$EDIT_SPEC" -eq 1 ] || return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    step "master-spec.md 에디터 열기 (dry-run이라 미실행)"
    return 0
  fi
  if [ ! -t 0 ] || [ ! -t 1 ]; then
    step "master-spec.md 에디터 건너뜀 (비대화 실행; 생성 후 직접 편집)"
    return 0
  fi
  local editor_cmd="${EDITOR:-vi}"
  step "master-spec.md 에디터 열기 ($editor_cmd)"
  # EDITOR="code -w" 같은 일반적인 공백 포함 명령을 허용한다.
  if ( cd "$TARGET" && $editor_cmd docs/master-spec.md ); then
    SPEC_EDITOR_OPENED=1
  else
    step "에디터가 비정상 종료(무시하고 계속) — 나중에 docs/master-spec.md를 직접 편집하세요."
  fi
}
open_spec_editor

step "README.md (포인터 stub)"
[ "$DRY_RUN" -eq 0 ] && render_tokens > "$TARGET/README.md" <<'TPL'
# @@CODENAME@@

Project Hephaestus 운영 하네스에서 `init_new_project.sh`로 클린 추출한 프로젝트입니다 (추출일: @@DATE@@).
Ralph Loop(명세 → 분할 → 헤드리스 실행 → 검증 → 복구 → 인간 승인) 방식으로 운영합니다.

## 빠른 시작

```bash
$EDITOR docs/master-spec.md            # 1) 명세 (Office Hours 6질문)
$EDITOR scripts/run_checks.local.sh    # 2) 검증 명령 확인/수정
./scripts/run_checks.sh                # 3) 0 exit 확인
cp docs/tickets/TEMPLATE.md docs/tickets/T001-first.md
$EDITOR docs/tickets/T001-first.md     # 4) 첫 티켓
./scripts/run_loop.sh T001-first --dry-run   # 5) 프롬프트 미리보기
```

## 구조

| 경로 | 역할 |
|---|---|
| `docs/master-spec.md` | 제품 명세 (Step 1) |
| `docs/runbook.md` | Ralph Loop 운영 규칙 |
| `docs/tickets/` | 작업 단위 (`TEMPLATE.md` 복사) |
| `docs/decisions/` | ADR (의사결정 기록) |
| `skills/` | AI 페르소나 4종 |
| `scripts/` | 루프 실행 도구 (`run_checks.local.sh`에 프로젝트 검증) |
| `mission-control/` | 이 프로젝트 전용 Mission Control 웹 (`./scripts/mission_control.sh start`) |
| `state/`, `.ralph/` | 런타임 상태 (git 무시) |

운영 규칙 전체: [`docs/runbook.md`](docs/runbook.md)
TPL

# ─────────────────────────────────────────────────────────
# 10. git init + 초기 커밋
# ─────────────────────────────────────────────────────────
say ""
say "[5/6] git 초기화"
if [ "$DO_GIT" -eq 0 ]; then step "건너뜀 (--no-git)"
elif ! command -v git >/dev/null 2>&1; then step "건너뜀 (git 미설치)"
elif [ "$DRY_RUN" -eq 1 ]; then step "git init + 초기 커밋 (dry-run이라 미실행)"
elif git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then step "건너뜀 (이미 git 저장소)"
else
  git -C "$TARGET" init -q
  git -C "$TARGET" add -A
  git -C "$TARGET" commit -q -m "init: Hephaestus 하네스 클린 추출 ($CODENAME)" \
    || step "커밋 생략 (변경 없음 또는 git author 미설정)"
  step "git init 완료 + 초기 커밋"
fi

# ─────────────────────────────────────────────────────────
# 11. 스모크 테스트 + 다음 단계
# ─────────────────────────────────────────────────────────
say ""
say "[6/6] 검증"
if [ "$DRY_RUN" -eq 1 ]; then
  say ""; say "DRY-RUN 완료 — 실제로 복사하지 않았습니다."; exit 0
fi
if ( cd "$TARGET" && ./scripts/run_checks.sh >/dev/null 2>&1 ); then
  step "✓ run_checks.sh 0 exit (새 레포 검증 통과)"
else
  step "⚠ run_checks.sh 비-0 exit — 'cd $TARGET && ./scripts/run_checks.sh'로 확인"
fi

cat <<EOF

✅ 클린 추출 완료 → $TARGET

다음 단계:
  cd "$TARGET"
EOF
[ "$SPEC_EDITOR_OPENED" -eq 1 ] || echo '  $EDITOR docs/master-spec.md          # 명세(Office Hours) 작성'
[ "$STACK" = "none" ] && echo '  $EDITOR scripts/run_checks.local.sh   # 검증 명령 채우기'
cat <<EOF
  cp docs/tickets/TEMPLATE.md docs/tickets/T001-first.md
  ./scripts/run_loop.sh T001-first --dry-run

가져오지 않은 것(의도적): PDF·OCR·보고서·ADR 이력·DONE 티켓·기존 master-spec/README.
EOF
