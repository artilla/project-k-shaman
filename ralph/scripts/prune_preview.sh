#!/usr/bin/env bash
# prune_preview.sh — ADR-0133: READ-ONLY retention preview (NO deletion).
#
# Applies the retention policy (ADR-0132 §2: keep-last-N >= floor, optional
# --older-than) to .vN snapshots and the two append-only state logs, and prints a
# manifest classifying each item as KEEP vs delete-CANDIDATE — plus a deterministic
# manifest sha256 that the (separate, destructive) T216 confirm gate will match.
#
# OBSERVE-ONLY: reads the filesystem and prints. NEVER deletes, writes, runs git,
# creates .bak, or commits. There is NO delete code path and NO --confirm argument.
# Actual deletion is a SEPARATE decision (T216 / ADR-0132 — destructive, gated).
#
#   prune_preview.sh snapshots [--base <doc>] [--keep <N=10>] [--older-than <YYYY-MM-DD>]
#   prune_preview.sh logs [--log <token_rates_history|token_usage>] [--keep-rows <N=1000>] [--older-than <YYYY-MM-DD>]
#
# Path-safety mirrors snapshot_ls.sh: absolute paths, `..`, snapshots themselves,
# tickets, ADRs, sub-paths, symlinks and arbitrary paths are REJECTED.
# Exit 0 on success, 2 on bad argument / rejected path.
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

FLOOR=5            # keep-last-N can never drop below this (ADR-0132 §2 / §5.2)

# --- portable read-only helpers (no writes) ------------------------------------
sha256_stdin() { if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'; else shasum -a 256 | awk '{print $1}'; fi; }
size_of()  { stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null || echo 0; }
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
date_epoch() { date -d "$1" +%s 2>/dev/null || date -j -f "%Y-%m-%d" "$1" +%s 2>/dev/null || echo ''; }

# allowlist parity with snapshot_ls.sh (governing/operational docs + persona skills).
allow_base_doc() {
  case "$1" in
    docs/master-spec.md|ralph/docs/runbook.md) return 0 ;;
    ralph/skills/implementer.md|ralph/skills/planner.md|ralph/skills/reviewer.md|ralph/skills/security-reviewer.md) return 0 ;;
    docs/decisions/*|docs/tickets/*) return 1 ;;
    docs/*.v[0-9]*.md) return 1 ;;
    docs/*/*) return 1 ;;
    docs/*.md) return 0 ;;
  esac
  return 1
}

resolve_base() {
  local doc="$1"
  case "$doc" in
    /*)   echo "❌ 절대 경로는 미리보기 대상이 아닙니다: $doc" >&2; exit 2 ;;
    *..*) echo "❌ 상위 경로(..)는 허용되지 않습니다: $doc" >&2; exit 2 ;;
  esac
  doc="${doc#./}"
  [ -L "$doc" ] && { echo "❌ 심볼릭 링크는 거부됩니다: $doc" >&2; exit 2; }
  allow_base_doc "$doc" || { echo "❌ 허용되지 않은 미리보기 대상: '${doc}' (지배/운영 문서만 — 티켓·ADR·소스·.vN·하위 경로·임의 경로 거부)." >&2; exit 2; }
  printf '%s' "${doc%.md}"
}

# classify one base's .vN snapshots into keep (latest effective_keep) vs candidate.
# Emits TAB lines: "<path>\t<size>" for candidates only (to MANIFEST_TMP via stdout caller).
preview_base() {
  local base="$1" keep="$2" older="$3"
  local f n eff older_epoch=''
  local -a ns=()
  shopt -s nullglob
  for f in "$base".v[0-9]*.md; do
    [ -L "$f" ] && continue                      # never classify a symlink
    n="$(basename "$f" | sed -n 's/.*\.v\([0-9][0-9]*\)\.md$/\1/p')"
    [ -n "$n" ] && ns+=("$n")
  done
  shopt -u nullglob
  local total="${#ns[@]}"
  # effective keep is never below FLOOR (cannot prune more than policy floor allows)
  eff="$keep"; [ "$eff" -lt "$FLOOR" ] && eff="$FLOOR"
  [ -n "$older" ] && older_epoch="$(date_epoch "$older")"
  local kept=0 cand=0 cbytes=0
  if [ "$total" -gt 0 ]; then
    local sorted; sorted="$(printf '%s\n' "${ns[@]}" | sort -n)"
    # the highest-N `eff` snapshots are always KEEP (latest, incl. the newest).
    local keep_floor_n
    keep_floor_n="$(printf '%s\n' "$sorted" | tail -n "$eff" | head -1)"
    local x file mt
    while IFS= read -r x; do
      file="${base}.v${x}.md"
      if [ "$total" -le "$eff" ] || [ "$x" -ge "$keep_floor_n" ]; then
        kept=$((kept+1)); continue              # within latest N → KEEP
      fi
      # older snapshot → candidate, optionally gated by --older-than (AND)
      if [ -n "$older_epoch" ]; then
        mt="$(mtime_of "$file")"
        [ "$mt" -ge "$older_epoch" ] && { kept=$((kept+1)); continue; }
      fi
      local sz; sz="$(size_of "$file")"
      cand=$((cand+1)); cbytes=$((cbytes+sz))
      printf '%s\t%s\n' "$file" "$sz" >>"$MANIFEST_TMP"
    done <<EOF
$sorted
EOF
  fi
  printf '%s · 전체 %d · 보존(keep) %d · 삭제후보(candidate) %d · 후보 %d bytes (floor %d·keep %d)\n' \
    "$base" "$total" "$kept" "$cand" "$cbytes" "$FLOOR" "$eff"
}

preview_log() {
  local name="$1" keep_rows="$2" older="$3"
  local file="state/${name}.log"
  [ -L "$file" ] && { echo "❌ 심볼릭 링크는 거부됩니다: $file" >&2; exit 2; }
  if [ ! -f "$file" ]; then printf 'state/%s.log · (없음)\n' "$name"; return 0; fi
  local rows; rows="$(wc -l <"$file" | tr -d ' ')"
  local cand=0
  if [ "$rows" -gt "$keep_rows" ]; then cand=$((rows-keep_rows)); fi
  # candidate rows = the oldest (head) rows beyond keep_rows; bytes measured, not deleted.
  local cbytes=0
  if [ "$cand" -gt 0 ]; then
    cbytes="$(head -n "$cand" "$file" | wc -c | tr -d ' ')"
    head -n "$cand" "$file" | sed "s#^#${file}:row\t#" >>"$MANIFEST_TMP"
  fi
  printf 'state/%s.log · 전체 %d행 · 보존 %d행 · 삭제후보 %d행 · 후보 %d bytes (keep-rows %d)\n' \
    "$name" "$rows" "$((rows<keep_rows?rows:keep_rows))" "$cand" "$cbytes" "$keep_rows"
}

# --- arg parse (read-only; NO --confirm / --reason / --manifest-sha here) -------
sub="${1:-snapshots}"; shift || true
base=''; keep=10; keep_rows=1000; older=''; logname=''
while [ "$#" -gt 0 ]; do
  case "$1" in
    --base) base="${2:-}"; shift 2 ;;
    --keep) keep="${2:-}"; shift 2 ;;
    --keep-rows) keep_rows="${2:-}"; shift 2 ;;
    --older-than) older="${2:-}"; shift 2 ;;
    --log) logname="${2:-}"; shift 2 ;;
    *) echo "❌ 알 수 없는 인자: $1 (읽기 전용 — 삭제 인자 없음)" >&2; exit 2 ;;
  esac
done
case "$keep" in (*[!0-9]*|'') echo "❌ --keep 정수" >&2; exit 2 ;; esac
case "$keep_rows" in (*[!0-9]*|'') echo "❌ --keep-rows 정수" >&2; exit 2 ;; esac

MANIFEST_TMP="$(mktemp)"; trap 'rm -f "$MANIFEST_TMP"' EXIT   # temp lives outside ROOT; never written into repo

echo "# prune_preview (읽기 전용·삭제 없음·ADR-0133)"
case "$sub" in
  snapshots)
    if [ -n "$base" ]; then
      b="$(resolve_base "$base")"; preview_base "$b" "$keep" "$older"
    else
      shopt -s nullglob; bases=()
      for f in docs/*.v[0-9]*.md ralph/docs/*.v[0-9]*.md ralph/skills/*.v[0-9]*.md; do
        b="$(printf '%s' "$f" | sed -E 's/\.v[0-9]+\.md$//')"
        case "$b" in (docs/*/*) continue ;; esac
        allow_base_doc "${b}.md" && bases+=("$b")
      done
      shopt -u nullglob
      if [ "${#bases[@]}" -eq 0 ]; then echo "스냅샷 없음 (미리보기 비어 있음)."; else
        printf '%s\n' "${bases[@]}" | sort -u | while IFS= read -r b; do preview_base "$b" "$keep" "$older"; done
      fi
    fi
    ;;
  logs)
    if [ -n "$logname" ]; then
      case "$logname" in
        token_rates_history|token_usage) preview_log "$logname" "$keep_rows" "$older" ;;
        *) echo "❌ --log 은 token_rates_history|token_usage 만" >&2; exit 2 ;;
      esac
    else
      preview_log token_rates_history "$keep_rows" "$older"
      preview_log token_usage "$keep_rows" "$older"
    fi
    ;;
  *) echo "❌ 서브커맨드는 snapshots|logs (읽기 전용)" >&2; exit 2 ;;
esac

# deterministic manifest sha256 over the sorted candidate lines (measured facts only).
sha="$(sort "$MANIFEST_TMP" | sha256_stdin)"
printf 'manifest-sha256: %s\n' "$sha"
exit 0
