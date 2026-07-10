// mission-control/inbox.mjs
// ADR-0170 T264 P2-Inbox-b: HITL 결정 계약 + 상태 읽기 모델 (읽기 전용 · file=truth · 신규 writer/exec 0).
//
// 대기 승인 항목의 허용 결정(allowedDecisions)과 상태(state)를 기존 파일에서 도출한다.
// 실행 배선(edit/respond)·정책 판정·만료 쓰기는 비범위(§0) — 본 모듈은 *읽어서 분류*만 한다.
//
//   allowedDecisions — v1: 위험 exec 승인은 [approve, reject]. ADR-0172 T265: 대응되는
//                      세션이 live(paused/running)면 respond 추가(기존 session_ctl redirect 대상).
//                      edit는 계약 예약(미배선, ADR-0172 §0-1).
//   state            — pending(대기·마커 없음) | decided(승인 마커 존재) | superseded(awaiting 이탈·마커 없음).
//                      stale(만료)은 만료 데이터 소스 부재로 v1 도출 불가 — 계약 예약.

import { readFileSync, existsSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
// 리뷰 M5: 세션 상태 도출은 공용 원시 단일 소스(server.mjs 미러 복제 제거).
import { sessionStateFromEvents } from './read-primitives.mjs';
// 리뷰 2차 P1-7: 승인 마커 판정 단일 소스 — 실행기(run_loop.sh)와 공유.
import { validateApproval } from './approval.mjs';

// v1 허용 결정 집합. edit는 후속 ADR(P2-Inbox-edit)에서 추가.
export const ALLOWED_DECISIONS_V1 = ['approve', 'reject'];

// ADR-0172 T265: live 세션 상태(redirect 수용 가능). terminal 상태는 respond 불가.
// session_ctl redirect는 abort+재디스패치라 살아있는 세션에만 의미가 있다.
const RESPONDABLE_SESSION_STATES = new Set(['paused', 'running']);

// 참고(리뷰 M5 비범위): server.mjs의 parseFrontmatter는 주석/CRLF/JSON 배열을 지원하는
// 더 엄격한 파서다. 이 관용 파서는 Inbox 표시용 최소 필드만 읽는다 — 의도적 비통일.
// 파싱 규칙 변경 시 양쪽 영향을 함께 검토할 것.
function parseFrontmatter(text) {
  const fm = {};
  const m = text.match(/^---\n([\s\S]*?)\n---/);
  if (!m) return fm;
  for (const line of m[1].split('\n')) {
    const mm = line.match(/^([A-Za-z0-9_]+):\s*(.*)$/);
    if (!mm) continue;
    let v = mm[2].trim();
    if (/^\[.*\]$/.test(v)) {
      v = v.slice(1, -1).split(',').map(s => s.trim().replace(/^["']|["']$/g, '')).filter(Boolean);
    } else {
      v = v.replace(/^["']|["']$/g, '');
      if (v === 'true') v = true; else if (v === 'false') v = false;
    }
    fm[mm[1]] = v;
  }
  return fm;
}

function readTickets(root) {
  const out = [];
  for (const dir of [join(root, 'docs', 'tickets'), join(root, 'docs', 'tickets', 'DONE')]) {
    let files = [];
    try { files = readdirSync(dir); } catch { continue; }
    const done = dir.endsWith('DONE');
    for (const f of files) {
      if (!/\.md$/.test(f)) continue;
      let fm;
      try { fm = parseFrontmatter(readFileSync(join(dir, f), 'utf8')); } catch { continue; }
      if (!fm.id) continue;
      out.push({
        id: String(fm.id), title: fm.title || '', persona: fm.persona || '',
        safe: fm.safe === true, labels: Array.isArray(fm.labels) ? fm.labels : [],
        status: done ? 'done' : String(fm.status || 'open'),
      });
    }
  }
  return out;
}

function hasApprovalMarker(root, id) {
  try {
    const f = join(root, 'docs', 'approvals', `${id}.md`);
    if (!existsSync(f)) return false;
    // 리뷰 M8: 라인 선두 앵커(선두 `- ` 허용 — markerScopeConfirmation과 동일 계약) —
    // 본문 서술 중간의 `... approved_at: ...` 오탐 방지.
    return /^\s*-?\s*approved_at:\s*"?[^"\n]+/m.test(readFileSync(f, 'utf8'));
  } catch { return false; }
}

/**
 * 티켓에 대응하는 세션 상태(읽기). state/reservations/<id>.d/events.jsonl에서 도출.
 * 예약 디렉터리가 없으면 null(세션 없음 → respond 불가). 읽기 전용.
 */
export function sessionStateForTicket(root, id) {
  if (!/^T[0-9]{3,}$/.test(String(id))) return null;
  const dir = join(root, 'state', 'reservations', `${id}.d`);
  if (!existsSync(dir)) return null;
  let events = [];
  try {
    const raw = readFileSync(join(dir, 'events.jsonl'), 'utf8');
    events = raw.split('\n').filter(Boolean).map(line => {
      try { return JSON.parse(line); } catch { return { action: 'parse-error' }; }
    });
  } catch { /* events.jsonl 없을 수 있음 — 빈 이벤트면 기본 running */ }
  return sessionStateFromEvents(events);
}

/**
 * ADR-0172 T265: 세션 상태별 추가 허용 결정(순수). live(paused/running)면 [respond], 아니면 [].
 * null/terminal/미지 상태는 [] — 정직(살아있지 않은 세션엔 respond를 제안하지 않는다).
 */
export function respondableDecisions(sessionState) {
  return RESPONDABLE_SESSION_STATES.has(String(sessionState)) ? ['respond'] : [];
}

/**
 * 단일 티켓의 결정 상태(읽기 도출). pending|decided|stale|superseded.
 * ADR-0174 T267: awaiting-approval + 마커 있음 + scope 불일치 → stale(이전 사이클 잔여 마커 등).
 *
 * 리뷰 2차 P1-7: 판정은 approval.mjs validateApproval 단일 소스 — 실행기
 * (run_loop.sh validate_safe_false_approval)와 동일한 검증기다. malformed 마커는
 * 실행기가 거부하므로 UI도 'decided'가 아니라 'pending'으로 정직하게 표시한다.
 */
export function decisionState(root, ticket) {
  const status = (ticket && ticket.status) || 'open';
  if (status === 'awaiting-approval') {
    const v = validateApproval(root, ticket.id);
    if (v.state === 'ok') return 'decided';
    // 리뷰 3차 P1: unverifiable(TODO scope·섹션 부재·티켓 읽기 실패)도 실행기가 거부하는
    // 재승인 대상 — UI에서는 stale과 동일하게 조치 필요로 표시한다.
    if (v.state === 'stale' || v.state === 'unverifiable') return 'stale';
    return 'pending'; // missing·malformed — 실행기 기준 아직 유효한 결정이 없다
  }
  // awaiting 이탈: 마커 있으면 승인·이동, 없으면 철회. 여기서는 이력 존재만 본다.
  return hasApprovalMarker(root, ticket.id) ? 'decided' : 'superseded';
}

/**
 * 대기 승인 큐 — 항목별 allowedDecisions + state (읽기 전용).
 * ADR-0172 T265: 대응 세션이 live면 allowedDecisions에 respond를 더한다(approve/reject는 항상 보존).
 */
export function listPending(root) {
  return readTickets(root)
    .filter(t => t.status === 'awaiting-approval')
    .map(t => ({
      id: t.id, title: t.title, persona: t.persona, safe: t.safe,
      allowedDecisions: ALLOWED_DECISIONS_V1.concat(respondableDecisions(sessionStateForTicket(root, t.id))),
      state: decisionState(root, t),
    }))
    // 리뷰 M2: numeric 비교 — 사전순은 T1000 < T999로 4자리 전환 시 순서가 깨진다.
    .sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
}
