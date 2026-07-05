#!/usr/bin/env bash
# rate_config.sh — ADR-0080: declaratively set token COST rates by writing
# state/token_rates.json (file = the single source of truth). Same pattern as
# set_mode.sh / state/loop_mode (ADR-0054): a plain gitignored state file, no audit
# commit. Mission Control dispatches this via the localhost-only `rate_config` exec
# (T099); the server never writes the file itself (file=truth, CLI parity).
#
#   rate_config.sh set --in <X> --out <Y> [--cache-read <A>] [--cache-creation <B>]
#                      [--model <name>:<in>:<out>]...
#
# Rates are an ASSUMPTION (config, $/Mtok) — NOT a measurement. The reader labels
# cost as estimated with the rate + source. Token counts (measured) are unaffected.
# ADR-0098: --model adds an opt-in per-model rate (repeatable). flat --in/--out stay
# the default/fallback rate; models without an entry fall back to flat. No --model →
# no "models" key (current flat behavior, no regression).
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"
RATES_FILE="state/token_rates.json"

usage() { echo 'usage: rate_config.sh set --in <X> --out <Y> [--cache-read <A>] [--cache-creation <B>] [--budget <$>] [--model <name>:<in>:<out>[:<cacheRead>[:<cacheCreation>]]]...   ($/Mtok, >=0)' >&2; }

# non-negative finite number (integer or decimal). Rejects negatives, NaN, junk.
is_nonneg_num() {
  case "$1" in
    ''|*[!0-9.]*) return 1 ;;            # only digits and dot
    *.*.*) return 1 ;;                   # at most one dot
  esac
  return 0
}

[ "${1:-}" = "set" ] || { usage; exit 2; }
shift

rin=""; rout=""; rcr=""; rcc=""; rbudget=""
model_specs=""   # newline-separated raw "name:in:out" specs (ADR-0098, Bash-3 safe)
while [ $# -gt 0 ]; do
  case "$1" in
    --in)             rin="${2:-}"; shift ;;
    --out)            rout="${2:-}"; shift ;;
    --cache-read)     rcr="${2:-}"; shift ;;
    --cache-creation) rcc="${2:-}"; shift ;;
    --budget)         rbudget="${2:-}"; shift ;;   # ADR-0090: opt-in cost budget ($)
    --model)          model_specs="${model_specs}${2:-}
"; shift ;;                                          # ADR-0098: opt-in per-model rate (repeatable)
    *) echo "❌ 알 수 없는 인자: $1" >&2; usage; exit 2 ;;
  esac
  shift
done

# in/out required; cache optional. All must be non-negative finite numbers.
[ -n "$rin" ] && [ -n "$rout" ] || { echo "❌ --in 과 --out 은 필수입니다 (\$/Mtok)." >&2; exit 2; }
for pair in "in:$rin" "out:$rout"; do
  k="${pair%%:*}"; v="${pair#*:}"
  is_nonneg_num "$v" || { echo "❌ ${k} 요율은 비음수 숫자여야 합니다 (받음: '${v}')." >&2; exit 2; }
done
[ -z "$rcr" ] || is_nonneg_num "$rcr" || { echo "❌ cache-read 요율은 비음수 숫자여야 합니다 (받음: '${rcr}')." >&2; exit 2; }
[ -z "$rcc" ] || is_nonneg_num "$rcc" || { echo "❌ cache-creation 요율은 비음수 숫자여야 합니다 (받음: '${rcc}')." >&2; exit 2; }
[ -z "$rbudget" ] || is_nonneg_num "$rbudget" || { echo "❌ budget(예산)은 비음수 숫자여야 합니다 (받음: '${rbudget}')." >&2; exit 2; }

# ADR-0098/0102: validate per-model specs and build the "models" JSON object.
#   <name>:<in>:<out>[:<cacheRead>[:<cacheCreation>]]   (3~5 fields; cache opt-in)
# Bash-3 safe: split on ':' (model names carry no ':') with globbing disabled. flat
# --in/--out (and flat cache) remain the default/fallback rate.
models_json=""; model_count=0; models_compact=""
while IFS= read -r spec; do
  [ -n "$spec" ] || continue
  oldifs="$IFS"; IFS=':'; set -f; set -- $spec; set +f; IFS="$oldifs"
  nf=$#
  mname="${1:-}"; min="${2:-}"; mout="${3:-}"; mcr="${4:-}"; mcc="${5:-}"
  case "$nf" in 3|4|5) : ;; *) echo "❌ --model 형식은 <name>:<in>:<out>[:<cacheRead>[:<cacheCreation>]] 입니다 (받음: '${spec}')." >&2; exit 2 ;; esac
  [ -n "$mname" ] || { echo "❌ --model 이름이 비어 있습니다 (받음: '${spec}')." >&2; exit 2; }
  case "$mname" in *'"'*) echo "❌ --model 이름에 \"는 허용되지 않습니다 (받음: '${mname}')." >&2; exit 2 ;; esac
  is_nonneg_num "$min" || { echo "❌ model(${mname}) in 요율은 비음수 숫자여야 합니다 (받음: '${min}')." >&2; exit 2; }
  is_nonneg_num "$mout" || { echo "❌ model(${mname}) out 요율은 비음수 숫자여야 합니다 (받음: '${mout}')." >&2; exit 2; }
  [ -z "$mcr" ] || is_nonneg_num "$mcr" || { echo "❌ model(${mname}) cache_read 요율은 비음수 숫자여야 합니다 (받음: '${mcr}')." >&2; exit 2; }
  [ -z "$mcc" ] || is_nonneg_num "$mcc" || { echo "❌ model(${mname}) cache_creation 요율은 비음수 숫자여야 합니다 (받음: '${mcc}')." >&2; exit 2; }
  [ "$model_count" -gt 0 ] && models_json="${models_json},"
  entry="\"input\": ${min}, \"output\": ${mout}"
  [ -n "$mcr" ] && entry="${entry}, \"cache_read\": ${mcr}"
  [ -n "$mcc" ] && entry="${entry}, \"cache_creation\": ${mcc}"
  models_json="${models_json}
    \"${mname}\": { ${entry} }"
  # ADR-0106: compact per-model form for the history audit column: name=in/out/cr/cc.
  models_compact="${models_compact:+${models_compact};}${mname}=${min}/${mout}/${mcr:--}/${mcc:--}"
  model_count=$((model_count + 1))
done <<EOF
${model_specs}
EOF

mkdir -p state 2>/dev/null || true

# write JSON (file=truth). Plain write — state/ is gitignored operational config.
{
  printf '{\n'
  printf '  "input": %s,\n' "$rin"
  printf '  "output": %s' "$rout"
  [ -n "$rcr" ] && printf ',\n  "cache_read": %s' "$rcr"
  [ -n "$rcc" ] && printf ',\n  "cache_creation": %s' "$rcc"
  [ -n "$rbudget" ] && printf ',\n  "budget": %s' "$rbudget"
  [ "$model_count" -gt 0 ] && printf ',\n  "models": {%s\n  }' "$models_json"
  printf '\n}\n'
} > "$RATES_FILE"

# ADR-0100/0106: append a rate-history audit line (append-only, gitignored state/*.log).
# Best-effort & non-fatal — a history failure must NOT break the rate write above.
# TSV: ts, in, out, cache_read, cache_creation, budget, model_count, per_model ('-' =
# unset). The per_model column (ADR-0106) is compact 'name=in/out/cr/cc;...' so that the
# retro temporal join can apply the rate that was actually in effect, per model.
{
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$rin" "$rout" \
    "${rcr:--}" "${rcc:--}" "${rbudget:--}" "$model_count" "${models_compact:--}" \
    >> "state/token_rates_history.log"
} 2>/dev/null || true

echo "💲 요율 기록 (${RATES_FILE}): in=\$${rin}/out=\$${rout} per Mtok${rcr:+ · cache_read=\$${rcr}}${rcc:+ · cache_creation=\$${rcc}}${rbudget:+ · 예산=\$${rbudget}}$([ "$model_count" -gt 0 ] && printf ' · model 요율 %d개' "$model_count") (구성값·가정). Insights가 파일을 우선 사용합니다. 이력: state/token_rates_history.log"
