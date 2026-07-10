#!/usr/bin/env bash
# ticket_body.sh — ADR-0062: freeform, NON-LLM edit of an OPEN ticket's BODY
# (the markdown after the frontmatter). The file is the truth; this script is the
# writer (CLI parity). Mission Control pipes the proposed body to this script's
# STDIN via the localhost-only `ticket_body` exec command (T099) — the server
# never writes the source itself.
#
#   ticket_body.sh set <TXXX>      # new body on stdin
#   ./scripts/ticket_body.sh set T123 < newbody.md   # CLI parity
#
# HARD GUARD — replaces ONLY the body. The frontmatter block (---…---), and thus
# every execution-gating field (safe/status/id/depends_on), is preserved byte for
# byte. Only OPEN tickets; DONE / approval markers / TEMPLATE are refused. Body is
# rendered escape-first (ADR-0042) so it is data, never executed. NUL rejected,
# 16KB cap.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
MAX_BYTES=16384

usage() { echo "usage: ticket_body.sh set <TXXX>   (new body on stdin)" >&2; }

action="${1:-}"; id="${2:-}"
[ "$action" = "set" ] || { usage; exit 2; }
case "$id" in
  T[0-9][0-9][0-9]*) : ;;
  *) echo "❌ 잘못된 티켓 id: '${id}' (형식 TXXX)" >&2; exit 2 ;;
esac

shopt -s nullglob
matches=( docs/tickets/"${id}"-*.md )
if [ "${#matches[@]}" -eq 0 ]; then
  echo "❌ open 티켓을 찾을 수 없습니다: ${id} (DONE·승인 마커는 본문 편집 대상이 아닙니다)" >&2
  exit 2
fi
if [ "${#matches[@]}" -gt 1 ]; then
  echo "❌ ${id}에 매칭되는 티켓이 여러 개입니다." >&2; exit 2
fi
file="${matches[0]}"
case "$(basename "$file")" in TEMPLATE.md) echo "❌ TEMPLATE은 편집 대상이 아닙니다." >&2; exit 2 ;; esac

# 리뷰 8차 P1: canonical 경계 — symlink 티켓(외부 파일로 연결)은 편집 대상이 아니다.
# git status에 안 잡히는 저장소 밖 대상 변경을 차단한다.
if [ -h "$file" ] || [ ! -f "$file" ]; then
  echo "❌ ${id} 티켓이 symlink이거나 regular file이 아닙니다 — 편집 거부 (fail-closed)." >&2
  exit 2
fi
_tdir_real="$(cd "$(dirname "$file")" && pwd -P)"
if [ "$_tdir_real" != "$(pwd -P)/docs/tickets" ]; then
  echo "❌ 티켓 물리 경로가 canonical docs/tickets가 아닙니다 (symlink 디렉터리?) — 편집 거부." >&2
  exit 2
fi


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
_safe_write() {  # stdin → $1 (same-dir temp + rename), $2=canonical 상대 디렉터리
  local f="$1" want_dir="$2" tmp perm
  tmp=$(mktemp "${want_dir}/.write.XXXXXX") || return 1
  # 리뷰 11차 P1: 입력 복사 실패(부분 출력)를 성공으로 넘기지 않는다.
  if ! cat > "$tmp"; then
    rm -f "$tmp"
    echo "❌ 임시 파일 쓰기 실패 — 원본 무변조 유지" >&2
    return 1
  fi
  if ! _write_guard "$f" "$want_dir"; then rm -f "$tmp"; return 1; fi
  # 리뷰 11차 P2 + 12차 P2: mode 보존 실패도 publish 중단 (조용한 0600 고정 방지).
  perm="$(stat -c '%a' "$f" 2>/dev/null || stat -f '%Lp' "$f" 2>/dev/null || true)"
  if [ -n "$perm" ] && ! chmod "$perm" "$tmp" 2>/dev/null; then
    rm -f "$tmp"
    echo "❌ mode 보존 실패 — publish 중단" >&2
    return 1
  fi
  # 리뷰 12차 P2: mv 실패 시 임시 파일을 남기지 않는다.
  if ! mv -f "$tmp" "$f"; then
    rm -f "$tmp"
    echo "❌ rename 실패 — 원본 무변조 유지" >&2
    return 1
  fi
}

# 리뷰 11차 P1: 읽기 시점 identity 고정 — 이후 모든 쓰기는 같은 dev/inode여야 한다.
EXPECT_INO="$(_stat_ino "${file}")"
EXPECT_SHA="$(_sha_of "${file}")"


# 하드 가드: open 상태만.
status="$(awk '/^---$/{fm++;next} fm==1 && $1=="status:"{sub(/^[^:]+:[ \t]*/,"");sub(/[ \t]+#.*$/,"");gsub(/^[ \t]+|[ \t]+$/,"");print;exit}' "$file")"
if [ "$status" != "open" ]; then
  echo "❌ ${id} status='${status}' — open 티켓만 본문 편집할 수 있습니다(실행/승인 게이트 보호)." >&2
  exit 3
fi

# 프론트매터 블록의 끝(2번째 ---) 라인 번호. 없으면 거부(프론트매터 무결성).
fm_end="$(awk '/^---$/{c++; if(c==2){print NR; exit}}' "$file")"
[ -n "$fm_end" ] || { echo "❌ ${id}에 닫힌 프론트매터 블록(---…---)이 없습니다." >&2; exit 4; }

# stdin → temp (바이트 보존). temp은 일반 tmpfs(마운트 제약 무관).
tmp="$(mktemp "${TMPDIR:-/tmp}/ralph-body.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
cat > "$tmp"

sz=$(wc -c < "$tmp" | tr -d ' ')
if [ "$sz" -gt "$MAX_BYTES" ]; then
  echo "❌ 본문이 상한(${MAX_BYTES}B)을 초과합니다 (${sz}B)." >&2; exit 2
fi
# NUL 거부: NUL 제거본과 원본이 다르면 NUL 포함.
if ! tr -d '\000' < "$tmp" | cmp -s - "$tmp"; then
  echo "❌ 본문에 NUL 바이트가 있어 거부합니다." >&2; exit 2
fi

# 프론트매터 블록(1..fm_end) 바이트 보존 + 빈 줄 + 새 본문. in-place 재기록(unlink 비의존).
content="$( head -n "$fm_end" "$file"; printf '\n'; cat "$tmp" )"
printf '%s\n' "$content" | _safe_write "$file" "docs/tickets" || exit 4

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  git add "$file"
  if ! git diff --cached --quiet -- "$file"; then
    git commit -m "ticket_body(${id}): edit body" >/dev/null
  fi
fi
echo "✏️  ${id} 본문 교체 (${sz}B, 프론트매터 보존·단일 감사 커밋·git revert 가역)."
