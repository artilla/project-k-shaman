#!/usr/bin/env bash
# ticket_edit.sh — ADR-0058: structured, auditable, NON-LLM edits to a ticket's
# ORGANIZATIONAL metadata only (priority, labels). The file is the truth; this
# script is the writer (CLI parity). Mission Control dispatches it via the
# localhost-only `ticket_edit` exec command (T099). A human can run it directly.
#
# HARD GUARD — this script ONLY ever rewrites the `priority` or `labels` line of
# an OPEN ticket's frontmatter. It NEVER touches execution-gating fields
# (safe / status / id / depends_on), NEVER edits DONE tickets, the TEMPLATE, or
# approval markers. priority/labels carry no execution/approval/merge meaning, so
# they are orthogonal to the safe:false gate (ADR-0007).
#
# 사용:
#   ./scripts/ticket_edit.sh set-priority T123 P1
#   ./scripts/ticket_edit.sh set-labels   T123 "ui,autonomy,test"
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

usage() { echo "usage: ticket_edit.sh set-priority <TXXX> <P0|P1|P2|P3> | set-labels <TXXX> \"<csv>\"" >&2; }

action="${1:-}"; id="${2:-}"; value="${3:-}"

case "$id" in
  T[0-9][0-9][0-9]*) : ;;
  *) echo "❌ 잘못된 티켓 id: '${id}' (형식 TXXX)" >&2; exit 2 ;;
esac

# 대상은 docs/tickets/ 의 open 티켓만. DONE/·TEMPLATE·승인 마커는 절대 대상 아님.
shopt -s nullglob
matches=( docs/tickets/"${id}"-*.md )
if [ "${#matches[@]}" -eq 0 ]; then
  echo "❌ open 티켓을 찾을 수 없습니다: ${id} (DONE 티켓·승인 마커는 편집 대상이 아닙니다)" >&2
  exit 2
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "❌ ${id}에 매칭되는 티켓이 여러 개입니다." >&2; exit 2
fi
file="${matches[0]}"

# 리뷰 9차 P1: canonical 경계 — symlink 티켓(외부 파일 연결)은 쓰기 대상이 아니다.
if [ -h "$file" ] || [ ! -f "$file" ]; then
  echo "❌ 티켓이 symlink이거나 regular file이 아닙니다 — 거부 (fail-closed)." >&2
  exit 2
fi
_tdir_real="$(cd "$(dirname "$file")" && pwd -P)"
if [ "$_tdir_real" != "$(pwd -P)/docs/tickets" ]; then
  echo "❌ 티켓 물리 경로가 canonical docs/tickets가 아닙니다 (symlink 디렉터리?) — 거부." >&2
  exit 2
fi

case "$(basename "$file")" in TEMPLATE.md) echo "❌ TEMPLATE은 편집 대상이 아닙니다." >&2; exit 2 ;; esac


# 리뷰 10차 P1: 쓰기 직전 identity 재검증 + same-dir temp + rename.
# - 재검증: 초기 검사 후 파일이 symlink/hardlink로 교체되는 TOCTOU 창 축소
# - rename은 대상 링크 inode 자체를 교체하므로, 그 사이 symlink로 바뀌어도
#   외부 대상 파일은 변조되지 않는다 (cross-device mv의 copy-through 방지 겸용)
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

# 리뷰 15차 P1: 어떤 종료 경로에서도 자기 소유 write lock을 남기지 않는다 —
# publish~감사 커밋 임계구역 도중 실패해도 다음 writer가 대기 없이 진행한다.
trap '[ "$(cat "$_TW_LOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$_TW_LOCK" 2>/dev/null || true' EXIT

# 리뷰 11차 P1: 읽기 시점 identity 고정 — 이후 모든 쓰기는 같은 dev/inode여야 한다.
EXPECT_INO="$(_stat_ino "${file}")"
EXPECT_SHA="$(_sha_of "${file}")"


fm_field() {  # frontmatter 키 1개 읽기
  awk -v k="$1" '
    /^---$/ { fm++; next }
    fm==1 && $1==k":" { sub(/^[^:]+:[ \t]*/, ""); sub(/[ \t]+#.*$/, ""); gsub(/^[ \t]+|[ \t]+$/, ""); print; exit }
  ' "$file"
}

# 하드 가드: open 상태만 편집(실행/승인/머지 의미가 있는 다른 상태는 거부).
status="$(fm_field status || true)"
if [ "$status" != "open" ]; then
  echo "❌ ${id} status='${status}' — open 티켓만 메타 편집할 수 있습니다(실행/승인 게이트 보호)." >&2
  exit 3
fi

# frontmatter의 지정 키 1줄만 awk로 치환(본문·다른 키 무변경). 임시파일·unlink 비의존.
rewrite_key() {
  local key="$1" newline="$2" content
  content=$(awk -v key="$key" -v line="$newline" '
    BEGIN { fm=0; done=0 }
    /^---$/ { fm++; print; next }
    (fm==1 && !done && $1==key":") { print line; done=1; next }
    { print }
    END { if (!done) exit 9 }
  ' "$file") || { echo "❌ 프론트매터에 '${key}' 키가 없습니다." >&2; exit 4; }
  printf '%s\n' "$content" | _safe_write "$file" "docs/tickets" || exit 4
}

commit_edit() {  # 단일 감사 커밋(가역). git 저장소가 아니면 파일만 갱신.
  local msg="$1"
  if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    git add "$file"
    if ! git diff --cached --quiet -- "$file"; then
      git commit -m "$msg" >/dev/null
    fi
  fi
}

case "$action" in
  set-priority)
    case "$value" in
      P0|P1|P2|P3) : ;;
      *) echo "❌ priority는 P0|P1|P2|P3 중 하나여야 합니다 (받음: '${value}')." >&2; exit 2 ;;
    esac
    old="$(fm_field priority || echo '?')"
    # 리뷰 15차 P1: publish와 감사 커밋을 단일 임계구역으로 — lock이 publish 직후
    # 풀리면 사이에 끼어든 다른 writer의 변경까지 이 커밋에 오귀속됐다.
    if ! _acquire_write_lock; then echo "❌ write lock 획득 실패 — 편집하지 않습니다." >&2; exit 4; fi
    rewrite_key priority "priority: ${value}"
    commit_edit "ticket_edit(${id}): priority ${old}→${value}"
    _release_write_lock
    echo "✏️  ${id} priority ${old}→${value} (단일 감사 커밋, git revert 가역)."
    ;;
  set-labels)
    # csv → 안전 토큰만 허용(영숫자·하이픈·언더스코어). YAML 배열로 직렬화.
    IFS=',' read -r -a raw <<< "${value}"
    arr=()
    for t in "${raw[@]}"; do
      t="$(printf '%s' "$t" | tr -d '[:space:]')"
      [ -z "$t" ] && continue
      case "$t" in
        *[!A-Za-z0-9_-]*) echo "❌ 잘못된 라벨 토큰: '${t}' (영숫자·하이픈·언더스코어만)." >&2; exit 2 ;;
      esac
      arr+=("$t")
    done
    yaml='['
    for i in "${!arr[@]}"; do
      [ "$i" -gt 0 ] && yaml+=", "
      yaml+="\"${arr[$i]}\""
    done
    yaml+=']'
    old="$(fm_field labels || echo '?')"
    # 리뷰 15차 P1: publish~감사 커밋 단일 임계구역 (위 set-priority와 동일).
    if ! _acquire_write_lock; then echo "❌ write lock 획득 실패 — 편집하지 않습니다." >&2; exit 4; fi
    rewrite_key labels "labels: ${yaml}"
    commit_edit "ticket_edit(${id}): labels → ${yaml}"
    _release_write_lock
    echo "✏️  ${id} labels → ${yaml} (단일 감사 커밋, git revert 가역)."
    ;;
  *)
    usage; exit 2 ;;
esac
