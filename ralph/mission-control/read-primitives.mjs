// ralph/mission-control/read-primitives.mjs — 공용 읽기 원시(리뷰 M5: 미러 코드 단일화).
//
// server.mjs와 읽기 모델 모듈(autonomy/inbox/trace)에 각각 복제돼 있던 "동치 미러"를
// 한 곳으로 모은다. 한쪽만 수정되어 표시(UI)와 enforcement가 조용히 어긋나는 drift를
// 구조적으로 차단하는 것이 목적이다. 전부 읽기 전용 — 어떤 파일도 쓰지 않는다(file=truth).
//
// 범위(정확 동치인 것만):
//   readLoopMode(root)            — state/loop_mode (ADR-0054)
//   readAutopilotGrant(root)      — state/autopilot_grant (ADR-0056) · expiryHuman 포함(상위집합)
//   sessionStateFromEvents(events)— events.jsonl 마지막 의미 이벤트로 상태 도출
//   parseFailuresLog(file)        — failures.log TSV → {ts,ticket,stage,retry,message}
//   parseTokenUsageLog(file)      — token_usage.log TSV (ADR-0050)
//
// 비범위: parseFrontmatter — server(주석/CRLF/JSON 배열 지원·null 반환)와 inbox(관용
// 파서·{} 반환)는 의도적으로 다른 계약이라 여기서 통일하지 않는다(후속 검토 항목).

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

/** loop 모드(읽기). 'suggest'|'co-pilot'|'autopilot'|null(미설정/불량). ADR-0054. */
export function readLoopMode(root) {
  try {
    const p = join(root, 'state', 'loop_mode');
    if (!existsSync(p)) return null;
    const first = (readFileSync(p, 'utf8').split('\n')[0] || '').trim().toLowerCase();
    if (first === 'suggest') return 'suggest';
    if (first === 'co-pilot' || first === 'copilot') return 'co-pilot';
    if (first === 'autopilot') return 'autopilot';
    return null;
  } catch { return null; }
}

/**
 * autopilot grant(읽기, ADR-0056). 유효(budget>0·미만료)면
 * { budget, minutesLeft, issuedBy, expiryHuman }, 아니면 null — 추정 없음.
 * 표시 전용: orchestrator는 라운드마다 독립 재검증한다.
 */
export function readAutopilotGrant(root) {
  try {
    const p = join(root, 'state', 'autopilot_grant');
    if (!existsSync(p)) return null;
    const fields = {};
    for (const line of readFileSync(p, 'utf8').split('\n')) {
      const m = line.match(/^([a-z_]+)=(.*)$/);
      if (m) fields[m[1]] = m[2];
    }
    const budget = Number(fields.budget);
    const expiryEpoch = Number(fields.expiry_epoch);
    if (!Number.isFinite(budget) || budget <= 0) return null;
    if (!Number.isFinite(expiryEpoch)) return null;
    const minutesLeft = Math.floor((expiryEpoch - Math.floor(Date.now() / 1000)) / 60);
    if (minutesLeft < 0) return null; // expired
    return { budget, minutesLeft, issuedBy: fields.issued_by || '?', expiryHuman: fields.expiry_human || '' };
  } catch { return null; }
}

/**
 * 세션 이벤트 → 상태(순수). 마지막 의미 이벤트가 결정한다:
 * pause→paused · resume→running · failed/idle-exit/abort/timeout/completed→그 상태 · 없음→running.
 */
export function sessionStateFromEvents(events) {
  for (let i = events.length - 1; i >= 0; i -= 1) {
    const action = String((events[i] && events[i].action) || '');
    if (action === 'pause') return 'paused';
    if (action === 'resume') return 'running';
    if (action === 'failed') return 'failed';
    if (action === 'idle-exit') return 'idle-exit';
    if (action === 'abort' || action === 'timeout' || action === 'completed') return action;
  }
  return 'running';
}

/** failures.log TSV(ts, ticket, stage, retry, message…) → 캐노니컬 레코드 배열. 불량 라인 스킵. */
export function parseFailuresLog(file) {
  try {
    if (!existsSync(file)) return [];
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => {
      const p = line.split('\t');
      if (p.length < 5) return null;
      return { ts: p[0], ticket: p[1], stage: p[2], retry: p[3], message: p.slice(4).join('\t') };
    }).filter(Boolean);
  } catch { return []; }
}

/** token_usage.log TSV(ADR-0050: ts, ticket, model, input, output, cache_read, cache_creation). */
export function parseTokenUsageLog(file) {
  try {
    if (!existsSync(file)) return [];
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).map(line => {
      const p = line.split('\t');
      if (p.length < 5) return null;
      return {
        ts: p[0], ticket: p[1], model: p[2],
        input: Number(p[3]) || 0, output: Number(p[4]) || 0,
        cache_read: Number(p[5]) || 0, cache_creation: Number(p[6]) || 0,
      };
    }).filter(Boolean);
  } catch { return []; }
}
