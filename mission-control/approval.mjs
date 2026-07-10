// mission-control/approval.mjs
// 리뷰 2차 P1-7: safe:false 승인 마커 검증 단일 소스.
// Inbox(UI, inbox.mjs)와 실행기(scripts/run_loop.sh validate_safe_false_approval)가
// 같은 판정기를 공유한다 — 이전에는 실행기(bash awk)와 UI(mjs)가 서로 다른 검증을 갖고 있어
// UI가 stale로 표시한 승인이 실행기에서는 통과하는 불일치가 있었다.
//
// 상태 계약:
//   missing   — docs/approvals/<id>.md 없음(또는 읽기 실패)
//   malformed — 필수 필드(approved_by/approved_at/scope_confirmation/rollback_plan) 누락·빈 값
//               또는 approved_at ISO8601 형식 위반
//   stale     — 마커의 scope_confirmation이 현재 티켓 §변경 범위/Scope와 불일치
//               (이전 사이클 잔여 마커 등 — 재승인 필요)
//   ok        — 실행 가능
//
// stale 판정은 보수적(ADR-0174 §3): 측정 불가(구형 마커 스코프 형식·TODO 폴백·티켓 섹션 없음·
// 티켓 본문 없음)는 stale로 몰지 않는다 — 거짓 stale 금지.
//
// CLI (run_loop.sh·approve.sh가 호출):
//   node mission-control/approval.mjs <root> <TXXX>
//   stdout: "<state>[ 누락필드...]"   exit: ok=0 / missing=3 / malformed=4 / stale=5 / usage=2

import { readFileSync, existsSync, readdirSync, realpathSync, lstatSync } from 'node:fs';
import { join } from 'node:path';
import { pathToFileURL } from 'node:url';

export const REQUIRED_FIELDS = ['approved_by', 'approved_at', 'scope_confirmation', 'rollback_plan'];

// run_loop.sh(구 bash 검증)와 동일 계약: Z 또는 ±hh:mm 오프셋의 초 단위 ISO8601.
const ISO8601_RE = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(Z|[+-]\d{2}:\d{2})$/;

// ADR-0174 T267: approve.sh section_oneline의 정확 미러 — 헤딩 키워드 섹션의 첫 3줄을
// 한 줄로 압축. `## ` 헤딩만 경계(### 등은 무시), 리스트/인용/체크박스 마커·`*#` 제거.
export function extractSection(text, kw) {
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
    const line = raw
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
export function yamlEscapeCut(s) {
  return String(s).replace(/\\/g, '\\\\').replace(/"/g, '\\"').slice(0, 400);
}

export function markerPath(root, id) {
  return join(root, 'docs', 'approvals', `${id}.md`);
}

// 마커 필드 파싱. 선두 `- ` 허용(리뷰 M8 계약). 따옴표 값은 저장된 escaped 형태 그대로
// 보존한다(scope 비교가 escaped-vs-escaped이므로 unescape 금지). 비따옴표 값은
// bash approval_field와 동일하게 inline `# 주석`을 제거한다.
export function parseMarker(text) {
  const fields = {};
  for (const key of REQUIRED_FIELDS) {
    const re = new RegExp(`^\\s*-?\\s*${key}:\\s*(?:"((?:[^"\\\\]|\\\\.)*)"\\s*$|(.*)$)`, 'm');
    const m = String(text).match(re);
    if (!m) continue;
    fields[key] = m[1] !== undefined
      ? m[1]
      : m[2].replace(/[ \t]+#.*$/, '').trim();
  }
  return fields;
}

// 티켓 본문 읽기(id-*.md — tickets/ 또는 DONE/). 없으면 null.
export function readTicketText(root, id) {
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

/**
 * 승인 마커 종합 판정 — UI/실행기 공용 단일 소스.
 * @returns {{state: 'missing'|'malformed'|'stale'|'ok', missing: string[]}}
 */
export function validateApproval(root, id) {
  const f = markerPath(root, id);
  let text;
  try {
    if (!existsSync(f)) return { state: 'missing', missing: [...REQUIRED_FIELDS] };
    // 리뷰 10차 P1: 승인 artifact 경계 — 마커가 symlink이거나 approvals 디렉터리의
    // 물리 경로가 canonical(root/docs/approvals)이 아니면 승인으로 인정하지 않는다.
    const st = lstatSync(f);
    if (st.isSymbolicLink() || !st.isFile()) {
      return { state: 'unverifiable', missing: [], reason: '승인 마커가 symlink/비정규 파일 — canonical 경계 위반' };
    }
    const dirReal = realpathSync(join(root, 'docs', 'approvals'));
    const wantReal = join(realpathSync(root), 'docs', 'approvals');
    if (dirReal !== wantReal) {
      return { state: 'unverifiable', missing: [], reason: 'docs/approvals 물리 경로가 canonical이 아님 (symlink?)' };
    }
    text = readFileSync(f, 'utf8');
  } catch {
    return { state: 'missing', missing: [...REQUIRED_FIELDS] };
  }

  const fields = parseMarker(text);
  const missing = REQUIRED_FIELDS.filter(k => !fields[k]);
  if (fields.approved_at && !ISO8601_RE.test(fields.approved_at)) missing.push('approved_at(ISO8601)');
  if (missing.length) return { state: 'malformed', missing };

  // stale/unverifiable: 마커 scope_confirmation vs 현재 티켓 §변경 범위/Scope.
  // 리뷰 3차 P1: 측정 불가를 ok로 돌려보내면 Scope 섹션 삭제·헤딩 변경·TODO 마커로
  // stale 검사를 우회할 수 있었다 — 검증 불가는 'unverifiable'로 분리하고 실행기는
  // 거부한다(fail-closed). 사유는 reason에 담는다.
  const markerScope = fields.scope_confirmation;
  if (/^TODO: confirm exact approved scope/.test(markerScope)) {
    return { state: 'unverifiable', missing: [], reason: 'scope_confirmation이 TODO 초안 그대로 — 실제 승인 범위로 채워야 합니다' };
  }
  const ticketText = readTicketText(root, id);
  if (ticketText == null) {
    return { state: 'unverifiable', missing: [], reason: '티켓 본문을 찾거나 읽을 수 없음 — scope 대조 불가' };
  }
  const cur = extractSection(ticketText, '변경 범위') || extractSection(ticketText, 'Scope');
  if (!cur) {
    return { state: 'unverifiable', missing: [], reason: '티켓에 `## 변경 범위`/`## Scope` 섹션이 없음 — scope 대조 불가' };
  }
  if (yamlEscapeCut(cur) !== markerScope) return { state: 'stale', missing: [] };
  return { state: 'ok', missing: [] };
}

// ── CLI ───────────────────────────────────────────────────────────────────────
const CLI_EXIT = { ok: 0, missing: 3, malformed: 4, stale: 5, unverifiable: 6 };

// main-module 판정은 symlink에 안전해야 한다 — macOS의 /var/folders는 /private/var의
// symlink라 pathToFileURL(argv[1])와 import.meta.url이 어긋나고, 그러면 CLI 블록이
// 조용히 건너뛰어 exit 0(=승인)이 된다(fail-open). realpath 양쪽 비교로 방지.
function isMainModule() {
  const entry = process.argv[1];
  if (!entry) return false;
  try {
    if (pathToFileURL(entry).href === import.meta.url) return true;
    return pathToFileURL(realpathSync(entry)).href === import.meta.url;
  } catch {
    return false;
  }
}

if (isMainModule()) {
  const [root, id] = process.argv.slice(2);
  if (!root || !id || !/^T\d+$/.test(id)) {
    console.error('usage: node mission-control/approval.mjs <root> <TXXX>');
    process.exit(2);
  }
  const v = validateApproval(root, id);
  if (v.missing.length) console.log(`${v.state} ${v.missing.join(' ')}`);
  else if (v.reason) console.log(`${v.state} ${v.reason}`);
  else console.log(v.state);
  process.exit(CLI_EXIT[v.state] ?? 2);
}
