#!/usr/bin/env bash
# pick_next_ticket.sh — 다음에 처리할 티켓 1개의 경로를 stdout에 출력.
#
# 동적 경로 탐색(JIT). 워터폴 사전 종속성 정의 대신, 현재 시점에서
# (1) 의존성이 모두 done이고 (2) 우선순위가 가장 높고 (3) safe 라벨이 맞는
# 첫 번째 티켓을 고른다.
#
# 사용:
#   ./scripts/pick_next_ticket.sh             # 모든 open 중에서 선택
#   ./scripts/pick_next_ticket.sh --safe-only # safe: true 만
#
# stdout: 티켓 파일 경로 (없으면 빈 문자열, exit 0).
# safe:false skip 메시지도 stdout에 출력될 수 있으므로, 호출자는
# `^docs/tickets/.*\.md$` 라인만 티켓 경로로 해석해야 한다.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

SAFE_ONLY=0
[ "${1:-}" = "--safe-only" ] && SAFE_ONLY=1

# 프론트매터 필드 추출 (yq가 없는 환경 가정 — awk로 처리)
# inline `# 주석`도 제거한다 (TEMPLATE이 가진 주석이 실제 값에 섞이지 않도록).
# 리뷰 3차 P1: `---` 토글 파싱은 본문의 `--- key: v ---` 블록도 frontmatter로 읽어
# 실행 권한(safe 등)이 본문에서 주입될 수 있었다 — 1행에서 시작하는 최초 frontmatter
# 블록만 읽는다.
# 리뷰 4차 P1: (a) 닫는 `---` 부재 시 frontmatter 전체 무효, (b) 키는 1열 시작 강제
# (들여쓴 중첩 키 `  safe: true` 차단).
field_of() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { closed = 1; exit }
    !found && substr($0, 1, length(k) + 1) == k ":" {
      line = $0
      sub(/^[^:]+:[ \t]*/, "", line)
      sub(/[ \t]+#.*$/, "", line)
      gsub(/^[ \t]+|[ \t]+$/, "", line)
      # 리뷰 6~8차 P2: quoted scalar 허용 — 같은 종류의 따옴표 "쌍"일 때만 벗긴다
      # (혼합 쌍/미폐 따옴표 보존, BSD awk 호환을 위해 regex 대신 문자 비교).
      if (length(line) >= 2) {
        fc = substr(line, 1, 1); lc = substr(line, length(line), 1)
        if ((fc == "\"" && lc == "\"") || (fc == "\047" && lc == "\047"))
          line = substr(line, 2, length(line) - 2)
      }
      val = line
      found = 1
    }
    END { if (closed && found) print val }
  ' "$file"
}

# 최초 frontmatter 블록 안에서 key(1열 시작)가 등장하는 횟수.
# 0=누락, 2+=중복, 닫는 `---` 부재 시 무조건 0 — 모두 fail-closed 대상.
frontmatter_field_count() {
  local file="$1" key="$2"
  awk -v k="$key" '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { closed = 1; exit }
    substr($0, 1, length(k) + 1) == k ":" { n++ }
    END { print (closed ? n + 0 : 0) }
  ' "$file"
}

# 우선순위 점수: P0=0, P1=1, P2=2, P3=3 (작을수록 먼저)
priority_score() {
  case "$1" in
    P0) echo 0 ;; P1) echo 1 ;; P2) echo 2 ;; P3) echo 3 ;; *) echo 9 ;;
  esac
}

ticket_id_from_path() {
  local base; base=$(basename "$1" .md)
  echo "${base%%-*}"
}

set_status() {
  local file="$1" new_status="$2" tmp ok
  # 리뷰 5차 P1: 교체 전에 frontmatter 유효성 검증 — 유효하지 않으면(CRLF opener,
  # `---trailing` closer, status 0/2회) 원본을 건드리지 않고 실패한다.
  ok=$(awk '
    NR == 1 { if ($0 != "---") { print "no"; exit }; next }
    !closed && $0 == "---" { closed = 1; next }
    !closed && substr($0, 1, 7) == "status:" { n++ }
    END { if (closed && n == 1) print "yes"; else print "no" }
  ' "$file")
  if [ "$ok" != "yes" ]; then
    echo "❌ $file: frontmatter가 유효하지 않아 status를 변경할 수 없습니다." >&2
    return 1
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/ralph-status.XXXXXX")
  # 리뷰 3차 P1: 최초 frontmatter 블록만 수정 (본문 `---` 블록의 status: 라인 보호)
  awk -v new_status="$new_status" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && $0 == "---" { fm = 2; print; next }
    fm == 1 && substr($0, 1, 7) == "status:" {
      print "status: " new_status
      next
    }
    { print }
  ' "$file" > "$tmp"
  mv "$tmp" "$file"
}

mark_awaiting_approval() {
  local file="$1" id="$2"
  local status
  status=$(field_of "$file" status || true)
  [ "$status" = "awaiting-approval" ] && return 0

  set_status "$file" "awaiting-approval"

  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$file"
    if ! git diff --cached --quiet -- "$file"; then
      git commit -m "ralph: mark $id awaiting-approval" >/dev/null
    fi
  fi
}

shopt -s nullglob

# 리뷰 8차 P1: docs/·docs/tickets/ 자체가 symlink면 canonical 경계가 깨진다 — fail-closed.
# 리뷰 9차 P2: 구성 오류를 exit 0("후보 없음"=정상 idle)으로 위장하지 않는다 — exit 2.
# 리뷰 10차 P1: DONE/ symlink도 포함 — 외부 파일이 depends_on을 충족시키는 우회 차단.
if [ -h "docs" ] || [ -h "docs/tickets" ] || [ -h "docs/tickets/DONE" ]; then
  echo "docs/tickets(/DONE) 경로가 symlink입니다 — canonical 경계 위반 (fail-closed, exit 2)." >&2
  exit 2
fi

candidates=()
for f in docs/tickets/T*.md; do
  [ "$(basename "$f")" = "TEMPLATE.md" ] && continue

  # 리뷰 8차 P1: symlink 티켓(외부 파일 연결)은 후보에서 제외 (fail-closed).
  if [ -h "$f" ] || [ ! -f "$f" ]; then
    echo "[SKIP] $(basename "$f") — symlink이거나 regular file이 아님. fail-closed로 제외."
    continue
  fi

  base=$(basename "$f" .md)
  id="${base%%-*}"

  # 리뷰 5차 P1: 권위 필드 단일성 — 셸은 첫 값, 서버는 마지막 값을 읽으므로 중복 선언은
  # split-brain을 만든다. 리뷰 6차 P1: id는 정확히 1회 + T<숫자> 형식 + 파일명 ID 일치.
  dup_bad=0
  for fkey in safe status id; do
    if [ "$(frontmatter_field_count "$f" "$fkey")" != "1" ]; then
      echo "[SKIP] $id — frontmatter의 ${fkey} 선언이 정확히 1회가 아닙니다. fail-closed로 제외 — 티켓 frontmatter를 고치세요."
      dup_bad=1
      break
    fi
  done
  [ "$dup_bad" = "1" ] && continue
  if [ "$(frontmatter_field_count "$f" persona)" -gt 1 ]; then
    echo "[SKIP] $id — frontmatter의 persona 선언이 중복입니다. fail-closed로 제외 — 티켓 frontmatter를 고치세요."
    continue
  fi
  fm_id=$(field_of "$f" id || true)
  if ! [[ "$id" =~ ^T[0-9]+$ ]]; then
    echo "[SKIP] $id — 파일명 ID가 T<숫자> 형식이 아닙니다. fail-closed로 제외."
    continue
  fi
  if [ "$fm_id" != "$id" ]; then
    echo "[SKIP] $id — frontmatter id('${fm_id}')가 파일명 ID와 다릅니다. fail-closed로 제외 — 티켓을 고치세요."
    continue
  fi

  status=$(field_of "$f" status || true)
  # 'open' 만 후보. done/skipped/blocked/awaiting-approval 는 제외.
  [ "$status" = "open" ] || continue

  # Reservation lock(state/reservations/<TXXX>.d)이 잡혀 있으면 다른 워커가 처리 중 → 제외.
  if [ -d "state/reservations/${id}.d" ]; then continue; fi

  safe=$(field_of "$f" safe || true)
  # 리뷰 2차 P1-6: safe는 정확히 'true'|'false'만 허용. 과거에는 "false가 아니면 후보"라서
  # 누락·오타('True', 'yes' 등) 티켓이 승인 게이트 없이 실행됐다 — fail-closed로 제외.
  case "$safe" in
    true) ;;
    false)
      if [ "$SAFE_ONLY" = "1" ]; then
        mark_awaiting_approval "$f" "$id"
        echo "[SKIP] $id — safe:false, 승인 필요. awaiting-approval 상태로 변경됨."
      else
        echo "[SKIP] $id — safe:false, 승인 필요. 명시적 run_loop 호출과 docs/approvals/${id}.md가 필요합니다."
      fi
      continue
      ;;
    *)
      echo "[SKIP] $id — safe 필드 비정상('${safe:-누락}'): 'true'|'false'만 허용. fail-closed로 제외 — 티켓 frontmatter를 고치세요."
      continue
      ;;
  esac
  candidates+=("$f")
done

if [ "${#candidates[@]}" -eq 0 ]; then
  exit 0  # 빈 출력 = 처리할 게 없음
fi

# 의존성 해소된 것만 (depends_on의 모든 티켓이 done이거나 비어있음)
deps_satisfied() {
  local file="$1"
  local deps
  # 리뷰 15차 P1: depends_on 선언은 최대 1회 — 첫 선언만 읽는 파서를 겨냥해
  # `depends_on: []` 뒤에 실제 dep을 숨기는 우회를 차단 (중복은 malformed).
  [ "$(frontmatter_field_count "$file" depends_on)" -le 1 ] || return 1
  # 리뷰 14차 P2: "최초 frontmatter 블록"만 읽는다 — 토글(fm = !fm) 방식은 본문의
  # 가짜 `---` 블록을 다시 frontmatter로 읽어 direct-run(run_loop)과 선택 결과가
  # 달라졌다. run_loop.deps_satisfied_strict와 동일한 첫-블록 시맨틱.
  deps=$(awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    substr($0, 1, 11) == "depends_on:" {
      sub(/^[^:]+:[ \t]*/, ""); print; exit
    }
  ' "$file")
  # 리뷰 13차 P1: inline comment 제거 후 외곽 브래킷은 정확히 한 쌍만 벗긴다 —
  # 내부 브래킷까지 지우면 [T[001]] → T001 로 malformed 값이 승격된다. 미폐 브래킷은
  # malformed → 미충족 (fail-closed).
  deps="$(printf '%s' "$deps" | sed 's/[[:space:]]#.*$//; s/^[[:space:]]*//; s/[[:space:]]*$//')"
  case "$deps" in
    '['*']') deps="${deps#\[}"; deps="${deps%\]}" ;;
    '['*|*']') return 1 ;;
  esac
  deps="$(printf '%s' "$deps" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
  [ -z "$deps" ] && return 0
  # 리뷰 14차 P1: 빈 원소([,]·[T001,]·[,T001])는 malformed — "의존성 없음"으로
  # 승격하지 않는다. read -ra는 후행 빈 필드를 버리므로 분리 전에 원문으로 검사.
  case ",${deps}," in *,,*) return 1 ;; esac
  IFS=',' read -ra arr <<< "$deps"
  # 리뷰 11차 P1: 사용 시점에 DONE 물리 경로를 재검증 — 초기 검사 후 디렉터리가
  # 교체되는 경합 차단.
  local done_real
  done_real="$(cd docs/tickets/DONE 2>/dev/null && pwd -P)" || return 1
  [ "$done_real" = "$(pwd -P)/docs/tickets/DONE" ] || return 1

  for dep in "${arr[@]}"; do
    # 리뷰 12차 P1 + 13차 P1: 공백만 strip하고 quote는 "같은 쌍" 1겹만 벗긴다 —
    # 혼합 제거는 미폐 quote("T001')를 정상 ID로 승격시켰다.
    dep="$(printf '%s' "$dep" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    case "$dep" in
      '"'*'"') dep="${dep#\"}"; dep="${dep%\"}" ;;
      "'"*"'") dep="${dep#?}"; dep="${dep%?}" ;;
    esac
    # 리뷰 14차 P1: 빈 원소([,]·[T001,] 등)는 malformed — "의존성 없음"으로 승격하지
    # 않는다 (fail-closed). 빈 목록은 위의 [ -z "$deps" ] 단계에서 이미 처리됐다.
    [ -z "$dep" ] && return 1
    # 리뷰 11차 P1: dependency ID 형식 강제 — 비정상 ID(글롭 문자 등)가 DONE 밖
    # 파일을 완료 증거로 만들던 우회 차단.
    if ! [[ "$dep" =~ ^T[0-9]+$ ]]; then
      return 1
    fi
    # 리뷰 10차 P1: DONE 파일 자체가 symlink(외부 파일)면 의존성 충족으로 치지 않는다.
    # 리뷰 12차 P1: 완료 증거는 파일명이 아니라 실제 frontmatter(id 일치 + status done)
    # + git tracked 파일이어야 한다.
    local dep_ok=0 dep_f
    for dep_f in docs/tickets/DONE/"${dep}"-*.md docs/tickets/DONE/"${dep}".md; do
      [ -f "$dep_f" ] && [ ! -h "$dep_f" ] || continue
      # 리뷰 14차 P1: 증거 frontmatter의 id/status는 정확히 1회 선언이어야 한다 —
      # 중복 선언 파일(첫 값만 읽혀 우회 가능)은 완료 증거로 인정하지 않는다.
      [ "$(frontmatter_field_count "$dep_f" id)" = "1" ] || continue
      [ "$(frontmatter_field_count "$dep_f" status)" = "1" ] || continue
      [ "$(field_of "$dep_f" id || true)" = "$dep" ] || continue
      [ "$(field_of "$dep_f" status || true)" = "done" ] || continue
      if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git ls-files --error-unmatch "$dep_f" >/dev/null 2>&1 || continue
      fi
      dep_ok=1; break
    done
    [ "$dep_ok" = "1" ] || return 1
  done
  return 0
}

ready=()
for f in "${candidates[@]}"; do
  if deps_satisfied "$f"; then ready+=("$f"); fi
done

[ "${#ready[@]}" -eq 0 ] && exit 0

# 우선순위 + 파일명으로 정렬
best=""; best_score=999
for f in "${ready[@]}"; do
  p=$(field_of "$f" priority || echo P9)
  s=$(priority_score "$p")
  if [ "$s" -lt "$best_score" ] || { [ "$s" -eq "$best_score" ] && [[ "$f" < "$best" ]]; }; then
    best="$f"; best_score=$s
  fi
done

echo "$best"
