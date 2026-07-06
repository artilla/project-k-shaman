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

// ADR-0174 T267: approve.sh의 section_oneline 정확 미러 — 헤딩 키워드 섹션의 첫 3줄을
// 한 줄로 압축. `## ` 헤딩만 경계(### 등은 무시), 리스트/인용/체크박스 마커·`*#` 제거.
function extractSection(text, kw) {
  const lines = String(text).split('\n');
  let inSec = false;
  const out = [];
  for (const raw of lines) {
    if (/^##\s/.test(raw)) {           // `## ` 헤딩만 섹션 경계
      if (inSec) break;
      inSec = raw.includes(kw);
      continue;
    }
    if (!inSec) continue;
    let line = raw
      .replace(/^[ \t]*[-*>][ \t]*/, '')      // 리스트/인용 마커
      .replace(/^[ \t]*\[[ xX]\][ \t]*/, '')  // 체크박스
      .replace(/[`*#]/g, '')                  // 코드/강조/헤딩 문자
      .replace(/^[ \t]+/, '').replace(/[ \t]+$/, '');
    if (!/\S/.test(line)) continue;
    out.push(line);
  }
  return out.slice(0, 3).join(' ').replace(/ {2,}/g, ' ').replace(/\s+$/, '');
}

// approve.sh의 yaml_escape + cut -c1-400 미러(마커 저장 형태와 동일 변환).
function yamlEscapeCut(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').slice(0, 400);
}

// 승인 마커의 scope_confirmation 값(저장된 escaped 형태) 읽기. 선두 `- ` 허용. 없으면 null.
function markerScopeConfirmation(root, id) {
  try {
    const f = join(root, 'docs', 'approvals', `${id}.md`);
    if (!existsSync(f)) return null;
    const m = readFileSync(f, 'utf8').match(/^\s*-?\s*scope_confirmation:\s*"((?:[^"\\]|\\.)*)"/m);
    return m ? m[1] : null;
  } catch { return null; }
}

// 티켓 본문 텍스트 읽기(id-*.md, tickets/ 또는 DONE/). 없으면 null.
function readTicketText(root, id) {
  for (const dir of [join(root, 'docs', 'tickets'), join(root, 'docs', 'tickets', 'DONE')]) {
    let files = [];
    try { files = readdirSync(dir); } catch { continue; }
    for (const f of files) {
      if (f.startsWith(`${id}-`) && f.endsWith('.md')) {
        try { return readFileSync(join(dir, f), 'utf8'); } catch { return null; }
      }
    }
  }
  return null;
}

// ADR-0174 §3: 승인 마커가 현재 티켓 scope와 불일치하면 stale(내용 기반·정직).
// 측정 불가(구형 마커·TODO 폴백·섹션 없음)는 보수적으로 false(거짓 stale 금지).
function isStaleApproval(root, id) {
  const markerScope = markerScopeConfirmation(root, id);
  if (markerScope == null) return false;                                  // 구형 마커(필드 없음)
  if (/^TODO: confirm exact approved scope/.test(markerScope)) return false; // 추출 불가로 승인됨
  const text = readTicketText(root, id);
  if (text == null) return false;
  const cur = extractSection(text, '변경 범위') || extractSection(text, 'Scope');
  if (!cur) return false;                                                 // 현재 추출 불가 → 보수적 decided
  return yamlEscapeCut(cur) !== markerScope;                              // 불일치 → stale
}

/**
 * 단일 티켓의 결정 상태(읽기 도출). pending|decided|stale|superseded.
 * ADR-0174 T267: awaiting-approval + 마커 있음 + scope 불일치 → stale(이전 사이클 잔여 마커 등).
 */
export function decisionState(root, ticket) {
  const status = (ticket && ticket.status) || 'open';
  const decided = hasApprovalMarker(root, ticket.id);
  if (status === 'awaiting-approval') {
    if (!decided) return 'pending';
    return isStaleApproval(root, ticket.id) ? 'stale' : 'decided';
  }
  return decided ? 'decided' : 'superseded'; // awaiting 이탈: 마커 있으면 승인·이동, 없으면 철회
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
