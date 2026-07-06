// mission-control/trace.mjs
// ADR-0166 P2-Trace: 파일 기반 trace projection (읽기 전용 · file=truth · 신규 writer/exec 0).
//
// 기존 산출물을 canonical run/span 읽기 모델로 투영한다(§2/§3). 서버를 import하지 않는
// 자립 모듈 — root를 받아 파일을 직접 읽으므로 픽스처로 단위 테스트 가능. 어떤 파일도 쓰지 않는다.
//
//   run  = Ralph 라운드(= 티켓 1회 처리). runId = ticket(v1; 다회 처리 분리는 후속).
//   span = run 자식. type ∈ lifecycle | model | failure | decision (+ 예약: tool/guardrail/handoff/custom).

import { readFileSync, existsSync, readdirSync, statSync } from 'node:fs';
import { join } from 'node:path';
// 리뷰 M5: 세션 상태·failures·token_usage 파서는 공용 원시 단일 소스(미러 복제 제거).
import { sessionStateFromEvents, parseFailuresLog, parseTokenUsageLog } from './read-primitives.mjs';

// ── 작은 파서(읽기 전용) ────────────────────────────────────────────────
function readKeyValueFile(file) {
  const out = {};
  try {
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const m = line.match(/^([A-Za-z0-9_]+)\s*[:=]\s*(.*)$/);
      if (m) out[m[1]] = m[2].trim();
    }
  } catch { /* missing/unreadable → {} */ }
  return out;
}

function parseEvents(file) {
  try {
    if (!existsSync(file)) return [];
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => {
      try { return JSON.parse(line); }
      catch { return { ts: '', actor: 'system', action: 'parse-error', detail: line }; }
    });
  } catch { return []; }
}

const sessionState = sessionStateFromEvents;
const parseFailures = root => parseFailuresLog(join(root, 'state', 'failures.log'));
const parseTokenUsage = root => parseTokenUsageLog(join(root, 'state', 'token_usage.log'));

function parseApprovals(root) {
  const dir = join(root, 'docs', 'approvals');
  try {
    if (!existsSync(dir)) return [];
    return readdirSync(dir).filter(f => /^T[0-9]+\.md$/.test(f)).map(f => {
      const id = f.replace(/\.md$/, '');
      let approvedAt = '';
      try {
        // 리뷰 M8: 라인 선두 앵커(선두 `- ` 허용) — 본문 서술 중간의 `approved_at:` 오탐 방지.
        const m = readFileSync(join(dir, f), 'utf8').match(/^\s*-?\s*approved_at:\s*"?([^"\n]+)"?/m);
        approvedAt = m ? m[1].trim() : '';
      } catch { /* ignore */ }
      return { id, approvedAt };
    });
  } catch { return []; }
}

function collectReservations(root) {
  const dir = join(root, 'state', 'reservations');
  const out = {};
  try {
    if (!existsSync(dir)) return out;
    for (const entry of readdirSync(dir)) {
      if (!entry.endsWith('.d')) continue;
      const id = entry.slice(0, -2);
      if (!/^T[0-9]{3,}$/.test(id)) continue;
      const d = join(dir, entry);
      out[id] = { meta: readKeyValueFile(join(d, 'meta')), events: parseEvents(join(d, 'events.jsonl')) };
    }
  } catch { /* directory may disappear */ }
  return out;
}

// ── run/span 빌더 ──────────────────────────────────────────────────────
const spanIdFor = (runId, type, i) => `${runId}:${type}:${i}`;

function buildRun(ticket, src) {
  const res = src.reservations[ticket] || null;
  const meta = res ? res.meta : {};
  const spans = [];

  if (res) {
    res.events.forEach((e, i) => spans.push({
      spanId: spanIdFor(ticket, 'lifecycle', i), runId: ticket, type: 'lifecycle',
      name: String((e || {}).action || 'event'), ts: String((e || {}).ts || ''), durationMs: null,
      status: (e || {}).action === 'failed' ? 'err' : 'info',
      attrs: { actor: (e || {}).actor || '', detail: (e || {}).detail || '' },
    }));
  }
  src.tokens.filter(t => t.ticket === ticket).forEach((t, i) => spans.push({
    spanId: spanIdFor(ticket, 'model', i), runId: ticket, type: 'model',
    name: t.model || 'model', ts: String(t.ts || ''), durationMs: null, status: 'ok',
    attrs: { model: t.model, input: t.input, output: t.output, cacheRead: t.cache_read, cacheCreation: t.cache_creation },
  }));
  src.failures.filter(f => f.ticket === ticket).forEach((f, i) => spans.push({
    spanId: spanIdFor(ticket, 'failure', i), runId: ticket, type: 'failure',
    name: f.stage || 'failure', ts: String(f.ts || ''), durationMs: null, status: 'err',
    attrs: { stage: f.stage, retry: f.retry, message: f.message },
  }));
  src.approvals.filter(a => a.id === ticket && a.approvedAt).forEach((a, i) => spans.push({
    spanId: spanIdFor(ticket, 'decision', i), runId: ticket, type: 'decision',
    name: 'approve', ts: String(a.approvedAt || ''), durationMs: null, status: 'ok',
    attrs: { approvedAt: a.approvedAt },
  }));

  spans.sort((a, b) => String(a.ts).localeCompare(String(b.ts)));

  const tsList = spans.map(s => s.ts).filter(Boolean).slice().sort();
  const startedAt = meta.started_at || tsList[0] || null;
  const endedAt = tsList.length ? tsList[tsList.length - 1] : null;

  let state;
  if (res) state = sessionState(res.events);
  else if (spans.some(s => s.type === 'failure')) state = 'failed';
  else state = 'completed'; // 과거 흔적(토큰/승인)만 → 완료 라운드로 표기

  const running = state === 'running' || state === 'paused';
  const hasErr = state === 'failed' || spans.some(s => s.status === 'err');
  const status = running ? 'running' : (hasErr ? 'err' : 'ok');

  let durationMs = null; // 정직: 양 끝이 파싱 가능할 때만(추정 아님)
  if (startedAt && endedAt) {
    const a = Date.parse(startedAt), b = Date.parse(endedAt);
    if (!Number.isNaN(a) && !Number.isNaN(b) && b >= a) durationMs = b - a;
  }

  return {
    runId: ticket, ticket,
    persona: meta.persona || '', mode: meta.mode || '', root: meta.root || '',
    startedAt: startedAt || null, endedAt: endedAt || null,
    state, status, durationMs, spanCount: spans.length, spans,
  };
}

function buildAll(root) {
  const reservations = collectReservations(root);
  const failures = parseFailures(root);
  const tokens = parseTokenUsage(root);
  const approvals = parseApprovals(root).filter(a => a.approvedAt);
  const ids = new Set();
  Object.keys(reservations).forEach(id => ids.add(id));
  failures.forEach(f => ids.add(f.ticket));
  tokens.forEach(t => ids.add(t.ticket));
  approvals.forEach(a => ids.add(a.id));
  const src = { reservations, failures, tokens, approvals };
  const runs = Array.from(ids).map(id => buildRun(id, src));
  runs.sort((a, b) => String(b.startedAt || '').localeCompare(String(a.startedAt || '')));
  return runs;
}

/**
 * 리뷰 M1: 요청-스코프 1회 계산용 — 모든 run(스팬 포함)을 한 번의 파일 스캔으로 반환.
 * listRuns/getRun을 반복 호출하면 호출마다 reservations·failures·token_usage·approvals를
 * 재독하므로, 한 렌더/요청에서 여러 run을 참조할 때는 이 결과를 재사용할 것.
 */
export function collectRuns(root) {
  return buildAll(root);
}

/** collectRuns 결과에서 단일 run 조회(파일 재독 없음). 없으면 null. */
export function runFrom(runs, runId) {
  return (Array.isArray(runs) ? runs : []).find(r => r.runId === runId) || null;
}

/** 모든 run의 요약(스팬 제외, spanCount 포함). 최신순. */
export function listRuns(root) {
  return buildAll(root).map(({ spans, ...summary }) => summary); // eslint-disable-line no-unused-vars
}

/** 단일 run 상세(스팬 포함). 없으면 null. */
export function getRun(root, runId) {
  return buildAll(root).find(r => r.runId === runId) || null;
}
