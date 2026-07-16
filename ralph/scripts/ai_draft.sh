#!/usr/bin/env bash
# ai_draft.sh — ADR-0072/0074: read-only AI draft PROPOSER (NOT a writer).
#
# Proposes a SINGLE-SHOT draft for a specified target and prints it to STDOUT
# ONLY. It never writes files or git. The human reviews the draft and applies it
# via an existing approved write surface (ticket_body / doc_edit). Mission Control
# dispatches this via the localhost-only `ai_draft` exec (T099); the draft is
# rendered escape-first (ADR-0042). This is narrow, single-purpose assistance —
# NOT a chatbot (master-spec §5 Non-goal preserved): no multi-turn, no
# conversation, no general queries. AUTONOMY: the loop/orchestrator/grant NEVER
# call this — it is a human-initiated, read-only action only.
#
#   ai_draft.sh ticket-body <ticket-id>     # ticket body draft → stdout
#   ai_draft.sh doc <doc-key>               # allowlisted doc draft → stdout (ADR-0074)
#
# doc-key is the SAME allowlist as doc_edit (runbook + skills) — master-spec is
# EXCLUDED (its draft is a separate, stronger decision; doc-key cannot name it).
set -euo pipefail

ROOT="${RALPH_ROOT:-$(pwd)}"
cd "$ROOT"

CLAUDE_CMD="${CLAUDE_CMD:-claude}"
CLAUDE_MODEL="${CLAUDE_MODEL:-sonnet}"
# read-only planning mode — the proposer must NOT be able to edit files even if
# the model attempts to. NEVER bypassPermissions here (that is the autonomous
# loop's mode, run_headless). This is the proposer≠writer boundary in the script.
AI_DRAFT_PERMISSION_MODE="${AI_DRAFT_PERMISSION_MODE:-plan}"
TOKEN_TELEMETRY="${RALPH_TOKEN_TELEMETRY:-0}"
USAGE_CAPTURE="$ROOT/ralph/scripts/lib/usage_capture.mjs"

# doc-key → fixed path (allowlist identical to doc_edit.sh). master-spec/tickets/
# ADR/source are NOT included — master-spec draft is a separate decision (ADR-0074).
doc_key_to_path() {
  case "$1" in
    runbook)                 echo "ralph/docs/runbook.md" ;;
    skill:implementer)       echo "ralph/skills/implementer.md" ;;
    skill:planner)           echo "ralph/skills/planner.md" ;;
    skill:reviewer)          echo "ralph/skills/reviewer.md" ;;
    skill:security-reviewer) echo "ralph/skills/security-reviewer.md" ;;
    *) return 1 ;;
  esac
}

target="${1:-}"; arg="${2:-}"
prompt=""
telemetry_id=""

case "$target" in
  ticket-body)
    case "$arg" in
      T[0-9]*) ;;
      *) echo "❌ 유효하지 않은 티켓 id: ${arg}" >&2; exit 2 ;;
    esac
    tf="$(ls docs/tickets/${arg}-*.md docs/tickets/DONE/${arg}-*.md 2>/dev/null | head -1 || true)"
    [ -n "$tf" ] && [ -f "$tf" ] || { echo "❌ 티켓 ${arg} 를 찾을 수 없습니다." >&2; exit 2; }
    title="$(awk '/^title:[ \t]*/{sub(/^title:[ \t]*/,"");print;exit}' "$tf")"
    labels="$(awk '/^labels:[ \t]*/{sub(/^labels:[ \t]*/,"");print;exit}' "$tf")"
    body="$(awk 'BEGIN{f=0} /^---[ \t]*$/{f++; next} f>=2{print}' "$tf")"
    telemetry_id="$arg"
    prompt="$(cat <<EOF
당신은 Ralph Loop 티켓의 본문 초안을 제안하는 보조자입니다.
아래 티켓의 본문(목적·범위·완료 기준) 초안을 한국어 Markdown으로 제안하세요.
규칙: 대화하지 말 것. 인사·설명·메타 발언 없이 초안 본문만 출력할 것.
이것은 제안이며 인간이 검토 후 직접 적용합니다.

제목: ${title}
라벨: ${labels}
현재 본문:
${body}
EOF
)"
    ;;
  doc)
    # ADR-0074: allowlisted operational doc draft. doc-key (NOT a raw path) maps to
    # the doc_edit allowlist; master-spec is excluded (cannot be named — separate verb).
    docfile="$(doc_key_to_path "$arg")" || { echo "❌ 허용되지 않은 doc-key: '${arg}' (master-spec·티켓·ADR·소스·임의 경로는 초안 대상 아님)." >&2; exit 2; }
    [ -f "$docfile" ] || { echo "❌ 대상 문서가 없습니다: $docfile" >&2; exit 2; }
    current="$(cat "$docfile")"
    telemetry_id="doc:${arg}"
    prompt="$(cat <<EOF
당신은 Ralph Loop의 운영 문서 개정 초안을 제안하는 보조자입니다.
아래 문서(${arg})의 개선된 전체 교체 초안을 한국어 Markdown으로 제안하세요.
규칙: 대화하지 말 것. 인사·설명·메타 발언 없이 문서 초안 전체만 출력할 것.
이것은 제안이며 인간이 검토 후 기존 doc_edit 표면으로 직접 적용합니다.

문서 키: ${arg}
현재 내용:
${current}
EOF
)"
    ;;
  master-spec)
    # ADR-0076: master-spec draft — a SEPARATE verb (NOT a doc-key, so the doc
    # target can never name master-spec). Read-only proposer: the §4 carve-out
    # governs EDITING (spec_edit), not this read-only proposal. The human applies
    # the draft via spec_edit's strong gate (reason + vN snapshot + strong confirm).
    specfile="docs/master-spec.md"
    [ -f "$specfile" ] || { echo "❌ 대상 문서가 없습니다: $specfile" >&2; exit 2; }
    current="$(cat "$specfile")"
    telemetry_id="doc:master-spec"
    prompt="$(cat <<EOF
당신은 Ralph Loop의 지배 문서(master-spec) 개정 초안을 제안하는 보조자입니다.
아래 master-spec의 개선된 전체 교체 초안을 한국어 Markdown으로 제안하세요.
규칙: 대화하지 말 것. 인사·설명·메타 발언 없이 문서 초안 전체만 출력할 것.
이것은 제안이며, 인간이 검토 후 spec_edit 강한 게이트(사유·버전 스냅샷·2차 확인)로
직접 적용합니다. 지배 문서이므로 보수적이고 정확하게 제안하세요.

현재 내용:
${current}
EOF
)"
    ;;
  interview)
    # ADR-0078: bounded multi-turn interview. The accumulated transcript arrives on
    # STDIN; <turn> selects the prompt. turn < cap → ask ONE clarifying question;
    # turn >= cap → produce the final ticket draft. Single-purpose (requirement
    # gathering → ticket draft) — NOT a chatbot: no general queries, no memory
    # beyond the transcript passed in. Read-only proposer (STDOUT only, no writes).
    # The turn cap is ALSO enforced server-side (server is authoritative).
    INTERVIEW_MAX_TURNS="${INTERVIEW_MAX_TURNS:-3}"
    case "$arg" in
      ''|*[!0-9]*) echo "❌ interview turn은 정수여야 합니다: '${arg}'" >&2; exit 2 ;;
    esac
    [ "$arg" -ge 1 ] && [ "$arg" -le "$INTERVIEW_MAX_TURNS" ] || { echo "❌ interview turn은 1..${INTERVIEW_MAX_TURNS} 범위여야 합니다 (받음: ${arg})." >&2; exit 2; }
    transcript="$(cat)"   # bounded transcript on stdin (server validates size)
    telemetry_id="interview"
    if [ "$arg" -lt "$INTERVIEW_MAX_TURNS" ]; then
      prompt="$(cat <<EOF
당신은 Ralph Loop 티켓의 요구사항을 수집하는 인터뷰 보조자입니다.
목적은 오직 하나 — 티켓(목적·범위·완료 기준)을 명확히 하기 위한 요구 수집입니다.
아래 지금까지의 대화를 보고, 요구사항을 구체화할 **명확화 질문 1개만** 한국어로 출력하세요.
규칙: 범용 대화·잡담·일반 질의에 응하지 말 것. 질문 1개만 출력(설명·인사 없이).
현재 턴: ${arg} / ${INTERVIEW_MAX_TURNS}.

지금까지의 대화:
${transcript}
EOF
)"
    else
      prompt="$(cat <<EOF
당신은 Ralph Loop 티켓의 요구사항을 수집하는 인터뷰 보조자입니다.
이번이 마지막 턴(${arg}/${INTERVIEW_MAX_TURNS})입니다. 더 질문하지 말고, 아래 대화에서
모은 요구사항으로 **최종 티켓 본문 초안**(목적·범위·완료 기준)을 한국어 Markdown으로
출력하세요. 규칙: 대화·메타 발언 없이 티켓 초안 본문만 출력.
이것은 제안이며 인간이 검토 후 기존 new_ticket 표면으로 직접 생성합니다.

지금까지의 대화:
${transcript}
EOF
)"
    fi
    ;;
  *)
    echo "usage: ai_draft.sh ticket-body <ticket-id> | doc <doc-key> | master-spec | interview <turn>" >&2; exit 2 ;;
esac

# read-only invocation, draft to STDOUT only (no file/git writes). usage attributed
# to telemetry_id (ticket id, or doc:<key> for doc drafts).
if [ "$TOKEN_TELEMETRY" = "1" ] && [ -f "$USAGE_CAPTURE" ]; then
  mkdir -p state 2>/dev/null || true
  printf '%s' "$prompt" | "$CLAUDE_CMD" -p --permission-mode "$AI_DRAFT_PERMISSION_MODE" --model "$CLAUDE_MODEL" --output-format stream-json --verbose \
    | node "$USAGE_CAPTURE" "state/token_usage.log" "$telemetry_id" "$CLAUDE_MODEL"
else
  printf '%s' "$prompt" | "$CLAUDE_CMD" -p --permission-mode "$AI_DRAFT_PERMISSION_MODE" --model "$CLAUDE_MODEL"
fi
