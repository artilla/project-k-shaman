#!/usr/bin/env bash
# approve.sh — create a run_loop-compatible approval marker or reject a ticket.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

usage() {
  cat <<'EOF'
usage:
  scripts/approve.sh <TXXX>
  scripts/approve.sh --reject "reason" <TXXX>
EOF
}

REJECT_REASON=""
ID=""

while [ "$#" -gt 0 ]; do
  case "$1" in
    --reject)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      REJECT_REASON="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    T*)
      ID="$1"
      shift
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

[ -n "$ID" ] || { usage >&2; exit 2; }
case "$ID" in
  T[0-9]*) ;;
  *) echo "invalid ticket id: $ID" >&2; exit 2 ;;
esac

shopt -s nullglob
matches=(docs/tickets/"$ID"-*.md)
if [ "${#matches[@]}" -eq 0 ]; then
  echo "ticket not found: $ID" >&2
  exit 1
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "multiple tickets match $ID" >&2
  printf '  %s\n' "${matches[@]}" >&2
  exit 1
fi
TICKET="${matches[0]}"

# 리뷰 9차 P1: canonical 경계 — symlink 티켓에 승인 마커를 만들거나 status를 바꾸지 않는다.
if [ -h "$TICKET" ] || [ ! -f "$TICKET" ]; then
  echo "❌ 티켓이 symlink이거나 regular file이 아닙니다 — 거부 (fail-closed)." >&2
  exit 2
fi
_tdir_real="$(cd "$(dirname "$TICKET")" && pwd -P)"
if [ "$_tdir_real" != "$(pwd -P)/docs/tickets" ]; then
  echo "❌ 티켓 물리 경로가 canonical docs/tickets가 아닙니다 (symlink 디렉터리?) — 거부." >&2
  exit 2
fi



# 리뷰 10차 P1: 쓰기 직전 identity 재검증 + same-dir temp + rename (TOCTOU/hardlink 차단).
# 리뷰 12차: GNU coreutils의 `stat -f`는 "파일시스템" 모드라 성공하면서 무관한 값을
# 반환한다(예: -f%l=최대 파일명 길이, -f%d=free nodes → 가변) — GNU(-c) 우선, BSD(-f) 폴백.
_file_links() { stat -c '%h' "$1" 2>/dev/null || stat -f '%l' "$1" 2>/dev/null; }
_stat_ino() { stat -c '%d:%i' "$1" 2>/dev/null || stat -f '%d:%i' "$1" 2>/dev/null; }
_write_guard() {
  local f="$1" want_dir="$2"
  [ -h "$f" ] && { echo "❌ 쓰기 직전 재검증 실패: symlink 교체 감지" >&2; return 1; }
  [ -f "$f" ] || { echo "❌ 쓰기 직전 재검증 실패: regular file 아님" >&2; return 1; }
  [ "$(_file_links "$f")" = "1" ] || { echo "❌ 쓰기 직전 재검증 실패: hardlink(links>1)" >&2; return 1; }
  # 리뷰 11차 P1: 읽기 시점에 기록한 dev/inode와 일치해야 한다 — 같은 경로에 놓인
  # "다른" regular 파일로의 교체(TOCTOU)를 잡는다.
  if [ -n "${EXPECT_INO:-}" ] && [ "$(_stat_ino "$f")" != "$EXPECT_INO" ]; then
    echo "❌ 쓰기 직전 재검증 실패: 파일 identity(dev/inode) 변경" >&2; return 1
  fi
  # 리뷰 12차 P1: 내용 CAS — 읽기 시점 SHA와 다르면 그 사이 "같은 inode"가 수정된
  # 것(동시 편집) → lost-update 방지를 위해 publish 거부. (guard~rename 사이의
  # 잔여 나노초 창은 파일시스템 한계로 문서화)
  if [ -n "${EXPECT_SHA:-}" ] && [ "$(_sha_of "$f")" != "$EXPECT_SHA" ]; then
    echo "❌ 쓰기 직전 재검증 실패: 내용 변경 감지(동시 수정) — 다시 시도하세요" >&2; return 1
  fi
  [ "$(cd "$(dirname "$f")" && pwd -P)" = "$(pwd -P)/$want_dir" ] || { echo "❌ 쓰기 직전 재검증 실패: canonical 경로 아님" >&2; return 1; }
}
_sha_of() { git hash-object -- "$1" 2>/dev/null || shasum "$1" 2>/dev/null | awk '{print $1}'; }
# 리뷰 13차 P1: writer publish 직렬화 — SHA 검사(guard)와 rename 사이가 lock 없이는
# CAS가 아니다. 모든 writer가 같은 lock 아래에서 guard→publish를 수행해야 동시
# 편집의 한쪽이 조용히 유실되지 않는다 (패자는 SHA 불일치로 명시 거부됨).
_TW_LOCK="state/ticket_write.lock.d"
_TW_HELD=0
_acquire_write_lock() {
  local _i=0 _p _mp
  # 리뷰 14차 P1: 재진입 지원 — 결정(critical section)이 lock을 쥔 채 _safe_write를
  # 부를 수 있어야 approve/reject 상호 직렬화가 단일 임계구역으로 성립한다.
  if [ "${_TW_HELD:-0}" -gt 0 ]; then _TW_HELD=$((_TW_HELD+1)); return 0; fi
  mkdir -p state 2>/dev/null || true
  while :; do
    if mkdir "$_TW_LOCK" 2>/dev/null; then
      if echo "$$" > "$_TW_LOCK/pid" 2>/dev/null; then _TW_HELD=1; return 0; fi
      rm -rf "$_TW_LOCK" 2>/dev/null || true
      return 1
    fi
    _p="$(cat "$_TW_LOCK/pid" 2>/dev/null || true)"
    if [ -n "$_p" ] && ! kill -0 "$_p" 2>/dev/null; then
      # stale lock — 원자적 rename으로 회수. 리뷰 14차 P1: 회수를 "관찰한 그 lock"에
      # 결속 — 이동한 디렉터리의 pid가 관찰한 dead pid와 다르면(그 사이 새 live
      # owner로 교체) 원복하고 대기한다. live lock 삭제 → 상호배제 붕괴 방지.
      if mv "$_TW_LOCK" "$_TW_LOCK.reclaim.$$" 2>/dev/null; then
        _mp="$(cat "$_TW_LOCK.reclaim.$$/pid" 2>/dev/null || true)"
        if [ "$_mp" = "$_p" ]; then
          rm -rf "$_TW_LOCK.reclaim.$$" 2>/dev/null || true
          continue
        fi
        if ! mv "$_TW_LOCK.reclaim.$$" "$_TW_LOCK" 2>/dev/null; then
          echo "❌ live write lock 원복 실패 — fail-closed로 중단합니다: ${_TW_LOCK}.reclaim.$$ 확인" >&2
          return 1
        fi
      fi
    fi
    _i=$((_i+1))
    if [ "$_i" -ge 100 ]; then
      echo "❌ ticket write lock 획득 실패(경합 지속) — ${_TW_LOCK} 확인" >&2
      return 1
    fi
    sleep 0.1
  done
}
_release_write_lock() {
  if [ "${_TW_HELD:-0}" -gt 1 ]; then _TW_HELD=$((_TW_HELD-1)); return 0; fi
  if [ "$(cat "$_TW_LOCK/pid" 2>/dev/null)" = "$$" ]; then
    rm -rf "$_TW_LOCK" 2>/dev/null || true
  fi
  _TW_HELD=0
}
_safe_write() {  # stdin → $1 (same-dir temp + rename), $2=canonical 상대 디렉터리
  local f="$1" want_dir="$2" tmp perm
  tmp=$(mktemp "${want_dir}/.write.XXXXXX") || return 1
  # 리뷰 11차 P1: 입력 복사 실패(부분 출력)를 성공으로 넘기지 않는다.
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    echo "❌ 임시 파일 쓰기 실패 — 원본 무변조 유지" >&2
    return 1
  fi
  # 리뷰 13차 P1: guard(SHA CAS 포함)~rename을 lock 아래에서 수행 — publish 직렬화.
  if ! _acquire_write_lock; then rm -f "$tmp"; return 1; fi
  if ! _write_guard "$f" "$want_dir"; then _release_write_lock; rm -f "$tmp"; return 1; fi
  # 리뷰 11차 P2 + 12차 P2 + 13차 P2: mode 조회 실패(빈 값)도 publish 중단 —
  # 조용한 0600 고정 방지 (fail-closed).
  perm="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || true)"
  if [ -z "$perm" ]; then
    _release_write_lock; rm -f "$tmp"
    echo "❌ 원본 mode 조회 실패 — publish 중단 (mode 유실 방지)" >&2
    return 1
  fi
  if ! chmod "$perm" "$tmp" 2>/dev/null; then
    _release_write_lock; rm -f "$tmp"
    echo "❌ mode 보존 실패 — publish 중단" >&2
    return 1
  fi
  # 리뷰 12차 P2: mv 실패 시 임시 파일을 남기지 않는다.
  if ! mv -f "$tmp" "$f"; then
    _release_write_lock; rm -f "$tmp"
    echo "❌ rename 실패 — 원본 무변조 유지" >&2
    return 1
  fi
  _release_write_lock
}

# 리뷰 11차 P1: 읽기 시점 identity 고정 — 이후 모든 쓰기는 같은 dev/inode여야 한다.
EXPECT_INO="$(_stat_ino "${TICKET}")"
EXPECT_SHA="$(_sha_of "${TICKET}")"

# 리뷰 13차 P1: 결정(approve/reject)은 티켓 상태와 직렬화 — 이미 reject(skipped)·
# done·진행 중(forging) 티켓에 새 결정을 얹지 않는다. open/awaiting-approval만 허용.
_TSTATUS="$(awk '
  NR == 1 { if ($0 != "---") exit; next }
  $0 == "---" { exit }
  substr($0, 1, 7) == "status:" {
    sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
  }
' "$TICKET")"
case "$_TSTATUS" in
  open|awaiting-approval) : ;;
  *)
    echo "❌ ${ID} status='${_TSTATUS}' — approve/reject 대상이 아닙니다 (open|awaiting-approval만 허용, 이미 확정된 결정을 덮지 않음)." >&2
    exit 3
    ;;
esac


set_status() {
  local file="$1" new_status="$2" tmp ok
  # 리뷰 5차 P1: 교체 전에 frontmatter 유효성을 검증한다 — CRLF 티켓(opener 불일치)은
  # 아무것도 안 바꾸면서 rc=0을 반환했고, `---trailing` closer는 본문 status:까지
  # 변조했다. opener(1행 정확히 ---)·closer(정확히 ---)·status 정확히 1회가 아니면
  # 원본을 건드리지 않고 실패한다.
  ok=$(awk '
    NR == 1 { if ($0 != "---") { print "no"; exit }; next }
    !closed && $0 == "---" { closed = 1; next }
    !closed && substr($0, 1, 7) == "status:" { n++ }
    END { if (closed && n == 1) print "yes"; else print "no" }
  ' "$file")
  if [ "$ok" != "yes" ]; then
    echo "❌ $file: frontmatter가 유효하지 않아 status를 변경할 수 없습니다 (1행 '---' opener, '---' closer, status 정확히 1회 필요 — CRLF 여부도 확인하세요)." >&2
    return 1
  fi
  # 리뷰 3차 P1: 최초 frontmatter 블록만 수정 (본문 `---` 블록의 status: 라인 보호)
  # 리뷰 10차 P1: same-dir temp + rename + 직전 재검증
  awk -v new_status="$new_status" '
    NR == 1 && $0 == "---" { fm = 1; print; next }
    fm == 1 && $0 == "---" { fm = 2; print; next }
    fm == 1 && substr($0, 1, 7) == "status:" { print "status: " new_status; next }
    { print }
  ' "$file" | _safe_write "$file" "docs/tickets" || return 1
}

if [ -n "$REJECT_REASON" ]; then
  # 리뷰 12차 P1: status 교체 + Rejection 기록을 "단일 publish"로 — 과거 2회 publish는
  # 두 번째 실패 시 status만 바뀌고 기록이 누락됐다. producer(스테이지 파일 완성)가
  # 실패하면 publish 자체가 없다(부분 출력이 파이프로 먼저 나가던 문제 제거).
  _fm_ok=$(awk '
    NR == 1 { if ($0 != "---") { print "no"; exit }; next }
    !closed && $0 == "---" { closed = 1; next }
    !closed && substr($0, 1, 7) == "status:" { n++ }
    END { if (closed && n == 1) print "yes"; else print "no" }
  ' "$TICKET")
  if [ "$_fm_ok" != "yes" ]; then
    echo "❌ $TICKET: frontmatter가 유효하지 않아 reject할 수 없습니다 (opener/closer/단일 status 필요)." >&2
    exit 2
  fi
  # 리뷰 14차 P1: approve/reject 상호 직렬화 — 결정은 write lock 임계구역 안에서
  # "상태 재확인 + 승인 마커 부재 확인 + publish"를 원자적으로 수행한다. 초기 status
  # 게이트만으로는 게이트 통과 후 상대 결정이 끼어들 수 있어, skipped 티켓과 유효
  # approval marker가 공존했다 (둘 다 rc=0).
  if ! _acquire_write_lock; then
    echo "❌ 결정 직렬화 lock 획득 실패 — reject를 수행하지 않습니다." >&2
    exit 2
  fi
  _TSTATUS_NOW="$(awk '
    NR == 1 { if ($0 != "---") exit; next }
    $0 == "---" { exit }
    substr($0, 1, 7) == "status:" {
      sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
    }
  ' "$TICKET")"
  case "$_TSTATUS_NOW" in
    open|awaiting-approval) : ;;
    *)
      _release_write_lock
      echo "❌ ${ID} status='${_TSTATUS_NOW}' — 임계구역 재확인에서 reject 대상이 아님 (동시 결정 감지)." >&2
      exit 3
      ;;
  esac
  if [ -e "docs/approvals/${ID}.md" ]; then
    _release_write_lock
    echo "❌ ${ID}: 승인 마커(docs/approvals/${ID}.md)가 이미 존재합니다 — 승인된 티켓은 reject할 수 없습니다. 결정을 뒤집으려면 마커를 명시적으로 삭제한 뒤 재시도하세요." >&2
    exit 3
  fi
  _stage=$(mktemp "docs/tickets/.stage.XXXXXX")
  # 리뷰 13차 P1: producer를 단계별로 검증 — `{ awk; printf; }` 그룹은 마지막 printf의
  # 성공이 awk의 중간 실패(부분 출력)를 덮어 부분 문서가 rc=0으로 게시됐다.
  if ! awk '
      NR == 1 && $0 == "---" { fm = 1; print; next }
      fm == 1 && $0 == "---" { fm = 2; print; next }
      fm == 1 && substr($0, 1, 7) == "status:" { print "status: skipped"; next }
      { print }
    ' "$TICKET" > "$_stage"; then
    rm -f "$_stage"; _release_write_lock
    echo "❌ reject 내용 생성 실패(status 교체 단계) — 원본 무변조 유지" >&2
    exit 2
  fi
  # 본문이 통째로 유실되지 않았는지 확인 — stage는 원본과 같은 줄 수여야 한다.
  if [ "$(wc -l < "$_stage")" -ne "$(wc -l < "$TICKET")" ]; then
    rm -f "$_stage"; _release_write_lock
    echo "❌ reject stage 검증 실패(줄 수 불일치 — 부분 출력?) — 원본 무변조 유지" >&2
    exit 2
  fi
  if ! {
    printf '\n## Rejection\n\n'
    printf -- '- rejected_at: "%s"\n' "$(date -Iseconds)"
    printf -- '- reason: "%s"\n' "$REJECT_REASON"
  } >> "$_stage"; then
    rm -f "$_stage"; _release_write_lock
    echo "❌ reject 내용 생성 실패(Rejection 기록 단계) — 원본 무변조 유지" >&2
    exit 2
  fi
  _safe_write "$TICKET" "docs/tickets" < "$_stage" || { rm -f "$_stage"; _release_write_lock; exit 2; }
  rm -f "$_stage"
  _release_write_lock
  echo "rejected $ID: $REJECT_REASON"
  exit 0
fi

mkdir -p docs/approvals
# 리뷰 10차 P1: 승인 artifact 경계 — approvals 디렉터리(및 조상 docs)가 symlink면
# 마커가 저장소 밖에 쓰인다. 물리 경로 대조 + 마커 자체 symlink 거부.
if [ -h "docs/approvals" ] || [ "$(cd docs/approvals && pwd -P)" != "$(pwd -P)/docs/approvals" ]; then
  echo "❌ docs/approvals 물리 경로가 canonical이 아닙니다 (symlink?) — 승인 거부 (fail-closed)." >&2
  exit 2
fi
MARKER="docs/approvals/${ID}.md"
if [ -h "$MARKER" ]; then
  echo "❌ ${MARKER} 가 symlink입니다 — 승인 마커로 사용할 수 없습니다 (fail-closed)." >&2
  exit 2
fi
APPROVER="${RALPH_APPROVED_BY:-}"
if [ -z "$APPROVER" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  APPROVER="$(git config user.name || true)"
fi
APPROVER="${APPROVER:-$(whoami)}"

# ADR-0037 §3.4: draft scope_confirmation / rollback_plan from the ticket's
# §변경 범위 / §롤백 sections instead of a bare TODO placeholder. The draft is a
# starting point — a human still confirms (the marker is committed and audited).
section_oneline() {
  # $1=file, $2=heading keyword → first ~3 content lines as one compact line.
  # 리뷰 4차 P2: `| head -3`은 긴 섹션에서 head 조기 종료 → awk SIGPIPE(141)로
  # pipefail+set -e 아래 스크립트 전체가 죽었다 — 3줄 제한을 awk 내부에서 처리.
  awk -v kw="$2" '
    /^##[[:space:]]/ { if (inSec) exit; inSec = (index($0, kw) > 0); next }
    inSec {
      line=$0
      gsub(/^[[:space:]]*[-*>][[:space:]]*/, "", line)
      gsub(/^[[:space:]]*\[[ xX]\][[:space:]]*/, "", line)
      gsub(/[`*#]/, "", line)
      gsub(/^[[:space:]]+/, "", line); gsub(/[[:space:]]+$/, "", line)
      if (line ~ /^```/) next
      if (line ~ /[^[:space:]]/) { print line; if (++n >= 3) exit }
    }
  ' "$1" | tr '\n' ' ' | sed 's/  */ /g; s/[[:space:]]*$//'
}
yaml_escape() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g' | cut -c1-400; }

SCOPE_DRAFT="$(section_oneline "$TICKET" '변경 범위')"
[ -n "$SCOPE_DRAFT" ] || SCOPE_DRAFT="$(section_oneline "$TICKET" 'Scope')"
[ -n "$SCOPE_DRAFT" ] || SCOPE_DRAFT="TODO: confirm exact approved scope for $ID"
ROLLBACK_DRAFT="$(section_oneline "$TICKET" '롤백')"
[ -n "$ROLLBACK_DRAFT" ] || ROLLBACK_DRAFT="$(section_oneline "$TICKET" 'Reversibility')"
[ -n "$ROLLBACK_DRAFT" ] || ROLLBACK_DRAFT="git revert <commit>"

# 리뷰 14차 P1: approve/reject 상호 직렬화 — 마커 생성은 write lock 임계구역 안에서
# "상태 재확인 + 원자적 생성"으로 수행한다. 초기 status 게이트 통과 후 reject가
# 끼어들면 skipped 티켓에 유효 approval marker가 공존할 수 있었다 (둘 다 rc=0).
if ! _acquire_write_lock; then
  echo "❌ 결정 직렬화 lock 획득 실패 — 승인을 수행하지 않습니다." >&2
  exit 2
fi
_TSTATUS_NOW="$(awk '
  NR == 1 { if ($0 != "---") exit; next }
  $0 == "---" { exit }
  substr($0, 1, 7) == "status:" {
    sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit
  }
' "$TICKET")"
case "$_TSTATUS_NOW" in
  open|awaiting-approval) : ;;
  *)
    _release_write_lock
    echo "❌ ${ID} status='${_TSTATUS_NOW}' — 임계구역 재확인에서 approve 대상이 아님 (동시 결정 감지)." >&2
    exit 3
    ;;
esac
if [ ! -f "$MARKER" ]; then
  # 리뷰 10차 P1: 마커도 same-dir temp + rename — 생성 창에서의 symlink 교체 차단.
  _mtmp=$(mktemp "docs/approvals/.marker.XXXXXX")
  cat > "$_mtmp" <<EOF
approved_by: "$APPROVER"
approved_at: "$(date -Iseconds)"
scope_confirmation: "$(yaml_escape "$SCOPE_DRAFT")"
rollback_plan: "$(yaml_escape "$ROLLBACK_DRAFT")"
EOF
  # 리뷰 11차 P1: 생성 직전 approvals 디렉터리 물리 경로를 재검증 — 초기 검사 후
  # 디렉터리가 symlink로 교체되면 mv가 cross-device copy로 저장소 밖에 쓸 수 있다.
  if [ -h "docs/approvals" ] || [ "$(cd docs/approvals 2>/dev/null && pwd -P)" != "$(pwd -P)/docs/approvals" ]; then
    rm -f "$_mtmp"; _release_write_lock
    echo "❌ docs/approvals 가 생성 직전 canonical이 아님(교체 감지) — 거부 (fail-closed)." >&2
    exit 2
  fi
  if [ -h "$MARKER" ]; then
    rm -f "$_mtmp"; _release_write_lock
    echo "❌ ${MARKER} 가 symlink로 교체됨 — 거부 (fail-closed)." >&2
    exit 2
  fi
  # 리뷰 12차 P1: 원자적 생성(ln은 대상이 이미 있으면 실패) — 동시 승인 경합에서
  # 한쪽 결정이 다른 쪽 마커를 조용히 덮어쓰지 않는다.
  if ln "$_mtmp" "$MARKER" 2>/dev/null; then
    rm -f "$_mtmp"
  else
    rm -f "$_mtmp"; _release_write_lock
    # 리뷰 13차 P1: 경쟁 패자는 남의 결정을 편집/검증 대상으로 삼지 않는다 —
    # 기존 마커를 안내만 하고 "승인 미수행"으로 종료.
    echo "⚠️  ${MARKER} 가 그 사이 생성됨(동시 승인 경합) — 기존 마커를 유지하고 이 승인 시도는 중단합니다. 기존 결정을 확인하세요."
    exit 3
  fi
fi
_release_write_lock

echo "approval marker ready: $MARKER"
if [ -n "${EDITOR:-}" ]; then
  "$EDITOR" "$MARKER"
else
  echo "EDITOR is not set; edit $MARKER before running run_loop."
fi

# 리뷰 2차 P1-7: 실행기(run_loop)와 동일한 단일 검증기로 마커를 즉시 판정해 안내한다.
# 여기서 ok가 아니면 run_loop도 같은 이유로 거부한다 — 승인 직후 바로 고칠 수 있게 표시.
if command -v node >/dev/null 2>&1 && [ -f "$ROOT/mission-control/approval.mjs" ]; then
  VALIDATION="$(node "$ROOT/mission-control/approval.mjs" "$ROOT" "$ID" 2>&1 || true)"
  echo "validator: $VALIDATION"
  case "$VALIDATION" in
    ok) ;;
    stale*) echo "⚠️  티켓 §변경 범위가 마커와 불일치(stale) — run_loop가 거부합니다. 마커를 삭제 후 재실행하세요." ;;
    malformed*) echo "⚠️  필수 필드 누락(malformed) — run_loop가 거부합니다. ${MARKER}를 보완하세요." ;;
    unverifiable*) echo "⚠️  scope 검증 불가(unverifiable) — run_loop가 거부합니다. 티켓에 '## 변경 범위' 섹션을 추가하고 마커 scope_confirmation을 맞추세요." ;;
  esac
fi
