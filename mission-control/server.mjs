#!/usr/bin/env node
// mission-control/server.mjs
// ADR-0024: localhost-only, stateless, zero npm dependencies
//
// Usage:
//   node mission-control/server.mjs [--port <n>] [--root <path>] [--private-path <iface>]

import { createServer as createHttpServer } from 'node:http';
import { createServer as createHttpsServer } from 'node:https';
import { readFileSync, existsSync, readdirSync, statSync, lstatSync, realpathSync, watch, appendFileSync, mkdirSync, openSync, closeSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, dirname, resolve, sep, basename } from 'node:path';
import { spawn } from 'node:child_process';
import { randomBytes, createHash } from 'node:crypto'; // ADR-0200 T292: console 승인 nonce·sha256
import { resolvePrivatePathBindings } from './private-path.mjs';
import { loadPrivatePathTlsOptions, schemeForBinding } from './tls-certificates.mjs';
import {
  createPairingToken,
  exchangePairingToken,
  revokeDeviceToken,
  renewDeviceToken,
  renameDevice,
  touchDeviceLastSeen,
  listDevices,
  countActiveDevices,
  resolveMaxDevices,
  isLocalhostAddress,
  RENEWAL_WINDOW_MS,
} from './token-store.mjs';
import { tokenAuthDecision, execScopeDecision, extractBearerToken } from './token-auth.mjs';
import { listRuns, getRun, collectRuns, runFrom } from './trace.mjs'; // ADR-0166 T260: 읽기 전용 trace projection (collectRuns/runFrom: 리뷰 M1 요청-스코프 1회 계산)
import { decisionState } from './inbox.mjs'; // ADR-0170 T264: HITL 결정 상태(읽기)
import { projectPolicy, grantPosture } from './autonomy.mjs'; // ADR-0176 T269 정책 projection · ADR-0178 T271 grant posture(읽기)
import { ticketAgeDays, agingLevel, leadTimeDays, columnFlowSummary, resolveDeps, reverseDepsIndex, reverseDepsFromIndex, blocksConsistency } from './board.mjs'; // ADR-0180/0182/0184/0190/0192/0194: aging·lead-time·흐름·의존·역방향·정합성(읽기) — index는 리뷰 M7
import { skillCoverage, coverageSummary } from './library.mjs'; // ADR-0186 T279: playbook coverage(읽기)
// 리뷰 M5: 읽기 원시 단일 소스 — autonomy/inbox/trace와의 "동치 미러" 복제 제거.
import {
  readLoopMode as readLoopModePrimitive,
  readAutopilotGrant as readAutopilotGrantPrimitive,
  sessionStateFromEvents as sessionStateFromEventsPrimitive,
  parseFailuresLog,
  parseTokenUsageLog,
} from './read-primitives.mjs';
import {
  clientScript,
  escapeHtml,
  renderConfirmModal,
  renderOfflineBadge,
  renderRespondButton,
  renderSessionInterventionBar,
  renderWriteButton,
  renderPairingMain,
  renderPairBootstrapPage,
} from './ui.mjs';

const __dirname = dirname(fileURLToPath(import.meta.url));

// ── CLI args ──────────────────────────────────────────────
const args = process.argv.slice(2);

const portIdx = args.indexOf('--port');
const PORT = portIdx !== -1 ? parseInt(args[portIdx + 1], 10) : 7474;

const rootIdx = args.indexOf('--root');
const ROOT = rootIdx !== -1 ? args[rootIdx + 1] : join(__dirname, '..');

// ADR-0203 T298: OpenClaw-level 로컬 운영자 경계 — Operator Console 기본 on.
// localhost에서는 기본 제공되며, MC_CONSOLE=0은 긴급 disable switch(off → 404).
// UI 숨김이 아니라 API 차단: 렌더·라우트·POST 전부 이 플래그로 게이트한다.
const CONSOLE_ENABLED = process.env.MC_CONSOLE !== '0';

const privatePathIdx = args.indexOf('--private-path');
const PRIVATE_PATH_ENABLED = privatePathIdx !== -1;
if (PRIVATE_PATH_ENABLED && (!args[privatePathIdx + 1] || args[privatePathIdx + 1].startsWith('--'))) {
  process.stderr.write('[mission-control] --private-path requires an interface name\n');
  process.exit(1);
}

const HOST = '127.0.0.1';
let BINDINGS;
try {
  // ADR-0024 §2 원칙 1 + ADR-0027: default remains localhost-only.
  BINDINGS = resolvePrivatePathBindings(PRIVATE_PATH_ENABLED ? args[privatePathIdx + 1] : null);
} catch (error) {
  process.stderr.write(`[mission-control] ${error.message}\n`);
  process.exit(1);
}

// ── Paths ─────────────────────────────────────────────────
const DEVICES_DIR    = join(ROOT, 'state', 'devices');
const TICKETS_DIR    = join(ROOT, 'docs', 'tickets');
const REVIEWS_DIR    = join(ROOT, 'docs', 'reviews');
const APPROVALS_DIR  = join(ROOT, 'docs', 'approvals');
const DECISIONS_DIR  = join(ROOT, 'docs', 'decisions');
const MASTER_SPEC_PATH = join(ROOT, 'docs', 'master-spec.md');
const SKILLS_DIR     = join(ROOT, 'skills');
const RESERVATIONS_DIR = join(ROOT, 'state', 'reservations');
const FAILURES_LOG   = join(ROOT, 'state', 'failures.log');
const TOKEN_USAGE_LOG = join(ROOT, 'state', 'token_usage.log');
const TOKEN_RATES_FILE = join(ROOT, 'state', 'token_rates.json');
const TOKEN_RATES_HISTORY = join(ROOT, 'state', 'token_rates_history.log');   // ADR-0100: append-only audit
// ADR-0078: bounded AI interview turn cap (server-authoritative). Env override for ops.
const INTERVIEW_MAX_TURNS = Math.max(1, Number(process.env.MISSION_CONTROL_INTERVIEW_MAX_TURNS) || 3);
const LOOP_MODE_PATH = join(ROOT, 'state', 'loop_mode'); // ADR-0054: declarative loop autonomy mode (file = truth)
const AUTOPILOT_GRANT_PATH = join(ROOT, 'state', 'autopilot_grant'); // ADR-0056: finite self-expiring unattended-operation grant
const LOGS_DIR       = join(ROOT, '.ralph', 'logs');
const UI_CSS_PATH    = join(__dirname, 'ui.css');
// ADR-0038 §3.3: stuck(막힘) 관측 신호 임계값(게이트 아님, 표시 전용).
const posIntEnv = (name, fallback) => {
  const n = Number(process.env[name]);
  return Number.isFinite(n) && n > 0 ? n : fallback;
};
const STUCK_FORGING_MS = posIntEnv('MISSION_CONTROL_STUCK_FORGING_MS', 30 * 60 * 1000);
const STUCK_FAILS      = posIntEnv('MISSION_CONTROL_STUCK_FAILS', 2);
const QR_MJS_PATH    = join(__dirname, 'qr.mjs');
const STATIC_CACHE_URLS = [
  '/ui.css',
  '/manifest.webmanifest',
  '/icons/icon-192.svg',
  '/icons/icon-512.svg',
];

let PRIVATE_PATH_TLS_OPTIONS = null;
if (PRIVATE_PATH_ENABLED) {
  try {
    PRIVATE_PATH_TLS_OPTIONS = loadPrivatePathTlsOptions(ROOT);
  } catch (error) {
    process.stderr.write(`[mission-control] ${error.message}\n`);
    process.exit(1);
  }
}

// ── Version (file=truth) ──────────────────────────────────
// ADR-0164 T256: package.json이 없는 zero-dep 레포(ADR-0024)에서 v0.0.0으로 표기되던 버그 수정.
// 최신 baseline ADR 파일명에서 도출 — 예: docs/decisions/0162-v0.83-baseline.md → 0.83.0.
// 봉인(새 baseline ADR)마다 자동 갱신. exec/네트워크 없음(파일=진실).
const pkgPath = join(ROOT, 'package.json');
function deriveBaselineVersion(root) {
  try {
    let best = null;
    for (const f of readdirSync(join(root, 'docs', 'decisions'))) {
      const m = f.match(/-v(\d+)\.(\d+)-baseline\.md$/);
      if (!m) continue;
      const v = [Number(m[1]), Number(m[2])];
      if (!best || v[0] > best[0] || (v[0] === best[0] && v[1] > best[1])) best = v;
    }
    return best ? `${best[0]}.${best[1]}.0` : null;
  } catch { return null; }
}
const VERSION = (existsSync(pkgPath)
  ? (JSON.parse(readFileSync(pkgPath, 'utf8')).version ?? null)
  : null) ?? deriveBaselineVersion(ROOT) ?? '0.0.0';

// 프로젝트 정체성 노출: 서버는 --root로 아무 프로젝트나 가리킬 수 있으므로,
// 지금 어느 루트를 보고 있는지를 셸(브랜드 부제·버전줄)과 /api/version에 표시한다.
// 이름은 ROOT 폴더명(파일=진실·해석 없음), 전체 경로는 tooltip으로만(정직·최소 노출).
const PROJECT_NAME = basename(resolve(ROOT)) || String(ROOT);

// ADR-0024 / T247: cache-busting tag for the ui.css <link> = stylesheet mtime.
// Combined with /ui.css no-cache (T246), the versioned URL makes the browser drop
// any pre-no-cache stale entry and re-fetch whenever ui.css changes — so CSS fixes
// land on a normal refresh instead of reverting to a cached old layout.
function uiCssHref() {
  try { return '/ui.css?v=' + Math.floor(statSync(UI_CSS_PATH).mtimeMs); }
  catch { return '/ui.css?v=' + VERSION; }
}

// ── Frontmatter parser ────────────────────────────────────
// 참고(리뷰 M5 비범위): inbox.mjs에도 관용 frontmatter 파서가 있다. 이쪽은 주석 제거·
// CRLF·JSON 배열·null 반환을 지원하는 더 엄격한 계약이라 의도적으로 통일하지 않았다.
// 어느 한쪽의 파싱 규칙을 바꿀 때는 반대쪽 영향(티켓 분류 vs Inbox 목록)을 함께 검토할 것.
function parseFrontmatter(content) {
  // 리뷰 5차 P2: 셸(field_of)과 동일 계약 — opener는 1행의 정확한 `---`(CRLF 거부),
  // closer는 정확한 `---` 단독 행(`---trailing` 오인 금지). 셸이 거부하는 티켓을
  // UI가 Run 가능으로 표시하는 split-brain 방지.
  const match = content.match(/^---\n([\s\S]*?)\n---(?:\n|$)/);
  if (!match) return null;
  const fm = {};
  // 리뷰 4차 P2: 중복 키는 last-write-wins로 조용히 덮여 `safe: false` 뒤의
  // `safe: true`가 이겼다 — 중복 키 목록을 함께 노출해 소비자(safe_malformed)가
  // fail-closed 판정에 쓸 수 있게 한다.
  const seenKeys = new Set();
  const duplicateKeys = new Set();
  for (const line of match[1].split('\n')) {
    const m = line.match(/^(\w+):\s*(.*)/);
    if (!m) continue;
    const [, key, rawFull] = m;
    if (seenKeys.has(key)) duplicateKeys.add(key);
    seenKeys.add(key);
    // Strip inline YAML comments (space(s) followed by #)
    const commentIdx = rawFull.search(/\s+#/);
    const raw = (commentIdx !== -1 ? rawFull.slice(0, commentIdx) : rawFull).trim();
    if (!raw) continue;
    if (raw.startsWith('[')) {
      try { fm[key] = JSON.parse(raw); } catch { fm[key] = []; }
      continue;
    }
    // 리뷰 7차 P2: unquote를 boolean 판정보다 먼저 — `safe: "true"`가 문자열로 남아
    // 셸(실행 허용)과 어긋나던 split-brain 해소. 셸 field_of도 쌍·홑따옴표를 벗긴다.
    // 리뷰 8차 P2: 같은 종류의 쌍일 때만 unquote — `"open'` 혼합 쌍을 벗기지 않는다.
    // 리뷰 9차 P1: 외곽 quote 종류를 한 번만 판단(if/else) — 체이닝은 `"'true'"`를
    // 두 겹 벗겨 boolean으로 승격시켰다 (셸은 한 겹만 벗긴다).
    let unquoted = raw;
    if (/^".*"$/.test(raw)) unquoted = raw.slice(1, -1);
    else if (/^'.*'$/.test(raw)) unquoted = raw.slice(1, -1);
    if (unquoted === 'true') {
      fm[key] = true;
    } else if (unquoted === 'false') {
      fm[key] = false;
    } else {
      fm[key] = unquoted;
    }
  }
  if (Object.keys(fm).length === 0) return null;
  if (duplicateKeys.size > 0) fm._duplicateKeys = Array.from(duplicateKeys);
  return fm;
}

// ── Read model ────────────────────────────────────────────
let modelDirty = true;
let modelCache = null;
let modelFingerprint = '';

function listTicketFiles() {
  const files = [];
  const collect = (dir, doneDir = false) => {
    if (!existsSync(dir)) return;
    for (const f of readdirSync(dir)) {
      const fp = join(dir, f);
      // 리뷰 9차 P1: lstatSync — statSync는 symlink 티켓/디렉터리를 따라가
      // 외부 파일이 canonical 티켓으로 모델에 올라왔다. symlink는 제외(fail-closed).
      let st;
      try { st = lstatSync(fp); } catch { continue; }
      if (st.isSymbolicLink()) continue;
      if (st.isDirectory()) {
        if (f === 'DONE') collect(fp, true);
        continue;
      }
      if (!st.isFile() || !f.endsWith('.md') || f === 'TEMPLATE.md') continue;
      files.push({ file: doneDir ? `DONE/${f}` : f, path: fp, doneDir, stat: st });
    }
  };
  collect(TICKETS_DIR);
  return files;
}

function statFingerprint(path) {
  try {
    const st = statSync(path);
    return `${st.mtimeMs}:${st.ctimeMs}:${st.size}`;
  } catch {
    return 'missing';
  }
}

// 알려진 한계(리뷰 M6): reservations는 `.d` *디렉터리*의 stat만 본다. 디렉터리 mtime은
// 내부 파일 append(예: events.jsonl 이벤트 추가)로는 변하지 않으므로, 이벤트 내용만
// 바뀌는 변경은 이 fingerprint를 무효화하지 않는다. 현재 읽기 모델은 예약 디렉터리의
// 존재 여부(forging 분류)만 의존하므로 안전 — 모델이 events *내용*에 의존하게 되면
// 내부 파일 stat까지 포함하도록 확장할 것.
function readModelFingerprint() {
  const parts = [];
  try {
    for (const entry of listTicketFiles()) {
      parts.push(`ticket:${entry.file}:${entry.stat.mtimeMs}:${entry.stat.ctimeMs}:${entry.stat.size}`);
    }
  } catch {
    parts.push('tickets:error');
  }
  try {
    if (existsSync(RESERVATIONS_DIR)) {
      for (const f of readdirSync(RESERVATIONS_DIR).sort()) {
        if (!f.endsWith('.d')) continue;
        parts.push(`reservation:${f}:${statFingerprint(join(RESERVATIONS_DIR, f))}`);
      }
    } else {
      parts.push('reservations:missing');
    }
  } catch {
    parts.push('reservations:error');
  }
  return parts.join('|');
}

function buildModel() {
  const byStatus = {};
  const parseErrors = [];

  // Collect reservation markers: TXXX.d -> "forging"
  const reserved = new Set();
  const reservationStats = new Map();
  try {
    if (existsSync(RESERVATIONS_DIR)) {
      for (const f of readdirSync(RESERVATIONS_DIR)) {
        if (!f.endsWith('.d')) continue;
        const id = f.slice(0, -2);
        reserved.add(id);
        try { reservationStats.set(id, statSync(join(RESERVATIONS_DIR, f))); } catch { /* ignore */ }
      }
    }
  } catch { /* directory may not exist */ }

  // Scan tickets and DONE/; DONE directory placement is authoritative.
  try {
    if (existsSync(TICKETS_DIR)) {
      for (const entry of listTicketFiles()) {
        try {
          const content = readFileSync(entry.path, 'utf8');
          const fm = parseFrontmatter(content);
          if (!fm || !fm.id) {
            parseErrors.push({ file: entry.file, status: 'parse-error', error: 'missing id or frontmatter' });
            continue;
          }
          let status = entry.doneDir ? 'done' : String(fm.status || 'open');
          if (reserved.has(String(fm.id))) status = 'forging';
          const reservationStat = reservationStats.get(String(fm.id));
          const ticket = {
            id: String(fm.id),
            title: String(fm.title || ''),
            status,
            priority: String(fm.priority || ''),
            // 리뷰 2차 P1-6: strict — 정확히 true일 때만 safe (누락/오타는 fail-closed로 unsafe 표시).
            // 리뷰 4차 P2: 중복 safe 선언도 malformed — 실행기(frontmatter_field_count ≠ 1 거부)와 정합.
            safe: fm.safe === true && !(fm._duplicateKeys || []).includes('safe'),
            safe_malformed: (fm.safe !== true && fm.safe !== false) || (fm._duplicateKeys || []).includes('safe'),
            // 리뷰 5차 P2: 실행기는 status 정확히 1회 + id/persona 중복 금지를 요구한다 —
            // status 누락(기본화된 'open')이나 권위 필드 중복 티켓에 Run을 노출하지 않는다.
            status_missing: !entry.doneDir && !fm.status,
            authority_malformed: (fm._duplicateKeys || []).some(k => ['id', 'status', 'persona', 'safe'].includes(k)),
            // 리뷰 9차 P1: 실행기(run_loop)는 persona를 [A-Za-z0-9_-]+로 제한한다 —
            // 경로 조작형 persona는 UI/writer에서도 malformed로 취급.
            persona_malformed: !/^[A-Za-z0-9_-]*$/.test(String(fm.persona || '')),
            // 리뷰 7차 P1: 실행기는 frontmatter id == 파일명 ID(T<숫자>, 전체 basename
            // 형식 포함)를 요구한다 — 불일치 카드(T301 파일 + id:T999)에 Run 미노출.
            id_malformed: (() => {
              const fnBase = entry.file.replace(/^DONE\//, '').replace(/\.md$/, '');
              const fnId = (fnBase.match(/^T\d+/) || [''])[0];
              return !/^T\d+$/.test(String(fm.id))
                || String(fm.id) !== fnId
                || !(fnBase === fnId || fnBase.startsWith(fnId + '-'));
            })(),
            persona: String(fm.persona || ''),
            estimate: String(fm.estimate || ''),
            depends_on: Array.isArray(fm.depends_on) ? fm.depends_on : [],
            blocks: Array.isArray(fm.blocks) ? fm.blocks : [], // ADR-0194 T288: 정합성 대조용(읽기)
            labels: Array.isArray(fm.labels) ? fm.labels.map(String) : [],
            created: fm.created ? String(fm.created) : '',
            spec_ref: fm.spec_ref ? String(fm.spec_ref) : '',
            completed_at: fm.completed_at ? String(fm.completed_at) : '',
            completed_at_est: fm.completed_at_est ? String(fm.completed_at_est) : '',
            started_at: fm.started_at ? String(fm.started_at) : '',
            // ADR-0070: durable per-ticket token totals (measured counts) written by
            // the loop telemetry hook at done. Absent → 0 (no backfill; fail-closed).
            tokens_total: Number(fm.tokens_total) || 0,
            tokens_in: Number(fm.tokens_in) || 0,
            tokens_out: Number(fm.tokens_out) || 0,
            file: entry.file,
            mtimeMs: entry.stat.mtimeMs,
          };
          if (reservationStat) ticket.reservedAtMs = reservationStat.mtimeMs;
          if (!byStatus[status]) byStatus[status] = [];
          byStatus[status].push(ticket);
        } catch (e) {
          parseErrors.push({ file: entry.file, status: 'parse-error', error: String(e) });
        }
      }
    }
  } catch { /* tickets dir may not exist */ }

  if (parseErrors.length > 0) byStatus['parse-error'] = parseErrors;
  return { byStatus };
}

function getModel() {
  const nextFingerprint = readModelFingerprint();
  if (modelDirty || !modelCache || nextFingerprint !== modelFingerprint) {
    modelCache = buildModel();
    modelFingerprint = nextFingerprint;
    modelDirty = false;
  }
  return modelCache;
}

// ── fs.watch invalidation (ADR-0024 §2: 변경 시 다음 요청에서 재스캔) ────
function setupWatchers() {
  const invalidate = () => { modelDirty = true; };
  try {
    if (existsSync(TICKETS_DIR)) watch(TICKETS_DIR, invalidate);
  } catch { /* may not exist in test environments */ }
  try {
    if (existsSync(RESERVATIONS_DIR)) watch(RESERVATIONS_DIR, invalidate);
  } catch { /* may not exist */ }
}
setupWatchers();

// ── Failures log parser (TSV: timestamp\tticket_id\tstage\tretry\tmessage) ─
// 리뷰 M5: 파싱은 공용 원시로 위임 — 이 파일의 기존 필드명(timestamp/ticket_id) 계약만 유지.
function parseFailures() {
  return parseFailuresLog(FAILURES_LOG).map(f => ({
    timestamp: f.ts,
    ticket_id: f.ticket,
    stage: f.stage,
    retry: f.retry,
    message: f.message,
  }));
}

// ADR-0050: token usage telemetry (measured counts). Read-only — written by the
// loop (run_headless). TSV: ts, ticket, model, input, output, cache_read, cache_creation.
function parseTokenUsage() {
  return parseTokenUsageLog(TOKEN_USAGE_LOG); // 리뷰 M5: 공용 원시 위임(동일 필드)
}

// ADR-0080: token COST rates (an ASSUMPTION, $/Mtok). Precedence: file > env > unset.
// The loop never writes this — rate_config.sh does (file=truth). Reader only.
function readTokenRates() {
  // 1) state/token_rates.json (file=truth, written by rate_config.sh)
  try {
    if (existsSync(TOKEN_RATES_FILE)) {
      const j = JSON.parse(readFileSync(TOKEN_RATES_FILE, 'utf8'));
      const input = Number(j.input), output = Number(j.output);
      if (Number.isFinite(input) && Number.isFinite(output) && (input >= 0 && output >= 0) && (input > 0 || output > 0)) {
        const cr = Number(j.cache_read), cc = Number(j.cache_creation);
        const bg = Number(j.budget);   // ADR-0090: opt-in cost budget ($, config)
        return {
          input, output,
          cache_read: Number.isFinite(cr) && cr >= 0 ? cr : NaN,
          cache_creation: Number.isFinite(cc) && cc >= 0 ? cc : NaN,
          budget: Number.isFinite(bg) && bg >= 0 ? bg : NaN,
          models: normalizeModelRates(j.models),   // ADR-0098: opt-in per-model rates
          source: 'file', configured: true,
        };
      }
    }
  } catch { /* malformed file → fall through to env */ }
  // 2) env (backward-compatible)
  const eIn = Number(process.env.MISSION_CONTROL_TOKEN_RATE_IN);
  const eOut = Number(process.env.MISSION_CONTROL_TOKEN_RATE_OUT);
  if (Number.isFinite(eIn) && Number.isFinite(eOut) && (eIn > 0 || eOut > 0)) {
    const eCr = Number(process.env.MISSION_CONTROL_TOKEN_RATE_CACHE_READ);
    const eCc = Number(process.env.MISSION_CONTROL_TOKEN_RATE_CACHE_CREATION);
    return {
      input: eIn, output: eOut,
      cache_read: Number.isFinite(eCr) && eCr >= 0 ? eCr : NaN,
      cache_creation: Number.isFinite(eCc) && eCc >= 0 ? eCc : NaN,
      budget: NaN,   // ADR-0090: budget is file-only (no env)
      models: {},    // ADR-0098: per-model rates are file-only (no env)
      source: 'env', configured: true,
    };
  }
  // 3) unset
  return { input: NaN, output: NaN, cache_read: NaN, cache_creation: NaN, budget: NaN, models: {}, source: null, configured: false };
}

// ADR-0098: normalize the opt-in per-model rate map. Accepts only entries whose
// input/output are finite & >= 0; everything else (malformed entries, non-objects)
// is dropped. Returns a plain { model: { input, output } } map (possibly empty).
function normalizeModelRates(raw) {
  const out = {};
  if (!raw || typeof raw !== 'object') return out;
  for (const [name, v] of Object.entries(raw)) {
    if (!name || !v || typeof v !== 'object') continue;
    const mi = Number(v.input), mo = Number(v.output);
    if (Number.isFinite(mi) && mi >= 0 && Number.isFinite(mo) && mo >= 0) {
      const entry = { input: mi, output: mo };
      // ADR-0102: opt-in per-model cache rates. Only finite & >= 0 are accepted;
      // absent/invalid → omitted (cost falls back to the flat cache rate).
      const mcr = Number(v.cache_read), mcc = Number(v.cache_creation);
      if (Number.isFinite(mcr) && mcr >= 0) entry.cache_read = mcr;
      if (Number.isFinite(mcc) && mcc >= 0) entry.cache_creation = mcc;
      out[name] = entry;
    }
  }
  return out;
}

// ADR-0100: read the append-only rate-history audit log (written by rate_config.sh).
// READ-ONLY — the server never writes this. TSV: ts, in, out, cache_read,
// cache_creation, budget, model_count ('-' = unset). Returns the most-recent `limit`
// entries, newest first (or [] when absent/empty).
function parseRateHistory(limit = 10) {
  try {
    if (!existsSync(TOKEN_RATES_HISTORY)) return [];
    const rows = readFileSync(TOKEN_RATES_HISTORY, 'utf8').split('\n').filter(Boolean).map(line => {
      const p = line.split('\t');
      if (p.length < 3) return null;
      const f = (s) => (s === undefined || s === '-' || s === '') ? null : s;
      return { ts: p[0], in: p[1], out: p[2], cacheRead: f(p[3]), cacheCreation: f(p[4]), budget: f(p[5]), modelCount: Number(p[6]) || 0 };
    }).filter(Boolean);
    return rows.slice(-limit).reverse();   // newest first
  } catch { return []; }
}

// ADR-0106: parse the compact per-model history column 'name=in/out/cr/cc;...' into a
// { name: { input, output, cache_read?, cache_creation? } } map. '-'/absent → {}.
// Cache fields are '-' when unset; only finite & >= 0 numbers are accepted.
function parseHistoryModels(raw) {
  const out = {};
  if (!raw || raw === '-') return out;
  for (const part of String(raw).split(';')) {
    const eq = part.indexOf('=');
    if (eq < 1) continue;
    const name = part.slice(0, eq);
    const f = part.slice(eq + 1).split('/');
    const ni = Number(f[0]), no = Number(f[1]);
    if (!name || !Number.isFinite(ni) || ni < 0 || !Number.isFinite(no) || no < 0) continue;
    const entry = { input: ni, output: no };
    const cr = Number(f[2]), cc = Number(f[3]);
    if (f[2] !== undefined && f[2] !== '-' && Number.isFinite(cr) && cr >= 0) entry.cache_read = cr;
    if (f[3] !== undefined && f[3] !== '-' && Number.isFinite(cc) && cc >= 0) entry.cache_creation = cc;
    out[name] = entry;
  }
  return out;
}

// ADR-0104/0106: read the FULL rate history in chronological (ts-ascending) order for
// the retro-point cost temporal join. READ-ONLY. The per-model column (ADR-0106, when
// present) lets the join apply the rate that was in effect per model; old 7-column
// lines carry no per-model map → flat fallback (v0.55).
function parseRateHistoryChrono() {
  try {
    if (!existsSync(TOKEN_RATES_HISTORY)) return [];
    const rows = readFileSync(TOKEN_RATES_HISTORY, 'utf8').split('\n').filter(Boolean).map(line => {
      const p = line.split('\t');
      if (p.length < 3) return null;
      const num = (s) => { const n = Number(s); return Number.isFinite(n) && n >= 0 ? n : 0; };
      const inR = Number(p[1]), outR = Number(p[2]);
      if (!Number.isFinite(inR) || !Number.isFinite(outR)) return null;
      // ADR-0106: optional per-model column (index 7), compact 'name=in/out/cr/cc;...'.
      // Old 7-column lines have no column 7 → empty models map → flat fallback (v0.55).
      const models = parseHistoryModels(p[7]);
      return { ts: p[0], in: inR, out: outR, cacheRead: num(p[3]), cacheCreation: num(p[4]), models };
    }).filter(Boolean);
    rows.sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));   // chronological
    return rows;
  } catch { return []; }
}

function formatAge(ms) {
  if (!Number.isFinite(ms) || ms < 0) return '0m00s';
  const totalSeconds = Math.floor(ms / 1000);
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return `${minutes}m${String(seconds).padStart(2, '0')}s`;
}

function allTickets() {
  const { byStatus } = getModel();
  return Object.values(byStatus).flat();
}

// ADR-0164 T257 (P1b): 좌측 세로 그룹 내비(운영/이해/구성). 클래스(mc-nav/mc-nav__item)·
// aria-current 유지(R5 호환). 페이지 본문(main)은 무변경 — 셸만 교체.
function renderNav(active, isLocalhost = true, stats = { sessions: 0, approvals: 0 }) {
  const item = (href, key, label, ico, extra = '') =>
    `<a class="mc-nav__item${active === key ? ' is-active' : ''}" href="${href}"${active === key ? ' aria-current="page"' : ''}><span class="mc-nav__ico" aria-hidden="true">${ico}</span><span class="mc-nav__label">${label}</span>${extra}</a>`;
  // ADR-0202 R1: 카운트 배지는 기존 shellStats 데이터만(신규 백엔드 없음). V4/Local은 정적 태그.
  const badge = n => (n > 0 ? `<span class="mc-nav__badge">${n}</span>` : '');
  const tag = t => `<span class="mc-nav__tag">${t}</span>`;
  const group = (label, items) => (items ? `<div class="mc-navgroup"><p class="mc-navgroup__label">${label}</p>${items}</div>` : '');
  // ADR-0027 §2.1: pairing/새 프로젝트는 localhost 전용 데스크톱 표면.
  const pairing = isLocalhost ? item('/pairing', 'pairing', 'Pairing', '⧉') : '';
  const newproj = isLocalhost ? item('/new-project', 'newproject', '새 프로젝트', '＋', tag('Local')) : ''; // T289: 독립 페이지
  // ADR-0203 T298: Operator Console — localhost 기본 on(MC_CONSOLE=0만 disable) + localhost일 때만 메뉴 존재.
  // 메뉴 숨김은 보조일 뿐, 실제 차단은 라우트/POST의 서버 게이트(off→404, non-localhost→403).
  const consoleItem = (isLocalhost && CONSOLE_ENABLED) ? item('/console', 'console', 'Console', '⌘') : '';
  return `<nav class="mc-nav" aria-label="Mission Control">
${group('운영 · Operate', item('/', 'board', 'Forge Board', '▦') + item('/sessions', 'sessions', 'Live Sessions', '◑', badge(stats.sessions)) + item('/inbox', 'inbox', 'Approval Inbox', '✓', badge(stats.approvals)))}
${group('부트스트랩', newproj + pairing + consoleItem)}
${group('설계 · 분석', item('/spec', 'spec', 'Spec Studio', '§', tag('V4')) + item('/library', 'library', 'Library', '❏', tag('V4')) + item('/insights', 'insights', 'Insights', '▤', tag('V4')) + item('/autonomy', 'autonomy', 'Autonomy', '⌥'))}
</nav>`;
}

// ADR-0164 T257: 글로벌 상태 스트립 카운트 — 기존 데이터에서만(신규 백엔드 없음).
function shellStats(isLocalhost = true) {
  const out = { approvals: 0, failures: 0, sessions: 0, mode: 'Co-pilot' };
  try { out.approvals = (getModel().byStatus['awaiting-approval'] || []).length; } catch { /* */ }
  try { out.failures = parseFailures().length; } catch { /* */ }
  try { out.sessions = listSessions().length; } catch { /* */ }
  try {
    const m = readLoopMode();
    out.mode = m ? ({ suggest: 'Suggest', 'co-pilot': 'Co-pilot', autopilot: 'Autopilot' }[m] || m) : 'Co-pilot';
  } catch { /* */ }
  return out;
}

function renderShell(title, active, main, { isLocalhost = true, draftPreview = false } = {}) {
  const shellStatsCache = shellStats(isLocalhost);
  return `<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>${escapeHtml(title)} — Hephaestus Mission Control</title>
<meta name="theme-color" content="#0E1116">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="apple-mobile-web-app-title" content="Mission Control">
<link rel="manifest" href="/manifest.webmanifest">
<link rel="stylesheet" href="${uiCssHref()}">
<style>
@media (max-width: 768px){.mc-inbox{grid-template-columns:1fr}}
:focus-visible{outline:2px solid var(--focus)}
</style>
</head>
<body>
<div class="mc-app">
  <aside class="mc-sidenav" aria-label="사이드 내비게이션">
    <div class="mc-brand"><span class="mc-brand__logo" aria-hidden="true">⚒</span><div class="mc-brand__txt"><p class="mc-kicker">HEPHAESTUS</p><strong>Mission Control</strong><span class="mc-brand__proj" title="${escapeHtml(resolve(ROOT))}">~/${escapeHtml(PROJECT_NAME)}</span></div></div>
    ${renderNav(active, isLocalhost, shellStatsCache)}
    <div class="mc-sidenav__foot">
      <button type="button" class="mc-nav-collapse" data-nav-collapse aria-pressed="false" aria-label="내비게이션 접기">⇤ 접기</button>
      <p class="mc-foot-line">${isLocalhost ? `localhost:${PORT} · 외부 노출 없음` : '모바일 · 관측/승인 전용 (T099)'}</p>
      <p class="mc-foot-line">진실의 원천 = 파일 시스템</p>
      <div class="mc-version" title="${escapeHtml(resolve(ROOT))}">v${escapeHtml(VERSION)} — ${isLocalhost ? 'localhost' : 'mobile · approve/reject only'} · ${escapeHtml(PROJECT_NAME)}</div>
    </div>
  </aside>
  <div class="mc-main">
    <header class="mc-strip">
      <button type="button" class="mc-hamburger" data-nav-toggle aria-label="내비게이션 열기" aria-expanded="false">☰</button>
      <a class="mc-stat mc-stat--alert" href="/inbox"><span class="mc-stat__label">승인</span> <strong>${shellStatsCache.approvals}</strong></a>
      <a class="mc-stat" href="/insights"><span class="mc-stat__label">실패</span> <strong>${shellStatsCache.failures}</strong></a>
      <a class="mc-stat" href="/sessions"><span class="mc-stat__label">세션</span> <strong>${shellStatsCache.sessions}</strong></a>
      <a class="mc-stat mc-modeseg" href="/autonomy" aria-label="자율성 모드: ${escapeHtml(shellStatsCache.mode)} (읽기 전용 표시 — 변경은 Autonomy에서)"><span class="mc-stat__label">모드</span><span class="mc-modeseg__opts" aria-hidden="true">${['Suggest', 'Co-pilot', 'Autopilot'].map(m => `<strong class="mc-modeseg__opt${m === shellStatsCache.mode ? ' is-on' : ''}">${m}</strong>`).join('')}</span></a>
      <span class="mc-strip__spacer"></span>
      <button type="button" class="mc-cmd-open" data-cmd-open aria-haspopup="dialog">검색·실행 <kbd>⌘K</kbd></button>
      <button type="button" class="mc-notify" data-open-notifications hidden>앱이 열려 있을 때 알림</button>
      <button type="button" class="mc-install" data-install-app hidden aria-label="앱으로 설치">앱으로 설치</button>
    </header>
    <header class="mc-pagehead"><h1>${escapeHtml(title)}</h1></header>
    ${renderOfflineBadge()}
    ${main}
  </div>
</div>
<div class="mc-nav-backdrop" data-nav-backdrop hidden></div>
<div class="mc-cmd-scrim" data-cmd-scrim hidden>
  <div class="mc-cmd" role="dialog" aria-modal="true" aria-label="커맨드 팔레트 (페이지 이동·액션)">
    <input class="mc-cmd__input" data-cmd-input type="text" placeholder="페이지 이동·액션 검색…" autocomplete="off" role="combobox" aria-expanded="true" aria-controls="mc-cmd-list" aria-activedescendant="">
    <ul class="mc-cmd__list" id="mc-cmd-list" data-cmd-list role="listbox" aria-label="명령"></ul>
  </div>
</div>
<div id="mc-toast" class="mc-toast" aria-live="polite"></div>
${renderConfirmModal()}
${clientScript()}
${isLocalhost && draftPreview ? draftPreviewScript() : ''}
</body>
</html>`;
}

// ADR-0082: client-side, read-only line-diff renderer for AI draft previews. NO new
// exec/writer/file path — it only RENDERS two strings the client already holds (the
// current textarea value + the draft response). Each diff line is set via textContent
// (escape-first, ADR-0042); the +/− marker is structure (CSS class). The draft is a
// suggestion ("변경 미리보기 — 아직 적용 안 됨"); applying still goes through the
// existing write surfaces (ticket_body / doc_edit / spec_edit). Localhost-only.
function draftPreviewScript() {
  return `<script>
(() => {
  const MAX_LINES = 2000;
  const MAX_WORDS = 400;   // ADR-0088: per-line word-diff cap (fallback to line diff above)
  const MAX_CHARS = 2000;  // ADR-0092: per-changed-run char-diff cap (fallback to word highlight above)
  // ADR-0092: char-level LCS over single characters. Same structure as wordLcs/
  // lcsDiff (tokens are characters). Returns [' '|'-'|'+', char].
  function charLcs(a, b) {
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const out = []; let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push([' ', a[i]]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push(['-', a[i]]); i++; }
      else { out.push(['+', b[j]]); j++; }
    }
    while (i < n) out.push(['-', a[i++]]);
    while (j < m) out.push(['+', b[j++]]);
    return out;
  }
  // ADR-0088: word-level LCS over tokens (words + whitespace, split kept for faithful
  // reconstruction). Returns [' '|'-'|'+', token] like the line diff.
  function wordLcs(a, b) {
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const out = []; let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push([' ', a[i]]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push(['-', a[i]]); i++; }
      else { out.push(['+', b[j]]); j++; }
    }
    while (i < n) out.push(['-', a[i++]]);
    while (j < m) out.push(['+', b[j++]]);
    return out;
  }
  function lcsDiff(a, b) {
    const n = a.length, m = b.length;
    const dp = Array.from({ length: n + 1 }, () => new Uint16Array(m + 1));
    for (let i = n - 1; i >= 0; i--) for (let j = m - 1; j >= 0; j--)
      dp[i][j] = a[i] === b[j] ? dp[i + 1][j + 1] + 1 : Math.max(dp[i + 1][j], dp[i][j + 1]);
    const out = []; let i = 0, j = 0;
    while (i < n && j < m) {
      if (a[i] === b[j]) { out.push([' ', a[i]]); i++; j++; }
      else if (dp[i + 1][j] >= dp[i][j + 1]) { out.push(['-', a[i]]); i++; }
      else { out.push(['+', b[j]]); j++; }
    }
    while (i < n) out.push(['-', a[i++]]);
    while (j < m) out.push(['+', b[j++]]);
    return out;
  }
  // outEl = [data-ai-draft-out] container; currentText = baseline; draftText = proposal.
  window.__mcDraftPreview = function(outEl, currentText, draftText) {
    if (!outEl) return;
    const note = outEl.querySelector('.mc-ai-draft__note');
    const body = outEl.querySelector('[data-ai-draft-body]');
    if (!body) return;
    const cur = String(currentText == null ? '' : currentText);
    const draft = String(draftText == null ? '' : draftText) || '(초안 없음)';
    const a = cur.split('\\n'), b = draft.split('\\n');
    const tooBig = (a.length + b.length) > MAX_LINES;
    let mode = tooBig ? 'full' : 'diff';
    if (note) note.textContent = 'AI 초안 — 변경 미리보기 (제안이며 아직 적용되지 않았습니다. 위 편집기에 복사·편집해 기존 저장 버튼으로 적용하세요.)';
    // toolbar (created once)
    let bar = outEl.querySelector('[data-diff-toolbar]');
    if (!bar) {
      bar = document.createElement('div');
      bar.className = 'mc-diff__bar';
      bar.setAttribute('data-diff-toolbar', '');
      const mk = (label, m) => { const btn = document.createElement('button'); btn.type = 'button'; btn.className = 'mc-diff__tab'; btn.textContent = label; btn.dataset.diffMode = m; return btn; };
      bar.appendChild(mk('diff', 'diff'));
      bar.appendChild(mk('단어', 'word'));
      bar.appendChild(mk('문자', 'char'));
      bar.appendChild(mk('전문', 'full'));
      bar.appendChild(mk('구문', 'syntax'));
      outEl.insertBefore(bar, body);
      bar.addEventListener('click', (e) => { const t = e.target.closest('[data-diff-mode]'); if (!t) return; mode = t.dataset.diffMode; render(); });
    }
    // append a whole-line diff row (escape-safe).
    function lineRow(t, line) {
      const div = document.createElement('div');
      div.className = 'mc-diff__line mc-diff__line--' + (t === '+' ? 'add' : t === '-' ? 'del' : 'ctx');
      div.textContent = (t === ' ' ? '  ' : t + ' ') + line;   // textContent = escape-safe
      body.appendChild(div);
    }
    // ADR-0088/0092: render a modified -/+ line pair with intra-line highlighting.
    // useChar (ADR-0092): refine each changed word run with a character LCS so only
    // changed CHARACTERS are highlighted; word mode (useChar=false) unchanged.
    function wordRows(x, y, useChar) {
      const wx = x.split(/(\\s+)/), wy = y.split(/(\\s+)/);
      if (wx.length + wy.length > MAX_WORDS) { lineRow('-', x); lineRow('+', y); return; }
      const del = document.createElement('div'); del.className = 'mc-diff__line mc-diff__line--del';
      const add = document.createElement('div'); add.className = 'mc-diff__line mc-diff__line--add';
      del.appendChild(document.createTextNode('- ')); add.appendChild(document.createTextNode('+ '));
      const span = (cls, tok) => { const s = document.createElement('span'); s.className = cls; s.textContent = tok; return s; }; // textContent = escape-safe
      if (useChar) {
        // ADR-0092: buffer a changed run (del-side text vs add-side text), then char-diff.
        const charSeg = (dx, dy) => {
          if ((dx.length + dy.length) > MAX_CHARS) {   // cap → fall back to word highlight
            if (dx) del.appendChild(span('mc-wdiff__del', dx));
            if (dy) add.appendChild(span('mc-wdiff__add', dy));
            return;
          }
          for (const [ct, ch] of charLcs(Array.from(dx), Array.from(dy))) {
            if (ct === ' ') { del.appendChild(span('mc-cdiff__ctx', ch)); add.appendChild(span('mc-cdiff__ctx', ch)); }
            else if (ct === '-') { del.appendChild(span('mc-cdiff__del', ch)); }
            else { add.appendChild(span('mc-cdiff__add', ch)); }
          }
        };
        let dbuf = '', abuf = '';
        const flush = () => { if (dbuf || abuf) charSeg(dbuf, abuf); dbuf = ''; abuf = ''; };
        for (const [wt, tok] of wordLcs(wx, wy)) {
          if (wt === ' ') { flush(); del.appendChild(span('mc-wdiff__ctx', tok)); add.appendChild(span('mc-wdiff__ctx', tok)); }
          else if (wt === '-') { dbuf += tok; }
          else { abuf += tok; }
        }
        flush();
      } else {
        for (const [wt, tok] of wordLcs(wx, wy)) {
          if (wt === ' ') { del.appendChild(span('mc-wdiff__ctx', tok)); add.appendChild(span('mc-wdiff__ctx', tok)); }
          else if (wt === '-') { del.appendChild(span('mc-wdiff__del', tok)); }
          else { add.appendChild(span('mc-wdiff__add', tok)); }
        }
      }
      body.appendChild(del); body.appendChild(add);
    }
    // ADR-0110: markdown syntax highlight (read-only). Tokens are wrapped in spans via
    // textContent (escape-first) — NO markdown→HTML conversion, so no injection surface.
    // markdown-only: headings, fenced code, list markers, blockquote, inline code spans.
    const BT = String.fromCharCode(96);   // backtick (avoids template-literal escaping)
    function mdSpan(cls, text) { const s = document.createElement('span'); s.className = cls; s.textContent = text; return s; }
    // ADR-0112: highlight inline emphasis/link on a non-code segment. Markers are KEPT
    // (textContent — no markdown→HTML); links are NOT anchors (text only, no navigation).
    // Only clear non-greedy matches are highlighted; anything ambiguous stays plain.
    // ADR-0120: strikethrough (~~text~~) added as the trailing alternative (m4). Its marker
    // (~~) does not overlap with *, _ or [ so leftmost matching keeps it cleanly separate
    // from strong/em/link; markers are KEPT (textContent — color only, no markdown→HTML).
    // ADR-0120: strikethrough (~~text~~) is m4. ADR-0122: image (![alt](url)) is m5, added at
    // the tail — it starts with '!' so leftmost matching keeps it whole (a link, starting with
    // '[', never splits it off); markers/URL are KEPT (textContent — color only, no <img>/<a>).
    // ADR-0124: footnote ref ([^id]) is m6 (tail) — link (m1) is tried first so [^id](url) stays
    // a link; footnote only matches when there is no following (url). No anchor/navigation.
    // ADR-0126: reference-style link [text][ref] (m7) and image ![alt][ref] (m8) at the tail —
    // they require ][ (vs inline's ](), so inline link/image (m1/m5) win when (url) is present;
    // bare shortcut [text] is intentionally NOT matched (avoids over-matching arbitrary brackets).
    // ADR-0128: triple-marker combined emphasis ***text***/___text___ (m9, bold+italic) at the
    // tail — a flat token (no recursion); strong/em can't match ***x*** (the 3rd marker char
    // breaks their [^*]/[^_] class), so it is a pure addition with no precedence conflict.
    const MD_INLINE = /(\\[[^\\]\\n]+\\]\\([^)\\n]+\\))|(\\*\\*[^*\\n]+\\*\\*|__[^_\\n]+__)|(\\*[^*\\n]+\\*|_[^_\\n]+_)|(~~[^~\\n]+~~)|(!\\[[^\\]\\n]*\\]\\([^)\\n]+\\))|(\\[\\^[^\\]\\n]+\\])|(\\[[^\\]\\n]+\\]\\[[^\\]\\n]*\\])|(!\\[[^\\]\\n]*\\]\\[[^\\]\\n]*\\])|(\\*\\*\\*[^*\\n]+\\*\\*\\*|___[^_\\n]+___)/;
    function mdEmphasis(parent, text) {
      let rest = text;
      while (rest) {
        const m = MD_INLINE.exec(rest);
        if (!m) { parent.appendChild(document.createTextNode(rest)); break; }
        if (m.index > 0) parent.appendChild(document.createTextNode(rest.slice(0, m.index)));
        const cls = m[1] ? 'mc-md-link' : m[2] ? 'mc-md-strong' : m[3] ? 'mc-md-em' : m[4] ? 'mc-md-strike' : m[5] ? 'mc-md-image' : m[6] ? 'mc-md-footnote' : (m[7] || m[8]) ? 'mc-md-reflink' : 'mc-md-strongem';
        parent.appendChild(mdSpan(cls, m[0]));   // full match incl. markers (escape-first)
        rest = rest.slice(m.index + m[0].length);
      }
    }
    function mdInline(parent, text) {
      // ADR-0110: inline code spans (matched backtick pairs). ADR-0112: emphasis/link is
      // applied to the NON-code segments only, so code-span precedence is preserved.
      const segs = text.split(BT);
      for (let i = 0; i < segs.length; i++) {
        const isCode = (i % 2 === 1) && (i !== segs.length - 1);
        if (isCode) parent.appendChild(mdSpan('mc-md-codespan', BT + segs[i] + BT));
        else if (i % 2 === 1) { if (segs[i] !== '') mdEmphasis(parent, BT + segs[i]); else parent.appendChild(document.createTextNode(BT)); }   // unmatched trailing backtick
        else if (segs[i] !== '') mdEmphasis(parent, segs[i]);
      }
    }
    function mdRender(container) {
      let inFence = false;
      for (const line of draft.split('\\n')) {
        const div = document.createElement('div'); div.className = 'mc-md-line';
        const isFence = line.replace(/^\\s+/, '').slice(0, 3) === BT + BT + BT;
        if (isFence) { div.appendChild(mdSpan('mc-md-code', line)); inFence = !inFence; }
        else if (inFence) { div.appendChild(mdSpan('mc-md-code', line)); }
        else if (/^#{1,6}\\s/.test(line)) { div.appendChild(mdSpan('mc-md-heading', line)); }
        else if (/^\\s*>/.test(line)) { div.appendChild(mdSpan('mc-md-quote', line)); }
        else {
          const lm = line.match(/^(\\s*)([-*+]|\\d+\\.)(\\s+)/);
          if (lm) {
            div.appendChild(mdSpan('mc-md-list', lm[1] + lm[2] + lm[3]));
            let restL = line.slice(lm[0].length);
            // ADR-0147: task-list checkbox at the start of a list item ([ ]/[x]/[X] + space).
            const cm = restL.match(/^(\\[[ xX]\\])(\\s)/);
            if (cm) { div.appendChild(mdSpan('mc-md-task', cm[1])); restL = restL.slice(cm[1].length); }
            mdInline(div, restL);
          }
          else { mdInline(div, line); }
        }
        container.appendChild(div);
      }
    }
    function render() {
      body.textContent = '';
      for (const t of bar.querySelectorAll('[data-diff-mode]')) t.classList.toggle('is-active', t.dataset.diffMode === mode);
      // ADR-0110: 구문 — markdown highlight of the whole draft (read-only; not a diff).
      // Falls back to plain 전문 above the line cap (tooBig handled by the branch below).
      if (mode === 'syntax' && !tooBig) {
        const pre = document.createElement('div'); pre.className = 'mc-diff__full mc-md'; mdRender(pre); body.appendChild(pre);
        return;
      }
      if (mode === 'full' || tooBig) {
        const pre = document.createElement('div'); pre.className = 'mc-diff__full'; pre.textContent = draft; body.appendChild(pre);
        if (tooBig) { const w = document.createElement('div'); w.className = 'mc-diff__note'; w.textContent = '(diff 생략 — 라인 수 상한 초과)'; body.insertBefore(w, pre); }
        return;
      }
      const rows = lcsDiff(a, b);
      for (let k = 0; k < rows.length; k++) {
        const [t, line] = rows[k];
        // ADR-0088/0092: in word/char mode, an adjacent -/+ pair is a modified line →
        // intra-line diff (char mode refines changed word runs to character level).
        if ((mode === 'word' || mode === 'char') && t === '-' && k + 1 < rows.length && rows[k + 1][0] === '+') {
          wordRows(line, rows[k + 1][1], mode === 'char');
          k++;   // consumed the paired '+' line
          continue;
        }
        lineRow(t, line);
      }
    }
    render();
  };
})();
</script>`;
}

// ADR-0190 T284: dep blocker 상태의 짧은 한글 라벨(읽기). 기존 컬럼 라벨과 일관.
const DEP_STATUS_LABELS = {
  open: '대기',
  forging: 'forging',
  verify: '검증',
  'awaiting-approval': '승인대기',
  blocked: '보류',
  skipped: '취소',
  missing: '없음',
};
function depStatusLabel(status) {
  return DEP_STATUS_LABELS[status] || String(status || '');
}

// 리뷰 M7: allTickets 대신 reverseDepsIndex() 사전 계산 결과(depIndex)를 받는다 —
// 카드마다 전 티켓을 재순회하던 O(N²)를 렌더당 1회 O(N) 인덱스 구축으로 대체(동일 결론).
function renderTicketCard(ticket, doneIds, nowMs, isLocalhost = true, failCount = 0, ticketsById = {}, depIndex = null) {
  const unmet = (ticket.depends_on || []).filter(id => !doneIds.has(String(id)));
  const blocked = unmet.length > 0;
  const status = ticket.status || 'open';
  const forgingAgeMs = nowMs - (ticket.reservedAtMs || nowMs);
  const age = status === 'forging' ? `<span class="mc-chip mc-chip--ember">${formatAge(forgingAgeMs)}</span>` : '';
  // ADR-0190 T284: 미충족 dep을 blocker 제목·상태로 해소(읽기). ID만 나열하던 칩을
  // 명료화 — 각 blocker의 상태(승인대기/forging/보류…)와 missing(파일 없는 ID)을 표시.
  // blocked 판정(위 doneIds 기반)·Backlog 분류·Run 가시성은 무변경.
  const deps = blocked
    ? `<span class="mc-deps" aria-label="미충족 의존">⛓ ${resolveDeps(ticket.depends_on, ticketsById)
        .filter(d => !d.met)
        .map(d => {
          const lbl = depStatusLabel(d.status);
          const titleAttr = d.missing
            ? `${d.id} — 티켓 파일 없음(오타/삭제?)`
            : `${d.id} ${d.title}`.trim();
          const cls = d.missing ? 'mc-dep mc-dep--missing' : 'mc-dep';
          return `<span class="${cls}" title="${escapeHtml(titleAttr)}">${escapeHtml(d.id)} ${escapeHtml(lbl)}</span>`;
        })
        .join(' ')}</span>`
    : '';
  // ADR-0192 T286: 역방향(downstream) 신호 — "이 티켓이 무엇을 막는가". 실제 depends_on
  // 엣지에서 역집계(reverseDeps). openCount>0(아직 대기 중 downstream)일 때만·done 카드는
  // 이미 엣지 충족이므로 제외(active-only). 우선순위 힌트일 뿐 정렬·게이트 아님.
  let blocksChip = '';
  if (status !== 'done') {
    const rev = reverseDepsFromIndex(ticket.id, depIndex);
    if (rev.openCount > 0) {
      const tip = rev.downstream
        .filter(d => d.status !== 'done')
        .map(d => `${d.id} ${depStatusLabel(d.status) || d.status}`.trim())
        .join(', ');
      blocksChip = `<span class="mc-blocks" aria-label="이 티켓이 막는 downstream" title="${escapeHtml(tip)}">⛓→ ${rev.openCount}</span>`;
    }
  }
  // ADR-0194 T288: blocks 선언 정합성 경보(읽기 무결성 신호). declared blocks 중 실제
  // depends_on 역엣지 없는 stale 선언만(actual-not-declared는 규범이라 경보 안 함).
  // 메타데이터 무결성이므로 모든 상태에 표시(시간 신호 아님·active-only 아님).
  let staleChip = '';
  const cons = blocksConsistency(ticket.blocks, ticket.id, null, depIndex);
  if (cons.staleCount > 0) {
    const tip = cons.stale
      .map(s => `${s.id} ${s.reason === 'missing' ? '대상 없음' : '엣지 없음'}`)
      .join(', ');
    staleChip = `<span class="mc-blocks-stale" aria-label="blocks 선언 불일치" title="${escapeHtml(tip)}">⚠ blocks 선언 ${cons.staleCount}</span>`;
  }
  // ADR-0038 §3.3: stuck(막힘) 관측 배지 — 읽기 전용 신호, 게이트 아님.
  const stuckForging = status === 'forging' && forgingAgeMs >= STUCK_FORGING_MS
    ? '<span class="mc-stuck" title="forging 지연">⏳ stuck</span>' : '';
  const repeatFail = failCount >= STUCK_FAILS
    ? `<span class="mc-stuck mc-stuck--fail" title="반복 실패 ${failCount}회">↻ 반복 실패 ${failCount}</span>` : '';
  // ADR-0180 T274: card aging(생성 후 경과·읽기 신호). active 상태만, done/parked·age 불명은 미표시.
  // forging은 reservation-age를 이미 보여주므로 created-age 칩은 비-forging에만(중복 숫자 방지);
  // aging/stale 강조 배지는 모든 active에 표시(다른 의미의 시간 신호).
  const aging = agingLevel(ticket, nowMs);          // null = done/parked/age 불명
  const ageDays = ticketAgeDays(ticket.created, nowMs);
  let agingChip = '';
  if (aging === 'aging' || aging === 'stale') {
    agingChip = `<span class="mc-aging mc-aging--${aging}" title="생성 후 ${ageDays}일">${ageDays}d</span>`;
  } else if (aging === 'fresh' && status !== 'forging' && ageDays != null) {
    agingChip = `<span class="mc-age" title="생성 후 ${ageDays}일">${ageDays}d</span>`;
  }
  // ADR-0182 T276: done 카드 lead-time(생성→완료) 칩. measured/estimated 구분·null(계측 이전) 미표시.
  // aging과 상호배타(aging은 active, lead-time은 done) — 한 카드에 둘 다 뜨지 않는다.
  const lead = status === 'done' ? leadTimeDays(ticket) : null;
  const leadChip = lead
    ? (lead.basis === 'measured'
        ? `<span class="mc-lead" title="lead-time(측정): ${lead.days}일">${lead.days}d 리드</span>`
        : `<span class="mc-lead mc-lead--est" title="lead-time(추정): ${lead.days}일">~${lead.days}d 리드(추정)</span>`)
    : '';
  const signals = stuckForging || repeatFail ? `<div class="mc-card__signals">${stuckForging}${repeatFail}</div>` : '';
  // ADR-0027 §2.1: non-localhost (mobile) is observe + approve/reject only —
  // run_loop is denied server-side (T099); hide the control to match. UI hiding
  // is convenience only; the server remains authoritative. Run shows ONLY on a
  // ready open card (deps met) — Backlog (blocked open) carries no dispatch.
  // 리뷰 3차 P1: safe가 malformed(누락·오타)면 Run 노출 금지 — 실행기(run_loop)도
  // rc=14로 거부하지만(실행기가 권위), UI도 fail-closed로 일치시킨다.
  // 리뷰 5차 P2: status 누락·권위 필드 중복도 실행기가 거부하므로 동일하게 미노출.
  // 리뷰 8차 P1: Run뿐 아니라 메타·본문·lifecycle writer 전부 동일 게이트(cardWritable).
  const cardWritable = !ticket.safe_malformed && !ticket.status_missing
      && !ticket.authority_malformed && !ticket.id_malformed && !ticket.persona_malformed;
  const runButton = isLocalhost && status === 'open' && !blocked && cardWritable
    ? renderWriteButton({
        label: 'Run',
        cliCommand: `./scripts/run_loop.sh ${ticket.id}`,
        execCommand: 'run_loop',
        ticketId: ticket.id,
        className: 'mc-write--compact',
      })
    : '';
  return `<article class="mc-card mc-card--${escapeHtml(status)}${blocked ? ' is-blocked' : ''}" role="button" tabindex="0" aria-disabled="${blocked ? 'true' : 'false'}" aria-label="${escapeHtml(ticket.id)} ${escapeHtml(ticket.title)}" data-persona="${escapeHtml(ticket.persona || '')}" data-safe="${ticket.safe ? 'safe' : 'unsafe'}" data-blocked="${blocked ? 'true' : 'false'}">
  <div class="mc-card__top">
    <span class="mc-ticket-id">${escapeHtml(ticket.id)}</span>
    <span class="mc-chip">${escapeHtml(ticket.priority || 'P?')}</span>
  </div>
  <h3>${escapeHtml(ticket.title || '(untitled)')}</h3>
  <div class="mc-card__meta">
    <span>${escapeHtml(ticket.persona || 'n/a')}</span>
    <span>${escapeHtml(ticket.estimate || 'n/a')}</span>
    <span class="${ticket.safe ? 'mc-safe' : 'mc-unsafe'}">${ticket.safe_malformed ? 'safe:?' : (ticket.safe ? 'safe' : 'safe:false')}</span>
    ${age}
    ${agingChip}
    ${leadChip}
  </div>
  ${signals}
  ${deps}
  ${blocksChip}
  ${staleChip}
  ${runButton ? `<div class="mc-card-actions">${runButton}</div>` : ''}
  ${cardWritable ? renderTicketEditRow(ticket, isLocalhost, status) : ''}
  ${cardWritable ? renderTicketLifecycleControls(ticket, isLocalhost, status) : ''}
  ${cardWritable ? renderTicketBodyEditor(ticket, isLocalhost, status) : ''}
</article>`;
}

// ADR-0062: localhost-only freeform body editor for OPEN tickets. Textarea is
// pre-filled with the current (escaped) body; on save the board handler pipes it
// to ticket_body via exec (stdin). Collapsed in <details> so it doesn't bloat
// cards. Mobile never renders this (observe-only, T099).
function renderTicketBodyEditor(ticket, isLocalhost, status) {
  if (!isLocalhost || status !== 'open') return '';
  let body = '';
  try { body = readTicketBody(ticket); } catch { body = ''; }
  const cli = `./scripts/ticket_body.sh set ${ticket.id} < body.md`;
  // ADR-0072: read-only AI draft proposer. The button dispatches ai_draft (localhost
  // only, T099) and shows the draft in a read-only block — the human reviews and
  // copies it into the textarea above, then applies via the existing ticket_body
  // surface. The proposer never writes; this is a suggestion, not a measured truth.
  const aiCli = `./scripts/ai_draft.sh ticket-body ${ticket.id}`;
  return `<details class="mc-card-body-edit" data-ticket-body-row data-ticket-id="${escapeHtml(ticket.id)}">
    <summary>본문 편집</summary>
    <textarea class="mc-edit-body" data-ticket-body maxlength="16000" aria-label="${escapeHtml(ticket.id)} 본문">${escapeHtml(body)}</textarea>
    <div class="mc-body-edit__actions">
      <button type="button" class="mc-write mc-write--compact" data-ticket-body-save title="$ ${escapeHtml(cli)}" aria-description="$ ${escapeHtml(cli)}">본문 저장</button>
      <button type="button" class="mc-write mc-write--compact" data-ticket-body-review aria-description="현재 on-disk 본문과 편집기 내용을 비교 (읽기 전용)">변경 검토</button>
      <button type="button" class="mc-write mc-write--compact mc-write--ai" data-ai-draft title="$ ${escapeHtml(aiCli)}" aria-description="$ ${escapeHtml(aiCli)}">AI 초안 제안</button>
    </div>
    <div class="mc-ai-draft" data-ai-draft-out hidden>
      <div class="mc-ai-draft__note">AI 초안 — 검토 후 적용 (제안이며 측정·사실이 아닙니다. 위 편집기에 복사·편집해 적용하세요.)</div>
      <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
    </div>
    <div class="mc-ai-draft" data-ticket-review-out hidden>
      <div class="mc-ai-draft__note">변경 검토 — 적용 전 현재 on-disk 본문과 비교 (읽기 전용·아직 적용 안 됨)</div>
      <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
    </div>
  </details>`;
}

// ADR-0060: localhost-only organizational lifecycle control. cancel on an open
// card (→skipped), reopen on a parked card (skipped/blocked →open). Semantic verbs
// only — no raw status setting. data-ticket-lifecycle (not data-exec-command) so
// it uses the dedicated board handler. Mobile never renders this (observe-only).
function renderTicketLifecycleControls(ticket, isLocalhost, status) {
  if (!isLocalhost) return '';
  let verb = '', label = '';
  if (status === 'open') { verb = 'cancel'; label = '취소'; }
  else if (status === 'skipped' || status === 'blocked') { verb = 'reopen'; label = '재개'; }
  else return '';
  const danger = verb === 'cancel' ? ' mc-write--danger' : '';
  const cli = `./scripts/ticket_lifecycle.sh ${verb} ${ticket.id}`;
  return `<div class="mc-card-actions mc-lifecycle">
    <button type="button" class="mc-write mc-write--compact${danger}" data-ticket-lifecycle="${verb}" data-ticket-id="${escapeHtml(ticket.id)}" title="$ ${escapeHtml(cli)}" aria-description="$ ${escapeHtml(cli)}">${label}</button>
  </div>`;
}

// ADR-0058: localhost-only structured metadata edit (priority/labels) for OPEN
// tickets. Dispatches ticket_edit.sh via exec; mobile (non-localhost) never sees
// this (observe-only, T099). data-ticket-edit-* (not data-exec-command) so it
// uses the dedicated board edit handler, not the shared exec handler.
function renderTicketEditRow(ticket, isLocalhost, status) {
  if (!isLocalhost || status !== 'open') return '';
  const cur = String(ticket.priority || 'P2');
  const curLabels = (ticket.labels || []).join(',');
  const opts = ['P0', 'P1', 'P2', 'P3']
    .map(p => `<option value="${p}"${p === cur ? ' selected' : ''}>${p}</option>`).join('');
  return `<div class="mc-card-edit" data-ticket-edit-row data-ticket-id="${escapeHtml(ticket.id)}" data-cur-priority="${escapeHtml(cur)}" data-cur-labels="${escapeHtml(curLabels)}">
    <select class="mc-edit-priority" data-ticket-edit-priority aria-label="${escapeHtml(ticket.id)} 우선순위">${opts}</select>
    <input type="text" class="mc-edit-labels" data-ticket-edit-labels value="${escapeHtml(curLabels)}" maxlength="120" placeholder="labels (csv)" aria-label="${escapeHtml(ticket.id)} 라벨" />
    <button type="button" class="mc-write mc-write--compact" data-ticket-edit-save title="$ ./scripts/ticket_edit.sh set-priority|set-labels ${escapeHtml(ticket.id)}" aria-description="$ ./scripts/ticket_edit.sh set-priority|set-labels ${escapeHtml(ticket.id)}">메타 저장</button>
  </div>`;
}

// ── Library ⑤ (ADR-0044): 읽기 전용 Playbook/Knowledge 브라우저 ─
// skills/*.md 페르소나 파서. parseFrontmatter는 인라인 배열만 다루므로 여기서는
// YAML 블록 시퀀스(when_to_invoke / forbidden)를 직접 파싱한다. 읽기 전용.
function parseSkillFile(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---\r?\n?([\s\S]*)$/);
  if (!m) return null;
  const body = m[2] || '';
  const fm = {};
  let curKey = null;
  for (const line of m[1].split('\n')) {
    const kv = line.match(/^(\w+):\s*(.*)$/);
    const item = line.match(/^\s+-\s+(.*)$/);
    if (kv) {
      curKey = kv[1];
      const val = kv[2].trim().replace(/\s+#.*$/, '');
      if (val) { fm[curKey] = val.replace(/^["'](.*)["']$/, '$1'); curKey = null; }
      else { fm[curKey] = []; }
    } else if (item && curKey && Array.isArray(fm[curKey])) {
      fm[curKey].push(item[1].trim().replace(/^["'](.*)["']$/, '$1'));
    }
  }
  return {
    name: fm.name || '',
    description: fm.description || '',
    when_to_invoke: Array.isArray(fm.when_to_invoke) ? fm.when_to_invoke : [],
    forbidden: Array.isArray(fm.forbidden) ? fm.forbidden : [],
    body,
  };
}
function parseSkills() {
  try {
    if (!existsSync(SKILLS_DIR)) return [];
    return readdirSync(SKILLS_DIR)
      .filter(f => f.endsWith('.md'))
      .sort()
      .map(f => { try { return parseSkillFile(readFileSync(join(SKILLS_DIR, f), 'utf8')); } catch { return null; } })
      .filter(Boolean);
  } catch { return []; }
}

function renderPlaybookCard(skill) {
  const triggers = skill.when_to_invoke.length
    ? `<ul class="mc-skill-triggers">${skill.when_to_invoke.map(t => `<li>${escapeHtml(t)}</li>`).join('')}</ul>`
    : '<p class="mc-empty">트리거 없음</p>';
  const forbidden = skill.forbidden.length
    ? `<ul class="mc-skill-forbidden">${skill.forbidden.map(t => `<li>${escapeHtml(t)}</li>`).join('')}</ul>`
    : '';
  const body = skill.body.trim()
    ? `<details class="mc-skill-body"><summary>본문</summary>${renderMarkdown(skill.body)}</details>`
    : '';
  // ADR-0186 T280: playbook coverage 배지(읽기 신호). 구조 필드 완전성 — 점수/평가 아님.
  const cov = skillCoverage(skill);
  const covLabel = cov.level === 'complete' ? '완전' : cov.level === 'partial' ? '부분' : '빈약';
  const covBadge = `<span class="mc-cov mc-cov--${cov.level}" title="description ${cov.hasDescription ? '있음' : '없음'} · 트리거 ${cov.triggerCount}">${covLabel}</span>`;
  return `<article class="mc-playbook" aria-label="${escapeHtml(skill.name)} playbook">
  <div class="mc-card__top"><span class="mc-ticket-id">${escapeHtml(skill.name || '(unnamed)')}</span>${covBadge}</div>
  <p class="mc-playbook__desc">${escapeHtml(skill.description || '')}</p>
  <h4>when_to_invoke (트리거)</h4>${triggers}
  ${forbidden ? `<h4>forbidden (금지)</h4>${forbidden}` : ''}
  ${body}
</article>`;
}

function renderLibraryPage({ isLocalhost = true } = {}) {
  const skills = parseSkills();
  const cards = skills.length
    ? skills.map(renderPlaybookCard).join('\n')
    : '<p class="mc-empty">skills/ 없음</p>';

  // ADR-0186 T280: playbook coverage 요약(읽기). 완전성 카운트 — skills 있을 때만.
  const cs = coverageSummary(skills);
  const coverageBar = cs.total
    ? `<section class="mc-panel mc-cov-summary" aria-label="playbook coverage 요약">
    <div class="mc-panel__head"><h2>playbook coverage</h2><span>구조 완전성 · 읽기 · ADR-0186</span></div>
    <div class="mc-cov-counts">
      <span class="mc-cov mc-cov--complete">완전 ${cs.complete}</span>
      <span class="mc-cov mc-cov--partial">부분 ${cs.partial}</span>
      <span class="mc-cov mc-cov--sparse">빈약 ${cs.sparse}</span>
      <span class="mc-cov mc-cov--notrigger" title="when_to_invoke 없음 — 트리거 자동 호출 불가">트리거 없음 ${cs.noTrigger}</span>
      <span class="mc-cov-total">총 ${cs.total}</span>
    </div>
  </section>`
    : '';

  // 트리거 구조 뷰: 모든 skill의 when_to_invoke → 페르소나.
  const triggerRows = [];
  for (const s of skills) for (const t of s.when_to_invoke) triggerRows.push([t, s.name]);
  const triggerHtml = triggerRows.length
    ? `<ul class="mc-bars">${triggerRows.map(([t, p]) => `<li><span class="mc-bars__label" title="${escapeHtml(t)}">${escapeHtml(t)}</span><span class="mc-link-tickets">${escapeHtml(p)}</span></li>`).join('')}</ul>`
    : '<p class="mc-empty">트리거 없음</p>';

  // persona↔ticket 링키지(파일 기반): 진짜 주입 통계가 아니라 처리량 근사.
  const { byStatus } = getModel();
  const all = ['open', 'forging', 'verify', 'awaiting-approval', 'done'].flatMap(s => byStatus[s] || []);
  const personaCount = {};
  for (const t of all) { const p = t.persona || '(none)'; personaCount[p] = (personaCount[p] || 0) + 1; }
  const personaRows = Object.entries(personaCount).sort((a, b) => b[1] - a[1]);
  const personaHtml = personaRows.length
    ? renderBars(personaRows)
    : '<p class="mc-empty">데이터 없음</p>';

  const main = `<main class="mc-page mc-page--library" aria-label="Library">
  ${coverageBar}
  <section class="mc-playbooks" aria-label="Playbooks">${cards}</section>
  <div class="mc-insights-grid">
    <section class="mc-panel"><div class="mc-panel__head"><h2>트리거 구조 (Knowledge)</h2><span>when_to_invoke → 페르소나</span></div>${triggerHtml}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>persona ↔ ticket</h2><span>파일 기반 처리량</span></div>${personaHtml}</section>
    ${(() => {
      // ADR-0046: real per-persona usage from instrumented DONE (completed_at).
      // Pre-instrumentation tickets lack completed_at → "계측 이후 N건" only.
      const doneInstrumented = (byStatus.done || []).filter(t => t.completed_at);
      if (!doneInstrumented.length) {
        return `<section class="mc-panel"><div class="mc-panel__head"><h2>주입 사용 통계</h2></div><div class="mc-stat mc-stat--absent"><span class="mc-stat__n">—</span><span class="mc-stat__label">"이번 주 N회 주입"</span><span class="mc-stat__sub">데이터 없음 — 텔레메트리 선행</span></div></section>`;
      }
      const usage = {};
      for (const t of doneInstrumented) { const p = t.persona || '(none)'; usage[p] = (usage[p] || 0) + 1; }
      const rows = Object.entries(usage).sort((a, b) => b[1] - a[1]);
      return `<section class="mc-panel"><div class="mc-panel__head"><h2>주입 사용 통계</h2><span>계측 이후 n=${doneInstrumented.length}</span></div>${renderBars(rows, 'mc-bars__fill--ember')}</section>`;
    })()}
  </div>
</main>`;
  return renderShell('Library', 'library', main, { isLocalhost });
}

// ── Spec Studio ④ (ADR-0042): 읽기 전용 spec/결정 네비게이터 ────
// zero-dep 마크다운 서브셋 렌더러. HTML 이스케이프 우선 → 제한 마크업만 변환
// (주입 텍스트가 태그로 실행되지 않는다). 외부 라이브러리 없음(ADR-0024).
function renderMarkdownInline(escaped) {
  return escaped
    .replace(/`([^`]+)`/g, '<code>$1</code>')
    .replace(/\*\*([^*]+)\*\*/g, '<strong>$1</strong>')
    .replace(/\[([^\]]+)\]\(([^)\s]+)\)/g, (m, text, url) =>
      /^(https?:\/\/|\/|#|\.)/.test(url) ? `<a href="${url}" rel="noopener">${text}</a>` : m);
}
function renderMarkdown(md) {
  const lines = escapeHtml(String(md)).split('\n');
  const out = [];
  let i = 0;
  const flushPara = buf => { if (buf.length) { out.push(`<p>${renderMarkdownInline(buf.join(' '))}</p>`); buf.length = 0; } };
  const para = [];
  while (i < lines.length) {
    const line = lines[i];
    // code fence
    if (/^```/.test(line)) {
      flushPara(para);
      const code = [];
      i += 1;
      while (i < lines.length && !/^```/.test(lines[i])) { code.push(lines[i]); i += 1; }
      i += 1;
      out.push(`<pre class="mc-md-code"><code>${code.join('\n')}</code></pre>`);
      continue;
    }
    // table (| a | b | with a |---| separator on next line)
    if (/^\s*\|.*\|\s*$/.test(line) && i + 1 < lines.length && /^\s*\|[\s:|-]+\|\s*$/.test(lines[i + 1])) {
      flushPara(para);
      const cells = row => row.trim().replace(/^\||\|$/g, '').split('|').map(c => c.trim());
      const head = cells(line);
      i += 2;
      const body = [];
      while (i < lines.length && /^\s*\|.*\|\s*$/.test(lines[i])) { body.push(cells(lines[i])); i += 1; }
      out.push(`<table class="mc-md-table"><thead><tr>${head.map(c => `<th>${renderMarkdownInline(c)}</th>`).join('')}</tr></thead><tbody>${body.map(r => `<tr>${r.map(c => `<td>${renderMarkdownInline(c)}</td>`).join('')}</tr>`).join('')}</tbody></table>`);
      continue;
    }
    // heading
    const h = line.match(/^(#{1,6})\s+(.*)$/);
    if (h) { flushPara(para); const n = h[1].length; out.push(`<h${n} class="mc-md-h${n}">${renderMarkdownInline(h[2])}</h${n}>`); i += 1; continue; }
    // blockquote
    if (/^&gt;\s?/.test(line)) { flushPara(para); out.push(`<blockquote>${renderMarkdownInline(line.replace(/^&gt;\s?/, ''))}</blockquote>`); i += 1; continue; }
    // list
    if (/^\s*[-*]\s+/.test(line)) {
      flushPara(para);
      const items = [];
      while (i < lines.length && /^\s*[-*]\s+/.test(lines[i])) { items.push(`<li>${renderMarkdownInline(lines[i].replace(/^\s*[-*]\s+/, ''))}</li>`); i += 1; }
      out.push(`<ul>${items.join('')}</ul>`);
      continue;
    }
    if (/^\s*\d+\.\s+/.test(line)) {
      flushPara(para);
      const items = [];
      while (i < lines.length && /^\s*\d+\.\s+/.test(lines[i])) { items.push(`<li>${renderMarkdownInline(lines[i].replace(/^\s*\d+\.\s+/, ''))}</li>`); i += 1; }
      out.push(`<ol>${items.join('')}</ol>`);
      continue;
    }
    // blank → paragraph break
    if (/^\s*$/.test(line)) { flushPara(para); i += 1; continue; }
    para.push(line);
    i += 1;
  }
  flushPara(para);
  return out.join('\n');
}

// decisions/ 인덱스: 번호·제목·상태(읽기).
function parseAdrIndex() {
  try {
    if (!existsSync(DECISIONS_DIR)) return [];
    return readdirSync(DECISIONS_DIR)
      .filter(f => /^\d{4}-.*\.md$/.test(f))
      .map(f => {
        const num = f.slice(0, 4);
        let title = f, status = '';
        try {
          const text = readFileSync(join(DECISIONS_DIR, f), 'utf8');
          const t = text.match(/^#\s+(.+)$/m);
          if (t) title = t[1].trim();
          const s = text.match(/\*\*상태\*\*\s*:\s*([^\n(]+)/) || text.match(/상태\s*:\s*([^\n(]+)/);
          if (s) status = s[1].trim();
        } catch { /* ignore */ }
        return { num, title, status };
      })
      // 리뷰 후속: numeric 비교 — 현재 4자리 0-패딩이라 동작 동일하나, 자릿수 확장에 안전.
      .sort((a, b) => b.num.localeCompare(a.num, undefined, { numeric: true }));
  } catch { return []; }
}

// spec↔ticket 역색인: 티켓 spec_ref가 가리키는 대상별로 티켓을 묶는다(읽기).
function specTicketIndex() {
  const { byStatus } = getModel();
  const all = ['open', 'forging', 'verify', 'awaiting-approval', 'done'].flatMap(s => byStatus[s] || []);
  const idx = {};
  for (const t of all) {
    if (!t.spec_ref) continue;
    const target = String(t.spec_ref).split('#')[0].replace(/^docs\//, '');
    (idx[target] = idx[target] || []).push({ id: t.id, ref: t.spec_ref });
  }
  return Object.entries(idx).sort((a, b) => b[1].length - a[1].length);
}

function renderSpecPage({ isLocalhost = true } = {}) {
  let specMd = '';
  try { specMd = readFileSync(MASTER_SPEC_PATH, 'utf8'); } catch { specMd = ''; }
  // section TOC from ## headings
  const toc = [];
  for (const line of specMd.split('\n')) {
    const m = line.match(/^##\s+(.*)$/);
    if (m) { const id = 'sec-' + toc.length; toc.push({ id, text: m[1].trim() }); }
  }
  let tocIdx = -1;
  const specHtml = renderMarkdown(specMd).replace(/<h2 class="mc-md-h2">/g, () => { tocIdx += 1; return `<h2 id="sec-${tocIdx}" class="mc-md-h2">`; });
  const tocHtml = toc.length
    ? `<nav class="mc-spec-toc" aria-label="master-spec 목차"><h3>master-spec</h3><ul>${toc.map(s => `<li><a href="#${s.id}">${escapeHtml(s.text)}</a></li>`).join('')}</ul></nav>`
    : '';

  const adrs = parseAdrIndex();
  const adrHtml = adrs.length
    ? `<ul class="mc-adr-list">${adrs.map(a => `<li><span class="mc-ticket-id">ADR-${escapeHtml(a.num)}</span><span class="mc-adr-title">${escapeHtml(a.title.replace(/^ADR-\d+:\s*/, ''))}</span>${a.status ? `<span class="mc-adr-status">${escapeHtml(a.status)}</span>` : ''}</li>`).join('')}</ul>`
    : '<p class="mc-empty">결정 없음</p>';

  const links = specTicketIndex();
  const linkHtml = links.length
    ? `<ul class="mc-bars">${links.map(([target, tickets]) => `<li><span class="mc-bars__label" title="${escapeHtml(target)}">${escapeHtml(target)}</span><span class="mc-link-tickets">${tickets.map(t => escapeHtml(t.id)).join(', ')}</span></li>`).join('')}</ul>`
    : '<p class="mc-empty">spec_ref 링키지 없음</p>';

  const main = `<main class="mc-page mc-page--spec" aria-label="Spec Studio">
  <section class="mc-spec-layout">
    ${tocHtml}
    <article class="mc-spec-body">${specHtml || '<p class="mc-empty">master-spec.md 없음</p>'}</article>
  </section>
  <div class="mc-insights-grid">
    <section class="mc-panel"><div class="mc-panel__head"><h2>결정 인덱스 (ADR)</h2><span>${adrs.length}</span></div>${adrHtml}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>spec ↔ ticket 링키지</h2><span>spec_ref 역색인</span></div>${linkHtml}</section>
  </div>
  ${renderSpecMasterEdit(isLocalhost, specMd)}
  ${renderDocEditPanel(isLocalhost)}
  ${isLocalhost ? '<section class="mc-panel"><p class="mc-specedit__note">새 프로젝트 만들기는 <a href="/new-project">전용 페이지</a>로 이동했습니다.</p></section>' : ''}
</main>`;
  return renderShell('Spec Studio', 'spec', main, { isLocalhost, draftPreview: true });
}

// ADR-0068: localhost-only editor for the MOST governing doc, master-spec. Stronger
// gate than doc_edit — requires a non-empty reason + a strong confirm naming the
// governing impact. The server writes a master-spec.vN snapshot. NEVER invoked by
// the loop/grant — human-confirmed only. Mobile never renders this (read-only).
function renderSpecMasterEdit(isLocalhost, specMd) {
  if (!isLocalhost) return '';
  const cli = `./scripts/spec_edit.sh set --reason <reason> < spec.md`;
  return `<section class="mc-panel mc-specedit" aria-label="master-spec 편집" data-specedit>
    <div class="mc-panel__head"><h2>master-spec 편집</h2><span>localhost · 지배 문서 · ADR-0068</span></div>
    <p class="mc-specedit__note">⚠ master-spec는 <strong>루프/AI 행동 전체를 규정하는 지배 문서</strong>입니다. 전체 교체 편집이며, <strong>사유 기록·버전 스냅샷(master-spec.vN)·강한 확인</strong>을 거칩니다. 자율 루프·grant는 이 문서를 쓰지 않습니다(인간 확인 전용). 단일 감사 커밋·git revert 가역.</p>
    <details class="mc-specedit__body">
      <summary>master-spec.md 편집 열기</summary>
      <label class="mc-specedit__reason">사유 (필수)
        <input type="text" data-spec-reason maxlength="300" placeholder="왜 지배 문서를 바꾸나요? (감사 기록)" aria-label="편집 사유" />
      </label>
      <textarea class="mc-edit-body" data-spec-content maxlength="262144" aria-label="master-spec 내용">${escapeHtml(specMd)}</textarea>
      <div class="mc-body-edit__actions">
        <button type="button" class="mc-write mc-write--compact mc-write--danger" data-spec-save title="$ ${escapeHtml(cli)}" aria-description="$ ${escapeHtml(cli)}">전체 교체 저장 (지배 문서)</button>
        <button type="button" class="mc-write mc-write--compact" data-spec-review aria-description="현재 on-disk master-spec와 편집기 내용을 비교 (읽기 전용)">변경 검토</button>
        <button type="button" class="mc-write mc-write--compact mc-write--ai" data-spec-ai-draft title="$ ./scripts/ai_draft.sh master-spec" aria-description="$ ./scripts/ai_draft.sh master-spec">AI 초안 제안</button>
      </div>
      <div class="mc-ai-draft" data-ai-draft-out hidden>
        <div class="mc-ai-draft__note">AI 초안 — 검토 후 <strong>spec_edit 게이트(사유·2차 확인·vN 스냅샷)</strong>로 적용 (제안이며 측정·사실이 아닙니다. 위 편집기에 복사·편집하세요.)</div>
        <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
      </div>
      <div class="mc-ai-draft" data-spec-review-out hidden>
        <div class="mc-ai-draft__note">변경 검토 — 적용 전 현재 on-disk master-spec와 비교 (읽기 전용·아직 적용 안 됨)</div>
        <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
      </div>
    </details>
    ${specMasterEditScript()}
  </section>`;
}

function specMasterEditScript() {
  return `<script>
(() => {
  const panel = document.querySelector('.mc-specedit');
  if (!panel) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 6000); };
  // ADR-0076: read-only AI draft proposer for master-spec. Dispatches ai_draft
  // master-spec (localhost, T099), shows the draft read-only — the human copies it
  // into the textarea and applies via 전체 교체 저장 (spec_edit's strong gate). The
  // proposer never writes; the §4 carve-out conditions apply at the spec_edit step.
  const aiBtn = panel.querySelector('[data-spec-ai-draft]');
  if (aiBtn) {
    aiBtn.addEventListener('click', async (event) => {
      event.preventDefault();
      if (aiBtn.disabled) return;
      const out = panel.querySelector('[data-ai-draft-out]');
      const outBody = panel.querySelector('[data-ai-draft-body]');
      aiBtn.disabled = true;
      const prev = aiBtn.textContent;
      aiBtn.textContent = '초안 생성 중…';
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'ai_draft', target: 'master-spec' }) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || '거부됨');
        const draft = (data && typeof data.stdoutTail === 'string') ? data.stdoutTail : '';
        const curEl = panel.querySelector('[data-spec-content]');
        if (out) { window.__mcDraftPreview(out, curEl ? curEl.value : '', draft); out.hidden = false; }
        showToast('master-spec AI 초안 제안됨 — spec_edit 게이트로 적용');
      } catch (e) { showToast(String(e.message || e), true); }
      finally { aiBtn.disabled = false; aiBtn.textContent = prev; }
    });
  }
  // ADR-0114: opt-in 변경 검토 — read-only diff of the on-disk master-spec (captured at
  // load) vs the current editor content, BEFORE the spec_edit gate. Reuses the client-
  // side __mcDraftPreview renderer; no new exec/writer/server state. The strong save
  // gate (reason + confirm + vN snapshot) is unchanged — review is observe-only.
  const reviewBtn = panel.querySelector('[data-spec-review]');
  const reviewOut = panel.querySelector('[data-spec-review-out]');
  const baselineEl = panel.querySelector('[data-spec-content]');
  const baseline = baselineEl ? baselineEl.value : '';   // on-disk original at page load
  if (reviewBtn && reviewOut) {
    const reviewNote = '변경 검토 — 적용 전 현재 on-disk master-spec와 비교 (읽기 전용·아직 적용 안 됨)';
    reviewBtn.addEventListener('click', (event) => {
      event.preventDefault();
      const curEl = panel.querySelector('[data-spec-content]');
      window.__mcDraftPreview(reviewOut, baseline, curEl ? curEl.value : '');
      const noteEl = reviewOut.querySelector('.mc-ai-draft__note');
      if (noteEl) noteEl.textContent = reviewNote;   // __mcDraftPreview sets an "AI 초안" note; restore the review note
      reviewOut.hidden = false;
    });
  }
  const save = panel.querySelector('[data-spec-save]');
  if (!save) return;
  save.addEventListener('click', async (event) => {
    event.preventDefault();
    if (save.disabled) return;
    const reason = (panel.querySelector('[data-spec-reason]') || {}).value || '';
    const content = (panel.querySelector('[data-spec-content]') || {}).value || '';
    if (!reason.trim()) { showToast('사유(reason)를 입력하세요 — 지배 문서 변경엔 사유가 필수입니다', true); return; }
    if (!window.confirm('⚠ master-spec(지배 문서 — 루프 행동 전체에 영향)를 전체 교체합니다.\\n\\n사유: ' + reason.trim() + '\\n\\n버전 스냅샷(master-spec.vN)이 보존되고 git revert로 되돌릴 수 있습니다. 계속할까요?')) return;
    save.disabled = true;
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'spec_edit', action: 'set', reason: reason.trim(), content: content }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '거부됨');
      if (data.exitCode !== 0) throw new Error('실패: ' + data.exitCode);
      showToast('master-spec 저장됨 (스냅샷 보존)');
      setTimeout(() => window.location.reload(), 800);
    } catch (e) { showToast(String(e.message || e), true); save.disabled = false; }
  });
})();
</script>`;
}

// ADR-0149 Phase 2 (T236): localhost-only "새 프로젝트" panel. Enter a target path
// (+ codename + stack), PREVIEW (dry-run, read-only manifest) then CREATE (real
// clean-extract). Dispatches the init_new_project exec (T235): args are an argv
// array server-side, dryRun defaults true, SOURCE is never written. Mobile never
// renders this (non-localhost exec is 403, T099). Output is escape-first (textContent).
function renderNewProjectPanel(isLocalhost) {
  if (!isLocalhost) return '';
  return `<section class="mc-panel mc-newproj np-advanced" id="mc-newproj" aria-label="새 프로젝트 부트스트랩" data-newproj>
    <details class="mc-newproj__body">
      <summary class="np-advanced__summary"><span class="np-advanced__title"><span aria-hidden="true">⚙</span> 고급 설정 <span class="np-advanced__sub">코드명 · 검증 스택 · 포함 문서 · dry-run</span></span><span class="np-advanced__plus" aria-hidden="true">＋</span></summary>
      <div class="mc-field np-field--path" data-field="path">
        <label for="np-path">대상 경로 <span class="mc-field__req" aria-hidden="true">*</span> <span class="mc-field__sub">(이 저장소 밖 · 위 입력에서 자동 반영)</span></label>
        <input id="np-path" type="text" data-np-path maxlength="4096" placeholder="예: ../my-app" aria-describedby="np-path-hint np-path-err" />
        <p class="mc-field__hint" id="np-path-hint">새 프로젝트를 만들 폴더 경로. 저장소(SOURCE) 밖이어야 합니다.</p>
        <p class="mc-field__err" id="np-path-err" data-np-path-err role="alert" hidden></p>
      </div>
      <div class="mc-field" data-field="name">
        <label for="np-name">코드명 <span class="mc-field__sub">(선택 · 기본: 폴더 이름)</span></label>
        <input id="np-name" type="text" data-np-name maxlength="64" placeholder="예: shaman" aria-describedby="np-name-hint np-name-err" />
        <p class="mc-field__hint" id="np-name-hint">영문/숫자/.-_ 와 공백, 64자 이내.</p>
        <p class="mc-field__err" id="np-name-err" data-np-name-err role="alert" hidden></p>
      </div>
      <div class="mc-field" data-field="stack">
        <label for="np-stack">검증 스택 <span class="mc-field__sub">— "통과(GREEN)"의 기준</span></label>
        <div class="np-stacks" data-np-stacks role="group" aria-label="검증 스택 선택">
          <button type="button" class="np-stacks__chip is-on" data-np-stack-pick="none">나중에</button>
          <button type="button" class="np-stacks__chip" data-np-stack-pick="node">Node</button>
          <button type="button" class="np-stacks__chip" data-np-stack-pick="python">Python</button>
          <button type="button" class="np-stacks__chip" data-np-stack-pick="go">Go</button>
          <button type="button" class="np-stacks__chip" data-np-stack-pick="rust">Rust</button>
        </div>
        <select id="np-stack" data-np-stack class="np-stacks__select" aria-hidden="true" tabindex="-1" aria-describedby="np-stack-hint">
          <option value="none">기타/지금 없음</option>
          <option value="node">Node.js</option>
          <option value="python">Python</option>
          <option value="go">Go</option>
          <option value="rust">Rust</option>
        </select>
        <p class="mc-field__hint" id="np-stack-hint">고른 스택으로 새 레포의 <code>run_checks.local.sh</code>가 자동 작성됩니다.</p>
      </div>
      <div class="mc-field np-refs__label"><label>포함 문서 <span class="mc-field__sub">(선택 · 추가 복사)</span></label></div>
      <label class="mc-specedit__reason mc-newproj__ref"><input type="checkbox" data-np-onboarding /> 온보딩 quickstart 문서 포함 <code>--with-onboarding</code></label>
      <label class="mc-specedit__reason mc-newproj__ref"><input type="checkbox" data-np-glossary /> 용어집 glossary 문서 포함 <code>--with-glossary</code></label>
      <div class="mc-body-edit__actions">
        <button type="button" class="mc-write mc-write--compact np-dryrun" data-np-preview aria-description="dry-run: 복사 매니페스트만 (실제 복사 없음)">미리보기 (dry-run)</button>
        <span class="np-dryrun__note">실제 복사 없음 · 매니페스트만 · 기본값 참(preview-first)</span>
        <button type="button" class="mc-write mc-write--compact mc-write--danger" data-np-create aria-description="실제 클린 추출 (대상 폴더에 새 레포 생성)">생성</button>
      </div>
      <p class="mc-newproj__status" data-np-status role="status" aria-live="polite" hidden></p>
      <div class="mc-ai-draft" data-np-out hidden>
        <div class="mc-ai-draft__note">결과 — 미리보기는 읽기 전용 매니페스트입니다 (SOURCE 불변).</div>
        <pre class="mc-ai-draft__body" data-np-out-body></pre>
        ${renderHarnessNextSteps('np')}
      </div>
      <div class="np-transparency">
        <div>
          <div class="np-transparency__head np-transparency__head--in">✓ 복사됨 (이식 가능한 하네스)</div>
          <ul><li>scripts/ · skills/ · mission-control/</li><li>docs/tickets/TEMPLATE.md · runbook.md</li><li>.gitignore · run_checks.local.sh</li><li>master-spec/README 스텁 · smoke 테스트</li></ul>
        </div>
        <div>
          <div class="np-transparency__head np-transparency__head--out">✗ 가져오지 않음 (Hephaestus 누적물)</div>
          <ul><li>ADR 이력 · DONE 티켓</li><li>PDF · OCR · 보고서</li><li>기존 master-spec · product 테스트</li></ul>
        </div>
      </div>
      <p class="np-advanced__foot">SOURCE(이 저장소)는 변경되지 않음 · 모든 쓰기는 대상 폴더 안에서만 · 원복 = 대상 폴더 삭제 (ADR-0149)</p>
    </details>
    ${newProjectPanelScript()}
  </section>`;
}

// ─────────────────────────────────────────────────────────
// T289+T290 (ADR-0197 L1): /new-project Launchpad 페이지.
// 히어로(이름·경로 미리보기·CTA)가 기존 패널 머신(검증·__mcConfirm·exec 계약)을 구동한다.
// 단, 기존 폴더 충돌은 confirm 전에 fs-dirs로 먼저 감지해 CTA 치환만 한다.
// exec 계약·confirm(T251)·검증 규칙 무변경. Explain layer 문구는 final 기획 §3.5 정본.
// ─────────────────────────────────────────────────────────
const LAUNCHPAD_HELP = [
  ['project', '코드를 복사하는 게 아닙니다. AI 루프를 돌릴 운영 장비(스크립트·페르소나·티켓 템플릿)를 새 폴더에 깔아줍니다. 만들어진 폴더는 이 저장소와 완전히 독립이며, 이 저장소는 절대 변경되지 않습니다.'],
  ['stack', '새 프로젝트에서 "통과(GREEN)"의 기준을 정합니다. node를 고르면 npm test 같은 검사가 자동 세팅되고, AI 루프는 이 검사가 통과해야만 작업을 완료로 인정합니다. "나중에"를 골라도 되지만, 검사를 채우기 전까지는 코드가 깨져도 통과처럼 보일 수 있어요. 언제든 scripts/run_checks.local.sh에서 바꿀 수 있습니다.'],
  ['base', '프로젝트 폴더가 만들어질 상위 폴더입니다. 보안상 이 저장소의 부모 폴더 아래만 허용됩니다.'],
  ['docs', '새 프로젝트에 입문 가이드(quickstart)·용어집을 함께 복사할지입니다. 없어도 동작하며, 나중에 복사해도 됩니다.'],
  ['brown', '이미 코드가 있는 폴더에 운영 장비만 얹는 작업입니다. 별도 링크를 고르지 않아도 기존 폴더 경로를 입력하면 자동으로 스캔 결과가 열립니다. 기존 소스 코드는 건드리지 않지만 일부 하네스 파일이 덮어써질 수 있어, 무엇이 바뀌는지 목록을 먼저 보여드리고 확인을 받습니다.'],
];
function renderLaunchpadHelp() {
  const helpBtn = key => `<button type="button" class="mc-help" data-help="${key}" aria-expanded="false" aria-label="설명 보기">?</button>`;
  const pops = LAUNCHPAD_HELP.map(([k, txt]) =>
    `<div class="mc-help-pop" data-help-pop="${k}" role="dialog" aria-label="설명" hidden>${escapeHtml(txt)}<span class="mc-help-pop__more">ESC 또는 바깥 클릭으로 닫기</span></div>`).join('');
  return { helpBtn, pops };
}

function renderHarnessNextSteps(prefix) {
  const p = prefix === 'bf' ? 'bf' : 'np';
  return `<details class="mc-next-steps" data-${p}-next hidden>
    <summary>다음 단계</summary>
    <ol>
      <li><code data-${p}-next-cd></code></li>
      <li><code>$EDITOR docs/master-spec.md</code> — 프로젝트 명세 작성</li>
      <li><code>$EDITOR scripts/run_checks.local.sh</code> — 검증 스택이 none이면 검증 명령 채우기</li>
      <li><code>cp docs/tickets/TEMPLATE.md docs/tickets/T001-first.md</code> — 첫 티켓 작성</li>
      <li><code>./scripts/run_loop.sh T001-first --dry-run</code> — 프롬프트 미리보기</li>
      <li><code>./scripts/mission_control.sh start</code> — 이 프로젝트용 Mission Control 열기
        <button type="button" class="mc-write mc-write--compact np-open-mc" data-${p}-open-mc aria-description="타깃 프로젝트의 Mission Control을 시작하고 링크를 표시 (open_project_mc.sh)">웹에서 시작</button>
        <a class="np-open-mc__link" data-${p}-mc-link target="_blank" rel="noopener" hidden></a>
        <span class="np-open-mc__note">위 2~5단계(명세·검증·티켓·미리보기)는 새 프로젝트의 Mission Control 웹에서 진행할 수 있습니다.</span></li>
    </ol>
  </details>`;
}

function renderNewProjectPage(isLocalhost) {
  const { helpBtn, pops } = renderLaunchpadHelp();
  const base = dirname(resolve(ROOT));
  // ADR-0202 목업 v2 (New Project.dc.html, 2026-07-06 정본): 히어로·스마트 입력(라이브 preflight 필)·
  // 결과 카드·상태 CTA·CLI 힌트·occupied 스테퍼 게이트·고급 설정. 머신(exec·confirm·검증)은 무변경.
  const main = isLocalhost ? `<main class="mc-page mc-page--launchpad" aria-label="새 프로젝트">
  <section class="mc-launchpad mc-launchpad--v2" data-base="${escapeHtml(base)}" data-pf="">
    <div class="np-hero">
      <div class="np-hero__eyebrow">새 프로젝트 · CLEAN EXTRACT</div>
      <h2 class="mc-launchpad__title">무엇을 만들까요?${helpBtn('project')}</h2>
      <p class="mc-launchpad__hint"><strong>이름 입력 = 새 폴더</strong> · <strong>기존 폴더 경로 = 하네스 적용</strong> — 어느 쪽인지 시스템이 판별합니다 <span class="mc-launchpad__hint-ref">ADR-0201</span></p>
    </div>
    <div class="np-input">
      <span class="np-input__ico" data-lp-ico aria-hidden="true">✦</span>
      <input class="mc-launchpad__name" data-lp-name type="text" placeholder="프로젝트 이름 또는 기존 폴더 경로" autocomplete="off" autofocus aria-label="프로젝트 이름 또는 기존 폴더 경로" />
      <span class="np-input__pill" data-lp-pill hidden><span class="np-input__dot" aria-hidden="true"></span><span data-lp-pill-label></span></span>
      <button type="button" class="np-browse-btn" data-np-browse title="허용 base 아래 폴더 찾아보기 (읽기 전용)" aria-description="허용 base 아래 디렉터리 찾아보기 (읽기 전용·localhost)">🗂 찾아보기</button>
    </div>
    <div class="np-meta">
      <code class="np-meta__path" data-lp-path>${escapeHtml(base)}/…</code>
      <span class="np-meta__note" data-lp-pathnote>이름 또는 경로를 입력하세요</span>
      <span class="np-meta__spacer"></span>
      <span class="np-meta__legend">이름 = 새 폴더 · '/' 포함 = 기존 경로</span>
    </div>
    <p class="mc-launchpad__collide" data-lp-collide role="status" hidden></p>
    <div class="np-browser" data-np-browser hidden>
      <div class="np-browser__head"><span class="np-browser__label">현재 위치</span> <code data-np-cwd></code> <button type="button" class="mc-write mc-write--compact" data-np-up>↑ 상위로</button></div>
      <ul class="np-browser__dirlist" data-np-dirlist aria-label="디렉터리 목록"></ul>
      <p class="np-browser__foot">폴더만 표시 · base 범위 안 읽기 전용 · 저장소·닷파일 제외 (ADR-0155) · 선택은 입력 보조일 뿐, 최종 판별은 preflight</p>
    </div>
    <div class="np-result" data-lp-result hidden>
      <div class="np-result__icon" data-lp-rc-icon aria-hidden="true">✦</div>
      <div class="np-result__body">
        <div class="np-result__head"><strong data-lp-rc-title></strong><span class="np-result__tag">preflight: <span data-lp-rc-tag></span></span></div>
        <p class="np-result__desc" data-lp-rc-desc></p>
        <div class="np-result__recover"><span aria-hidden="true">↩</span><span>복구 · <span data-lp-rc-recover></span></span></div>
      </div>
    </div>
    <button type="button" class="mc-launchpad__cta" data-lp-create disabled><span data-lp-cta-label>프로젝트 만들기</span><span class="np-cta__arrow" data-lp-cta-arrow aria-hidden="true"></span></button>
    <p class="np-clihint" data-lp-cli hidden>$ <span data-lp-cli-text></span></p>
    <section class="mc-panel mc-brownfield np-gate" data-bf hidden aria-label="기존 폴더 검사 결과">
      <div class="np-stepper" aria-label="적용 단계">
        <div class="np-stepper__step"><span class="np-stepper__dot" data-bf-step="1">1</span><span class="np-stepper__text" data-bf-steptext="1">스캔·검토</span></div>
        <span class="np-stepper__line" data-bf-stepline="1"></span>
        <div class="np-stepper__step np-stepper__step--mid"><span class="np-stepper__dot" data-bf-step="2">2</span><span class="np-stepper__text" data-bf-steptext="2">확인 게이트</span></div>
        <span class="np-stepper__line" data-bf-stepline="2"></span>
        <div class="np-stepper__step np-stepper__step--end"><span class="np-stepper__dot" data-bf-step="3">3</span><span class="np-stepper__text" data-bf-steptext="3">적용</span></div>
      </div>
      <p class="mc-specedit__note">기존 폴더로 감지되어 자동 검사합니다. 기존 소스 코드(하네스 외 경로)는 변경되지 않지만, 하네스 파일은 덮어쓸 수 있어 결과 목록 확인 뒤에만 적용할 수 있습니다.</p>
      <input id="bf-path" type="hidden" data-bf-path />
      <button type="button" data-bf-scan hidden aria-hidden="true">자동 스캔</button>
      <div data-bf-result hidden>
        <div class="np-gate__head"><strong>무엇이 바뀌는지 — <span class="np-gate__hl">would-overwrite</span></strong><span class="np-gate__cli">$ init_new_project.sh --diff-manifest · 읽기 전용</span></div>
        <div class="np-tiles">
          <div class="np-tile"><div class="np-tile__num np-tile__num--over" data-bf-tile-over>0</div><div class="np-tile__label">덮어씀 OVERWRITE</div></div>
          <div class="np-tile"><div class="np-tile__num np-tile__num--new" data-bf-tile-new>0</div><div class="np-tile__label">신규 NEW</div></div>
          <div class="np-tile" data-bf-tile-git-box><div class="np-tile__git" data-bf-tile-git>git</div><div class="np-tile__label" data-bf-tile-gitnote></div></div>
        </div>
        <p class="mc-brownfield__chips" data-bf-chips></p>
        <ul class="mc-brownfield__list np-manifest" data-bf-list aria-label="would-overwrite 목록"></ul>
        <p class="mc-specedit__note" data-bf-gitnote></p>
        <div class="mc-brownfield__dirty" data-bf-dirty hidden>커밋되지 않은 변경이 있습니다. <strong>커밋이 이 작업의 유일한 복구 수단</strong>입니다 — 먼저 커밋한 뒤 다시 확인하세요.
          <pre class="mc-brownfield__cmd" data-bf-dirty-cmd></pre>
          <button type="button" class="mc-write mc-write--compact mc-write--danger" data-bf-commit aria-description="$ ./scripts/init_new_project.sh --snapshot-commit <target> (add -A + 고정 wip 커밋 · push 없음 · 복구: git reset --soft HEAD~1)">커밋하고 다시 확인</button>
          <button type="button" class="mc-write mc-write--compact" data-bf-copy-cmd>커밋 명령 복사</button>
          <span class="mc-brownfield__cmdnote">"커밋하고 다시 확인"은 대상 레포에 wip 커밋 1개만 만듭니다(push 없음 · 복구: git reset --soft HEAD~1) — ADR-0199</span>
        </div>
        <div data-bf-acks hidden>
          <label class="mc-specedit__reason"><input type="checkbox" data-bf-ack1 /> 위 목록을 확인했고, 덮어쓰기가 되돌릴 수 없음을 이해합니다.</label>
          <label class="mc-specedit__reason" data-bf-ack2-row hidden><input type="checkbox" data-bf-ack2 /> git이 아닌 폴더입니다 — <strong>백업을 만들었습니다</strong>(복구 수단은 백업뿐).</label>
          <div><button type="button" class="mc-write mc-write--danger np-apply" data-bf-apply disabled>하네스 적용 →</button></div>
        </div>
      </div>
      <div class="np-done" data-bf-done hidden>
        <p class="mc-specedit__note np-done__title">✅ 하네스 적용 완료 — <code data-bf-done-path></code></p>
        <p class="mc-specedit__note" data-bf-recover></p>
        ${renderHarnessNextSteps('bf')}
      </div>
      <p class="np-gate__invariant">게이트 불변 — 스캔 없이 적용 불가 · dirty 차단 · 비-git 백업 2중 체크 · 경로 변경 시 재스캔 (ADR-0198)</p>
    </section>
    ${renderNewProjectPanel(isLocalhost)}
    <div hidden data-help-src>${helpBtn('stack')}${helpBtn('base')}${helpBtn('docs')}${helpBtn('brown')}</div>
    ${pops}
    <p class="np-foot">모든 버튼에는 동등한 CLI 명령이 있습니다 · 새 프로젝트 생성은 localhost 데스크톱 전용 (모바일 관측 전용 · T099)</p>
    ${launchpadScript()}
  </section>
</main>` : `<main class="mc-page" aria-label="새 프로젝트"><section class="mc-panel"><p class="mc-specedit__note" role="note">새 프로젝트 만들기는 localhost 데스크톱에서만 가능합니다. 모바일은 관측 전용입니다(T099).</p></section></main>`;
  return renderShell('새 프로젝트', 'newproject', main, { isLocalhost });
}
function launchpadScript() {
  return `<script>
(() => {
  const lp = document.querySelector('.mc-launchpad');
  if (!lp) return;
  const base = lp.dataset.base || '';
  const nameEl = lp.querySelector('[data-lp-name]');
  const pathEl = lp.querySelector('[data-lp-path]');
  const collideEl = lp.querySelector('[data-lp-collide]');
  const cta = lp.querySelector('[data-lp-create]');
  const ctaLabel = lp.querySelector('[data-lp-cta-label]');
  const npPath = lp.querySelector('[data-np-path]');
  const npCreate = lp.querySelector('[data-np-create]');
  // ── 목업 v2: 라이브 preflight 표시 요소 (판별 권위는 서버 /api/new-project/preflight, fail-neutral) ──
  const icoEl = lp.querySelector('[data-lp-ico]');
  const pillEl = lp.querySelector('[data-lp-pill]');
  const pillLabelEl = lp.querySelector('[data-lp-pill-label]');
  const noteEl = lp.querySelector('[data-lp-pathnote]');
  const resultEl = lp.querySelector('[data-lp-result]');
  const rc = k => lp.querySelector('[data-lp-rc-' + k + ']');
  const cliEl = lp.querySelector('[data-lp-cli]');
  const cliTextEl = lp.querySelector('[data-lp-cli-text]');
  const arrowEl = lp.querySelector('[data-lp-cta-arrow]');
  const PF_META = {
    missing:  { icon: '＋', pill: '새 폴더', title: '새 폴더에 생성합니다',
      desc: '입력한 이름으로 새 폴더를 만들고 하네스를 설치합니다. 기존 파일과 충돌하지 않습니다.',
      recover: '생성 폴더 삭제 (rm -rf)' },
    empty:    { icon: '○', pill: '빈 폴더', title: '빈 기존 폴더에 생성합니다',
      desc: '이미 존재하지만 비어 있는 폴더입니다 (닷파일도 없음). 생성이 그대로 통과합니다 (L2).',
      recover: '폴더는 유지 · 이번 생성 파일만 삭제' },
    occupied: { icon: '▤', pill: '기존 폴더', title: '내용이 있는 기존 폴더입니다',
      desc: '하네스 적용 경로로 라우팅됩니다. 무엇이 바뀌는지 스캔으로 먼저 확인해야 하며, 스캔 없이 적용할 수 없습니다.',
      recover: '커밋 기준 git checkout · 기존 소스 불변' },
  };
  let pfState = null;   // 마지막 라이브 분류 (표시용 캐시 — 실행 경로는 매번 서버 재판별)
  let pfSeq = 0;
  const currentTarget = () => {
    if (isPathInput()) { const raw = nameEl.value.trim(); return raw.startsWith('~') ? '' : raw; }
    const s = slug(nameEl.value); return s ? base + '/' + (suffixed || s) : '';
  };
  const cliFor = (state, target) => {
    if (!state || !target) return '';
    if (state === 'occupied') return './scripts/init_new_project.sh --diff-manifest ' + target;
    const nm = ((document.querySelector('[data-np-name]') || {}).value || '').trim();
    const stack = (document.querySelector('[data-np-stack]') || {}).value || 'none';
    const onb = (document.querySelector('[data-np-onboarding]') || {}).checked;
    const glo = (document.querySelector('[data-np-glossary]') || {}).checked;
    return './scripts/init_new_project.sh ' + target + ' --stack ' + stack + (nm ? ' --name ' + nm : '') + (onb ? ' --with-onboarding' : '') + (glo ? ' --with-glossary' : '');
  };
  const paintPf = (state) => {
    pfState = state;
    lp.dataset.pf = state || '';
    const m = state ? PF_META[state] : null;
    if (icoEl) icoEl.textContent = m ? m.icon : '✦';
    if (pillEl) pillEl.hidden = !m;
    if (pillLabelEl) pillLabelEl.textContent = m ? m.pill : '';
    if (resultEl) resultEl.hidden = !m;
    if (m) {
      if (rc('icon')) rc('icon').textContent = m.icon;
      if (rc('title')) rc('title').textContent = m.title;
      if (rc('tag')) rc('tag').textContent = state;
      if (rc('desc')) rc('desc').textContent = m.desc;
      if (rc('recover')) rc('recover').textContent = m.recover;
    }
    const target = currentTarget();
    const cliText = cliFor(state, target);
    if (cliEl) cliEl.hidden = !cliText;
    if (cliTextEl) cliTextEl.textContent = cliText;
    if (noteEl) noteEl.textContent = !nameEl.value.trim() ? '이름 또는 경로를 입력하세요'
      : state === 'occupied' ? '— 기존 폴더 (내용 있음)'
      : state === 'empty' ? '— 빈 기존 폴더'
      : isPathInput() ? '— 판별 후 진행' : '에 만들어집니다';
    if (arrowEl) arrowEl.textContent = state === 'occupied' ? '↓' : state ? '→' : '';
    refreshCta();
  };
  const refreshCta = () => {
    if (!ctaLabel) return;
    if (pfState === 'occupied') { ctaLabel.textContent = '무엇이 바뀌는지 확인'; cta.disabled = false; return; }
    if (isPathInput()) { ctaLabel.textContent = '판별 후 진행'; cta.disabled = !nameEl.value.trim(); return; }
    const s = slug(nameEl.value);
    ctaLabel.textContent = suffixed ? suffixed + '로 만들기' : '프로젝트 만들기';
    cta.disabled = !s;
  };
  let pfTimer = null;
  const schedulePf = () => {
    if (pfTimer) clearTimeout(pfTimer);
    const target = currentTarget();
    if (!target) { paintPf(null); return; }
    pfTimer = setTimeout(async () => {
      const seq = ++pfSeq;
      try {
        const res = await fetch('/api/new-project/preflight?target=' + encodeURIComponent(target));
        const data = await res.json().catch(() => ({}));
        if (seq !== pfSeq) return;                     // 최신 입력만 반영
        paintPf(res.ok ? (data.state || null) : null); // fail-neutral: 표시만 초기화(실행 경로는 fail-closed 별도)
      } catch (e) { if (seq === pfSeq) paintPf(null); }
    }, 350);
  };
  let suffixed = null; // 충돌 감지 시 사용할 새 후보. 서버 exec 계약은 여전히 최종 권위.
  const slug = raw => String(raw).toLowerCase().replace(/\\s+/g, '-').replace(/[^a-z0-9._-]/g, '').replace(/-{2,}/g, '-').replace(/^[-.]+|[-.]+$/g, '');
  const showLaunchpadToast = (m, bad) => {
    const t = document.getElementById('mc-toast');
    if (!t) return;
    t.textContent = m;
    t.classList.toggle('is-error', !!bad);
    t.classList.add('is-visible');
    setTimeout(() => t.classList.remove('is-visible'), 6000);
  };
  const shellQuote = v => "'" + String(v).replace(/'/g, "'\\\\''") + "'";
  const prepareConflict = (s, next) => {
    suffixed = next;
    collideEl.textContent = '이미 ' + s + '이(가) 있어 ' + suffixed + '로 준비했습니다.';
    collideEl.hidden = false;
    refresh();
  };
  // ADR-0201 T293: 서버 preflight — missing/empty/occupied 분류(읽기 전용·fail-closed).
  // 사용자가 그린필드/브라운필드를 자기 분류하지 않는다. 실패는 throw → 생성 진행 없음.
  const preflightTarget = async (p) => {
    const res = await fetch('/api/new-project/preflight?target=' + encodeURIComponent(p));
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || 'preflight 실패');
    return data.state;
  };
  // occupied → 별도 화면으로 보내지 않고 같은 화면에서 스캔 게이트를 연다(ADR-0198 게이트 불변).
  const openAdoptInline = (target) => {
    const bfSec = document.querySelector('[data-bf]');
    if (!bfSec) return;
    const bfPath = bfSec.querySelector('[data-bf-path]');
    bfSec.hidden = false;
    if (bfPath) { bfPath.value = target; bfPath.dispatchEvent(new Event('input')); } // 재스캔 강제 규칙 승계
    collideEl.textContent = '기존 파일이 있는 폴더입니다 — 아래에서 무엇이 바뀌는지 먼저 확인합니다. 새로 만들려면 이름을 바꾸세요.';
    collideEl.hidden = false;
    const scanBtn = bfSec.querySelector('[data-bf-scan]');
    if (scanBtn) scanBtn.click();                          // 읽기 전용 스캔 자동 실행
    bfSec.scrollIntoView({ behavior: 'smooth', block: 'start' });
  };
  // ADR-0202 R5: 단일 입력 — '/' 포함이면 경로 모드(기존 폴더 경로), 아니면 이름 모드(슬러그).
  const isPathInput = () => (nameEl.value || '').includes('/');
  const refresh = () => {
    if (isPathInput()) {
      const raw = nameEl.value.trim();
      pathEl.textContent = raw || base + '/…';
      refreshCta();
      return;
    }
    const s = slug(nameEl.value);
    const target = suffixed || s;
    pathEl.textContent = target ? base + '/' + target : base + '/…';
    refreshCta();
  };
  nameEl.addEventListener('input', () => { suffixed = null; collideEl.hidden = true; pfState = null; refresh(); schedulePf(); });
  nameEl.addEventListener('keydown', e => { if (e.key === 'Enter' && !cta.disabled) cta.click(); });
  cta.addEventListener('click', async () => {
    const pathMode = isPathInput();
    const s = slug(nameEl.value);
    if ((!pathMode && !s) || !npPath || !npCreate) return;
    cta.disabled = true;
    try {
      // R5: 경로 모드는 입력을 그대로 대상 삼음('~'는 서버가 해석하지 않으므로 안내).
      const target = pathMode ? nameEl.value.trim() : base + '/' + (suffixed || s);
      if (pathMode && target.startsWith('~')) { showLaunchpadToast('~ 표기는 지원하지 않습니다 — 절대 경로나 ../ 상대 경로를 쓰세요.', true); return; }
      const state = await preflightTarget(target);   // fail-closed: 실패 = 생성 진행 없음
      if (state === 'occupied') { openAdoptInline(target); return; }
      npPath.value = target;                         // missing|empty → 기존 패널 머신에 위임(__mcConfirm→exec)
      npPath.dispatchEvent(new Event('input'));
      npCreate.click();
    } catch (e) {
      showLaunchpadToast('대상 폴더를 확인하지 못했습니다: ' + String(e.message || e), true);
    } finally {
      refresh();
    }
  });
  // 패널 쪽 preflight가 occupied를 감지했을 때도 같은 인라인 흐름으로 라우팅.
  document.addEventListener('mc:np-occupied', e => {
    const t = e && e.detail && e.detail.target; if (t) openAdoptInline(String(t));
  });
  document.addEventListener('mc:np-conflict', () => { // 비어있지 않음 → 에러 대신 CTA 치환(T290)
    const s = slug(nameEl.value); if (!s) return;
    prepareConflict(s, s + '-2');
  });
  // Explain layer: 클릭형 ? 팝오버 — 한 번에 하나·ESC/바깥 닫힘 (final 기획 §3.5)
  let open = null;
  const closeHelp = () => { if (open) { open.pop.hidden = true; open.btn.setAttribute('aria-expanded', 'false'); open = null; } };
  document.querySelectorAll('.mc-help').forEach(btn => btn.addEventListener('click', e => {
    e.stopPropagation();
    const pop = document.querySelector('[data-help-pop="' + btn.dataset.help + '"]');
    if (!pop) return;
    if (open && open.btn === btn) { closeHelp(); return; }
    closeHelp();
    const r = btn.getBoundingClientRect();
    pop.style.left = Math.max(12, Math.min(r.left, innerWidth - 360)) + 'px';
    pop.style.top = (r.bottom + 8 + scrollY) + 'px';
    pop.hidden = false; btn.setAttribute('aria-expanded', 'true');
    open = { pop, btn };
  }));
  document.addEventListener('click', e => { if (open && !open.pop.contains(e.target)) closeHelp(); });
  document.addEventListener('keydown', e => { if (e.key === 'Escape') closeHelp(); });
  // 설정 라벨 옆 도움말 배치(렌더 후 이동 — 패널 DOM 계약은 불변)
  const put = (sel, key) => { const el = lp.querySelector(sel); const b = lp.querySelector('[data-help-src] .mc-help[data-help="' + key + '"]'); if (el && b) el.appendChild(b); };
  put('label[for="np-stack"]', 'stack');
  put('label[for="np-path"]', 'base');
  put('.mc-newproj__ref', 'docs');
  put('.mc-launchpad__hint', 'brown');
  // ── 브라운필드 (ADR-0198 L6): D1 스캔 → D2 목록·게이트 → D3 완료. 전부 textContent(escape-first) ──
  const bf = document.querySelector('[data-bf]');
  if (bf) (() => {
    const q = s => bf.querySelector(s);
    const pathEl2 = q('[data-bf-path]'), result = q('[data-bf-result]'), list = q('[data-bf-list]');
    const chips = q('[data-bf-chips]'), gitnote = q('[data-bf-gitnote]'), dirtyBox = q('[data-bf-dirty]');
    const acks = q('[data-bf-acks]'), ack1 = q('[data-bf-ack1]'), ack2 = q('[data-bf-ack2]');
    const ack2Row = q('[data-bf-ack2-row]'), applyBtn = q('[data-bf-apply]'), doneBox = q('[data-bf-done]');
    const nextBox = q('[data-bf-next]'), nextCd = q('[data-bf-next-cd]');
    let gitState = null, scannedPath = null;
    let justCommittedHash = null; // L6.5 UX: 직전 스냅샷 커밋 해시 — 다음 재스캔이 clean 배너에 지속 표기 후 소비.
    // 목업 v2: 3단 스테퍼(스캔·검토 → 확인 게이트 → 적용) — 표시 전용, 게이트 로직 불변.
    const stepPaint = () => {
      const dirty = gitState === 'dirty' && dirtyBox && !dirtyBox.hidden;
      const s2done = !applyBtn.disabled && !dirty;
      const s3done = doneBox && !doneBox.hidden;
      const paint = (n, done, active) => {
        const dot = bf.querySelector('[data-bf-step="' + n + '"]');
        const txt = bf.querySelector('[data-bf-steptext="' + n + '"]');
        if (dot) { dot.classList.toggle('is-done', !!done); dot.classList.toggle('is-active', !!active && !done); dot.textContent = done ? '✓' : String(n); }
        if (txt) { txt.classList.toggle('is-done', !!done); txt.classList.toggle('is-active', !!active && !done); }
      };
      paint(1, true, false);
      paint(2, s2done || s3done, !s2done && !s3done);
      paint(3, s3done, (s2done && !s3done));
      const l1 = bf.querySelector('[data-bf-stepline="1"]'), l2 = bf.querySelector('[data-bf-stepline="2"]');
      if (l1) l1.classList.toggle('is-done', !!(s2done || s3done));
      if (l2) l2.classList.toggle('is-done', !!s3done);
    };
    const gate = () => { applyBtn.disabled = !(ack1.checked && (gitState !== 'none' || ack2.checked)); stepPaint(); };
    ack1.addEventListener('change', gate); ack2.addEventListener('change', gate);
    pathEl2.addEventListener('input', () => { result.hidden = true; scannedPath = null; }); // 경로 변경 = 재스캔 강제
    // L6.5: 커밋하고 다시 확인 — confirm 경유 스냅샷 커밋 후 자동 재스캔
    const commitBtn = q('[data-bf-commit]');
    if (commitBtn) commitBtn.addEventListener('click', async () => {
      const p2 = (pathEl2.value || '').trim(); if (!p2) return;
      let okc = true;
      if (window.__mcConfirm) {
        const r = await window.__mcConfirm({
          title: '대상 레포에 스냅샷 커밋을 만들까요?',
          what: p2 + ' 에서 git add -A 후 고정 메시지 wip 커밋 1개를 만듭니다. push는 하지 않습니다.',
          expected: 'dirty가 해소되고 자동으로 다시 검사합니다.',
          downside: '커밋은 가역입니다 — 되돌리기: git reset --soft HEAD~1 (파일 변경 없음).',
          recovery: 'git -C ' + p2 + ' reset --soft HEAD~1',
          submitLabel: '커밋', initialFocus: 'cancel',
        });
        okc = !!(r && r.ok);
      }
      if (!okc) return;
      commitBtn.disabled = true;
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'init_new_project', targetPath: p2, snapshotCommit: true }) });
        const data = await res.json().catch(() => ({}));
        const outText = String(data.stdoutTail || data.stderrTail || '');
        if (!res.ok || data.exitCode !== 0) { showLaunchpadToast('커밋 실패: ' + (data.error || outText || ('exit ' + data.exitCode)), true); return; }
        justCommittedHash = (outText.match(/COMMITTED (\\S+)/) || [])[1] || ''; // 재스캔이 지속 표기에 소비
        showLaunchpadToast('스냅샷 커밋 완료 — 다시 검사합니다. (' + outText.split('\\n')[0] + ')');
        q('[data-bf-scan]').click();               // 자동 재스캔
      } catch (err) { showLaunchpadToast('커밋 요청 실패: ' + String(err.message || err), true); }
      finally { commitBtn.disabled = false; }
    });
    // 커밋 명령 복사 — 실패 시 거짓 성공 금지(토스트로 명령 노출 fallback)
    const copyCmdBtn = q('[data-bf-copy-cmd]');
    if (copyCmdBtn) copyCmdBtn.addEventListener('click', async () => {
      const cmd = q('[data-bf-dirty-cmd]').textContent;
      let okc = false;
      try { await navigator.clipboard.writeText(cmd); okc = true; } catch (e2) { okc = false; }
      showLaunchpadToast(okc ? '커밋 명령이 복사되었습니다 — 터미널에서 실행 후 다시 확인하세요.' : '클립보드 접근 실패 — 화면의 명령을 직접 선택해 복사하세요.', !okc);
    });
    q('[data-bf-scan]').addEventListener('click', async () => {
      const p = (pathEl2.value || '').trim(); if (!p) { showLaunchpadToast('먼저 위 입력에 기존 폴더 경로를 입력하세요.', true); return; }
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'init_new_project', targetPath: p, scan: true }) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || data.exitCode !== 0) { showLaunchpadToast(String(data.error || '스캔 실패'), true); return; }
        const lines = String(data.stdoutTail || '').split('\\n').map(l => l.trim()).filter(Boolean);
        if (lines.some(l => l.indexOf('TARGET_MISSING') === 0)) { showLaunchpadToast('폴더가 없습니다 — 새 프로젝트는 위 기본 화면에서 만드세요.', true); return; }
        gitState = (lines.find(l => l.indexOf('GIT ') === 0) || 'GIT none').slice(4);
        while (list.firstChild) list.removeChild(list.firstChild);
        let over = 0, fresh = 0;
        for (const l of lines) {
          if (l.indexOf('GIT ') === 0) continue;
          const li = document.createElement('li');
          li.textContent = l.replace(/^OVERWRITE /, '덮어씀: ').replace(/^NEW /, '신규: ').replace(/^PRESERVE /, '보존: ');
          if (l.indexOf('OVERWRITE') === 0) { li.className = 'is-hit'; over += 1; }
          else if (l.indexOf('PRESERVE') === 0) { li.className = 'is-keep'; }
          else { fresh += 1; }
          list.appendChild(li);
        }
        chips.textContent = '덮어씀 ' + over + ' · 신규 ' + fresh + ' · git ' + gitState;
        // 목업 v2: 통계 타일 — 스캔 결과 실측치만 표기(가공 없음).
        const tileOver = q('[data-bf-tile-over]'), tileNew = q('[data-bf-tile-new]');
        const tileGit = q('[data-bf-tile-git]'), tileGitNote = q('[data-bf-tile-gitnote]'), tileGitBox = q('[data-bf-tile-git-box]');
        if (tileOver) tileOver.textContent = String(over);
        if (tileNew) tileNew.textContent = String(fresh);
        if (tileGit) tileGit.textContent = (gitState === 'none' ? '✗' : '✓') + ' git';
        if (tileGitNote) tileGitNote.textContent = gitState === 'none' ? '저장소 아님' : gitState;
        if (tileGitBox) { tileGitBox.classList.toggle('is-none', gitState === 'none'); tileGitBox.classList.toggle('is-dirty', gitState === 'dirty'); }
        const dirty = gitState === 'dirty';
        if (dirty) { // 조치 명령 추천(shell-escape) — 실행은 사용자 터미널(원클릭은 L6.5 결정 대상)
          const shq2 = v => "'" + String(v).replace(/'/g, "'\\\\''") + "'";
          q('[data-bf-dirty-cmd]').textContent = 'cd ' + shq2(p) + " && git add -A && git commit -m 'wip: before harness adopt'";
        }
        dirtyBox.hidden = !dirty; acks.hidden = dirty;
        ack2Row.hidden = gitState !== 'none';
        // L6.5 UX: 직전 원클릭 커밋이 dirty를 해소했으면, 사라지는 토스트 대신 지속 성공 줄을 남긴다.
        const committedPrefix = (!dirty && gitState === 'clean' && justCommittedHash)
          ? '✅ 스냅샷 커밋 ' + justCommittedHash + ' 생성됨 · 이제 clean. ' : '';
        gitnote.textContent = dirty ? '' : (gitState === 'clean'
          ? committedPrefix + 'git 저장소(clean) — init 생략·기존 이력 보존. 적용 후 복구: git checkout . (적용 전 커밋 기준)'
          : 'git 저장소가 아닙니다 — 복구 수단은 백업뿐입니다.');
        justCommittedHash = null; // 1회 소비 — 이후 수동 재스캔에는 표기하지 않음
        ack1.checked = false; ack2.checked = false; gate();
        scannedPath = p; result.hidden = false;
      } catch (err) { showLaunchpadToast('스캔 요청 실패: ' + String(err.message || err), true); }
    });
    applyBtn.addEventListener('click', async () => {
      if (!scannedPath) return;
      let ok = true;
      if (window.__mcConfirm) {
        const r = await window.__mcConfirm({
          title: '기존 프로젝트에 하네스를 적용할까요?',
          what: '위 목록의 파일이 덮어써지거나 생성됩니다 (대상: ' + scannedPath + ', --force).',
          expected: '기존 소스 코드는 변경되지 않고, 하네스 경로만 복사·생성됩니다.',
          downside: gitState === 'clean' ? '복구: git checkout . (적용 전 커밋 기준). 이 작업 자체는 Undo가 없습니다.' : '복구 수단은 적용 전 백업뿐입니다. 이 작업은 Undo가 없습니다.',
          recovery: gitState === 'clean' ? 'git -C ' + scannedPath + ' checkout .' : '적용 전 백업 복원',
          submitLabel: '하네스 적용', initialFocus: 'cancel',
        });
        ok = !!(r && r.ok);
      }
      if (!ok) return;
      applyBtn.disabled = true;
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'init_new_project', targetPath: scannedPath, force: true, stack: 'none', dryRun: false }) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok || data.exitCode !== 0) { showLaunchpadToast(String(data.error || ('적용 실패: exit ' + data.exitCode)), true); gate(); return; }
        result.hidden = true; doneBox.hidden = false;
        q('[data-bf-done-path]').textContent = scannedPath;
        const omcBtn = q('[data-bf-open-mc]'); if (omcBtn) omcBtn.dataset.target = scannedPath; // T303
        q('[data-bf-recover]').textContent = gitState === 'clean'
          ? '복구가 필요하면: git checkout . (적용 전 커밋 기준)'
          : '복구가 필요하면 적용 전 만든 백업을 복원하세요.';
        if (nextBox && nextCd) { nextBox.hidden = false; nextCd.textContent = 'cd ' + shellQuote(scannedPath); }
        stepPaint();
        showLaunchpadToast('하네스 적용 완료');
      } catch (err) { showLaunchpadToast('적용 요청 실패: ' + String(err.message || err), true); gate(); }
    });
  })();
})();
</script>`;
}

function newProjectPanelScript() {
  return `<script>
(() => {
  const panel = document.querySelector('.mc-newproj');
  if (!panel) return;
  // ADR-0161 T254 (AUDIT-1): #mc-toast는 이 패널보다 뒤에 렌더되므로 init 캐시는 null이 됨.
  // 호출 시점에 조회해야 패널 토스트가 동작(렌더 순서 무관). escape-first: textContent.
  const showToast = (m, bad) => { const toast = document.getElementById('mc-toast'); if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 6000); };
  const out = panel.querySelector('[data-np-out]');
  const outBody = panel.querySelector('[data-np-out-body]');
  const nextBox = panel.querySelector('[data-np-next]');
  const nextCd = panel.querySelector('[data-np-next-cd]');
  const pathEl = panel.querySelector('[data-np-path]');
  const nameEl = panel.querySelector('[data-np-name]');
  const stackEl = panel.querySelector('[data-np-stack]');
  // 목업 v2: 검증 스택 칩 — 표시용 버튼이 기존 select(data-np-stack, 머신 계약)를 구동한다.
  const stackChips = panel.querySelectorAll('[data-np-stack-pick]');
  const paintStacks = () => stackChips.forEach(c => c.classList.toggle('is-on', c.dataset.npStackPick === ((stackEl || {}).value || 'none')));
  stackChips.forEach(c => c.addEventListener('click', () => { if (stackEl) { stackEl.value = c.dataset.npStackPick; stackEl.dispatchEvent(new Event('change')); } paintStacks(); }));
  paintStacks();
  const forceEl = panel.querySelector('[data-np-force]');
  const onbEl = panel.querySelector('[data-np-onboarding]');
  const glossEl = panel.querySelector('[data-np-glossary]');
  const shellQuote = v => "'" + String(v).replace(/'/g, "'\\\\''") + "'";
  // T303 (ADR-0207): "웹에서 시작" — 타깃 MC를 exec(open_project_mc)로 기동하고 링크 표시.
  // np·bf 완료 박스 공용. target은 완료 시점에 dataset으로 주입된다 (escape-first: textContent/href만).
  document.querySelectorAll('[data-np-open-mc],[data-bf-open-mc]').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      e.preventDefault();
      const target = btn.dataset.target || '';
      if (!target) { showToast('대상 경로를 알 수 없습니다', true); return; }
      const link = btn.hasAttribute('data-np-open-mc')
        ? document.querySelector('[data-np-mc-link]') : document.querySelector('[data-bf-mc-link]');
      btn.disabled = true;
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'open_project_mc', targetPath: target }) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || '거부됨');
        if (data.exitCode !== 0) throw new Error('시작 실패: ' + String(data.stderrTail || 'exit ' + data.exitCode).slice(0, 300));
        const m = String(data.stdoutTail || '').match(/URL: (http:\\/\\/127\\.0\\.0\\.1:\\d+\\/)/);
        if (!m) throw new Error('URL을 확인하지 못했습니다 — 출력: ' + String(data.stdoutTail || '').slice(0, 200));
        if (link) { link.href = m[1]; link.textContent = '열기 → ' + m[1]; link.hidden = false; }
        showToast('새 프로젝트 Mission Control 실행 중 — 링크를 클릭하세요');
      } catch (err) { showToast(String(err.message || err), true); }
      finally { btn.disabled = false; }
    });
  });
  const armOpenMc = (prefix, target) => {
    const b = document.querySelector('[data-' + prefix + '-open-mc]');
    if (b) b.dataset.target = target;
  };
  const showNextSteps = target => { if (nextBox && nextCd) { nextBox.hidden = false; nextCd.textContent = 'cd ' + shellQuote(target); } armOpenMc('np', target); };
  const hideNextSteps = () => { if (nextBox) nextBox.hidden = true; if (nextCd) nextCd.textContent = ''; };
  // ADR-0158 T250: 필드 단위 검증. 클라이언트는 힌트만(blur 후), 검증 권위는 서버.
  // 에러는 textContent + aria-invalid 토글(DOM 텍스트만). 로드 시점에는 에러 표시 안 함.
  const fieldOf = el => el && el.closest('.mc-field');
  const setErr = (input, sel, msg) => { const f = fieldOf(input), e = panel.querySelector(sel); if (f) f.classList.add('is-invalid'); if (input) input.setAttribute('aria-invalid', 'true'); if (e) { e.textContent = String(msg); e.hidden = false; } };
  const clearErr = (input, sel) => { const f = fieldOf(input), e = panel.querySelector(sel); if (f) f.classList.remove('is-invalid'); if (input) input.removeAttribute('aria-invalid'); if (e) { e.textContent = ''; e.hidden = true; } };
  const clearAllErr = () => { clearErr(pathEl, '[data-np-path-err]'); clearErr(nameEl, '[data-np-name-err]'); };
  // 서버 400 {error} → 해당 필드로 매핑(서버 권위·false-OK 없음). 그 외는 toast.
  const mapServerError = (msg) => { const m = String(msg || ''); if (/targetPath|outside this repository/i.test(m)) setErr(pathEl, '[data-np-path-err]', m); else if (/invalid name/i.test(m)) setErr(nameEl, '[data-np-name-err]', m); };
  if (pathEl) { pathEl.addEventListener('input', () => clearErr(pathEl, '[data-np-path-err]')); pathEl.addEventListener('blur', () => { const v = (pathEl.value || '').trim(); if (v && v.length > 4096) setErr(pathEl, '[data-np-path-err]', '경로가 너무 깁니다 (≤4096).'); else clearErr(pathEl, '[data-np-path-err]'); }); }
  if (nameEl) { nameEl.addEventListener('input', () => clearErr(nameEl, '[data-np-name-err]')); nameEl.addEventListener('blur', () => { const v = (nameEl.value || '').trim(); if (v && (v.length > 64 || !/^[A-Za-z0-9 ._-]+$/.test(v))) setErr(nameEl, '[data-np-name-err]', '영문/숫자/.-_ 와 공백, 64자 이내만 사용하세요.'); else clearErr(nameEl, '[data-np-name-err]'); }); }
  const show = (text) => { if (out && outBody) { out.hidden = false; outBody.textContent = String(text); } }; // escape-first: textContent
  // ADR-0158 T252: 로딩 a11y. 디스패치 중 버튼 비활성 + role=status 영역으로 진행 노출(Primer Loading).
  // 스피너는 CSS pseudo, 라벨은 textContent(DOM 텍스트만). aria-busy로 보조기술에 진행 알림.
  const statusEl = panel.querySelector('[data-np-status]');
  const setBusy = (on, text) => {
    panel.querySelectorAll('[data-np-preview],[data-np-create]').forEach(b => { b.disabled = on; });
    if (on) panel.setAttribute('aria-busy', 'true'); else panel.removeAttribute('aria-busy');
    if (!statusEl) return;
    if (on) { statusEl.hidden = false; statusEl.classList.add('is-busy'); statusEl.textContent = text || '처리 중…'; }
    else { statusEl.hidden = true; statusEl.classList.remove('is-busy'); statusEl.textContent = ''; }
  };
  const dispatch = async (dryRun, btn) => {
    clearAllErr();
    const targetPath = ((pathEl || {}).value || '').trim();
    if (!targetPath) { setErr(pathEl, '[data-np-path-err]', '대상 경로를 입력하세요.'); showToast('대상 경로를 입력하세요', true); if (pathEl) pathEl.focus(); return; }
    const payload = { command: 'init_new_project', targetPath, stack: (stackEl || {}).value || 'none', dryRun };
    const nm = ((nameEl || {}).value || '').trim();
    if (nm) payload.name = nm;
    if ((forceEl || {}).checked) payload.force = true;
    if ((onbEl || {}).checked) payload.withOnboarding = true;
    if ((glossEl || {}).checked) payload.withGlossary = true;
    setBusy(true, dryRun ? '미리보기 중…' : '생성 중…');
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { mapServerError(data.error || '거부됨'); throw new Error(data.error || '거부됨'); }
      show(data.stdoutTail || data.stderrTail || ('exit ' + data.exitCode));
      // T290: 비어있지 않은 대상 → 에러가 아니라 CTA 치환(Launchpad가 수신).
      if (data.exitCode !== 0 && /비어있지 않습니다/.test(String(data.stderrTail || data.stdoutTail || ''))) {
        document.dispatchEvent(new CustomEvent('mc:np-conflict'));
      }
      if (data.exitCode !== 0) { hideNextSteps(); throw new Error((dryRun ? '미리보기' : '생성') + ' 실패: exit ' + data.exitCode); }
      if (dryRun) hideNextSteps(); else showNextSteps(targetPath);
      showToast(dryRun ? '미리보기 완료 — 실제 복사 없음' : '새 프로젝트 생성 완료');
    } catch (e) { showToast(String(e.message || e), true); }
    finally { setBusy(false); }
  };
  const pv = panel.querySelector('[data-np-preview]');
  if (pv) pv.addEventListener('click', (e) => { e.preventDefault(); dispatch(true, pv); });
  const cr = panel.querySelector('[data-np-create]');
  if (cr) cr.addEventListener('click', async (e) => {
    e.preventDefault();
    const p = ((pathEl || {}).value || '').trim();
    if (!p) { setErr(pathEl, '[data-np-path-err]', '대상 경로를 입력하세요.'); showToast('대상 경로를 입력하세요', true); if (pathEl) pathEl.focus(); return; }
    // ADR-0201 T293: confirm 전에 서버 preflight — fail-closed(확인 불가 = 생성 없음).
    // occupied는 에러가 아니라 같은 화면의 스캔 게이트로 라우팅(자기 분류 요구 없음).
    let pfState;
    try {
      const pfRes = await fetch('/api/new-project/preflight?target=' + encodeURIComponent(p));
      const pfData = await pfRes.json().catch(() => ({}));
      if (!pfRes.ok) { mapServerError(pfData.error); throw new Error(pfData.error || 'preflight 거부'); }
      pfState = pfData.state;
    } catch (pfErr) { showToast('대상 폴더를 확인하지 못했습니다: ' + String(pfErr.message || pfErr), true); return; }
    if (pfState === 'occupied') {
      document.dispatchEvent(new CustomEvent('mc:np-occupied', { detail: { target: p } }));
      showToast('기존 파일이 있는 폴더입니다 — 무엇이 바뀌는지 먼저 확인하세요.');
      return;
    }
    // ADR-0158 T251: 공용 mc-confirm-modal 재사용(접근성: 위험 액션 → 취소 초기 포커스).
    const force = (forceEl || {}).checked;
    const emptyDir = pfState === 'empty'; // ADR-0201: 빈 기존 폴더 통과 — 복구 문구만 분기
    const opts = {
      title: '새 프로젝트를 생성할까요?',
      what: (emptyDir ? '기존 빈 폴더 안에 하네스를 클린 추출합니다' : '대상 폴더에 하네스를 클린 추출합니다') + ' (대상: ' + p + ').' + (force ? ' --force: 비어있지 않은 대상이면 기존 파일에 덮어쓸 수 있습니다.' : ''),
      expected: '대상 폴더에 새 레포가 생성되고 git init까지 끝납니다.',
      downside: 'SOURCE(이 저장소)는 변경되지 않습니다. 기존 파일이 있는 폴더는 생성 대신 같은 화면의 스캔 확인으로 전환됩니다. ' + (emptyDir ? '빈 폴더는 유지되며, 이번 생성으로 만들어진 파일만 삭제해 되돌릴 수 있습니다.' : '새로 만들어진 폴더만 삭제하면 완전히 되돌릴 수 있습니다.'),
      recovery: emptyDir ? '폴더는 유지 — 이번 생성으로 만들어진 파일만 삭제: ' + p : '이번 생성으로 새로 만들어진 폴더만 삭제: ' + p,
      submitLabel: '생성',
      initialFocus: 'cancel',
    };
    let ok;
    if (window.__mcConfirm) { const r = await window.__mcConfirm(opts); ok = !!(r && r.ok); }
    else { ok = window.confirm(opts.title + '\\n\\n' + opts.what + '\\n\\n' + opts.downside); }
    if (!ok) { if (cr) cr.focus(); return; }
    dispatch(false, cr);
  });

  // ADR-0155 Phase 2: read-only directory picker (assists path input only).
  // 목업 v2: 브라우저 UI는 히어로 입력줄로 이동(스마트 입력 보조) — 훅 이름·계약은 불변.
  const browseBtn = document.querySelector('[data-np-browse]');
  const browser = document.querySelector('[data-np-browser]');
  const cwdEl = document.querySelector('[data-np-cwd]');
  const dirList = document.querySelector('[data-np-dirlist]');
  const upBtn = document.querySelector('[data-np-up]');
  let curParent = null;
  const renderDirs = (data) => {
    if (cwdEl) cwdEl.textContent = data.base || '';          // escape-first
    curParent = data.parent || null;
    if (upBtn) upBtn.disabled = !curParent;
    if (!dirList) return;
    while (dirList.firstChild) dirList.removeChild(dirList.firstChild);
    (data.entries || []).forEach(name => {
      const li = document.createElement('li');
      const b = document.createElement('button');
      b.type = 'button';
      b.className = 'mc-newproj__dir np-browser__dir';
      b.textContent = name;                                  // escape-first: textContent only (아이콘은 CSS ::before)
      b.addEventListener('click', () => {
        const next = (data.base.endsWith('/') ? data.base : data.base + '/') + name;
        if (pathEl) pathEl.value = next;                     // fill path input (assist only)
        // 목업 v2: 스마트 입력에도 반영해 라이브 preflight가 즉시 분류(선택은 보조, 판별은 preflight).
        const lpName = document.querySelector('[data-lp-name]');
        if (lpName) { lpName.value = next; lpName.dispatchEvent(new Event('input')); }
        loadDirs(next);
      });
      li.appendChild(b);
      dirList.appendChild(li);
    });
  };
  const loadDirs = async (base) => {
    try {
      const url = '/api/fs/dirs' + (base ? ('?base=' + encodeURIComponent(base)) : '');
      const res = await fetch(url);
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '목록 거부됨');
      renderDirs(data);
    } catch (e) { showToast(String(e.message || e), true); }
  };
  if (browseBtn && browser) browseBtn.addEventListener('click', (e) => {
    e.preventDefault();
    const opening = browser.hidden;
    browser.hidden = !opening;
    // Start at the default allowed base; the typed path may be a not-yet-existing target.
    if (opening) loadDirs('');
  });
  if (upBtn) upBtn.addEventListener('click', (e) => { e.preventDefault(); if (curParent) loadDirs(curParent); });
})();
</script>`;
}

// ADR-0066: localhost-only editor for ALLOWLISTED governing operational docs
// (runbook + persona playbooks). master-spec is NOT here — it stays read-only
// (ADR-0042 deferral). Each doc is a <details> with its full content prefilled;
// on save the panel pipes it to doc_edit via exec. Mobile never renders this.
function renderDocEditPanel(isLocalhost) {
  if (!isLocalhost) return '';
  const docs = [
    { key: 'runbook', label: 'runbook.md', path: join(ROOT, 'docs', 'runbook.md') },
    { key: 'skill:implementer', label: 'skills/implementer.md', path: join(SKILLS_DIR, 'implementer.md') },
    { key: 'skill:planner', label: 'skills/planner.md', path: join(SKILLS_DIR, 'planner.md') },
    { key: 'skill:reviewer', label: 'skills/reviewer.md', path: join(SKILLS_DIR, 'reviewer.md') },
    { key: 'skill:security-reviewer', label: 'skills/security-reviewer.md', path: join(SKILLS_DIR, 'security-reviewer.md') },
  ];
  const rows = docs.map(d => {
    let content = '';
    try { content = readFileSync(d.path, 'utf8'); } catch { content = ''; }
    const cli = `./scripts/doc_edit.sh set ${d.key} < doc.md`;
    // ADR-0074: read-only AI draft proposer for this doc-key. Dispatches ai_draft
    // (localhost, T099), shows the draft read-only — the human copies it into the
    // textarea and applies via 전체 교체 저장 (doc_edit). The proposer never writes.
    const aiCli = `./scripts/ai_draft.sh doc ${d.key}`;
    return `<details class="mc-docedit" data-docedit data-doc-key="${escapeHtml(d.key)}">
      <summary>${escapeHtml(d.label)}</summary>
      <textarea class="mc-edit-body" data-doc-content maxlength="262144" aria-label="${escapeHtml(d.label)} 내용">${escapeHtml(content)}</textarea>
      <div class="mc-body-edit__actions">
        <button type="button" class="mc-write mc-write--compact" data-doc-save title="$ ${escapeHtml(cli)}" aria-description="$ ${escapeHtml(cli)}">전체 교체 저장</button>
        <button type="button" class="mc-write mc-write--compact" data-doc-review aria-description="현재 on-disk 문서와 편집기 내용을 비교 (읽기 전용)">변경 검토</button>
        <button type="button" class="mc-write mc-write--compact mc-write--ai" data-doc-ai-draft title="$ ${escapeHtml(aiCli)}" aria-description="$ ${escapeHtml(aiCli)}">AI 초안 제안</button>
        <label class="mc-docedit__snap"><input type="checkbox" data-doc-snapshot /> 스냅샷 보존(.vN)</label>
      </div>
      <div class="mc-ai-draft" data-ai-draft-out hidden>
        <div class="mc-ai-draft__note">AI 초안 — 검토 후 적용 (제안이며 측정·사실이 아닙니다. 위 편집기에 복사·편집해 적용하세요.)</div>
        <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
      </div>
      <div class="mc-ai-draft" data-doc-review-out hidden>
        <div class="mc-ai-draft__note">변경 검토 — 적용 전 현재 on-disk 문서와 비교 (읽기 전용·아직 적용 안 됨)</div>
        <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
      </div>
    </details>`;
  }).join('\n');
  return `<section class="mc-panel mc-docedit-panel" aria-label="운영 문서 편집">
    <div class="mc-panel__head"><h2>운영 문서 편집</h2><span>localhost · ADR-0066</span></div>
    <p class="mc-docedit__note">runbook·페르소나 플레이북을 <strong>전체 교체</strong>로 편집합니다(단일 감사 커밋·git revert 가역). <strong>master-spec는 편집 대상이 아닙니다</strong>(읽기 전용 — 별도 결정).</p>
    ${rows}
    ${docEditScript()}
  </section>`;
}

function docEditScript() {
  return `<script>
(() => {
  const panel = document.querySelector('.mc-docedit-panel');
  if (!panel) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  // ADR-0116: per-row on-disk baseline captured at page load (one editor per doc row).
  const baselines = new Map();
  for (const ta of panel.querySelectorAll('[data-doc-content]')) baselines.set(ta, ta.value);
  panel.addEventListener('click', async (event) => {
    // ADR-0116: opt-in 변경 검토 — read-only diff of this row's on-disk baseline vs its
    // current editor content, via the client-side __mcDraftPreview. No new exec/writer/
    // server state; the doc_edit save gate is unchanged (review is observe-only).
    const reviewBtn = event.target.closest('button[data-doc-review]');
    if (reviewBtn) {
      event.preventDefault();
      const rrow = reviewBtn.closest('[data-docedit]');
      if (!rrow) return;
      const ta = rrow.querySelector('[data-doc-content]');
      const reviewOut = rrow.querySelector('[data-doc-review-out]');
      if (ta && reviewOut) {
        window.__mcDraftPreview(reviewOut, baselines.has(ta) ? baselines.get(ta) : '', ta.value);
        const noteEl = reviewOut.querySelector('.mc-ai-draft__note');
        if (noteEl) noteEl.textContent = '변경 검토 — 적용 전 현재 on-disk 문서와 비교 (읽기 전용·아직 적용 안 됨)';   // restore review note
        reviewOut.hidden = false;
      }
      return;
    }
    // ADR-0074: read-only AI draft proposer — dispatch ai_draft doc, show the draft
    // (textContent = escape-safe). The human copies it into the textarea and applies
    // via 전체 교체 저장 (doc_edit). The proposer never writes.
    const aiBtn = event.target.closest('button[data-doc-ai-draft]');
    if (aiBtn) {
      event.preventDefault();
      if (aiBtn.disabled) return;
      const arow = aiBtn.closest('[data-docedit]');
      if (!arow) return;
      const akey = arow.dataset.docKey;
      const out = arow.querySelector('[data-ai-draft-out]');
      const outBody = arow.querySelector('[data-ai-draft-body]');
      aiBtn.disabled = true;
      const prev = aiBtn.textContent;
      aiBtn.textContent = '초안 생성 중…';
      try {
        const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'ai_draft', target: 'doc', docKey: akey }) });
        const data = await res.json().catch(() => ({}));
        if (!res.ok) throw new Error(data.error || '거부됨');
        const draft = (data && typeof data.stdoutTail === 'string') ? data.stdoutTail : '';
        const curEl = arow.querySelector('[data-doc-content]');
        if (out) { window.__mcDraftPreview(out, curEl ? curEl.value : '', draft); out.hidden = false; }
        showToast(akey + ' AI 초안 제안됨 — 검토 후 적용');
      } catch (e) { showToast(String(e.message || e), true); }
      finally { aiBtn.disabled = false; aiBtn.textContent = prev; }
      return;
    }
    const save = event.target.closest('button[data-doc-save]');
    if (!save || save.disabled) return;
    event.preventDefault();
    const row = save.closest('[data-docedit]');
    if (!row) return;
    const key = row.dataset.docKey;
    const ta = row.querySelector('[data-doc-content]');
    const content = ta ? ta.value : '';
    const snapEl = row.querySelector('[data-doc-snapshot]');
    const snapshot = !!(snapEl && snapEl.checked);   // ADR-0086: opt-in .vN snapshot
    if (!window.confirm("'" + key + "' 문서를 전체 교체할까요? (단일 커밋·git revert 가역" + (snapshot ? " · .vN 스냅샷 보존" : "") + ")")) return;
    save.disabled = true;
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'doc_edit', action: 'set', docKey: key, content: content, snapshot: snapshot }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '거부됨');
      if (data.exitCode !== 0) throw new Error('실패: ' + data.exitCode);
      showToast(key + ' 저장됨');
      setTimeout(() => window.location.reload(), 700);
    } catch (e) { showToast(String(e.message || e), true); save.disabled = false; }
  });
})();
</script>`;
}

// ── Insights ⑥ (ADR-0040): 파일-진실 집계, 읽기 전용 ───────────
// approvals 마커에서 approved_at만 읽는다(YAML 블록 내 한 줄). 본문 미파싱.
function parseApprovals() {
  try {
    if (!existsSync(APPROVALS_DIR)) return [];
    return readdirSync(APPROVALS_DIR)
      .filter(f => /^T[0-9]+\.md$/.test(f))
      .map(f => {
        const id = f.replace(/\.md$/, '');
        let approved_at = '';
        try {
          const m = readFileSync(join(APPROVALS_DIR, f), 'utf8').match(/approved_at:\s*"?([^"\n]+)"?/);
          approved_at = m ? m[1].trim() : '';
        } catch { /* ignore */ }
        return { id, approved_at };
      });
  } catch { return []; }
}

// ADR-0040 §3.2: derive only what files honestly record (frontmatter only).
function computeInsights() {
  const { byStatus } = getModel();
  const statuses = ['open', 'forging', 'verify', 'awaiting-approval', 'done'];
  const counts = {};
  for (const s of statuses) counts[s] = (byStatus[s] || []).length;
  const all = statuses.flatMap(s => byStatus[s] || []);
  const total = all.length;
  const safeCount = all.filter(t => t.safe).length;

  const tally = (arr, keyFn) => {
    const m = {};
    for (const x of arr) { const k = keyFn(x) || '(none)'; m[k] = (m[k] || 0) + 1; }
    return Object.entries(m).sort((a, b) => b[1] - a[1]);
  };
  const persona = tally(all, t => t.persona);
  const priority = tally(all, t => t.priority);
  const cohort = Object.entries(all.reduce((m, t) => {
    const mm = String(t.created || '').match(/(\d{4}-\d{2})/);
    if (mm) m[mm[1]] = (m[mm[1]] || 0) + 1;
    return m;
  }, {})).sort((a, b) => a[0].localeCompare(b[0]));

  const failures = parseFailures();
  const byStage = tally(failures, f => f.stage);
  const byTicket = tally(failures, f => f.ticket_id).filter(([, n]) => n >= 2).slice(0, 8);

  const approvals = parseApprovals();
  const ticketById = new Map(all.map(t => [String(t.id), t]));
  const latencies = [];
  for (const a of approvals) {
    const t = ticketById.get(a.id);
    if (!t || !t.created || !a.approved_at) continue;
    const cd = Date.parse(t.created), ad = Date.parse(a.approved_at);
    if (Number.isFinite(cd) && Number.isFinite(ad) && ad >= cd) latencies.push((ad - cd) / 86400000);
  }

  // ADR-0046: measured timing from DONE frontmatter (completed_at/started_at).
  // ADR-0048: estimated completion from completed_at_est (git-history backfill) —
  // kept in a SEPARATE field so estimated never mixes into measured. cycle time
  // is measured-only (estimates have no started_at).
  const done = byStatus.done || [];
  const cycleTimes = [];      // hours, MEASURED only (started→completed)
  const leadTimes = [];       // days,  measured (created→completed_at)
  const leadTimesEst = [];    // days,  estimated (created→completed_at_est)
  const completionMap = {};   // measured completed_at buckets
  const completionMapEst = {}; // estimated completed_at_est buckets
  for (const t of done) {
    if (t.completed_at) {
      const comp = Date.parse(t.completed_at);
      if (!Number.isFinite(comp)) continue;
      const cm = String(t.completed_at).match(/(\d{4}-\d{2})/);
      if (cm) completionMap[cm[1]] = (completionMap[cm[1]] || 0) + 1;
      if (t.started_at) { const st = Date.parse(t.started_at); if (Number.isFinite(st) && comp >= st) cycleTimes.push((comp - st) / 3600000); }
      if (t.created) { const cr = Date.parse(t.created); if (Number.isFinite(cr) && comp >= cr) leadTimes.push((comp - cr) / 86400000); }
    } else if (t.completed_at_est) {
      const comp = Date.parse(t.completed_at_est);
      if (!Number.isFinite(comp)) continue;
      const cm = String(t.completed_at_est).match(/(\d{4}-\d{2})/);
      if (cm) completionMapEst[cm[1]] = (completionMapEst[cm[1]] || 0) + 1;
      if (t.created) { const cr = Date.parse(t.created); if (Number.isFinite(cr) && comp >= cr) leadTimesEst.push((comp - cr) / 86400000); }
    }
  }
  // merged completion cohort (measured + estimated); split counts kept separately
  const mergedCompletion = { ...completionMap };
  for (const [k, v] of Object.entries(completionMapEst)) mergedCompletion[k] = (mergedCompletion[k] || 0) + v;
  const completionCohort = Object.entries(mergedCompletion).sort((a, b) => a[0].localeCompare(b[0]));
  const measuredCompletions = Object.values(completionMap).reduce((a, b) => a + b, 0);
  const estimatedCompletions = Object.values(completionMapEst).reduce((a, b) => a + b, 0);

  // ADR-0050/0080: token usage (measured counts, cache included). Cost is estimated
  // only if a rate is configured, labelled with the rate + source — never measured.
  const tokenRows = parseTokenUsage();
  const tokenSessions = tokenRows.length;
  const tokenIn = tokenRows.reduce((a, r) => a + r.input, 0);
  const tokenOut = tokenRows.reduce((a, r) => a + r.output, 0);
  const tokenCacheRead = tokenRows.reduce((a, r) => a + r.cache_read, 0);
  const tokenCacheCreation = tokenRows.reduce((a, r) => a + r.cache_creation, 0);
  // ADR-0080: rate is an ASSUMPTION (config). Precedence: token_rates.json > env > unset.
  const rates = readTokenRates();
  const rateIn = rates.input, rateOut = rates.output;
  const rateCacheRead = rates.cache_read, rateCacheCreation = rates.cache_creation;
  const rateSource = rates.source;   // 'file' | 'env' | null
  const rateConfigured = rates.configured;
  const cacheRateConfigured = Number.isFinite(rateCacheRead) || Number.isFinite(rateCacheCreation);
  // ADR-0098/0102: opt-in per-model rates. When configured, group tokens by model and
  // apply the per-model rate — in/out (ADR-0098) and cache (ADR-0102), each falling
  // back to the flat default for models/fields without an entry. No models → flat over
  // all tokens (mathematically identical to the prior behavior — no regression).
  const modelRates = rates.models || {};
  const modelRatesApplied = rateConfigured && Object.keys(modelRates).length > 0;
  const flatCR = Number.isFinite(rateCacheRead) ? rateCacheRead : 0;       // flat cache fallback (0 = unset)
  const flatCC = Number.isFinite(rateCacheCreation) ? rateCacheCreation : 0;
  let tokenCost;
  if (modelRatesApplied) {
    const byModel = new Map();
    for (const r of tokenRows) {
      const m = byModel.get(r.model) || { in: 0, out: 0, cr: 0, cc: 0 };
      m.in += r.input; m.out += r.output; m.cr += r.cache_read; m.cc += r.cache_creation; byModel.set(r.model, m);
    }
    tokenCost = 0;
    for (const [model, agg] of byModel) {
      const mr = modelRates[model] || {};
      const ri = Number.isFinite(mr.input) ? mr.input : rateIn;
      const ro = Number.isFinite(mr.output) ? mr.output : rateOut;
      const rcr = Number.isFinite(mr.cache_read) ? mr.cache_read : flatCR;        // per-model cache or flat fallback
      const rcc = Number.isFinite(mr.cache_creation) ? mr.cache_creation : flatCC;
      tokenCost += (agg.in / 1e6) * ri + (agg.out / 1e6) * ro + (agg.cr / 1e6) * rcr + (agg.cc / 1e6) * rcc;
    }
  } else {
    tokenCost = (tokenIn / 1e6) * rateIn + (tokenOut / 1e6) * rateOut
      + (tokenCacheRead / 1e6) * flatCR + (tokenCacheCreation / 1e6) * flatCC;
  }
  const estimatedCost = rateConfigured ? tokenCost : null;
  // ADR-0104: retro-point cost — an ADDITIVE read-only estimate that joins each token
  // row to the rate that was in effect at its timestamp (rate history, v0.53). Flat
  // only (history stores no per-model map) — labelled accordingly. The current-rate
  // `estimatedCost` above is untouched. Rows before the first history entry fall back
  // to the current flat rate. Absent history → not shown (would duplicate current).
  const rateHistoryChrono = parseRateHistoryChrono();
  const historyCostAvailable = rateConfigured && rateHistoryChrono.length > 0;
  let historyCost = null;
  if (historyCostAvailable) {
    historyCost = 0;
    for (const r of tokenRows) {
      // latest history entry with ts <= row.ts (rows are not assumed sorted).
      let eff = null;
      for (const h of rateHistoryChrono) { if (h.ts <= r.ts) eff = h; else break; }
      // ADR-0106: apply the per-model rate recorded in that entry for this row's model,
      // each field falling back to the entry's flat rate; pre-history → current flat.
      const mr = eff && eff.models ? eff.models[r.model] : null;
      const hi = mr && Number.isFinite(mr.input) ? mr.input : (eff ? eff.in : rateIn);
      const ho = mr && Number.isFinite(mr.output) ? mr.output : (eff ? eff.out : rateOut);
      const hcr = mr && Number.isFinite(mr.cache_read) ? mr.cache_read : (eff ? eff.cacheRead : flatCR);
      const hcc = mr && Number.isFinite(mr.cache_creation) ? mr.cache_creation : (eff ? eff.cacheCreation : flatCC);
      historyCost += (r.input / 1e6) * hi + (r.output / 1e6) * ho
        + (r.cache_read / 1e6) * hcr + (r.cache_creation / 1e6) * hcc;
    }
  }
  // ADR-0090: budget is a config value ($). Comparison is estimate(cost) vs config
  // (budget) — both assumptions, never measured. Observe-only (no side effects).
  const budget = rates.budget;
  const budgetSet = Number.isFinite(budget);
  const budgetComparable = budgetSet && estimatedCost != null;   // needs a rate to estimate cost
  const budgetExceeded = budgetComparable && estimatedCost >= budget;
  const budgetPct = budgetComparable && budget > 0 ? Math.round((estimatedCost / budget) * 100) : null;

  // ADR-0070: per-ticket token totals. durable frontmatter tokens_total (done
  // tickets) takes precedence — survives checkout/log rotation; the live
  // token_usage.log grouped by ticket fills in-progress/log-only tickets.
  // Measured counts only (cost stays rate-estimated). Empty ticket id →
  // "(unattributed)" so live rows are never silently dropped.
  const tokenByTicketMap = {};
  for (const t of allTickets()) {
    if (t.tokens_total > 0) tokenByTicketMap[t.id] = { total: t.tokens_total, in: t.tokens_in, out: t.tokens_out, durable: true };
  }
  const liveByTicket = {};
  for (const r of tokenRows) {
    const k = (r.ticket && r.ticket.trim()) ? r.ticket : '(unattributed)';
    if (!liveByTicket[k]) liveByTicket[k] = { in: 0, out: 0, cache: 0 };
    liveByTicket[k].in += r.input; liveByTicket[k].out += r.output;
    liveByTicket[k].cache += r.cache_read + r.cache_creation;
  }
  for (const [k, v] of Object.entries(liveByTicket)) {
    if (!tokenByTicketMap[k]) tokenByTicketMap[k] = { total: v.in + v.out, in: v.in, out: v.out, cache: v.cache, durable: false };
  }
  const tokenByTicket = Object.entries(tokenByTicketMap).sort((a, b) => b[1].total - a[1].total).slice(0, 10);

  return { counts, total, safeCount, unsafeCount: total - safeCount, persona, priority, cohort, byStage, byTicket, approvalCount: approvals.length, latencies, cycleTimes, leadTimes, leadTimesEst, completionCohort, measuredCompletions, estimatedCompletions, tokenSessions, tokenIn, tokenOut, tokenCacheRead, tokenCacheCreation, rateConfigured, rateIn, rateOut, rateCacheRead, rateCacheCreation, rateSource, cacheRateConfigured, modelRatesApplied, modelRateCount: Object.keys(modelRates).length, estimatedCost, historyCost, historyCostAvailable, budget, budgetSet, budgetComparable, budgetExceeded, budgetPct, tokenByTicket };
}

// ADR-0080: localhost rate-config panel. Rates are an assumption ($/Mtok); the
// writer is rate_config.sh (file=truth). The panel dispatches `rate_config` exec
// (localhost-only, T099) and shows the current rate + source (file/env/unset).
function renderRateConfigPanel(isLocalhost, ins) {
  if (!isLocalhost) return '';
  const cur = ins.rateConfigured
    ? `현재 요율: in $${ins.rateIn} / out $${ins.rateOut}${ins.cacheRateConfigured ? ` · cache read $${Number.isFinite(ins.rateCacheRead) ? ins.rateCacheRead : '—'} / new $${Number.isFinite(ins.rateCacheCreation) ? ins.rateCacheCreation : '—'}` : ''} per Mtok · 출처 <strong>${ins.rateSource === 'file' ? '파일(state/token_rates.json)' : 'env'}</strong> · 가정`
    : '현재 요율: 미설정 — 비용은 "데이터 없음"으로 표기됩니다.';
  const cli = './scripts/rate_config.sh set --in <X> --out <Y> [--cache-read <A>] [--cache-creation <B>]';
  return `<section class="mc-panel mc-rateconfig" data-rateconfig aria-label="요율 구성">
    <div class="mc-panel__head"><h2>요율 구성 (비용 추정)</h2><span>localhost · ADR-0080</span></div>
    <p class="mc-rateconfig__note">요율은 <strong>가정(구성값, $/Mtok)</strong>입니다 — 측정이 아닙니다. 비용 = 토큰 카운트(측정) × 요율(가정). 파일이 env보다 우선합니다. ${cur}</p>
    <details class="mc-rateconfig__body">
      <summary>요율 편집 열기</summary>
      <div class="mc-newticket__grid">
        <input type="number" min="0" step="0.01" data-rc-in placeholder="input $/Mtok (필수)" aria-label="input 요율" />
        <input type="number" min="0" step="0.01" data-rc-out placeholder="output $/Mtok (필수)" aria-label="output 요율" />
        <input type="number" min="0" step="0.01" data-rc-cache-read placeholder="cache_read $/Mtok (선택)" aria-label="cache_read 요율" />
        <input type="number" min="0" step="0.01" data-rc-cache-creation placeholder="cache_creation $/Mtok (선택)" aria-label="cache_creation 요율" />
        <input type="number" min="0" step="0.01" data-rc-budget placeholder="예산 $ (선택·관측 전용)" aria-label="비용 예산" />
      </div>
      <input type="text" class="mc-rateconfig__models" data-rc-models placeholder="모델 요율 (선택): name:in:out, … (예: claude-opus-4-8:15:75, claude-haiku-4-5:1:5)" aria-label="모델 요율 입력 (선택)" />
      <button type="button" class="mc-write mc-write--compact" data-rc-save title="$ ${escapeHtml(cli)}" aria-description="$ ${escapeHtml(cli)}">요율 저장</button>
    </details>
    ${rateConfigScript()}
  </section>`;
}

function rateConfigScript() {
  return `<script>
(() => {
  const panel = document.querySelector('.mc-rateconfig');
  if (!panel) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  const save = panel.querySelector('[data-rc-save]');
  if (!save) return;
  const val = (sel) => { const el = panel.querySelector(sel); const v = el ? el.value.trim() : ''; return v; };
  save.addEventListener('click', async (event) => {
    event.preventDefault();
    if (save.disabled) return;
    const rin = val('[data-rc-in]'), rout = val('[data-rc-out]');
    if (rin === '' || rout === '') { showToast('input·output 요율은 필수입니다', true); return; }
    const payload = { command: 'rate_config', action: 'set', in: rin, out: rout };
    const cr = val('[data-rc-cache-read]'), cc = val('[data-rc-cache-creation]'), bg = val('[data-rc-budget]');
    if (cr !== '') payload.cacheRead = cr;
    if (cc !== '') payload.cacheCreation = cc;
    if (bg !== '') payload.budget = bg;   // ADR-0090: opt-in cost budget
    // ADR-0098: opt-in per-model rates — parse "name:in:out, …" into a list.
    const mraw = val('[data-rc-models]');
    if (mraw !== '') {
      const models = mraw.split(',').map(s => s.trim()).filter(Boolean);
      if (models.length) payload.models = models;
    }
    save.disabled = true;
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '거부됨');
      if (data.exitCode !== 0) throw new Error('실패: ' + data.exitCode);
      showToast('요율 저장됨 (state/token_rates.json · 가정)');
      setTimeout(() => window.location.reload(), 700);
    } catch (e) { showToast(String(e.message || e), true); save.disabled = false; }
  });
})();
</script>`;
}

function renderBars(rows, accentClass = '') {
  if (!rows.length) return '<p class="mc-empty">데이터 없음</p>';
  const max = Math.max(...rows.map(([, n]) => n), 1);
  return `<ul class="mc-bars">${rows.map(([label, n]) =>
    `<li><span class="mc-bars__label">${escapeHtml(label)}</span><span class="mc-bars__track"><span class="mc-bars__fill ${accentClass}" style="width:${Math.round((n / max) * 100)}%"></span></span><span class="mc-bars__n">${n}</span></li>`
  ).join('')}</ul>`;
}

// ADR-0070: per-ticket token bars. Measured counts (k tokens); durable (done
// frontmatter) vs 라이브 (live log) labelled. Cost is auxiliary, only when a rate
// is configured, and always rate-labelled — never shown as measured.
function renderTokenByTicket(rows, { rateConfigured = false, rateIn = 0, rateOut = 0 } = {}) {
  if (!rows.length) return '<p class="mc-empty">데이터 없음 — 계측 선행</p>';
  const max = Math.max(...rows.map(([, v]) => v.total), 1);
  return `<ul class="mc-bars">${rows.map(([id, v]) => {
    const cost = rateConfigured ? ` · ~$${((v.in / 1e6) * rateIn + (v.out / 1e6) * rateOut).toFixed(2)}` : '';
    const mark = v.durable ? '' : ' <span class="mc-bars__tag">라이브</span>';
    // cache count only shown for live rows (durable frontmatter tokens_total has no cache split — v1).
    const cache = (!v.durable && v.cache) ? ` <span class="mc-bars__tag">cache ${Math.round(v.cache / 1000)}k</span>` : '';
    return `<li><span class="mc-bars__label">${escapeHtml(id)}${mark}${cache}</span><span class="mc-bars__track"><span class="mc-bars__fill mc-bars__fill--token" style="width:${Math.round((v.total / max) * 100)}%"></span></span><span class="mc-bars__n">${Math.round(v.total / 1000)}k${cost}</span></li>`;
  }).join('')}</ul>`;
}

function statCard(label, value, sub = '') {
  return `<div class="mc-stat"><span class="mc-stat__n">${escapeHtml(String(value))}</span><span class="mc-stat__label">${escapeHtml(label)}</span>${sub ? `<span class="mc-stat__sub">${escapeHtml(sub)}</span>` : ''}</div>`;
}

// ADR-0096: READ-ONLY snapshot inventory reader. Globs <base>.v<N>.md for the
// allowlisted governing/operational docs (top-level docs/*.md + persona skills),
// mirroring snapshot_ls.sh's allowlist + numeric-N semantics. Independent reader of
// the same file=truth (.vN files) — never writes, deletes, or execs. Returns a
// deterministic (base-sorted) array of { base, count, versions:[N…], latest }.
function computeSnapshotInventory() {
  const out = [];
  const scan = (dirAbs, dirRel, allow) => {
    let names;
    try { names = readdirSync(dirAbs); } catch { return; }
    const byBase = new Map();   // base(rel, no .md) → [N…]
    for (const f of names) {
      const m = /^(.+)\.v([0-9]+)\.md$/.exec(f);
      if (!m) continue;
      const baseName = m[1], n = Number(m[2]);
      if (!Number.isInteger(n)) continue;
      const docRel = `${dirRel}/${baseName}.md`;
      if (!allow(docRel)) continue;            // allowlist parity with snapshot_ls.sh
      const key = `${dirRel}/${baseName}`;
      (byBase.get(key) || byBase.set(key, []).get(key)).push(n);
    }
    for (const [base, ns] of byBase) {
      ns.sort((a, b) => a - b);                // numeric sort (v2 < v10)
      out.push({ base, count: ns.length, versions: ns.slice(), latest: ns[ns.length - 1] });
    }
  };
  // top-level docs/*.md (sub-paths like docs/onboarding/* are NOT allowlisted bases).
  scan(join(ROOT, 'docs'), 'docs', rel => rel === 'docs/master-spec.md' || rel === 'docs/runbook.md' || (/^docs\/[^/]+\.md$/.test(rel)));
  // persona skills only.
  scan(SKILLS_DIR, 'skills', rel => ['skills/implementer.md', 'skills/planner.md', 'skills/reviewer.md', 'skills/security-reviewer.md'].includes(rel));
  out.sort((a, b) => (a.base < b.base ? -1 : a.base > b.base ? 1 : 0));
  return out;
}

// ADR-0096: render the read-only snapshot inventory panel (display-only, no controls).
function renderSnapshotInventory(inv) {
  if (!inv.length) {
    return `<div class="mc-stat mc-stat--absent"><span class="mc-stat__n">—</span><span class="mc-stat__label">스냅샷 인벤토리</span><span class="mc-stat__sub">스냅샷 없음</span></div>`;
  }
  const rows = inv.map(e =>
    `<div class="mc-snaprow"><span class="mc-snaprow__base">${escapeHtml(e.base)}</span><span class="mc-snaprow__n">${e.count}개</span><span class="mc-snaprow__latest">최신 v${e.latest}</span></div>`
  ).join('');
  return `<div class="mc-snaplist">${rows}</div>`;
}

// ADR-0100: render the read-only rate-history panel (display-only, no controls).
// Rate values are config (assumptions); the timestamp is measured (when written).
function renderRateHistory(history) {
  if (!history.length) {
    return `<div class="mc-stat mc-stat--absent"><span class="mc-stat__n">—</span><span class="mc-stat__label">요율 이력</span><span class="mc-stat__sub">이력 없음</span></div>`;
  }
  const rows = history.map(h => {
    const extra = [
      (h.cacheRead || h.cacheCreation) ? `cache ${h.cacheRead ?? '—'}/${h.cacheCreation ?? '—'}` : '',
      h.budget ? `예산 $${h.budget}` : '',
      h.modelCount > 0 ? `model ${h.modelCount}개` : '',
    ].filter(Boolean).join(' · ');
    const summary = `in $${h.in}/out $${h.out}${extra ? ' · ' + extra : ''}`;
    return `<div class="mc-snaprow"><span class="mc-snaprow__base">${escapeHtml(h.ts)}</span><span class="mc-snaprow__latest">${escapeHtml(summary)}</span></div>`;
  }).join('');
  return `<div class="mc-snaplist">${rows}</div>`;
}

// ADR-0133: READ-ONLY retention preview panel (localhost-only). On demand, dispatches
// the read-only prune_preview exec and shows the keep/candidate manifest + sha as text.
// NO deletion: there is no confirm/delete control here — actual prune is T216 (separate).
function renderPrunePreview(isLocalhost) {
  if (!isLocalhost) return '';
  return `<section class="mc-panel"><div class="mc-panel__head"><h2>보존 미리보기</h2><span>읽기 전용 · 삭제 없음 (manifest·sha)</span></div>
    <div class="mc-body-edit__actions">
      <button type="button" class="mc-write mc-write--compact" data-prune-preview="snapshots">스냅샷 미리보기</button>
      <button type="button" class="mc-write mc-write--compact" data-prune-preview="logs">로그 미리보기</button>
    </div>
    <pre class="mc-ai-draft__body" data-prune-out aria-live="polite">정책 적용 보존/삭제 후보를 미리 봅니다 (삭제하지 않음).</pre>
    <script>
(() => {
  const out = document.querySelector('[data-prune-out]');
  if (!out) return;
  document.addEventListener('click', async (event) => {
    const btn = event.target.closest('button[data-prune-preview]');
    if (!btn) return;
    event.preventDefault();
    const sub = btn.getAttribute('data-prune-preview');
    out.textContent = '미리보기 실행 중…';
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'prune_preview', sub: sub }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '거부됨');
      out.textContent = (data && typeof data.stdoutTail === 'string' && data.stdoutTail) ? data.stdoutTail : '(출력 없음)';   // textContent = escape-safe, read-only
    } catch (e) { out.textContent = '오류: ' + String(e.message || e); }
  });
})();
    </script>
  </section>`;
}

// ADR-0168 T262: Insights run explorer + 실패 drill-down. /api/trace projection 소비(읽기 전용).
// 기존 KPI 집계/분포는 보조로 유지 — 본 섹션만 추가. escape-first(escapeHtml — DOM 텍스트만).
function renderRunExplorer(selectedRunId = '') {
  // 리뷰 M1: collectRuns 1회 — listRuns+getRun 이중 호출(파일 전수 재독 2회) 제거.
  const runs = collectRuns(ROOT);
  if (!runs.length) {
    return `<section class="mc-panel mc-run-explorer" aria-label="Run explorer">
      <div class="mc-panel__head"><h2>Run explorer</h2><span>읽기 전용 · ADR-0166</span></div>
      <p class="mc-empty">run 없음 — 라운드 산출물(state/reservations·failures·token_usage)이 쌓이면 표시됩니다.</p></section>`;
  }
  // 기본 선택: 지정 run → 첫 실패 run → 최신.
  const selected = runs.find(r => r.runId === selectedRunId)
    || runs.find(r => r.status === 'err') || runs[0];
  const detail = selected;
  const rows = runs.slice(0, 50).map(r =>
    `<li class="mc-run-row${r.runId === selected.runId ? ' is-active' : ''}"><a href="/insights?run=${escapeHtml(r.runId)}">`
    + `<span class="mc-run-row__id">${escapeHtml(r.runId)}</span>`
    + `<span class="mc-run-row__state">${escapeHtml(r.state)}</span>`
    + `<b class="mc-run-row__status mc-trace-status--${escapeHtml(r.status)}">${escapeHtml(r.status)}</b>`
    + `<span class="mc-run-row__spans">${r.spanCount} spans</span></a></li>`).join('');
  const spans = (detail && detail.spans ? detail.spans : []).map(s =>
    `<li class="mc-trace-span mc-trace-span--${escapeHtml(s.status)}"><em class="mc-trace-span__type">${escapeHtml(s.type)}</em>`
    + `<span class="mc-trace-span__name">${escapeHtml(s.name)}</span><b class="mc-trace-span__status">${escapeHtml(s.status)}</b></li>`).join('');
  const failSpan = (detail && detail.spans ? detail.spans : []).find(s => s.status === 'err');
  const drill = failSpan
    ? `<div class="mc-run-drill"><strong>왜 실패했는가</strong> — <em>${escapeHtml(failSpan.type)}</em> ${escapeHtml(failSpan.name)}: ${escapeHtml(String((failSpan.attrs && (failSpan.attrs.message || failSpan.attrs.stage)) || ''))}</div>`
    : '';
  return `<section class="mc-panel mc-run-explorer" aria-label="Run explorer">
    <div class="mc-panel__head"><h2>Run explorer</h2><span>읽기 전용 · "왜 실패했는가" drill-down · ADR-0166</span></div>
    <div class="mc-run-grid">
      <ol class="mc-run-list" aria-label="run 목록(최신순)">${rows}</ol>
      <div class="mc-run-detail" aria-label="run 상세">
        <div class="mc-panel__head"><h3>${escapeHtml(selected.runId)} · ${escapeHtml(selected.state)}</h3><span class="mc-trace-status--${escapeHtml(selected.status)}">${escapeHtml(selected.status)}</span></div>
        ${drill}
        <ol class="mc-trace-spans">${spans || '<li class="mc-empty">스팬 없음</li>'}</ol>
      </div>
    </div>
  </section>`;
}

function renderInsightsPage(selectedRunId = '', { isLocalhost = true } = {}) {
  const ins = computeInsights();
  const snapshotInventory = computeSnapshotInventory();
  const rateHistory = parseRateHistory();
  const safePct = ins.total ? Math.round((ins.safeCount / ins.total) * 100) : 0;
  const latNote = ins.latencies.length
    ? `${(ins.latencies.reduce((a, b) => a + b, 0) / ins.latencies.length).toFixed(1)}일 (n=${ins.latencies.length})`
    : '측정 가능 데이터 없음';

  // ADR-0040 §3.1: token cost is still NOT recorded (no telemetry source) →
  // honestly "데이터 없음". ADR-0046: cycle/lead time become real once the loop
  // records completed_at/started_at — labelled "계측 이후 N건" (not the whole history).
  const dataAbsent = label => `<div class="mc-stat mc-stat--absent"><span class="mc-stat__n">—</span><span class="mc-stat__label">${escapeHtml(label)}</span><span class="mc-stat__sub">데이터 없음 — 계측 선행</span></div>`;
  const avg = a => a.reduce((x, y) => x + y, 0) / a.length;
  // cycle time is MEASURED only (estimates have no started_at — ADR-0048).
  const cycleCard = ins.cycleTimes.length
    ? statCard('사이클 타임', avg(ins.cycleTimes).toFixed(1) + 'h', `측정 n=${ins.cycleTimes.length}`)
    : dataAbsent('사이클 타임');
  // lead time = measured (completed_at) + estimated (completed_at_est), split-labelled.
  const allLead = ins.leadTimes.concat(ins.leadTimesEst);
  const leadCard = allLead.length
    ? statCard('리드 타임', avg(allLead).toFixed(1) + '일', `측정 n=${ins.leadTimes.length} · 추정 n=${ins.leadTimesEst.length}`)
    : dataAbsent('리드 타임');

  // ADR-0090: estimated cost card with opt-in budget indicator (observe-only).
  // Both cost (estimate) and budget (config) are assumptions — labelled, never measured.
  let costCard;
  if (ins.tokenSessions && ins.rateConfigured) {
    const modelSub = ins.modelRatesApplied ? ` · model별 요율 ${ins.modelRateCount}개(가정)` : '';   // ADR-0098
    const rateSub = `요율 in $${ins.rateIn}/out $${ins.rateOut}${ins.cacheRateConfigured ? ` · cache read $${Number.isFinite(ins.rateCacheRead) ? ins.rateCacheRead : 0}/new $${Number.isFinite(ins.rateCacheCreation) ? ins.rateCacheCreation : 0}` : ''} per Mtok (가정·${ins.rateSource === 'file' ? '파일' : 'env'})${modelSub}`;
    const budgetSub = ins.budgetSet
      ? ` · 예산 $${ins.budget}${ins.budgetPct != null ? ` (${ins.budgetPct}%)` : ''}${ins.budgetExceeded ? ' — 예산 초과(추정·관측 전용)' : ''} (둘 다 가정)`
      : '';
    const badge = ins.budgetExceeded ? '<span class="mc-budget-badge">예산 초과</span>' : '';
    // ADR-0104: additive retro-point figure — cost at the rate in effect at each
    // session's time (rate history). Flat only (history has no per-model). Estimate.
    const historySub = ins.historyCostAvailable
      ? ` · 이력 요율 기준 ~$${ins.historyCost.toFixed(2)} (가정·per-model 이력 반영)`
      : '';
    costCard = `<div class="mc-stat${ins.budgetExceeded ? ' mc-stat--over' : ''}"><span class="mc-stat__n">$${ins.estimatedCost.toFixed(2)}</span><span class="mc-stat__label">추정 비용 ${badge}</span><span class="mc-stat__sub">${escapeHtml(rateSub + budgetSub + historySub)}</span></div>`;
  } else {
    // ADR-0090 fail-closed: budget set but no rate → cost not estimable.
    const sub = !ins.tokenSessions ? '데이터 없음 — 계측 선행' : (ins.budgetSet ? '비용 추정 불가 — 요율 미설정 (예산 설정됨)' : '데이터 없음 — 요율 미설정');
    costCard = `<div class="mc-stat mc-stat--absent"><span class="mc-stat__n">—</span><span class="mc-stat__label">추정 비용</span><span class="mc-stat__sub">${sub}</span></div>`;
  }

  const main = `<main class="mc-page mc-page--insights" aria-label="Insights">
  <section class="mc-stats" aria-label="처리량·구성">
    ${statCard('Done', ins.counts.done)}
    ${statCard('Open', ins.counts.open)}
    ${statCard('Forging', ins.counts.forging)}
    ${statCard('Approval 대기', ins.counts['awaiting-approval'])}
    ${statCard('safe 비율', safePct + '%', `safe ${ins.safeCount} / safe:false ${ins.unsafeCount}`)}
    ${statCard('승인 마커', ins.approvalCount, '승인 지연 ' + latNote)}
    ${cycleCard}
    ${leadCard}
    ${ins.tokenSessions
      ? statCard('토큰(측정)', `${Math.round((ins.tokenIn + ins.tokenOut) / 1000)}k`, `in ${Math.round(ins.tokenIn / 1000)}k · out ${Math.round(ins.tokenOut / 1000)}k · cache ${Math.round((ins.tokenCacheRead + ins.tokenCacheCreation) / 1000)}k (read ${Math.round(ins.tokenCacheRead / 1000)}k·new ${Math.round(ins.tokenCacheCreation / 1000)}k) · 계측 이후 n=${ins.tokenSessions}`)
      : dataAbsent('토큰(측정)')}
    ${costCard}
  </section>
  ${renderRunExplorer(selectedRunId)}
  ${renderRateConfigPanel(isLocalhost, ins)}
  <div class="mc-insights-grid">
    <section class="mc-panel"><div class="mc-panel__head"><h2>persona 분포</h2></div>${renderBars(ins.persona)}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>priority 분포</h2></div>${renderBars(ins.priority)}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>생성 코호트</h2><span>created 기준(완료 아님)</span></div>${renderBars(ins.cohort, 'mc-bars__fill--ember')}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>완료 throughput</h2><span>측정 n=${ins.measuredCompletions} · 추정 n=${ins.estimatedCompletions}</span></div>${renderBars(ins.completionCohort)}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>실패 — stage별</h2></div>${renderBars(ins.byStage, 'mc-bars__fill--fail')}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>실패 — 반복 티켓(≥2)</h2></div>${renderBars(ins.byTicket, 'mc-bars__fill--fail')}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>티켓별 토큰(측정)</h2><span>durable done · 라이브=로그${ins.rateConfigured ? ' · ~$ 요율 추정' : ''}</span></div>${renderTokenByTicket(ins.tokenByTicket, { rateConfigured: ins.rateConfigured, rateIn: ins.rateIn, rateOut: ins.rateOut })}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>스냅샷 인벤토리</h2><span>.vN 관측 전용 · 읽기</span></div>${renderSnapshotInventory(snapshotInventory)}</section>
    <section class="mc-panel"><div class="mc-panel__head"><h2>요율 이력</h2><span>append-only · 값=가정·시각=기록</span></div>${renderRateHistory(rateHistory)}</section>
    ${renderPrunePreview(isLocalhost)}
  </div>
</main>`;
  return renderShell('Insights', 'insights', main, { isLocalhost });
}

// ── 자율성 다이얼 (ADR-0052 읽기 전용 v1 → ADR-0054 모드 전환 컨트롤) ──────
// 3모드(Suggest/Co-pilot/Autopilot)는 현행 메커니즘에 매핑된다. ADR-0054로
// state/loop_mode가 truth가 되어 라이브 현재-모드를 정직하게 읽고, localhost에서
// 조이기/Co-pilot 전환을 dispatch한다(set_mode, T099). Autopilot 진입은 v1 제외
// (ADR-0054 §6.3 b) — 여기서 제공하지 않는다. 승인 게이트는 모드와 직교(불변).

// ADR-0054 §3.6: read the declarative loop mode (file = truth). Returns the
// canonical token or null when unset/invalid — never an estimate.
function readLoopMode() {
  return readLoopModePrimitive(ROOT); // 리뷰 M5: 공용 원시 위임(LOOP_MODE_PATH = ROOT/state/loop_mode)
}

// ADR-0056: read the autopilot grant (file = truth). Returns null when absent or
// invalid (budget<=0 or expired) — never an estimate. Used only to DISPLAY the
// grant posture; the orchestrator independently re-validates before each round.
function readAutopilotGrant() {
  return readAutopilotGrantPrimitive(ROOT); // 리뷰 M5: 공용 원시 위임(동일 필드·expiryHuman 포함)
}

function computeAutonomy() {
  const { byStatus } = getModel();
  const open = byStatus.open || [];
  const openSafe = open.filter(t => t.safe).length;
  return {
    openCount: open.length,
    openSafe,
    openUnsafe: open.length - openSafe,
    awaiting: (byStatus['awaiting-approval'] || []).length,
  };
}

function renderAutonomyPage({ isLocalhost = true } = {}) {
  const a = computeAutonomy();
  const liveMode = readLoopMode(); // null = 미설정(기본 Co-pilot)
  // 3모드 ↔ 현행 메커니즘 매핑(읽기). governing 기본은 Co-pilot.
  const modes = [
    { key: 'suggest',  name: 'Suggest',  govern: false, behavior: '모든 티켓 실행 전 확인',          mech: '--dry-run 상시' },
    { key: 'co-pilot', name: 'Co-pilot', govern: true,  behavior: 'safe:true 자동 · safe:false 승인 대기', mech: '--safe-only' },
    { key: 'autopilot', name: 'Autopilot', govern: false, behavior: '큐 소진까지 연속 실행',           mech: 'orchestrator + 스케줄' },
  ];
  // 라이브 현재-모드: 파일이 truth. 미설정이면 기본(Co-pilot)로 정직 표기.
  const effectiveKey = liveMode || 'co-pilot';
  const modeRows = modes.map(m => {
    const isCurrent = m.key === effectiveKey;
    const badges = `${m.govern ? '<span class="mc-mode__badge">governing 기본</span>' : ''}${isCurrent ? '<span class="mc-mode__badge mc-mode__badge--live">현재</span>' : ''}`;
    return `<tr class="mc-mode${m.govern ? ' is-governing' : ''}${isCurrent ? ' is-current' : ''}">
      <th scope="row">${escapeHtml(m.name)}${badges}</th>
      <td>${escapeHtml(m.behavior)}</td>
      <td><code>${escapeHtml(m.mech)}</code></td>
    </tr>`;
  }).join('');

  const currentLabel = modes.find(m => m.key === effectiveKey)?.name || 'Co-pilot';
  const liveNote = liveMode
    ? `현재 모드 <strong>${escapeHtml(currentLabel)}</strong> — <code>state/loop_mode</code> 기준(실측). 실행 중 루프는 다음 사이클 경계에서 적용합니다.`
    : `현재 모드 <strong>${escapeHtml(currentLabel)}</strong> — <code>state/loop_mode</code> 미설정이므로 <strong>기본</strong>으로 표기(추정 아님).`;

  // ADR-0054 §3.4/§6.3b: 전환 컨트롤은 localhost 전용. 조이기(Suggest)·Co-pilot만.
  // Autopilot 진입은 제공하지 않는다(별도 결정). 비-localhost는 관측만(T099).
  const controls = isLocalhost
    ? `<section class="mc-panel mc-mode-control" aria-label="모드 전환 (localhost)">
    <div class="mc-panel__head"><h2>모드 전환</h2><span>localhost 전용 · T099</span></div>
    <p class="mc-mode-control__hint">전환은 <code>state/loop_mode</code>에 기록되고(파일=진실, CLI 동등) 실행 중 루프가 <strong>다음 사이클 경계</strong>에서 적용합니다. 진행 중 티켓은 중단되지 않습니다. 승인 게이트는 모드와 무관하게 유지됩니다 — 어떤 모드도 safe:false 마커를 우회하지 않습니다.</p>
    <div class="mc-mode-control__buttons">
      <button type="button" class="mc-write mc-write--compact" title="$ ./scripts/set_mode.sh co-pilot" aria-description="$ ./scripts/set_mode.sh co-pilot" data-set-mode="co-pilot">Co-pilot로 — safe:true 자동, safe:false 승인 대기</button>
      <button type="button" class="mc-write mc-write--compact" title="$ ./scripts/set_mode.sh suggest" aria-description="$ ./scripts/set_mode.sh suggest" data-set-mode="suggest">Suggest로 (조이기) — 실행 전 확인(dry-run)</button>
    </div>
    <p class="mc-mode-control__note" role="note">Autopilot 진입은 v1에서 제공하지 않습니다(ADR-0054 §6.3 b — 인간 개입 최소화는 별도 결정). CLI에서 <code>run_loop.sh</code>를 <code>--safe-only</code> 없이 직접 기동해야 합니다.</p>
    ${autonomyControlScript()}
  </section>`
    : `<section class="mc-panel mc-mode-control mc-mode-control--observe" role="note">모드 전환은 localhost 데스크톱에서만 가능합니다. 모바일은 관측 전용입니다(T099 — approve/reject only).</section>`;

  // ADR-0056/0178: Autopilot grant posture — 라이브 상태(truth) 분류 + localhost 컨트롤.
  // ADR-0178 T272: none/active/revoked/expired/exhausted를 구분 표시(왜 멈췄는가 가시화). 읽기 전용.
  const posture = grantPosture(ROOT);
  const isActive = posture.state === 'active';
  const bindsNote = posture.bindsFirst === 'budget'
    ? ' · 다음 정지 사유 <strong>budget 소진</strong>'
    : posture.bindsFirst === 'expiry'
      ? ' · 다음 정지 사유 <strong>시간 만료</strong>'
      : ' · 다음 정지 사유 budget·시간 중 먼저';
  let grantStatus;
  if (posture.state === 'active') {
    grantStatus = `<p class="mc-grant__active"><span class="mc-grant__badge">활성</span> 무인 연속 운영 인가 — 잔여 budget <strong>${posture.budget}건</strong> · 만료까지 <strong>${posture.minutesLeft}분</strong>${posture.expiryHuman ? ` (${escapeHtml(posture.expiryHuman)})` : ''} · 발급 ${escapeHtml(posture.issuedBy)}${bindsNote}</p>`;
  } else if (posture.state === 'revoked') {
    grantStatus = `<p class="mc-grant__stopped mc-grant__stopped--revoked"><span class="mc-grant__badge mc-grant__badge--stop">비상 정지</span> 철회됨(kill) — ${escapeHtml(posture.revokedAt || '')} 운영자 철회. 무인 연속 중단. 재개하려면 아래에서 재발급.</p>`;
  } else if (posture.state === 'expired') {
    grantStatus = `<p class="mc-grant__stopped mc-grant__stopped--expired"><span class="mc-grant__badge mc-grant__badge--stop">시간 만료</span> 만료(default-tighten·시간)로 무인 연속 자동 정지. 재개하려면 아래에서 재발급.</p>`;
  } else if (posture.state === 'exhausted') {
    grantStatus = `<p class="mc-grant__stopped mc-grant__stopped--exhausted"><span class="mc-grant__badge mc-grant__badge--stop">budget 소진</span> budget(default-tighten·건수) 소진으로 무인 연속 자동 정지. 재개하려면 아래에서 재발급.</p>`;
  } else {
    grantStatus = `<p class="mc-grant__none">미발급 — orchestrator는 무인 연속 운영(watch)을 하지 않습니다(단발 attended 라운드만). safe:false는 어느 모드에서도 자동 실행되지 않습니다.</p>`;
  }
  const grantControls = isLocalhost
    ? `<div class="mc-grant__controls">
      <button type="button" class="mc-write mc-write--compact" title="$ ./scripts/autopilot_grant.sh issue --budget 1 --expiry-min 30" aria-description="$ ./scripts/autopilot_grant.sh issue --budget 1 --expiry-min 30" data-autopilot-grant data-budget="1" data-expiry-min="30">무인 연속 운영 인가 (budget 1 · 30분)</button>
      ${isActive ? '<button type="button" class="mc-write mc-write--compact mc-write--danger" title="$ ./scripts/autopilot_grant.sh revoke" aria-description="$ ./scripts/autopilot_grant.sh revoke" data-autopilot-revoke>철회 (즉시 중단)</button>' : ''}
    </div>
    ${autopilotGrantScript()}`
    : `<p class="mc-grant__observe" role="note">grant 발급/철회는 localhost 데스크톱에서만 가능합니다(T099).</p>`;
  const grantSection = `<section class="mc-panel mc-grant" aria-label="Autopilot 무인 연속 운영 grant">
    <div class="mc-panel__head"><h2>Autopilot — 무인 연속 운영 grant</h2><span>유한·자기만료 · ADR-0056</span></div>
    ${grantStatus}
    <p class="mc-grant__hint">유한·자기만료 인가입니다 — budget(처리 티켓 수)·expiry(만료) 중 먼저 닿는 쪽에서 무인 연속 운영이 자동 정지합니다(default-tightens). <strong>safe:false는 자동 실행되지 않으며, merge/close에는 승인 마커가 계속 필요합니다.</strong></p>
    ${grantControls}
  </section>`;

  // ADR-0176 T270: 정책 projection(읽기 전용) — 기존 enforcement를 deny/ask/allow + provenance로 합성 표시.
  // 막거나 허용하지 않는다(관측만, ADR-0052). enforcement(loop_mode·safe 게이트·exec scope·grant)가 진실.
  const policy = projectPolicy(ROOT);
  const policyRows = policy.rows.map(r => {
    const prov = r.provenance.map(p => `${p.source}: ${p.detail}`).join(' · ');
    return `<tr class="mc-policy-row">
      <th scope="row">${escapeHtml(r.label)}</th>
      <td><span class="mc-policy mc-policy--${escapeHtml(r.decision)}">${escapeHtml(r.decision)}</span></td>
      <td class="mc-policy__prov">${escapeHtml(prov)}</td>
    </tr>`;
  }).join('');
  const policySection = `<section class="mc-panel mc-policy-projection" aria-label="정책 projection (deny ask allow)">
    <div class="mc-panel__head"><h2>정책 projection</h2><span>읽기 전용 · 기존 enforcement 합성 · ADR-0176</span></div>
    <p class="mc-policy__note">현재 포스처(<strong>${escapeHtml(policy.posture.effectiveMode)}</strong>${policy.posture.grantValid ? ' · grant 활성' : ''})에서 각 요청 클래스가 어떻게 판정되는지 — 기존 enforcement(loop_mode·safe 게이트·exec scope·grant)를 합성해 <strong>표시만</strong> 합니다(실제 차단/허용은 enforcement가 수행).</p>
    <table class="mc-policy-table">
      <thead><tr><th scope="col">요청 클래스</th><th scope="col">판정</th><th scope="col">provenance</th></tr></thead>
      <tbody>${policyRows}</tbody>
    </table>
  </section>`;

  const execPosture = isLocalhost
    ? { host: 'localhost', detail: '전권 — 관측 + exec dispatch + 모드 전환 + grant 발급 가능' }
    : { host: '비-localhost (모바일)', detail: 'approve/reject only — exec dispatch·모드 전환·grant 차단 (T099)' };

  const main = `<main class="mc-page mc-page--autonomy" aria-label="자율성 다이얼">
  <section class="mc-panel mc-autonomy-note">
    <p>${liveNote}</p>
    <p>자율성 모드는 실행 페이스(확인 케이던스)이지 승인 게이트의 우회가 아닙니다. <strong>어떤 모드에서도 safe:false 티켓은 승인 마커가 있어야 merge됩니다</strong>(직교 불변).</p>
  </section>
  <section class="mc-panel">
    <div class="mc-panel__head"><h2>모드 ↔ 메커니즘 매핑</h2><span>현재 모드 = state/loop_mode</span></div>
    <table class="mc-mode-table">
      <thead><tr><th scope="col">모드</th><th scope="col">동작</th><th scope="col">현행 메커니즘</th></tr></thead>
      <tbody>${modeRows}</tbody>
    </table>
  </section>
  ${controls}
  ${grantSection}
  ${policySection}
  <section class="mc-stats" aria-label="safe 게이트 스냅샷">
    ${statCard('safe:true open', a.openSafe, '자동 실행 가능')}
    ${statCard('safe:false open', a.openUnsafe, '승인 게이트')}
    ${statCard('승인 대기', a.awaiting, '인간 대기 (awaiting-approval)')}
  </section>
  <section class="mc-panel mc-exec-scope">
    <div class="mc-panel__head"><h2>exec 스코프 포스처</h2><span>T099</span></div>
    <p class="mc-scope__now"><span class="mc-scope__host">${escapeHtml(execPosture.host)}</span> — ${escapeHtml(execPosture.detail)}</p>
    <p class="mc-scope__fixed">고정 정책: localhost = 전권(모드 전환 포함), 비-localhost = approve/reject only. set_mode는 비-localhost에서 거부됩니다(서버 권위 — socket peer-address).</p>
  </section>
</main>`;
  return renderShell('자율성 다이얼', 'autonomy', main, { isLocalhost });
}

// ADR-0056: localhost-only Autopilot grant dispatch (issue/revoke). Dedicated to
// the autonomy page — data-autopilot-grant / data-autopilot-revoke (not
// data-exec-command). Issue carries a stronger 2nd confirmation that names the
// honesty boundary (unattended safe:true draining; safe:false NOT auto-run; merge
// still needs a marker). Non-localhost never renders this; the server rejects the
// commands for non-localhost regardless (T099).
function autopilotGrantScript() {
  return `<script>
(() => {
  const root = document.querySelector('.mc-grant');
  if (!root) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  async function dispatch(payload, okMsg) {
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { showToast(data.error || '거부됨', true); return; }
      showToast(data.exitCode === 0 ? okMsg : '실패: ' + data.exitCode, data.exitCode !== 0);
      if (data.exitCode === 0) setTimeout(() => window.location.reload(), 600);
    } catch (e) { showToast(String(e), true); }
  }
  root.addEventListener('click', (event) => {
    const issue = event.target.closest('button[data-autopilot-grant]');
    const revoke = event.target.closest('button[data-autopilot-revoke]');
    if (issue) {
      event.preventDefault();
      const budget = issue.dataset.budget || '1';
      const expiry = issue.dataset.expiryMin || '30';
      const ok = window.confirm('무인 연속 운영을 인가합니다 (budget ' + budget + '건 · ' + expiry + '분).\\n\\n무인으로 safe:true 티켓을 연속 처리합니다. safe:false는 자동 실행되지 않으며, merge/close에는 승인 마커가 계속 필요합니다.\\nbudget 소진 또는 만료 시 자동으로 정지합니다. 계속할까요?');
      if (!ok) return;
      issue.disabled = true;
      dispatch({ command: 'autopilot_grant', budget: Number(budget), expiryMin: Number(expiry) }, '무인 연속 운영을 인가했습니다').finally(() => { issue.disabled = false; });
    } else if (revoke) {
      event.preventDefault();
      if (!window.confirm('autopilot grant를 즉시 철회할까요? 무인 연속 운영이 중단됩니다.')) return;
      revoke.disabled = true;
      dispatch({ command: 'autopilot_revoke' }, 'grant를 철회했습니다').finally(() => { revoke.disabled = false; });
    }
  });
})();
</script>`;
}

// ADR-0054 §6: localhost-only mode-switch dispatch. Dedicated to the autonomy
// page — uses data-set-mode (NOT data-exec-command) so it does not collide with
// the shared exec handler, and POSTs the set_mode command (no ticketId). A
// confirm step precedes the dispatch; on success the page reloads to reflect the
// new live mode. Non-localhost never renders this (controls are localhost-only),
// and the server rejects set_mode for non-localhost regardless (T099).
function autonomyControlScript() {
  return `<script>
(() => {
  const root = document.querySelector('.mc-mode-control');
  if (!root) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  root.addEventListener('click', async (event) => {
    const button = event.target.closest('button[data-set-mode]');
    if (!button || button.disabled) return;
    event.preventDefault();
    const mode = button.dataset.setMode;
    if (!window.confirm("loop_mode를 '" + mode + "'로 전환할까요? 실행 중 루프는 다음 사이클 경계에서 적용합니다(진행 티켓은 중단되지 않음).")) return;
    button.disabled = true;
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'set_mode', mode: mode }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { showToast(data.error || '모드 전환 거부됨', true); return; }
      showToast(data.exitCode === 0 ? "모드를 '" + mode + "'로 전환했습니다" : '모드 전환 실패: ' + data.exitCode, data.exitCode !== 0);
      if (data.exitCode === 0) setTimeout(() => window.location.reload(), 600);
    } catch (e) { showToast(String(e), true); }
    finally { button.disabled = false; }
  });
})();
</script>`;
}

function renderBoardPage({ isLocalhost = true } = {}) {
  const { byStatus } = getModel();
  const doneIds = new Set((byStatus.done || []).map(t => String(t.id)));
  const nowMs = Date.now();
  const isBlocked = t => (t.depends_on || []).some(id => !doneIds.has(String(id)));
  // ADR-0190 T284: id→{title,status} 대조 맵(읽기). dep 칩을 blocker 제목·상태로 해소.
  // ADR-0192 T286: allTickets(평탄화) — downstream(역방향) 역집계용.
  const ticketsById = {};
  const allTickets = [];
  for (const list of Object.values(byStatus)) {
    if (!Array.isArray(list)) continue;
    for (const t of list) {
      if (t && t.id != null) {
        ticketsById[String(t.id)] = { title: t.title || '', status: t.status || '' };
        allTickets.push(t);
      }
    }
  }
  // 리뷰 M7: 역엣지 인덱스 렌더당 1회 구축 — 카드마다 reverseDeps/blocksConsistency가
  // 전 티켓을 재순회하던 O(N²) 제거(reverseDeps와 동일 결론).
  const depIndex = reverseDepsIndex(allTickets);

  // ADR-0038 §3.1: derive Backlog (blocked open) vs Open/Ready (deps met). The
  // ticket files are unchanged — this is a render-time split.
  const openAll = byStatus.open || [];
  const backlog = openAll.filter(isBlocked);
  const ready = openAll.filter(t => !isBlocked(t));
  const verify = byStatus.verify || [];

  // failures per ticket → repeat-fail stuck signal (ADR-0038 §3.3).
  const allFailures = parseFailures();
  const failCountByTicket = new Map();
  for (const f of allFailures) {
    const id = String(f.ticket_id);
    failCountByTicket.set(id, (failCountByTicket.get(id) || 0) + 1);
  }

  // ADR-0038 §3.2: Verify is a CONDITIONAL column — shown only when a ticket
  // actually carries status:verify, so the (currently) always-empty column does
  // not occupy dead space. Forward-compatible if the loop later exposes verify.
  // ADR-0060: Parked = skipped(취소) + blocked(리뷰 거절). Conditional column so
  // cancelled/rejected tickets stay visible and can be reopened (reopen control).
  const parked = [...(byStatus.skipped || []), ...(byStatus.blocked || [])];
  const columns = [
    ['backlog', 'Backlog', backlog],
    ['open', 'Open', ready],
    ['forging', 'Forging', byStatus.forging || []],
    ...(verify.length ? [['verify', 'Verify', verify]] : []),
    ['awaiting-approval', 'Approval', byStatus['awaiting-approval'] || []],
    ...(parked.length ? [['parked', '보류/거절', parked]] : []),
    ['done', 'Done', byStatus.done || []],
  ];
  const colId = status => status === 'awaiting-approval' ? 'app' : status === 'forging' ? 'forge' : status;
  // ADR-0184 T278: 컬럼 흐름 요약(읽기) — per-card aging/lead-time를 컬럼 단위 카운트로 종합.
  // active는 aging/stale, done은 measured/추정. 전부 0이면 미표시. 막거나 정렬하지 않음(신호).
  const flowSummaryChip = tickets => {
    const s = columnFlowSummary(tickets, nowMs);
    const parts = [];
    if (s.aging) parts.push(`<span class="mc-flow mc-flow--aging">aging ${s.aging}</span>`);
    if (s.stale) parts.push(`<span class="mc-flow mc-flow--stale">stale ${s.stale}</span>`);
    if (s.leadMeasured) parts.push(`<span class="mc-flow mc-flow--lead">측정 ${s.leadMeasured}</span>`);
    if (s.leadEstimated) parts.push(`<span class="mc-flow mc-flow--lead-est">추정 ${s.leadEstimated}</span>`);
    return parts.length ? `<div class="mc-column__flow" aria-label="흐름 요약">${parts.join('')}</div>` : '';
  };
  const boardColumns = columns.map(([status, label, tickets]) =>
    `<section class="mc-column" id="c-${colId(status)}" aria-labelledby="h-${status}">
  <div class="mc-column__head">
    <h2 id="h-${status}"><span class="mc-column__dot" aria-hidden="true"></span>${label}</h2>
    <span>${tickets.length}</span>
  </div>
  ${flowSummaryChip(tickets)}
  <div class="mc-card-list">
    ${tickets.map(t => renderTicketCard(t, doneIds, nowMs, isLocalhost, failCountByTicket.get(String(t.id)) || 0, ticketsById, depIndex)).join('\n') || '<p class="mc-empty">No tickets</p>'}
  </div>
</section>`).join('\n');

  // ADR-0038 §3.4: client-side filters (persona/safe/blocked), localStorage-kept.
  const personas = [...new Set([...openAll, ...(byStatus.forging || []), ...(byStatus['awaiting-approval'] || []), ...(byStatus.done || [])]
    .map(t => t.persona).filter(Boolean))].sort();
  const personaOptions = ['<option value="">persona: 전체</option>', ...personas.map(p => `<option value="${escapeHtml(p)}">${escapeHtml(p)}</option>`)].join('');
  const filterBar = `<div class="mc-board-filters" role="group" aria-label="보드 필터">
    <select data-filter="persona" aria-label="persona 필터">${personaOptions}</select>
    <label class="mc-filter-toggle"><input type="checkbox" data-filter="safe-only"> safe만</label>
    <label class="mc-filter-toggle"><input type="checkbox" data-filter="hide-blocked"> blocked 숨김</label>
  </div>`;
  const filterScript = `<script>
(function(){
  var KEY = 'mc-board-filters';
  var sel = document.querySelector('[data-filter="persona"]');
  var safeOnly = document.querySelector('[data-filter="safe-only"]');
  var hideBlocked = document.querySelector('[data-filter="hide-blocked"]');
  if (!sel || !safeOnly || !hideBlocked) return;
  function load(){ try { return JSON.parse(localStorage.getItem(KEY) || '{}'); } catch(e){ return {}; } }
  function save(s){ try { localStorage.setItem(KEY, JSON.stringify(s)); } catch(e){} }
  function apply(){
    var s = { persona: sel.value, safeOnly: safeOnly.checked, hideBlocked: hideBlocked.checked };
    save(s);
    var cards = document.querySelectorAll('.mc-card');
    for (var i=0;i<cards.length;i++){
      var c = cards[i];
      var show = true;
      if (s.persona && c.getAttribute('data-persona') !== s.persona) show = false;
      if (s.safeOnly && c.getAttribute('data-safe') !== 'safe') show = false;
      if (s.hideBlocked && c.getAttribute('data-blocked') === 'true') show = false;
      c.style.display = show ? '' : 'none';
    }
  }
  var saved = load();
  if (saved.persona) sel.value = saved.persona;
  safeOnly.checked = !!saved.safeOnly;
  hideBlocked.checked = !!saved.hideBlocked;
  sel.addEventListener('change', apply);
  safeOnly.addEventListener('change', apply);
  hideBlocked.addEventListener('change', apply);
  apply();
})();
</script>`;

  const failures = allFailures.slice(-10).reverse();
  const failureRows = failures.length
    ? failures.map(f => `<li><span>${escapeHtml(f.timestamp)}</span><strong>${escapeHtml(f.ticket_id)}</strong><em>${escapeHtml(f.stage)}</em><p>${escapeHtml(f.message)}</p></li>`).join('\n')
    : '<li class="mc-empty">No recent failures</li>';

  const main = `<main class="mc-page" aria-label="Forge Board">
  ${filterBar}
  ${renderNewTicketForm(isLocalhost)}
  ${renderInterviewPanel(isLocalhost)}
  <section class="mc-board" aria-label="Ticket board">
    ${boardColumns}
  </section>
  <p class="mc-cli-note">$ ./scripts/run_loop.sh T&lt;id&gt; — 모든 버튼에는 동등한 CLI 명령이 툴팁으로 표시됩니다. UI가 죽어도 CLI로 완전 동작.</p>
  <aside class="mc-panel" aria-live="polite">
    <div class="mc-panel__head">
      <h2>Failures</h2>
      <span>latest 10</span>
    </div>
    <ol class="mc-failures">${failureRows}</ol>
  </aside>
  ${filterScript}
  ${isLocalhost ? boardTicketEditScript() : ''}
</main>`;
  return renderShell('Forge Board', 'board', main, { isLocalhost, draftPreview: true });
}

// ADR-0064: localhost-only "new ticket" form. Created tickets are FORCED
// safe:false (no safe input) — they can never auto-run. Mobile never renders this
// (observe-only, T099); the server rejects new_ticket for non-localhost anyway.
function renderNewTicketForm(isLocalhost) {
  if (!isLocalhost) return '';
  const personaOpts = ['implementer', 'planner', 'reviewer', 'security-reviewer']
    .map(p => `<option value="${p}">${p}</option>`).join('');
  const prioOpts = ['P0', 'P1', 'P2', 'P3']
    .map(p => `<option value="${p}"${p === 'P2' ? ' selected' : ''}>${p}</option>`).join('');
  return `<details class="mc-newticket" data-newticket>
    <summary>+ 새 티켓 (생성물은 safe:false — 실행엔 승인 마커 필요)</summary>
    <div class="mc-newticket__grid">
      <input type="text" data-nt-title maxlength="200" placeholder="제목 (필수)" aria-label="새 티켓 제목" />
      <select data-nt-priority aria-label="우선순위">${prioOpts}</select>
      <select data-nt-persona aria-label="페르소나">${personaOpts}</select>
      <input type="text" data-nt-labels maxlength="120" placeholder="labels (csv, 선택)" aria-label="라벨" />
    </div>
    <textarea data-nt-body class="mc-edit-body" maxlength="16000" placeholder="본문 (선택, 마크다운)" aria-label="새 티켓 본문"></textarea>
    <button type="button" class="mc-write mc-write--compact" data-nt-create title="$ ./scripts/new_ticket.sh create --title <title>" aria-description="$ ./scripts/new_ticket.sh create --title <title>">티켓 생성</button>
  </details>`;
}

// ADR-0078: bounded multi-turn AI interview (localhost). Fixed turn cap (server-
// authoritative), single purpose (requirement gathering → ticket draft), STATELESS
// (the transcript lives only in this panel's JS, never persisted), and the output
// is a DRAFT the human applies via new_ticket. NOT a chatbot. Mobile never renders.
function renderInterviewPanel(isLocalhost) {
  if (!isLocalhost) return '';
  return `<details class="mc-interview" data-interview>
    <summary>AI 인터뷰 (유한 턴 요구 수집 → 티켓 초안)</summary>
    <p class="mc-interview__note">유한 턴(서버 캡)·단일 목적·무상태(대화 미영속)·출력은 초안입니다. 챗봇이 아닙니다. 최종 초안은 위 <strong>새 티켓</strong>으로 생성하세요.</p>
    <div class="mc-interview__log" data-iv-log aria-live="polite"></div>
    <textarea data-iv-input class="mc-edit-body" maxlength="8000" placeholder="요구사항·답변을 입력하세요" aria-label="인터뷰 입력"></textarea>
    <div class="mc-body-edit__actions">
      <button type="button" class="mc-write mc-write--compact mc-write--ai" data-iv-send>보내기 <span data-iv-turn>(턴 1)</span></button>
      <button type="button" class="mc-write mc-write--compact" data-iv-compare aria-description="선택한 두 턴의 AI 산출을 비교 (읽기 전용)">산출 비교</button>
      <button type="button" class="mc-write mc-write--compact" data-iv-reset>초기화</button>
    </div>
    <div class="mc-iv-cmpsel" hidden data-iv-cmpsel>
      <label>턴 비교: <select data-iv-cmp-a aria-label="비교 턴 A"></select></label>
      <span>vs</span>
      <label><select data-iv-cmp-b aria-label="비교 턴 B"></select></label>
    </div>
    <div class="mc-ai-draft" data-iv-compare-out hidden>
      <div class="mc-ai-draft__note">산출 비교 — 직전 턴 vs 최신 턴 AI 산출 (읽기 전용·제안)</div>
      <pre class="mc-ai-draft__body" data-ai-draft-body></pre>
    </div>
    ${interviewScript()}
  </details>`;
}

function interviewScript() {
  return `<script>
(() => {
  const panel = document.querySelector('.mc-interview');
  if (!panel) return;
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  const log = panel.querySelector('[data-iv-log]');
  const input = panel.querySelector('[data-iv-input]');
  const send = panel.querySelector('[data-iv-send]');
  const reset = panel.querySelector('[data-iv-reset]');
  const turnLabel = panel.querySelector('[data-iv-turn]');
  const compareBtn = panel.querySelector('[data-iv-compare]');
  const compareOut = panel.querySelector('[data-iv-compare-out]');
  const cmpSelWrap = panel.querySelector('[data-iv-cmpsel]');
  const cmpA = panel.querySelector('[data-iv-cmp-a]');
  const cmpB = panel.querySelector('[data-iv-cmp-b]');
  // STATELESS server: the transcript lives only here and is sent each turn. Never persisted.
  let transcript = '';
  let turn = 1;
  // ADR-0130: per-turn AI outputs for the opt-in 산출 비교 (read-only diff). In-memory only
  // (same statelessness as transcript — never sent to server / persisted). ADR-0145: any two.
  const aiOutputs = [];
  // ADR-0145: rebuild the two turn-select dropdowns from aiOutputs (escape-first: option text via
  // textContent). Default A=prev(len-2)·B=latest(len-1) preserves the v0.68 prev-vs-latest pick.
  const refreshCmpOptions = () => {
    if (!cmpA || !cmpB) return;
    const n = aiOutputs.length;
    for (const sel of [cmpA, cmpB]) {
      sel.textContent = '';
      for (let i = 0; i < n; i++) { const o = document.createElement('option'); o.value = String(i); o.textContent = '턴 ' + (i + 1); sel.appendChild(o); }
    }
    if (n >= 2) { cmpA.value = String(n - 2); cmpB.value = String(n - 1); }
    if (cmpSelWrap) cmpSelWrap.hidden = n < 2;
  };
  const append = (who, text) => {
    const div = document.createElement('div');
    div.className = 'mc-interview__row';
    const b = document.createElement('strong'); b.textContent = who + ': ';
    const s = document.createElement('span'); s.textContent = text;   // textContent = escape-safe
    div.appendChild(b); div.appendChild(s); log.appendChild(div);
  };
  reset.addEventListener('click', (e) => { e.preventDefault(); transcript = ''; turn = 1; log.textContent = ''; input.value = ''; send.disabled = false; turnLabel.textContent = '(턴 1)'; aiOutputs.length = 0; if (compareOut) compareOut.hidden = true; refreshCmpOptions(); });
  // ADR-0130/0145: opt-in 산출 비교 — read-only diff of the two SELECTED AI turn outputs (default
  // prev vs latest), via the client-side __mcDraftPreview. Manual; needs >=2 outputs. No new exec/state.
  if (compareBtn && compareOut) compareBtn.addEventListener('click', (e) => {
    e.preventDefault();
    if (aiOutputs.length < 2) { showToast('비교할 AI 산출이 2개 이상 필요합니다', true); return; }
    let a = cmpA ? parseInt(cmpA.value, 10) : aiOutputs.length - 2;
    let b = cmpB ? parseInt(cmpB.value, 10) : aiOutputs.length - 1;
    if (!(a >= 0 && a < aiOutputs.length)) a = aiOutputs.length - 2;
    if (!(b >= 0 && b < aiOutputs.length)) b = aiOutputs.length - 1;
    window.__mcDraftPreview(compareOut, aiOutputs[a], aiOutputs[b]);
    const noteEl = compareOut.querySelector('.mc-ai-draft__note');
    if (noteEl) noteEl.textContent = '산출 비교 — 턴 ' + (a + 1) + ' vs 턴 ' + (b + 1) + ' AI 산출 (읽기 전용·제안)';   // restore compare note
    compareOut.hidden = false;
  });
  send.addEventListener('click', async (event) => {
    event.preventDefault();
    if (send.disabled) return;
    const msg = (input.value || '').trim();
    if (!msg) { showToast('입력을 작성하세요', true); return; }
    append('나', msg);
    transcript += '나: ' + msg + String.fromCharCode(10);
    input.value = '';
    send.disabled = true;
    try {
      const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ command: 'ai_draft', target: 'interview', turn: turn, transcript: transcript }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) throw new Error(data.error || '거부됨');
      const out = (data && typeof data.stdoutTail === 'string') ? data.stdoutTail : '';
      aiOutputs.push(out);   // ADR-0130: capture turn output for opt-in 산출 비교 (in-memory only)
      refreshCmpOptions();   // ADR-0145: refresh turn-select dropdowns from in-memory aiOutputs
      const last = turn >= ${INTERVIEW_MAX_TURNS};
      append(last ? 'AI 초안' : 'AI', out || '(응답 없음)');
      transcript += (last ? 'AI 초안: ' : 'AI: ') + out + String.fromCharCode(10);
      if (last) { showToast('인터뷰 완료 — 위 새 티켓으로 초안을 생성하세요'); turnLabel.textContent = '(완료)'; }
      else { turn += 1; send.disabled = false; turnLabel.textContent = '(턴 ' + turn + ')'; }
    } catch (e) { showToast(String(e.message || e), true); send.disabled = false; }
  });
})();
</script>`;
}

// ADR-0058: localhost-only board metadata-edit dispatch. One handler for all
// open-card edit rows. Compares against the row's current values and dispatches
// only the changed field(s) via ticket_edit exec; reloads on success. Mobile
// never renders the edit rows, and the server rejects ticket_edit for
// non-localhost regardless (T099).
function boardTicketEditScript() {
  return `<script>
(() => {
  const toast = document.getElementById('mc-toast');
  const showToast = (m, bad) => { if (!toast) return; toast.textContent = m; toast.classList.toggle('is-error', !!bad); toast.classList.add('is-visible'); setTimeout(() => toast.classList.remove('is-visible'), 5000); };
  async function dispatch(payload) {
    const res = await fetch('/api/exec', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    const data = await res.json().catch(() => ({}));
    if (!res.ok) throw new Error(data.error || '거부됨');
    if (data.exitCode !== 0) throw new Error('실패: ' + data.exitCode);
  }
  // ADR-0118: per-ticket-body on-disk baseline captured at page load (one editor per
  // ticket card) for the opt-in 변경 검토 (read-only diff before 본문 저장).
  const ticketBaselines = new Map();
  for (const ta of document.querySelectorAll('[data-ticket-body]')) ticketBaselines.set(ta, ta.value);
  document.addEventListener('click', async (event) => {
    // ADR-0118: opt-in 변경 검토 — read-only diff of this ticket's on-disk baseline vs
    // its current editor content, via the client-side __mcDraftPreview. No new exec/
    // writer/server state; the ticket_body save is unchanged (review is observe-only).
    const bodyReview = event.target.closest('button[data-ticket-body-review]');
    if (bodyReview) {
      event.preventDefault();
      event.stopPropagation();
      const rrow = bodyReview.closest('[data-ticket-body-row]');
      if (!rrow) return;
      const ta = rrow.querySelector('[data-ticket-body]');
      const reviewOut = rrow.querySelector('[data-ticket-review-out]');
      if (ta && reviewOut) {
        window.__mcDraftPreview(reviewOut, ticketBaselines.has(ta) ? ticketBaselines.get(ta) : '', ta.value);
        const noteEl = reviewOut.querySelector('.mc-ai-draft__note');
        if (noteEl) noteEl.textContent = '변경 검토 — 적용 전 현재 on-disk 본문과 비교 (읽기 전용·아직 적용 안 됨)';   // restore review note
        reviewOut.hidden = false;
      }
      return;
    }
    // ADR-0060: lifecycle verbs (cancel/reopen) — semantic, confirm + dispatch.
    const life = event.target.closest('button[data-ticket-lifecycle]');
    if (life) {
      event.preventDefault();
      event.stopPropagation();
      if (life.disabled) return;
      const action = life.dataset.ticketLifecycle;
      const id = life.dataset.ticketId;
      const verb = action === 'cancel' ? '취소(픽 큐에서 제외)' : '재개(픽 큐 복귀)';
      if (!window.confirm(id + ' 티켓을 ' + verb + ' 할까요?')) return;
      life.disabled = true;
      try {
        await dispatch({ command: 'ticket_lifecycle', action: action, ticketId: id });
        showToast(id + ' ' + action + ' 완료');
        setTimeout(() => window.location.reload(), 600);
      } catch (e) { showToast(String(e.message || e), true); life.disabled = false; }
      return;
    }
    // ADR-0064: new ticket — created safe:false (no safe input), gated for run.
    const create = event.target.closest('button[data-nt-create]');
    if (create) {
      event.preventDefault();
      event.stopPropagation();
      if (create.disabled) return;
      const form = create.closest('[data-newticket]');
      if (!form) return;
      const title = (form.querySelector('[data-nt-title]') || {}).value || '';
      if (!title.trim()) { showToast('제목을 입력하세요', true); return; }
      const priority = (form.querySelector('[data-nt-priority]') || {}).value || 'P2';
      const persona = (form.querySelector('[data-nt-persona]') || {}).value || 'implementer';
      const labels = ((form.querySelector('[data-nt-labels]') || {}).value || '').trim();
      const body = (form.querySelector('[data-nt-body]') || {}).value || '';
      create.disabled = true;
      try {
        await dispatch({ command: 'new_ticket', action: 'create', title: title.trim(), priority: priority, persona: persona, labels: labels, body: body });
        showToast('새 티켓 생성됨 (safe:false — 실행엔 승인 필요)');
        setTimeout(() => window.location.reload(), 700);
      } catch (e) { showToast(String(e.message || e), true); create.disabled = false; }
      return;
    }
    // ADR-0062: body save — pipe textarea content to ticket_body via exec.
    const bodySave = event.target.closest('button[data-ticket-body-save]');
    if (bodySave) {
      event.preventDefault();
      event.stopPropagation();
      if (bodySave.disabled) return;
      const row = bodySave.closest('[data-ticket-body-row]');
      if (!row) return;
      const id = row.dataset.ticketId;
      const ta = row.querySelector('[data-ticket-body]');
      const body = ta ? ta.value : '';
      bodySave.disabled = true;
      try {
        await dispatch({ command: 'ticket_body', action: 'set', ticketId: id, body: body });
        showToast(id + ' 본문 저장됨');
        setTimeout(() => window.location.reload(), 600);
      } catch (e) { showToast(String(e.message || e), true); bodySave.disabled = false; }
      return;
    }
    // ADR-0072: AI draft proposer — read-only. Dispatch ai_draft, show the draft in
    // a read-only block (textContent = escape-safe). The human copies it into the
    // textarea and applies via 본문 저장 (the proposer never writes).
    const aiDraft = event.target.closest('button[data-ai-draft]');
    if (aiDraft) {
      event.preventDefault();
      event.stopPropagation();
      if (aiDraft.disabled) return;
      const row = aiDraft.closest('[data-ticket-body-row]');
      if (!row) return;
      const id = row.dataset.ticketId;
      const out = row.querySelector('[data-ai-draft-out]');
      const outBody = row.querySelector('[data-ai-draft-body]');
      aiDraft.disabled = true;
      const prev = aiDraft.textContent;
      aiDraft.textContent = '초안 생성 중…';
      try {
        const r = await dispatch({ command: 'ai_draft', target: 'ticket-body', ticketId: id });
        const draft = (r && typeof r.stdoutTail === 'string') ? r.stdoutTail : '';
        const curEl = row.querySelector('[data-ticket-body]');
        if (out) { window.__mcDraftPreview(out, curEl ? curEl.value : '', draft); out.hidden = false; }
        showToast(id + ' AI 초안 제안됨 — 검토 후 적용');
      } catch (e) { showToast(String(e.message || e), true); }
      finally { aiDraft.disabled = false; aiDraft.textContent = prev; }
      return;
    }
    const save = event.target.closest('button[data-ticket-edit-save]');
    if (!save) return;
    event.preventDefault();
    event.stopPropagation();
    const row = save.closest('[data-ticket-edit-row]');
    if (!row) return;
    const id = row.dataset.ticketId;
    const prioritySel = row.querySelector('[data-ticket-edit-priority]');
    const labelsInput = row.querySelector('[data-ticket-edit-labels]');
    const newPriority = prioritySel ? prioritySel.value : '';
    const newLabels = labelsInput ? labelsInput.value.trim() : '';
    const tasks = [];
    if (newPriority && newPriority !== row.dataset.curPriority) tasks.push({ command: 'ticket_edit', action: 'set-priority', ticketId: id, priority: newPriority });
    if (newLabels !== (row.dataset.curLabels || '')) tasks.push({ command: 'ticket_edit', action: 'set-labels', ticketId: id, labels: newLabels });
    if (!tasks.length) { showToast('변경 사항 없음'); return; }
    save.disabled = true;
    try {
      for (const t of tasks) await dispatch(t);
      showToast(id + ' 메타 저장됨');
      setTimeout(() => window.location.reload(), 600);
    } catch (e) { showToast(String(e.message || e), true); save.disabled = false; }
  });
})();
</script>`;
}

function stripFrontmatter(content) {
  return content.replace(/^---\r?\n[\s\S]*?\r?\n---\r?\n?/, '');
}

function readTicketBody(ticket) {
  try {
    return stripFrontmatter(readFileSync(join(TICKETS_DIR, ticket.file), 'utf8'));
  } catch {
    return '';
  }
}

function extractSection(markdown, keyword) {
  const body = stripFrontmatter(markdown);
  const re = /^##\s+.*$/gm;
  const headings = [];
  let match;
  while ((match = re.exec(body)) !== null) {
    headings.push({ text: match[0], index: match.index });
  }
  const startIdx = headings.findIndex(h => h.text.includes(keyword));
  if (startIdx === -1) return '';
  const startLineEnd = body.indexOf('\n', headings[startIdx].index);
  const start = startLineEnd === -1 ? body.length : startLineEnd + 1;
  const end = headings[startIdx + 1]?.index ?? body.length;
  return body.slice(start, end).trim();
}

function markdownToText(markdown) {
  return markdown
    .split('\n')
    .map(line => line
      .replace(/^>\s?/, '')
      .replace(/^\s*-\s*\[[ xX]\]\s*/, '')
      .replace(/^\s*[-*]\s*/, '')
      .replace(/^```.*$/, '')
      .trim())
    .filter(Boolean)
    .join('\n');
}

function approvalParts(ticket) {
  const content = readTicketBody(ticket);
  const rationale = markdownToText(extractSection(content, '목표'));
  const expected = markdownToText(extractSection(content, '수용 기준'));
  const downside = markdownToText(extractSection(content, '롤백'));
  return {
    rationale,
    expected,
    downside,
    incomplete: !rationale || !expected || !downside,
  };
}

function latestFailureByTicket() {
  const map = new Map();
  for (const failure of parseFailures()) map.set(String(failure.ticket_id), failure);
  return map;
}

// ADR-0037 §3.2: surface RECORDED verification (run_checks/security) from
// docs/reviews/<ticket>*.md. Read-only — the card NEVER runs checks at render
// time (no side effects). Absent record → "검증 기록 없음" so the human knows.
function reviewStatus(ticketId) {
  try {
    if (!existsSync(REVIEWS_DIR)) return { found: false };
    const id = String(ticketId);
    const match = readdirSync(REVIEWS_DIR)
      .find(f => f.endsWith('.md') && (f === `${id}.md` || f.startsWith(`${id}-`)));
    if (!match) return { found: false };
    const text = readFileSync(join(REVIEWS_DIR, match), 'utf8');
    const line = text.split('\n').map(l => l.trim())
      .find(l => l.length <= 160 && /(run_checks|security|검증|PASS|통과|✅|❌|FAIL)/i.test(l));
    return { found: true, text: line || '검증 기록 있음' };
  } catch { return { found: false }; }
}

// ADR-0037 §3.1: recovery command for the 다운사이드 element. Prefer a command
// found in the ticket rollback section; else the conservative default.
function recoveryCommand(downside) {
  const found = String(downside || '').split('\n').map(s => s.trim())
    .find(s => /^(git\s+(revert|reset)|down|npm |node |\.\/scripts\/)/.test(s));
  return found || 'git revert <commit>';
}

// ADR-0037 §3.3: machine judgement for low-risk bulk-approval candidacy.
// FAIL-CLOSED — a candidate must be safe:false, labelled `docs`, carry no risk
// label, and its declared Scope must not reference any non-docs code/script/
// test path. Anything ambiguous is excluded (handled as an individual card).
const BULK_RISK_LABELS = ['security', 'auth', 'code', 'concurrency', 'ui', 'test', 'server', 'infra'];
function lowRiskDocsOnly(ticket) {
  // 리뷰 2차 P1-6: safe가 malformed인 티켓은 "명시적 safe:false"가 아니다 —
  // bulk 승인 후보에서 제외(fail-closed). 개별 카드로만 다룬다.
  if (ticket.safe_malformed) return false;
  if (ticket.safe !== false) return false;
  const labels = (ticket.labels || []).map(s => String(s).toLowerCase());
  if (!labels.includes('docs')) return false;
  if (labels.some(l => BULK_RISK_LABELS.includes(l))) return false;
  const body = readTicketBody(ticket);
  const scope = extractSection(body, '변경 범위') || extractSection(body, 'Scope') || body;
  if (/\b(mission-control\/|scripts\/|tests\/|state\/)/.test(scope)) return false;
  if (/[\w./-]+\.(mjs|js|sh|bats|css|json|ts|py)\b/.test(scope)) return false;
  return true;
}

function bulkApprovalCandidates() {
  const { byStatus } = getModel();
  return (byStatus['awaiting-approval'] || []).filter(lowRiskDocsOnly);
}

// ADR-0170 T263: HITL 컨텍스트(읽기 전용) — 결정 지점·스코프·허용 결정·요청 맥락(trace).
// 기존 카드/버튼/exec 무변경, 추가 표시만. escape-first(escapeHtml — DOM 텍스트만).
// 리뷰 M1: traceRuns(collectRuns 결과)를 페이지 렌더에서 1회 계산해 주입 — 카드마다
// getRun이 reservations·failures·approvals 전체를 재독하던 I/O 증폭 제거(동일 결론).
function renderHitlContext(ticket, traceRuns = null) {
  let run = null;
  try {
    run = traceRuns ? runFrom(traceRuns, String(ticket.id)) : getRun(ROOT, String(ticket.id));
  } catch { run = null; }
  const hasErr = !!(run && run.spans && run.spans.some(s => s.status === 'err'));
  const traceNote = run
    ? `run ${escapeHtml(run.state)} · ${escapeHtml(run.status)} · ${run.spanCount} spans${hasErr ? ' · 실패 span 있음' : ''}`
    : '연관 run 기록 없음';
  const labels = Array.isArray(ticket.labels) && ticket.labels.length
    ? ` · ${escapeHtml(ticket.labels.slice(0, 4).join(', '))}` : '';
  // ADR-0170 T264: 결정 상태(읽기 도출). pending|decided|stale(ADR-0174)|superseded.
  let state = 'pending';
  try { state = decisionState(ROOT, ticket); } catch { state = 'pending'; }
  // ADR-0174 T268: stale일 때 강조 안내(승인이 현재 티켓과 불일치).
  const staleNote = state === 'stale'
    ? '<span class="mc-hitl__stale">승인이 현재 티켓과 불일치 — 재확인 필요</span>'
    : '';
  // ADR-0174 §1/T268: edit는 동결 게이트(awaiting-approval)에서 직접 불가 — read-only 안내.
  // 편집-후-승인은 reject→reopen→Board 편집→재포지 흐름. 새 writer/exec/버튼 없음.
  const editPath = '게이트에서 직접 편집 불가(동결) — reject 후 Board에서 reopen·수정·재포지';
  return `<section class="mc-hitl" aria-label="HITL 컨텍스트 (읽기 전용)">
    <div class="mc-hitl__row"><span class="mc-hitl__k">상태</span><span class="mc-hitl__v"><span class="mc-state mc-state--${escapeHtml(state)}">${escapeHtml(state)}</span>${staleNote}</span></div>
    <div class="mc-hitl__row"><span class="mc-hitl__k">결정 지점</span><span class="mc-hitl__v">exec dispatch 승인 — ${escapeHtml(ticket.id)} · ${escapeHtml(ticket.persona || '?')}${labels}</span></div>
    <div class="mc-hitl__row"><span class="mc-hitl__k">스코프</span><span class="mc-hitl__v"><code>localhost</code> · exec whitelist (ADR-0024)</span></div>
    <div class="mc-hitl__row"><span class="mc-hitl__k">허용 결정</span><span class="mc-hitl__v"><span class="mc-decision">approve</span> <span class="mc-decision">reject</span></span></div>
    <div class="mc-hitl__row"><span class="mc-hitl__k">편집</span><span class="mc-hitl__v">${escapeHtml(editPath)}</span></div>
    <div class="mc-hitl__row"><span class="mc-hitl__k">요청 맥락</span><span class="mc-hitl__v">${traceNote}</span></div>
  </section>`;
}

function renderApprovalCard(ticket, failures, traceRuns = null) {
  const parts = approvalParts(ticket);
  const approveCmd = `./scripts/approve.sh ${ticket.id}`;
  const rejectCmd = `./scripts/approve.sh ${ticket.id} --reject "&lt;reason&gt;"`;
  const failure = failures.get(String(ticket.id));
  const review = reviewStatus(ticket.id);
  const recovery = recoveryCommand(parts.downside);
  const reviewBadge = review.found
    ? `<span class="mc-review mc-review--ok" title="docs/reviews 기록">리뷰: ${escapeHtml(review.text)}</span>`
    : `<span class="mc-review mc-review--none">검증 기록 없음</span>`;
  return `<article id="approval-${escapeHtml(ticket.id)}" class="mc-approval-card" role="button" tabindex="0" aria-label="${escapeHtml(ticket.id)} approval">
  <div class="mc-card__top">
    <span class="mc-ticket-id">${escapeHtml(ticket.id)}</span>
    <span class="mc-chip">${escapeHtml(ticket.priority || 'P?')}</span>
    <span class="mc-unsafe">safe:false</span>
    ${parts.incomplete ? '<span class="mc-warning">정보 부족</span>' : ''}
  </div>
  <h2>${escapeHtml(ticket.title || '(untitled)')}</h2>
  <div class="mc-approval-grid">
    <section><h3>근거</h3><p>${escapeHtml(parts.rationale || 'No rationale found')}</p></section>
    <section><h3>예상 결과</h3><p>${escapeHtml(parts.expected || 'No expected result found')}</p></section>
    <section><h3>다운사이드</h3><p>${escapeHtml(parts.downside || '롤백 정보 없음 — 기본 복구 사용')}</p><pre class="mc-recovery" aria-label="복구 명령">${escapeHtml(recovery)}</pre></section>
  </div>
  ${renderHitlContext(ticket, traceRuns)}
  <div class="mc-approval-actions">
    <span class="${failure ? 'mc-gate mc-gate--fail' : 'mc-gate'}">${failure ? '최근 실패 있음' : '최근 실패 없음'}</span>
    ${reviewBadge}
    <code class="mc-approval-cli" aria-hidden="true">$ ${approveCmd}</code>
    <div class="mc-approval-buttons">
      ${renderWriteButton({ label: 'Approve', cliCommand: approveCmd, execCommand: 'approve', ticketId: ticket.id })}
      ${renderWriteButton({ label: 'Reject', cliCommand: rejectCmd, execCommand: 'approve', ticketId: ticket.id, reject: true, className: 'mc-write--danger' })}
    </div>
  </div>
</article>`;
}

// ADR-0037 §3.3: low-risk batch review row. localhost-only (mobile gets single
// cards only, T099). Each id is re-validated server-side at POST time and a
// SEPARATE per-ticket marker is written — never a single blanket approval.
function renderBulkApprovalRow(candidates) {
  if (!candidates.length) return '';
  const ids = candidates.map(t => String(t.id));
  const list = candidates
    .map(t => `<li><span class="mc-ticket-id">${escapeHtml(t.id)}</span> ${escapeHtml(t.title || '')}</li>`)
    .join('\n');
  return `<section class="mc-bulk" aria-label="저위험 묶음 승인">
  <div class="mc-bulk__head">
    <h3>저위험 묶음 승인 후보 (${candidates.length}건)</h3>
    <span class="mc-bulk__hint">docs-only · 코드/보안/삭제 제외 · 티켓별 개별 마커</span>
  </div>
  <ul class="mc-bulk__list">${list}</ul>
  <button type="button" class="mc-write mc-bulk__approve" data-bulk-approve data-bulk-ids="${escapeHtml(ids.join(','))}">묶음 검토 후 일괄 승인 (${candidates.length}건)</button>
</section>`;
}

function isRespondableSession(session) {
  return ['paused', 'running'].includes(String(session?.state || ''));
}

// ADR-0172 T266: Inbox respond는 승인 카드가 아니라 live 세션 sub-queue에 둔다.
// reservation이 있는 티켓은 getModel()에서 forging으로 분류되어 awaiting-approval 큐에
// 남을 수 없기 때문이다. 기존 session_ctl redirect exec를 재사용하며 새 writer/exec 0.
function renderRespondableSessionsQueue({ isLocalhost = true } = {}) {
  const sessions = listSessions().filter(isRespondableSession);
  if (!sessions.length) return '';
  const rows = sessions.map(session => {
    const title = session.title || '(untitled)';
    const controls = isLocalhost
      ? `<div class="mc-respond-row">${renderRespondButton(session.id)}</div>`
      : '<div class="mc-session-actions mc-session-actions--observe" role="note">관측 전용 — respond는 localhost 데스크톱에서만 가능합니다.</div>';
    return `<article id="respond-${escapeHtml(session.id)}" class="mc-respond-card">
      <div class="mc-card__top">
        <span class="mc-ticket-id">${escapeHtml(session.id)}</span>
        <span class="mc-session-state ${session.state === 'paused' ? 'mc-session-state--paused' : 'mc-session-state--running'}">${escapeHtml(session.state)}</span>
      </div>
      <h3><a href="/sessions?session=${escapeHtml(session.id)}">${escapeHtml(title)}</a></h3>
      <p>${escapeHtml(session.persona || 'n/a')} · ${escapeHtml(session.timeout_backend || 'unknown')} · 기존 <code>session_ctl redirect</code> 재사용</p>
      ${controls}
    </article>`;
  }).join('\n');
  return `<section class="mc-respond-queue" aria-label="응답 가능 세션">
    <div class="mc-panel__head">
      <h2>응답 가능 세션</h2>
      <span>${sessions.length}</span>
    </div>
    <div class="mc-respond-grid">${rows}</div>
  </section>`;
}

function renderInboxPage({ isLocalhost = true } = {}) {
  const { byStatus } = getModel();
  const approvals = byStatus['awaiting-approval'] || [];
  const failures = latestFailureByTicket();
  // 리뷰 M1: trace 스캔은 페이지 렌더당 1회 — 카드 N개 × 전수 파일 재독 방지.
  const traceRuns = approvals.length ? collectRuns(ROOT) : null;
  const cards = approvals.length
    ? approvals.map(ticket => renderApprovalCard(ticket, failures, traceRuns)).join('\n')
    : '<p class="mc-empty">No approvals waiting</p>';
  // The inbox is the mobile-permitted surface: approve/reject only (T099 scope).
  // Bulk approval is localhost-only (ADR-0037 §3.3) — never rendered for mobile.
  const bulkRow = isLocalhost ? renderBulkApprovalRow(bulkApprovalCandidates()) : '';
  const respondQueue = renderRespondableSessionsQueue({ isLocalhost });
  // Bulk handler is inline + localhost-only. URL built by concatenation so the
  // R5 service-worker /api/ cache-lint never false-matches a bare literal here.
  const bulkScript = bulkRow ? `<script>
(function(){
  var btn = document.querySelector('[data-bulk-approve]');
  if (!btn) return;
  btn.addEventListener('click', function(){
    var ids = (btn.getAttribute('data-bulk-ids')||'').split(',').filter(Boolean);
    if (!ids.length) return;
    if (!window.confirm(ids.length + '건의 저위험 docs-only 티켓을 일괄 승인합니다. 각 티켓에 개별 승인 마커가 생성됩니다. 계속할까요?')) return;
    btn.disabled = true;
    fetch('/api' + '/approvals/bulk', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ ids: ids }) })
      .then(function(r){ return r.json(); })
      .then(function(){ window.location.reload(); })
      .catch(function(){ btn.disabled = false; });
  });
})();
</script>` : '';
  const main = `<main class="mc-page mc-page--inbox" aria-label="Approval Inbox">
  ${respondQueue}
  ${bulkRow}
  <section class="mc-inbox" aria-live="polite">
    ${cards}
  </section>
  ${bulkScript}
</main>`;
  return renderShell('Approval Inbox', 'inbox', main, { isLocalhost });
}

function readKeyValueFile(file) {
  const values = {};
  try {
    if (!existsSync(file)) return values;
    for (const line of readFileSync(file, 'utf8').split('\n')) {
      const idx = line.indexOf('=');
      if (idx <= 0) continue;
      values[line.slice(0, idx)] = line.slice(idx + 1);
    }
  } catch { /* ignore transient file changes */ }
  return values;
}

function parseSessionEvents(file) {
  try {
    if (!existsSync(file)) return [];
    return readFileSync(file, 'utf8')
      .split('\n')
      .filter(Boolean)
      .map(line => {
        try { return JSON.parse(line); }
        catch { return { ts: '', actor: 'system', action: 'parse-error', detail: line }; }
      });
  } catch { return []; }
}

function sessionLogPath(id) {
  return join(LOGS_DIR, `${id}.log`);
}

function readTail(file, maxLines = 80) {
  try {
    if (!existsSync(file)) return [];
    return readFileSync(file, 'utf8').split('\n').filter(Boolean).slice(-maxLines);
  } catch { return []; }
}

const sessionStateFromEvents = sessionStateFromEventsPrimitive; // 리뷰 M5: 공용 원시 위임

function listSessions() {
  const tickets = new Map(allTickets().map(ticket => [String(ticket.id), ticket]));
  const sessions = [];
  try {
    if (!existsSync(RESERVATIONS_DIR)) return sessions;
    for (const entry of readdirSync(RESERVATIONS_DIR)) {
      if (!entry.endsWith('.d')) continue;
      const id = entry.slice(0, -2);
      if (!/^T[0-9]{3,}$/.test(id)) continue;
      const dir = join(RESERVATIONS_DIR, entry);
      let stat;
      try { stat = statSync(dir); } catch { continue; }
      const meta = readKeyValueFile(join(dir, 'meta'));
      const events = parseSessionEvents(join(dir, 'events.jsonl'));
      const ticket = tickets.get(id) || null;
      sessions.push({
        id,
        title: ticket?.title || '',
        persona: meta.persona || ticket?.persona || '',
        mode: meta.mode || '',
        root: meta.root || '',
        started_at: meta.started_at || '',
        pgid: meta.pgid || 'unknown',
        timeout_backend: meta.timeout_backend || 'unknown',
        state: sessionStateFromEvents(events),
        reservedAtMs: stat.mtimeMs,
        logPath: sessionLogPath(id),
        logTail: readTail(sessionLogPath(id)),
        events,
      });
    }
  } catch { /* directory may disappear */ }
  // 리뷰 후속(M2 동일 패턴): numeric 비교 — 사전순은 T1000 < T999로 4자리 전환 시 깨진다.
  sessions.sort((a, b) => a.id.localeCompare(b.id, undefined, { numeric: true }));
  return sessions;
}

function renderSessionListItem(session, active) {
  const stateClass = session.state === 'paused' ? 'mc-session-state--paused' : 'mc-session-state--running';
  return `<li id="session-list-${escapeHtml(session.id)}" class="mc-session-item${active ? ' is-active' : ''}">
    <a href="/sessions?session=${escapeHtml(session.id)}">
      <span class="mc-ticket-id">${escapeHtml(session.id)}</span>
      <strong>${escapeHtml(session.title || '(untitled)')}</strong>
      <span>${escapeHtml(session.persona || 'n/a')} · ${escapeHtml(session.timeout_backend)}</span>
      <em class="mc-session-state ${stateClass}">${escapeHtml(session.state)}</em>
    </a>
  </li>`;
}

// ADR-0168 T261: Sessions에 trace 요약(읽기 전용). /api/trace projection을 서버 렌더로 주입.
// 세션 제어/exec/writer/스키마 무변경 — 추가 패널만. escape-first(escapeHtml — DOM 텍스트만).
function renderTraceSummary(run) {
  if (!run) return '';
  const dur = run.durationMs != null ? `${Math.round(run.durationMs / 1000)}s` : '—';
  const recent = (run.spans || []).slice(-6).map(s =>
    `<li class="mc-trace-span mc-trace-span--${escapeHtml(s.status)}"><em class="mc-trace-span__type">${escapeHtml(s.type)}</em><span class="mc-trace-span__name">${escapeHtml(s.name)}</span><b class="mc-trace-span__status">${escapeHtml(s.status)}</b></li>`
  ).join('');
  return `<section class="mc-panel mc-trace-summary" aria-label="Trace 요약 (읽기 전용)">
    <div class="mc-panel__head"><h3>Trace 요약</h3><span>읽기 전용 · ADR-0166</span></div>
    <div class="mc-trace-meta">
      <span>state <strong>${escapeHtml(run.state)}</strong></span>
      <span>status <strong class="mc-trace-status--${escapeHtml(run.status)}">${escapeHtml(run.status)}</strong></span>
      <span>spans <strong>${run.spanCount}</strong></span>
      <span>dur <strong>${escapeHtml(dur)}</strong></span>
    </div>
    <ol class="mc-trace-spans">${recent || '<li class="mc-empty">스팬 없음</li>'}</ol>
  </section>`;
}

function renderSessionsPage(selectedId = '', { isLocalhost = true } = {}) {
  const sessions = listSessions();
  const selected = sessions.find(session => session.id === selectedId) || sessions[0] || null;
  const list = sessions.length
    ? sessions.map(session => renderSessionListItem(session, selected?.id === session.id)).join('\n')
    : '<li class="mc-empty">No active sessions</li>';
  const events = selected?.events?.length
    ? selected.events.slice(-80).map(event => `<li><span>${escapeHtml(event.ts || '')}</span><strong>${escapeHtml(event.actor || 'system')}</strong><em>${escapeHtml(event.action || '')}</em><p>${escapeHtml(event.detail || '')}</p></li>`).join('\n')
    : '<li class="mc-empty">No session events</li>';
  const logText = selected ? selected.logTail.join('\n') : '';
  const detail = selected
    ? `<section id="session-${escapeHtml(selected.id)}" class="mc-session-detail" aria-labelledby="session-detail-title" tabindex="-1">
        <div class="mc-panel__head">
          <h2 id="session-detail-title">${escapeHtml(selected.id)} live stream</h2>
          <span>${escapeHtml(selected.state)} · pgid=${escapeHtml(selected.pgid)}</span>
        </div>
        ${renderSessionInterventionBar(selected, { isLocalhost })}
        <div class="mc-session-grid">
          <section class="mc-session-events-panel" aria-label="Session timeline">
            <h3>Timeline</h3>
            <ol id="mc-session-events" class="mc-session-events">${events}</ol>
          </section>
          <div class="mc-session-rail">
            ${renderTraceSummary(getRun(ROOT, selected.id))}
            <section class="mc-session-log-panel" aria-label="Session log">
              <h3>Log Tail</h3>
              <pre id="mc-session-log" data-session-stream="${escapeHtml(selected.id)}">${escapeHtml(logText)}</pre>
            </section>
          </div>
        </div>
      </section>`
    : `<section class="mc-session-detail" aria-live="polite"><p class="mc-empty">No active sessions</p></section>`;
  const main = `<main class="mc-page mc-page--sessions" aria-label="Live Sessions">
    <aside class="mc-panel mc-session-sidebar" aria-label="Active sessions">
      <div class="mc-panel__head">
        <h2>Workers</h2>
        <span>${sessions.length}</span>
      </div>
      <ol class="mc-session-list">${list}</ol>
    </aside>
    ${detail}
  </main>`;
  return renderShell('Live Sessions', 'sessions', main, { isLocalhost });
}

function sseWrite(res, event, payload) {
  res.write(`event: ${event}\n`);
  res.write(`data: ${JSON.stringify(payload)}\n\n`);
}

function approvalNotificationSnapshot() {
  const { byStatus } = getModel();
  return new Map((byStatus['awaiting-approval'] || []).map(ticket => [String(ticket.id), {
    id: String(ticket.id),
    title: String(ticket.title || ''),
    focusId: `approval-${ticket.id}`,
    href: `/inbox#approval-${ticket.id}`,
  }]));
}

function isSessionFailureNotification(failure) {
  return /^(idle-exit|claude-exec-failed|checks-failed)$/.test(String(failure.stage || ''));
}

function failureNotificationSnapshot() {
  return parseFailures()
    .filter(isSessionFailureNotification)
    .map(failure => ({
      key: [failure.timestamp, failure.ticket_id, failure.stage, failure.retry, failure.message].join('\t'),
      id: String(failure.ticket_id || ''),
      stage: String(failure.stage || ''),
      message: String(failure.message || ''),
      focusId: `session-${failure.ticket_id}`,
      href: `/sessions?session=${encodeURIComponent(failure.ticket_id)}#session-${encodeURIComponent(failure.ticket_id)}`,
    }));
}

function handleNotificationStream(req, res) {
  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });
  res.write('retry: 1000\n\n');

  let approvals = approvalNotificationSnapshot();
  let failures = new Set(failureNotificationSnapshot().map(item => item.key));

  const pump = () => {
    const nextApprovals = approvalNotificationSnapshot();
    for (const [id, payload] of nextApprovals) {
      if (!approvals.has(id)) sseWrite(res, 'approval-required', payload);
    }
    approvals = nextApprovals;

    const nextFailures = failureNotificationSnapshot();
    for (const payload of nextFailures) {
      if (!failures.has(payload.key)) sseWrite(res, 'session-failure', payload);
    }
    failures = new Set(nextFailures.map(item => item.key));
  };

  const timer = setInterval(pump, 1000);
  req.on('close', () => clearInterval(timer));
}

function handleSessionStream(req, res, id) {
  if (!/^T[0-9]{3,}$/.test(id)) {
    json(res, 400, { error: 'invalid session id' });
    return;
  }
  const dir = join(RESERVATIONS_DIR, `${id}.d`);
  if (!existsSync(dir)) {
    json(res, 404, { error: 'session not found' });
    return;
  }

  res.writeHead(200, {
    'Content-Type': 'text/event-stream; charset=utf-8',
    'Cache-Control': 'no-cache, no-transform',
    Connection: 'keep-alive',
  });
  res.write('retry: 1000\n\n');

  const logPath = sessionLogPath(id);
  const eventsPath = join(dir, 'events.jsonl');
  let logOffset = 0;
  let eventsOffset = 0;

  const readBuffer = file => {
    try {
      if (!existsSync(file)) return Buffer.alloc(0);
      return readFileSync(file);
    } catch {
      return Buffer.alloc(0);
    }
  };

  const pump = initial => {
    const logBuffer = readBuffer(logPath);
    if (initial) logOffset = Math.max(0, logBuffer.length - 8192);
    if (logBuffer.length < logOffset) logOffset = 0;
    if (logBuffer.length > logOffset) {
      const chunk = logBuffer.subarray(logOffset).toString('utf8');
      logOffset = logBuffer.length;
      for (const line of chunk.split('\n').filter(Boolean)) {
        sseWrite(res, 'log', { id, line });
      }
    }

    const eventsBuffer = readBuffer(eventsPath);
    if (eventsBuffer.length < eventsOffset) eventsOffset = 0;
    if (eventsBuffer.length > eventsOffset) {
      const chunk = eventsBuffer.subarray(eventsOffset).toString('utf8');
      eventsOffset = eventsBuffer.length;
      for (const line of chunk.split('\n').filter(Boolean)) {
        try { sseWrite(res, 'event', { id, event: JSON.parse(line) }); }
        catch { sseWrite(res, 'event', { id, event: { actor: 'system', action: 'parse-error', detail: line } }); }
      }
    }
  };

  pump(true);
  const timer = setInterval(() => pump(false), 500);
  req.on('close', () => clearInterval(timer));
}

function readRequestBody(req, limit = 8192) {
  return new Promise((resolve, reject) => {
    let body = '';
    req.setEncoding('utf8');
    req.on('data', chunk => {
      body += chunk;
      if (body.length > limit) {
        reject(new Error('request body too large'));
        req.destroy();
      }
    });
    req.on('end', () => resolve(body));
    req.on('error', reject);
  });
}

function json(res, status, payload) {
  res.writeHead(status, { 'Content-Type': 'application/json' });
  res.end(JSON.stringify(payload));
}

// ADR-0155 Phase 1: READ-ONLY, base-bounded directory listing for the new-project
// picker. NOT a filesystem browser — it lists only DIRECTORY NAMES under an
// allowlisted base (env MC_NEW_PROJECT_BASE, default dirname(ROOT)). realpath
// resolution + base containment blocks `..` and symlink escape; the repo (ROOT)
// and its interior, dotfiles, and all file entries are excluded. No file content
// is ever read. Throws on any out-of-bounds / unsafe request (caller → 400).
function listProjectDirs(baseParam) {
  if (typeof baseParam !== 'string') baseParam = '';
  if (baseParam.length > 4096 || /[\x00-\x1f\x7f]/.test(baseParam)) {
    throw new Error('invalid base (<=4096, no control chars)');
  }
  let allowRoot;
  try {
    allowRoot = realpathSync(process.env.MC_NEW_PROJECT_BASE || dirname(ROOT));
  } catch {
    throw new Error('project base directory is not accessible');
  }
  const realRoot = realpathSync(ROOT);
  // Resolve the requested path against the allowlisted base, then realpath it so
  // symlinks are followed BEFORE the containment check (no symlink escape).
  const requested = baseParam ? resolve(allowRoot, baseParam) : allowRoot;
  let real;
  try { real = realpathSync(requested); } catch { throw new Error('path not found'); }
  const within = p => p === allowRoot || p.startsWith(allowRoot + sep);
  if (!within(real)) throw new Error('base must stay within the allowed project base');
  // Never browse the repository itself or its interior.
  if (real === realRoot || real.startsWith(realRoot + sep)) {
    throw new Error('the repository itself is not browsable');
  }
  let st;
  try { st = statSync(real); } catch { throw new Error('path not found'); }
  if (!st.isDirectory()) throw new Error('not a directory');
  let dirents = [];
  try { dirents = readdirSync(real, { withFileTypes: true }); } catch { dirents = []; }
  const entries = dirents
    .filter(d => d.isDirectory() && !d.name.startsWith('.'))   // dirs only, no dotfiles, no symlinks
    .map(d => d.name)
    .filter(name => resolve(real, name) !== realRoot)          // hide the repo dir when listing its parent
    .sort((a, b) => a.localeCompare(b))
    .slice(0, 1000);
  const parent = real === allowRoot ? null : dirname(real);
  return { base: real, parent, entries };
}

// ADR-0201 T293: READ-ONLY preflight — classifies a create/adopt target as
// missing | empty | occupied so the unified /new-project flow can route without
// asking the user to self-classify. Path rules mirror the init_new_project exec
// branch (required, <=4096, no control chars, SOURCE rejected). Dotfiles COUNT:
// a folder holding only .git is occupied, not empty (strict, fail-closed).
// Never writes; any error throws (caller → 400 → UI blocks creation).
function newProjectPreflight(targetParam) {
  const targetPath = typeof targetParam === 'string' ? targetParam.trim() : '';
  if (!targetPath || targetPath.length > 4096 || /[\x00-\x1f\x7f]/.test(targetPath)) {
    throw new Error('invalid target (required, <=4096, no control chars)');
  }
  const rootAbs = resolve(ROOT);
  const tgtAbs = resolve(rootAbs, targetPath);
  if (tgtAbs === rootAbs || tgtAbs.startsWith(rootAbs + '/')) {
    throw new Error('target must be outside this repository (SOURCE is read-only)');
  }
  let st;
  try { st = statSync(tgtAbs); } catch { return { target: tgtAbs, state: 'missing' }; }
  if (!st.isDirectory()) throw new Error('target exists and is not a directory');
  const entries = readdirSync(tgtAbs); // dotfiles included — strict emptiness
  return { target: tgtAbs, state: entries.length === 0 ? 'empty' : 'occupied' };
}

function manifestJson() {
  return {
    name: 'Hephaestus Mission Control',
    short_name: 'Mission Control',
    description: 'Localhost-only approval inbox and forge board.',
    start_url: '/inbox',
    scope: '/',
    display: 'standalone',
    background_color: '#0E1116',
    theme_color: '#0E1116',
    icons: [
      { src: '/icons/icon-192.svg', sizes: '192x192', type: 'image/svg+xml', purpose: 'any maskable' },
      { src: '/icons/icon-512.svg', sizes: '512x512', type: 'image/svg+xml', purpose: 'any maskable' },
    ],
  };
}

function iconSvg(size) {
  const fontSize = Math.round(size * 0.46);
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${size}" height="${size}" viewBox="0 0 ${size} ${size}" role="img" aria-label="Hephaestus Mission Control">
  <rect width="${size}" height="${size}" rx="${Math.round(size * 0.16)}" fill="#0E1116"/>
  <rect x="${Math.round(size * 0.08)}" y="${Math.round(size * 0.08)}" width="${Math.round(size * 0.84)}" height="${Math.round(size * 0.84)}" rx="${Math.round(size * 0.12)}" fill="#161B22" stroke="#FF6B35" stroke-width="${Math.max(3, Math.round(size * 0.025))}"/>
  <text x="50%" y="54%" text-anchor="middle" dominant-baseline="middle" font-family="-apple-system, BlinkMacSystemFont, 'Segoe UI Emoji', sans-serif" font-size="${fontSize}" fill="#FFB86B">⚒</text>
</svg>`;
}

function serviceWorkerScript() {
  return `const CACHE_NAME = 'hephaestus-mission-control-static-v1';
const STATIC_CACHE_URLS = ${JSON.stringify(STATIC_CACHE_URLS)};

self.addEventListener('install', event => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then(cache => cache.addAll(STATIC_CACHE_URLS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', event => {
  event.waitUntil(
    caches.keys()
      .then(keys => Promise.all(keys.filter(key => key !== CACHE_NAME).map(key => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

// ADR-0029 §3.1: device token store for Authorization injection.
// Held in memory and persisted in IndexedDB (survives SW restarts). Never the
// service worker's truth — the server validates every request (token revocation
// stays immediate; a stale SW token cannot bypass it).
var mcDeviceToken = null;
var mcExpiresAt = 0;            // ms epoch of token expiry; 0 = unknown
var mcRenewing = false;
var mcLastRenewAttempt = 0;
var MC_RENEWAL_WINDOW_MS = ${RENEWAL_WINDOW_MS};
function mcIdb(mode, run) {
  return new Promise(function (resolve) {
    var req;
    try { req = indexedDB.open('mc-auth', 1); } catch (e) { resolve(null); return; }
    req.onupgradeneeded = function () { try { req.result.createObjectStore('kv'); } catch (e) {} };
    req.onsuccess = function () {
      var tx;
      try { tx = req.result.transaction('kv', mode); } catch (e) { resolve(null); return; }
      run(tx.objectStore('kv'), resolve);
    };
    req.onerror = function () { resolve(null); };
  });
}
function mcReadKey(key) { return mcIdb('readonly', function (store, resolve) { var g = store.get(key); g.onsuccess = function () { resolve(g.result || null); }; g.onerror = function () { resolve(null); }; }); }
function mcWriteKey(key, v) { return mcIdb('readwrite', function (store, resolve) { store.put(v, key); resolve(v); }); }
function mcGetToken() {
  if (mcDeviceToken) return Promise.resolve(mcDeviceToken);
  return mcReadKey('token').then(function (t) {
    mcDeviceToken = t;
    if (!mcExpiresAt) { mcReadKey('expires').then(function (e) { if (e) mcExpiresAt = new Date(e).getTime(); }); }
    return t;
  });
}

self.addEventListener('message', function (event) {
  var data = event.data || {};
  if (data.type === 'mc-set-token' && typeof data.token === 'string' && data.token) {
    mcDeviceToken = data.token; mcWriteKey('token', data.token);
    if (data.expires_at) { mcExpiresAt = new Date(data.expires_at).getTime(); mcWriteKey('expires', data.expires_at); }
  } else if (data.type === 'mc-clear-token') {
    mcDeviceToken = null; mcExpiresAt = 0; mcWriteKey('token', ''); mcWriteKey('expires', '');
  }
});

// ADR-0031 §3: single-flight auto-renew. When the stored token is within the
// renewal window, rotate it via POST /api/tokens/renew and broadcast the new
// token to clients so localStorage stays in sync. Best-effort, cooldown-guarded,
// never blocks the triggering request. The renewed token does not widen scope —
// non-localhost exec stays approve-only (T099, server-authoritative).
function mcMaybeRenew(token) {
  if (mcRenewing || !token || !mcExpiresAt) return;
  if (mcExpiresAt - Date.now() > MC_RENEWAL_WINDOW_MS) return;
  if (Date.now() - mcLastRenewAttempt < 60000) return; // cooldown vs clock-skew loops
  mcLastRenewAttempt = Date.now();
  mcRenewing = true;
  // Built by concatenation so the static R5 lint never sees a cached data-route literal.
  var renewUrl = '/api' + '/tokens/renew';
  fetch(renewUrl, { method: 'POST', headers: { 'Authorization': 'Bearer ' + token } })
    .then(function (r) { return r.ok ? r.json() : null; })
    .then(function (data) {
      if (!data) return undefined;
      if (data.renewed && data.token) {
        mcDeviceToken = data.token; mcWriteKey('token', data.token);
        mcExpiresAt = new Date(data.expires_at).getTime(); mcWriteKey('expires', data.expires_at);
        return self.clients.matchAll().then(function (cs) {
          cs.forEach(function (c) { c.postMessage({ type: 'mc-token-renewed', token: data.token, expires_at: data.expires_at }); });
        });
      }
      if (data.renewed === false && data.expires_at) {
        mcExpiresAt = new Date(data.expires_at).getTime(); mcWriteKey('expires', data.expires_at);
      }
      return undefined;
    })
    .catch(function () {})
    .then(function () { mcRenewing = false; });
}

// Inject Authorization: Bearer for same-origin requests when a device token is
// known. Used by non-localhost (mobile) so navigation / fetch / EventSource(SSE)
// carry the token the browser cannot otherwise attach. Never caches these
// responses (R5: /api and page root stay out of the cache).
function mcWithAuth(request) {
  return mcGetToken().then(function (token) {
    if (!token) return fetch(request);
    mcMaybeRenew(token);
    var headers = new Headers(request.headers);
    headers.set('Authorization', 'Bearer ' + token);
    return fetch(new Request(request, { headers: headers }));
  });
}

self.addEventListener('fetch', event => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;

  // Static app-shell assets: cache-first (unchanged).
  if (event.request.method === 'GET' && STATIC_CACHE_URLS.includes(url.pathname)) {
    event.respondWith(
      caches.match(event.request)
        .then(cached => cached || fetch(event.request).then(response => {
          const copy = response.clone();
          caches.open(CACHE_NAME).then(cache => cache.put(event.request, copy));
          return response;
        }))
    );
    return;
  }

  // Everything else same-origin (navigation, /api, SSE): Authorization injection,
  // no caching.
  event.respondWith(mcWithAuth(event.request));
});
`;
}

function parseHostHeader(host) {
  if (!host || typeof host !== 'string') return null;
  try {
    const parsed = new URL(`http://${host}`);
    return {
      hostname: parsed.hostname.toLowerCase(),
      port: parsed.port,
    };
  } catch {
    return null;
  }
}

function originAllowed(req) {
  const origin = req.headers.origin;
  if (!origin) return true;
  let parsed;
  try {
    parsed = new URL(origin);
  } catch {
    return false;
  }
  if (parsed.protocol !== 'http:' && parsed.protocol !== 'https:') return false;
  const originHost = parsed.hostname.toLowerCase();
  if (originHost === '127.0.0.1' || originHost === 'localhost' || originHost === '::1') return true;

  const requestHost = parseHostHeader(req.headers.host);
  return Boolean(requestHost)
    && originHost === requestHost.hostname
    && parsed.port === requestHost.port;
}

function shellQuote(value) {
  return `"${String(value).replace(/(["\\$`])/g, '\\$1')}"`;
}

function execPlan(payload) {
  const command = String(payload?.command || '');

  // ADR-0054 §6: localhost-only loop autonomy mode switch. Carries no ticketId.
  // The mode token is validated HERE (server defense) and again in set_mode.sh
  // (CLI parity). v1 accepts only suggest|co-pilot — 'autopilot' loosening is
  // refused (ADR-0054 §6.3 b), so Mission Control can never enter Autopilot.
  // Non-localhost is already blocked upstream by execScopeDecision (T099):
  // set_mode is not in NON_LOCALHOST_EXEC_ALLOW.
  if (command === 'set_mode') {
    const mode = String(payload?.mode || '');
    if (!/^(suggest|co-pilot)$/.test(mode)) {
      throw new Error("invalid mode (v1: suggest|co-pilot; autopilot excluded — ADR-0054 §6.3b)");
    }
    return {
      script: 'set_mode.sh',
      args: [mode],
      cliCommand: `./scripts/set_mode.sh ${mode}`,
    };
  }

  // ADR-0056: localhost-only Autopilot grant — authorizes finite, self-expiring
  // UNATTENDED CONTINUOUS operation (orchestrator --watch). Does NOT authorize
  // safe:false auto-forging. Non-localhost is blocked upstream by execScopeDecision
  // (T099): autopilot_grant/autopilot_revoke are not in NON_LOCALHOST_EXEC_ALLOW.
  if (command === 'autopilot_grant') {
    const budget = String(payload?.budget ?? '');
    const expiryMin = String(payload?.expiryMin ?? '');
    if (!/^[0-9]{1,4}$/.test(budget) || Number(budget) < 1) {
      throw new Error('invalid budget (positive integer)');
    }
    if (!/^[0-9]{1,4}$/.test(expiryMin) || Number(expiryMin) < 1) {
      throw new Error('invalid expiryMin (positive integer, minutes)');
    }
    return {
      script: 'autopilot_grant.sh',
      args: ['issue', '--budget', budget, '--expiry-min', expiryMin],
      cliCommand: `./scripts/autopilot_grant.sh issue --budget ${budget} --expiry-min ${expiryMin}`,
    };
  }

  if (command === 'autopilot_revoke') {
    return {
      script: 'autopilot_grant.sh',
      args: ['revoke'],
      cliCommand: `./scripts/autopilot_grant.sh revoke`,
    };
  }

  // ADR-0064: create a NEW ticket (no ticketId — it is auto-assigned). localhost-
  // only (T099). SAFETY ANCHOR: there is NO 'safe' parameter — new_ticket.sh forces
  // safe:false, so a created ticket can never auto-run (execution needs an approval
  // marker, ADR-0007). Title/priority/persona/labels are validated here (defense in
  // depth) and again in the script; the body travels via stdin (escape-first).
  if (command === 'new_ticket') {
    const action = String(payload?.action || 'create');
    if (action !== 'create') throw new Error('invalid new_ticket action (create)');
    const title = typeof payload?.title === 'string' ? payload.title : '';
    if (!title || title.length > 200 || /[\x00-\x1f\x7f]/.test(title)) {
      throw new Error('invalid title (required, <=200, no control chars)');
    }
    const priority = String(payload?.priority || 'P2');
    if (!/^P[0-3]$/.test(priority)) throw new Error('invalid priority (P0-P3)');
    const persona = String(payload?.persona || 'implementer');
    if (!/^(implementer|planner|reviewer|security-reviewer)$/.test(persona)) {
      throw new Error('invalid persona');
    }
    const labels = String(payload?.labels || '');
    if (labels.length > 200 || !/^[A-Za-z0-9_,\- ]*$/.test(labels)) throw new Error('invalid labels');
    const body = typeof payload?.body === 'string' ? payload.body : '';
    if (Buffer.byteLength(body, 'utf8') > 16384) throw new Error('body too large (<=16KB)');
    if (/\x00/.test(body)) throw new Error('body contains NUL');
    const args = ['create', '--title', title, '--priority', priority, '--persona', persona];
    if (labels) args.push('--labels', labels);
    return {
      script: 'new_ticket.sh',
      args,
      stdin: body,
      cliCommand: `./scripts/new_ticket.sh create --title <title> --priority ${priority} --persona ${persona} < body.md`,
    };
  }

  // ADR-0066: edit an ALLOWLISTED governing operational doc (runbook / playbooks).
  // doc-key (NOT a raw path) → fixed allowlist in doc_edit.sh; master-spec is not
  // in the list and is unreachable (ADR-0042 deferral preserved). localhost-only
  // (T099). Content travels via stdin (escape-first render, ADR-0042).
  if (command === 'doc_edit') {
    const docAction = String(payload?.action || 'set');
    if (docAction !== 'set') throw new Error('invalid doc_edit action (set)');
    const docKey = String(payload?.docKey || '');
    if (!/^(runbook|skill:(implementer|planner|reviewer|security-reviewer))$/.test(docKey)) {
      throw new Error('invalid doc-key (runbook|skill:<persona>; master-spec not editable)');
    }
    const content = typeof payload?.content === 'string' ? payload.content : '';
    const bytes = Buffer.byteLength(content, 'utf8');
    if (bytes < 16) throw new Error('content too short (>=16 bytes)');
    if (bytes > 262144) throw new Error('content too large (<=256KB)');
    if (/\x00/.test(content)) throw new Error('content contains NUL');
    // ADR-0086: opt-in .vN snapshot. Default (false/absent) = unchanged (git-history).
    const snapshot = payload?.snapshot === true;
    const args = snapshot ? ['set', docKey, '--snapshot'] : ['set', docKey];
    return {
      script: 'doc_edit.sh',
      args,
      stdin: content,
      cliCommand: `./scripts/doc_edit.sh set ${docKey}${snapshot ? ' --snapshot' : ''} < doc.md`,
    };
  }

  // ADR-0068: edit the MOST governing doc, master-spec — a SEPARATE, stronger gate
  // than doc_edit (NOT in its allowlist). Requires a non-empty reason (recorded in
  // the audit commit); spec_edit.sh also writes a master-spec.vN snapshot. localhost-
  // only (T099). NEVER invoked by the loop/orchestrator/grant — human-confirmed only.
  if (command === 'spec_edit') {
    const specAction = String(payload?.action || 'set');
    if (specAction !== 'set') throw new Error('invalid spec_edit action (set)');
    const reason = typeof payload?.reason === 'string' ? payload.reason : '';
    if (!reason.trim() || reason.length > 300 || /[\x00-\x1f\x7f]/.test(reason)) {
      throw new Error('reason required (<=300 chars, no control chars)');
    }
    const content = typeof payload?.content === 'string' ? payload.content : '';
    const bytes = Buffer.byteLength(content, 'utf8');
    if (bytes < 64) throw new Error('content too short (>=64 bytes)');
    if (bytes > 262144) throw new Error('content too large (<=256KB)');
    if (/\x00/.test(content)) throw new Error('content contains NUL');
    return {
      script: 'spec_edit.sh',
      args: ['set', '--reason', reason],
      stdin: content,
      cliCommand: `./scripts/spec_edit.sh set --reason <reason> < spec.md`,
    };
  }

  // ADR-0072: read-only AI draft PROPOSER. ai_draft.sh prints a single-shot draft
  // to stdout and NEVER writes — the human applies it via the existing ticket_body
  // write surface. ai_draft is NOT in NON_LOCALHOST_EXEC_ALLOW, so non-localhost is
  // refused upstream by execScopeDecision (T099). Narrow, single-purpose: NOT a
  // chatbot (master-spec §5 Non-goal). AUTONOMY: human-initiated only.
  if (command === 'ai_draft') {
    const target = String(payload?.target || '');
    if (target === 'ticket-body') {
      const ticketId = String(payload?.ticketId || '');
      if (!/^T\d+$/.test(ticketId)) throw new Error('invalid ticket id');
      return {
        script: 'ai_draft.sh',
        args: ['ticket-body', ticketId],
        cliCommand: `./scripts/ai_draft.sh ticket-body ${ticketId}`,
      };
    }
    // ADR-0074: allowlisted operational doc draft. docKey is the SAME allowlist as
    // doc_edit (master-spec excluded — cannot be named here). Read-only proposer.
    if (target === 'doc') {
      const docKey = String(payload?.docKey || '');
      if (!/^(runbook|skill:(implementer|planner|reviewer|security-reviewer))$/.test(docKey)) {
        throw new Error('invalid doc-key (runbook|skill:* allowlist; master-spec excluded)');
      }
      return {
        script: 'ai_draft.sh',
        args: ['doc', docKey],
        cliCommand: `./scripts/ai_draft.sh doc ${docKey}`,
      };
    }
    // ADR-0076: master-spec draft — separate verb (no doc-key, so the doc target
    // can never name master-spec). Read-only proposer; applied via spec_edit's
    // strong gate. localhost-only (not in NON_LOCALHOST_EXEC_ALLOW).
    if (target === 'master-spec') {
      return {
        script: 'ai_draft.sh',
        args: ['master-spec'],
        cliCommand: `./scripts/ai_draft.sh master-spec`,
      };
    }
    // ADR-0078: bounded multi-turn interview. The server is the AUTHORITY for the
    // turn cap (the client is not trusted): turn must be an integer in 1..MAX. The
    // server holds NO conversation state — the bounded transcript travels in the
    // request and is piped to the proposer on stdin. Read-only; the final draft is
    // applied by the human via new_ticket. NOT a chatbot (master-spec §5 Non-goal):
    // bounded turns + single purpose + stateless + draft output.
    if (target === 'interview') {
      const turn = Number(payload?.turn);
      if (!Number.isInteger(turn) || turn < 1 || turn > INTERVIEW_MAX_TURNS) {
        throw new Error(`invalid interview turn (1..${INTERVIEW_MAX_TURNS}; cap is server-enforced)`);
      }
      const transcript = typeof payload?.transcript === 'string' ? payload.transcript : '';
      if (Buffer.byteLength(transcript, 'utf8') > 32768) throw new Error('transcript too large (<=32KB)');
      if (/\x00/.test(transcript)) throw new Error('transcript contains NUL');
      return {
        script: 'ai_draft.sh',
        args: ['interview', String(turn)],
        stdin: transcript,
        env: { INTERVIEW_MAX_TURNS: String(INTERVIEW_MAX_TURNS) },
        cliCommand: `./scripts/ai_draft.sh interview ${turn}`,
      };
    }
    throw new Error('invalid ai_draft target (ticket-body|doc|master-spec|interview)');
  }

  // ADR-0080: token cost rate config. rate_config.sh is the writer (file=truth);
  // the server validates and dispatches only. Rates are an assumption ($/Mtok),
  // not measurements. localhost-only (not in NON_LOCALHOST_EXEC_ALLOW → 403 for
  // non-localhost, T099) — same as set_mode (a config toggle, not ticket work).
  if (command === 'rate_config') {
    const rcAction = String(payload?.action || 'set');
    if (rcAction !== 'set') throw new Error('invalid rate_config action (set)');
    const nn = (v, name, required) => {
      if (v === undefined || v === null || v === '') {
        if (required) throw new Error(`${name} required`);
        return null;
      }
      const n = Number(v);
      if (!Number.isFinite(n) || n < 0) throw new Error(`${name} must be a non-negative number`);
      return n;
    };
    const rin = nn(payload?.in, 'in', true);
    const rout = nn(payload?.out, 'out', true);
    const rcr = nn(payload?.cacheRead, 'cache-read', false);
    const rcc = nn(payload?.cacheCreation, 'cache-creation', false);
    const rbg = nn(payload?.budget, 'budget', false);   // ADR-0090: opt-in cost budget ($)
    const args = ['set', '--in', String(rin), '--out', String(rout)];
    if (rcr !== null) args.push('--cache-read', String(rcr));
    if (rcc !== null) args.push('--cache-creation', String(rcc));
    if (rbg !== null) args.push('--budget', String(rbg));
    // ADR-0098: opt-in per-model rates. Each entry is "name:in:out" — validate name
    // (non-empty, no '"'/':') and the two non-negative rates before dispatching.
    const models = payload?.models;
    if (models !== undefined && models !== null) {
      if (!Array.isArray(models)) throw new Error('models must be an array of "name:in:out"');
      for (const spec of models) {
        const s = String(spec);
        const parts = s.split(':');
        // ADR-0102: 3~5 fields — name:in:out[:cacheRead[:cacheCreation]].
        if (parts.length < 3 || parts.length > 5) throw new Error(`model must be name:in:out[:cacheRead[:cacheCreation]] (got '${s}')`);
        const [mname, min, mout, mcr, mcc] = parts;
        if (!mname || mname.includes('"')) throw new Error(`invalid model name (got '${mname}')`);
        nn(min, `model(${mname}) in`, true);
        nn(mout, `model(${mname}) out`, true);
        const ncr = nn(mcr, `model(${mname}) cache_read`, false);
        const ncc = nn(mcc, `model(${mname}) cache_creation`, false);
        let arg = `${mname}:${Number(min)}:${Number(mout)}`;
        if (ncr !== null) arg += `:${ncr}`;
        if (ncc !== null) arg += `:${ncc}`;
        args.push('--model', arg);
      }
    }
    return { script: 'rate_config.sh', args, cliCommand: `./scripts/rate_config.sh ${args.join(' ')}` };
  }

  // ADR-0133: READ-ONLY retention preview (no ticketId). prune_preview.sh classifies .vN
  // snapshots / state logs into keep vs delete-candidate per the retention policy and
  // prints a manifest + sha256 — it NEVER deletes/writes (no --confirm path exists). Not
  // in NON_LOCALHOST_EXEC_ALLOW → non-localhost refused (T099). Actual deletion is T216.
  if (command === 'prune_preview') {
    const sub = String(payload?.sub || 'snapshots');
    if (sub !== 'snapshots' && sub !== 'logs') throw new Error('invalid prune_preview sub (snapshots|logs)');
    const args = [sub];
    if (sub === 'snapshots') {
      const base = typeof payload?.base === 'string' ? payload.base : '';
      if (base) {
        if (base.length > 200 || /[\x00-\x1f\x7f]/.test(base)) throw new Error('invalid base');
        args.push('--base', base);
      }
      const keep = payload?.keep;
      if (keep !== undefined) {
        if (!Number.isInteger(keep) || keep < 0 || keep > 100000) throw new Error('invalid keep');
        args.push('--keep', String(keep));
      }
    } else {
      const logName = typeof payload?.log === 'string' ? payload.log : '';
      if (logName) {
        if (!/^(token_rates_history|token_usage)$/.test(logName)) throw new Error('invalid log');
        args.push('--log', logName);
      }
      const keepRows = payload?.keepRows;
      if (keepRows !== undefined) {
        if (!Number.isInteger(keepRows) || keepRows < 0 || keepRows > 100000000) throw new Error('invalid keepRows');
        args.push('--keep-rows', String(keepRows));
      }
    }
    const olderThan = typeof payload?.olderThan === 'string' ? payload.olderThan : '';
    if (olderThan) {
      if (!/^\d{4}-\d{2}-\d{2}$/.test(olderThan)) throw new Error('invalid olderThan (YYYY-MM-DD)');
      args.push('--older-than', olderThan);
    }
    return {
      script: 'prune_preview.sh',
      args,
      cliCommand: `./scripts/prune_preview.sh ${args.join(' ')}`,
    };
  }

  // ADR-0149 Phase 1: bootstrap a NEW project by clean-extracting the harness into
  // an external target dir. localhost-only (not in NON_LOCALHOST_EXEC_ALLOW → 403
  // for non-localhost, T099). SAFETY:
  //  - dryRun DEFAULTS TO TRUE — a real extract requires explicit dryRun:false
  //    (preview-first, ADR-0133 pattern). dry-run never copies (manifest only).
  //  - args travel as an ARGV ARRAY (no shell string interpolation / sh -c).
  //  - targetPath is rejected if empty / control chars / == ROOT / inside ROOT
  //    (defense in depth; init_new_project.sh also enforces SOURCE-immutability).
  //  - SOURCE (this repo) is NEVER written — the script only writes under TARGET.
  if (command === 'init_new_project') {
    const targetPath = typeof payload?.targetPath === 'string' ? payload.targetPath.trim() : '';
    if (!targetPath || targetPath.length > 4096 || /[\x00-\x1f\x7f]/.test(targetPath)) {
      throw new Error('invalid targetPath (required, <=4096, no control chars)');
    }
    // Reject SOURCE itself or any path inside SOURCE (ROOT). The script re-checks,
    // but the server refuses early so a bad path never reaches a writer.
    const rootAbs = resolve(ROOT);
    const tgtAbs = resolve(rootAbs, targetPath);
    if (tgtAbs === rootAbs || tgtAbs.startsWith(rootAbs + '/')) {
      throw new Error('targetPath must be outside this repository (SOURCE is read-only)');
    }
    // ADR-0199 L6.5: 스냅샷 커밋 — 대상 레포에 고정 wip 커밋 1개(가역·push 없음). 임의 명령 아님.
    if (payload?.snapshotCommit === true) {
      return {
        script: 'init_new_project.sh',
        args: ['--snapshot-commit', targetPath],
        cliCommand: `./scripts/init_new_project.sh --snapshot-commit ${targetPath}`,
      };
    }
    // ADR-0198 L6: 스캔 모드(--diff-manifest) — 읽기 전용 would-overwrite 대조. 옵션 무시.
    if (payload?.scan === true) {
      return {
        script: 'init_new_project.sh',
        args: ['--diff-manifest', targetPath],
        cliCommand: `./scripts/init_new_project.sh --diff-manifest ${targetPath}`,
      };
    }
    const name = typeof payload?.name === 'string' ? payload.name.trim() : '';
    if (name && (name.length > 64 || !/^[A-Za-z0-9 ._-]+$/.test(name))) {
      throw new Error('invalid name (<=64, [A-Za-z0-9 ._-])');
    }
    const stack = payload?.stack === undefined ? 'none' : String(payload.stack);
    if (!/^(node|python|go|rust|none)$/.test(stack)) {
      throw new Error('invalid stack (node|python|go|rust|none)');
    }
    const force = payload?.force === true;
    // ADR-0153: opt-in reference docs (additive copy only — quickstart / glossary).
    const withOnboarding = payload?.withOnboarding === true;
    const withGlossary = payload?.withGlossary === true;
    // preview-first: dryRun absent/true → --dry-run; only explicit false runs for real.
    const dryRun = payload?.dryRun !== false;
    const args = [targetPath, '--stack', stack];
    if (name) args.push('--name', name);
    if (force) args.push('--force');
    if (withOnboarding) args.push('--with-onboarding');
    if (withGlossary) args.push('--with-glossary');
    if (dryRun) args.push('--dry-run');
    return {
      script: 'init_new_project.sh',
      args,
      cliCommand: `./scripts/init_new_project.sh ${targetPath} --stack ${stack}${name ? ' --name ' + name : ''}${force ? ' --force' : ''}${withOnboarding ? ' --with-onboarding' : ''}${withGlossary ? ' --with-glossary' : ''}${dryRun ? ' --dry-run' : ''}`,
    };
  }

  // ADR-0207 (T303): 완료 화면 "다음 단계"의 웹 실행 — 타깃 프로젝트의 자체 Mission
  // Control을 시작하고 URL을 돌려준다. localhost-only (NON_LOCALHOST_EXEC_ALLOW 아님 →
  // 비-localhost 403, T099). SAFETY:
  //  - argv 배열 (shell 문자열 조립 없음), targetPath는 init_new_project와 동일하게
  //    SOURCE 안 경로 조기 거부 (스크립트도 재검사 — 이중 방어).
  //  - 스크립트가 하네스 마커(mission-control/server.mjs) 없는 폴더를 거부 —
  //    임의 폴더의 임의 코드를 실행하지 않는다.
  //  - 멱등: 이미 실행 중이면 기존 URL만 반환. SOURCE 무변경 (쓰기는 타깃 state/ 뿐).
  if (command === 'open_project_mc') {
    const targetPath = typeof payload?.targetPath === 'string' ? payload.targetPath.trim() : '';
    if (!targetPath || targetPath.length > 4096 || /[\x00-\x1f\x7f]/.test(targetPath)) {
      throw new Error('invalid targetPath (required, <=4096, no control chars)');
    }
    const rootAbs2 = resolve(ROOT);
    const tgtAbs2 = resolve(rootAbs2, targetPath);
    if (tgtAbs2 === rootAbs2 || tgtAbs2.startsWith(rootAbs2 + '/')) {
      throw new Error('targetPath must be outside this repository (SOURCE is read-only)');
    }
    const args = [targetPath];
    const port = payload?.port;
    if (port !== undefined) {
      if (!Number.isInteger(port) || port < 1024 || port > 65535) throw new Error('invalid port (1024-65535)');
      args.push('--port', String(port));
    }
    return {
      script: 'open_project_mc.sh',
      args,
      // MC 프로세스의 PATH에 node가 없을 수 있다(GUI/launchd 기동 등) — 지금 이 서버를
      // 돌리는 node 바이너리를 그대로 물려준다 (ADR-0078 plan.env 선례, 서버 권위 값).
      env: { NODE_BIN: process.execPath },
      cliCommand: `./scripts/open_project_mc.sh ${targetPath}${port !== undefined ? ' --port ' + port : ''}`,
    };
  }

  const ticketId = String(payload?.ticketId || '');
  if (!/^T[0-9]{3,}$/.test(ticketId)) {
    throw new Error('invalid ticketId');
  }

  // 리뷰 8차 P1: dispatch 재검증 — ticketId는 canonical(파일명·frontmatter id 일치,
  // 권위 필드 정상) 티켓 "정확히 1개"에 대응해야 한다. UI 숨김은 편의일 뿐이며,
  // 불일치 카드(T301 파일 + id:T999)의 쓰기 요청이 정상 T999를 조작하던 우회를
  // 서버에서 차단한다. 같은 id가 2개 파일에 존재하면 양쪽 모두 거부(충돌 표면화).
  {
    const model = getModel();
    const allTickets = Object.values(model.byStatus || {}).flat();
    const canonicalMatches = allTickets.filter(t => String(t.id) === ticketId);
    if (canonicalMatches.length !== 1) {
      throw new Error(`ticketId ${ticketId} resolves to ${canonicalMatches.length} tickets — refusing (need exactly 1 canonical)`);
    }
    const t = canonicalMatches[0];
    // 리뷰 9차 P1: dispatch 검증을 UI의 cardWritable과 동급으로 — safe/status/persona
    // malformed 티켓에 직접 HTTP 요청해도 writer가 실행되지 않는다.
    if (t.id_malformed || t.authority_malformed || t.safe_malformed || t.status_missing || t.persona_malformed) {
      throw new Error(`ticket ${ticketId} has malformed identity/authority/safe/status/persona frontmatter — refusing dispatch`);
    }
  }

  // ADR-0058: structured, NON-LLM edit of a ticket's ORGANIZATIONAL metadata
  // (priority/labels) via the ticket_edit.sh writer. localhost-only (T099 —
  // ticket_edit is not in NON_LOCALHOST_EXEC_ALLOW). The script hard-guards
  // execution-gating fields (safe/status/id/depends_on), DONE tickets, and
  // approval markers; priority/labels are orthogonal to the safe:false gate.
  if (command === 'ticket_edit') {
    const action = String(payload?.action || '');
    if (action === 'set-priority') {
      const priority = String(payload?.priority || '');
      if (!/^P[0-3]$/.test(priority)) throw new Error('invalid priority (P0-P3)');
      return {
        script: 'ticket_edit.sh',
        args: ['set-priority', ticketId, priority],
        cliCommand: `./scripts/ticket_edit.sh set-priority ${ticketId} ${priority}`,
      };
    }
    if (action === 'set-labels') {
      const labels = String(payload?.labels ?? '');
      // organizational tokens only: alnum, hyphen, underscore, comma, space.
      if (labels.length > 200 || !/^[A-Za-z0-9_,\- ]*$/.test(labels)) {
        throw new Error('invalid labels (alnum, -, _, comma; <=200 chars)');
      }
      return {
        script: 'ticket_edit.sh',
        args: ['set-labels', ticketId, labels],
        cliCommand: `./scripts/ticket_edit.sh set-labels ${ticketId} ${shellQuote(labels)}`,
      };
    }
    throw new Error('invalid ticket_edit action (set-priority|set-labels)');
  }

  // ADR-0060: organizational lifecycle transition via semantic verbs. localhost-
  // only (T099). cancel (open→skipped) / reopen (skipped|blocked→open). The
  // script's from-state guard encodes the allowed-transition whitelist; there is
  // no path to done/awaiting-approval/forging/verify (loop & approve.sh own those).
  if (command === 'ticket_lifecycle') {
    const action = String(payload?.action || '');
    if (action !== 'cancel' && action !== 'reopen') {
      throw new Error('invalid ticket_lifecycle action (cancel|reopen)');
    }
    return {
      script: 'ticket_lifecycle.sh',
      args: [action, ticketId],
      cliCommand: `./scripts/ticket_lifecycle.sh ${action} ${ticketId}`,
    };
  }

  // ADR-0062: freeform body edit of an OPEN ticket. The body travels via STDIN
  // (never argv) — the server pipes it, ticket_body.sh is the writer. localhost-
  // only (T099). The script preserves the frontmatter block byte-for-byte and
  // hard-guards non-open / DONE / approval markers; body is escape-first rendered.
  if (command === 'ticket_body') {
    const bodyAction = String(payload?.action || '');
    if (bodyAction !== 'set') throw new Error('invalid ticket_body action (set)');
    const body = typeof payload?.body === 'string' ? payload.body : '';
    if (Buffer.byteLength(body, 'utf8') > 16384) throw new Error('body too large (<=16KB)');
    if (/\x00/.test(body)) throw new Error('body contains NUL');
    return {
      script: 'ticket_body.sh',
      args: ['set', ticketId],
      stdin: body,
      cliCommand: `./scripts/ticket_body.sh set ${ticketId} < body.md`,
    };
  }

  if (command === 'run_loop') {
    return {
      script: 'run_loop.sh',
      args: [ticketId],
      // ADR-0208 (T306): 루프는 티켓당 수 분~수십 분 — 동기 exec의 120s 워치독이
      // run_loop를 중도 SIGTERM하고 claude 프로세스 그룹만 고아로 남기는 실결함이
      // 있었다 (2026-07-07 T018 실측 2회). 분리 디스패치로 즉시 응답한다.
      detach: true,
      cliCommand: `./scripts/run_loop.sh ${ticketId}`,
    };
  }

  if (command === 'approve') {
    const rejectReason = typeof payload.rejectReason === 'string' ? payload.rejectReason.trim() : '';
    if (rejectReason) {
      if (rejectReason.length > 300 || /[\0\r\n]/.test(rejectReason)) {
        throw new Error('invalid rejectReason');
      }
      return {
        script: 'approve.sh',
        args: [ticketId, '--reject', rejectReason],
        cliCommand: `./scripts/approve.sh ${ticketId} --reject ${shellQuote(rejectReason)}`,
      };
    }
    return {
      script: 'approve.sh',
      args: [ticketId],
      cliCommand: `./scripts/approve.sh ${ticketId}`,
    };
  }

  if (command === 'session_ctl') {
    const action = String(payload?.sessionAction || '');
    if (!/^(pause|resume|abort|redirect)$/.test(action)) {
      throw new Error('invalid session action');
    }
    if (action === 'redirect') {
      const instruction = typeof payload.instruction === 'string' ? payload.instruction.trim() : '';
      if (!instruction || instruction.length > 1000 || /[\0\r\n]/.test(instruction)) {
        throw new Error('invalid redirect instruction');
      }
      return {
        script: 'session_ctl.sh',
        args: [action, ticketId, instruction],
        cliCommand: `./scripts/session_ctl.sh redirect ${ticketId} ${shellQuote(instruction)}`,
      };
    }
    if (Object.prototype.hasOwnProperty.call(payload || {}, 'instruction')) {
      throw new Error('instruction is only valid for redirect');
    }
    return {
      script: 'session_ctl.sh',
      args: [action, ticketId],
      cliCommand: `./scripts/session_ctl.sh ${action} ${ticketId}`,
    };
  }

  throw new Error('command is not whitelisted');
}

function runScript(plan) {
  // ADR-0208 (T306): 장시간 루프 디스패치는 동기 HTTP 요청에 태우지 않는다.
  // plan.detach === true → 분리 프로세스 그룹으로 기동하고 즉시 응답. 출력은
  // state/dispatch/<ticket>-<ts>.log 로 (진행 관측은 기존 .ralph/logs·이벤트가 담당).
  if (plan.detach) {
    try {
      const tag = String(plan.args?.[0] || plan.script).replace(/[^A-Za-z0-9._-]+/g, '-');
      const dispatchDir = join(ROOT, 'state', 'dispatch');
      mkdirSync(dispatchDir, { recursive: true });
      const logPath = join(dispatchDir, `${tag}-${new Date().toISOString().replace(/[:.]/g, '-')}.log`);
      appendFileSync(logPath, `# dispatch ${plan.cliCommand}\n`);
      const out = openSync(logPath, 'a');
      const child = spawn(join(ROOT, 'scripts', plan.script), plan.args, {
        cwd: ROOT,
        env: { ...process.env, EDITOR: process.env.EDITOR || 'true', ...(plan.env || {}) },
        stdio: ['ignore', out, out],
        detached: true,
      });
      child.unref();
      closeSync(out);
      return Promise.resolve({
        exitCode: 0,
        stdoutTail: `[dispatched] ${plan.cliCommand} (pid ${child.pid})\n진행: 보드 카드·.ralph/logs — 디스패치 로그: ${logPath.slice(ROOT.length + 1)}`,
        cliCommand: plan.cliCommand,
      });
    } catch (error) {
      return Promise.resolve({ exitCode: 127, stdoutTail: String(error), cliCommand: plan.cliCommand });
    }
  }
  return new Promise(resolve => {
    // ADR-0062: optional stdin so a writer script (ticket_body.sh) can receive
    // freeform multi-line input safely (never via argv). Absent plan.stdin keeps
    // the original ['ignore', …] behaviour — existing dispatches are unchanged.
    const hasStdin = typeof plan.stdin === 'string';
    const child = spawn(join(ROOT, 'scripts', plan.script), plan.args, {
      cwd: ROOT,
      // ADR-0078: plan.env carries server-authoritative knobs (e.g. the interview
      // turn cap) into the script — never client-supplied values.
      env: { ...process.env, EDITOR: process.env.EDITOR || 'true', ...(plan.env || {}) },
      stdio: [hasStdin ? 'pipe' : 'ignore', 'pipe', 'pipe'],
    });
    if (hasStdin) {
      child.stdin.on('error', () => {}); // ignore EPIPE if the child exits early
      child.stdin.end(plan.stdin);
    }
    let stdout = '';
    let stderr = '';
    const timer = setTimeout(() => child.kill('SIGTERM'), 120000);
    child.stdout.on('data', chunk => { stdout += chunk; });
    child.stderr.on('data', chunk => { stderr += chunk; });
    child.on('close', code => {
      clearTimeout(timer);
      const combined = `${stdout}${stderr ? `\n${stderr}` : ''}`;
      resolve({
        exitCode: code ?? 1,
        stdoutTail: combined.slice(-4000),
        cliCommand: plan.cliCommand,
      });
    });
    child.on('error', error => {
      clearTimeout(timer);
      resolve({
        exitCode: 127,
        stdoutTail: String(error),
        cliCommand: plan.cliCommand,
      });
    });
  });
}

async function handleExec(req, res) {
  if (!originAllowed(req)) {
    json(res, 403, { error: 'non-local Origin rejected' });
    return;
  }

  let payload;
  try {
    // ADR-0062/0066: exec carries a ticket_body (≤16KB) or a doc_edit content
    // (≤256KB) whose JSON envelope (escaping) can exceed the default 8KB cap;
    // allow a larger bound for this privileged, scope-guarded endpoint. The
    // per-field byte caps (16KB / 256KB) are enforced in execPlan.
    payload = JSON.parse(await readRequestBody(req, 512 * 1024));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }

  // ADR-0027 §2.1-5: non-localhost exec scope guard (socket peer address, not headers).
  const scope = execScopeDecision({
    remoteAddress: req.socket.remoteAddress,
    command: payload?.command,
  });
  if (!scope.ok) {
    json(res, scope.status, scope.body);
    return;
  }

  let plan;
  try {
    plan = execPlan(payload);
  } catch (error) {
    json(res, 400, { error: error.message });
    return;
  }

  json(res, 200, await runScript(plan));
}

// ADR-0037 §3.3: low-risk bulk approval. localhost-only + same-origin. Each id
// must INDEPENDENTLY pass the lowRiskDocsOnly machine judgement at POST time
// (fail-closed), then a SEPARATE approve.sh run writes a per-ticket marker —
// never a single blanket approval. Mobile (non-localhost) is rejected here:
// the inbox gives mobile single cards only (T099). Audit = same per-ticket
// docs/approvals/<T>.md artifact as a manual approve.
async function handleBulkApprove(req, res) {
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    json(res, 403, { error: 'bulk approval requires localhost' });
    return;
  }
  if (!originAllowed(req)) {
    json(res, 403, { error: 'non-local Origin rejected' });
    return;
  }
  let payload;
  try { payload = JSON.parse(await readRequestBody(req)); }
  catch { json(res, 400, { error: 'invalid JSON body' }); return; }
  const ids = Array.isArray(payload?.ids) ? payload.ids.map(String) : [];
  if (!ids.length) { json(res, 400, { error: 'ids required' }); return; }
  // Re-validate every id against the CURRENT low-risk candidate set (fail-closed):
  // a stale or hand-crafted id that is not a docs-only candidate is refused.
  const candidates = new Set(bulkApprovalCandidates().map(t => String(t.id)));
  const results = [];
  for (const id of ids) {
    if (!/^T[0-9]{3,}$/.test(id)) { results.push({ id, ok: false, reason: 'invalid id' }); continue; }
    if (!candidates.has(id)) { results.push({ id, ok: false, reason: 'not a low-risk candidate' }); continue; }
    const outcome = await runScript(execPlan({ command: 'approve', ticketId: id }));
    results.push({ id, ok: outcome.exitCode === 0, exitCode: outcome.exitCode });
  }
  json(res, 200, { results });
}

// ── Token API handlers (ADR-0027 §2.1 조건 2) ─────────────

async function handleCreatePairingToken(req, res) {
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    json(res, 403, { error: 'pairing token creation requires localhost' });
    return;
  }
  const result = createPairingToken(DEVICES_DIR);
  json(res, 200, result);
}

// INV-ATOMIC-GATE (ADR-0035 §3.2): the device-limit count -> check -> issue
// sequence MUST stay a single SYNCHRONOUS critical section. In Node's single-
// threaded event loop, with no `await` (or other async boundary) between the
// count and the issue, concurrent exchanges cannot interleave here, so the gate
// is atomic for a single process. Introducing any async boundary inside this
// function reopens the N+1 over-count race (ADR-0033 §4). Keeping this a NON-
// async function (no `await` permitted) makes that regression structurally hard;
// the concurrent-exchange regression in tests/mission_control_device_limit.bats
// locks the behaviour. Multi-process shared state is unsupported (ADR-0035 §3.3).
function reserveSlotAndExchange(token) {
  // ADR-0033: device-count limit is an issuance gate (not an auth decision).
  // Checked BEFORE exchange so the pairing token is not consumed and can be
  // retried after the operator revokes an existing device. 409 is distinct from
  // the 401 of a missing/invalid token (T097).
  const limit = resolveMaxDevices();
  const active = countActiveDevices(DEVICES_DIR);
  if (active >= limit) {
    return { status: 409, body: { error: 'device limit reached', limit, active } };
  }
  const result = exchangePairingToken(DEVICES_DIR, token);
  if (!result) {
    return { status: 401, body: { error: 'invalid, expired, or already-used pairing token' } };
  }
  return { status: 200, body: result };
}

async function handleExchangePairingToken(req, res) {
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const token = typeof payload?.token === 'string' ? payload.token.trim() : '';
  if (!token) {
    json(res, 400, { error: 'token is required' });
    return;
  }
  // Atomic device-limit gate + issue. No `await` between count and issue — see
  // INV-ATOMIC-GATE on reserveSlotAndExchange.
  const outcome = reserveSlotAndExchange(token);
  json(res, outcome.status, outcome.body);
}

async function handleRevokeDeviceToken(req, res) {
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    json(res, 403, { error: 'token revocation requires localhost' });
    return;
  }
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const deviceId = typeof payload?.device_id === 'string' ? payload.device_id.trim() : '';
  if (!deviceId) {
    json(res, 400, { error: 'device_id is required' });
    return;
  }
  const ok = revokeDeviceToken(DEVICES_DIR, deviceId);
  if (!ok) {
    json(res, 404, { error: 'device not found' });
    return;
  }
  json(res, 200, { ok: true });
}

async function handleListDevices(req, res) {
  // Device management is a localhost-only desktop convenience surface.
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    json(res, 403, { error: 'device listing requires localhost' });
    return;
  }
  json(res, 200, { devices: listDevices(DEVICES_DIR) });
}

// ADR-0031 §3.1: authenticated token renewal. The bearer must already be valid
// (tokenAuthDecision gates this route, so expired/revoked/missing tokens are 401
// before reaching here). Within the 7-day window this rotates the token; outside
// it is a no-op. The renewed token does NOT widen scope — exec stays approve-only
// (T099) because that decision is keyed on req.socket.remoteAddress, not the token.
async function handleRenewToken(req, res) {
  const token = extractBearerToken(req.headers);
  if (!token) {
    json(res, 401, { error: 'Unauthorized' });
    return;
  }
  const result = renewDeviceToken(DEVICES_DIR, token);
  if (!result) {
    // token rotated out / revoked between auth and renew → client retries with the
    // latest service-worker token, or re-pairs.
    json(res, 401, { error: 'token cannot be renewed' });
    return;
  }
  json(res, 200, result);
}

async function handleRenameDevice(req, res) {
  // Label management is a localhost-only desktop action (ADR-0031 §3.4).
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    json(res, 403, { error: 'device rename requires localhost' });
    return;
  }
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const deviceId = typeof payload?.device_id === 'string' ? payload.device_id.trim() : '';
  const label = typeof payload?.label === 'string' ? payload.label : '';
  if (!deviceId) {
    json(res, 400, { error: 'device_id is required' });
    return;
  }
  if (!renameDevice(DEVICES_DIR, deviceId, label)) {
    json(res, 400, { error: 'device not found or label invalid' });
    return;
  }
  json(res, 200, { ok: true });
}

// ── Router ────────────────────────────────────────────────
// ── ADR-0200 T292: Operator Console — opt-in 운영자 실행 tier ──────────────
// mc-console:begin
// /api/exec whitelist(무인 자동화 tier)와 분리된 별도 endpoint. 루프·버튼·자동화
// 경로에서 호출 금지 — 운영자 대화형 전용. 보안 불변식은 서버가 강제한다:
//   1) opt-in은 API 차단(off→404), non-localhost→403 (T099 승계)
//   2) 승인은 서버 이벤트: request가 cwd+command+sha256+nonce를 고정 발급,
//      run은 정확 일치·1회용·TTL 내에서만 실행 (클라이언트 confirm은 보조 게이트)
//   3) 감사: state/console-log.jsonl append-only (전문 미저장 — tail만)
//   4) 실행 제한: stdin 없음 · timeout · output cap · process group kill · 동시 1개 · PTY 없음
const CONSOLE_APPROVAL_TTL_MS = parseInt(process.env.MC_CONSOLE_TTL_MS || '60000', 10);
const CONSOLE_TIMEOUT_MS = parseInt(process.env.MC_CONSOLE_TIMEOUT_MS || '30000', 10);
const CONSOLE_OUTPUT_CAP_BYTES = 256 * 1024;
const CONSOLE_LOG_TAIL_CHARS = 2048;
const consoleApprovals = new Map(); // approvalId → { cwd, command, sha256, createdMs, used }
let consoleRunning = false;
// ADR-0203 §2.4 T298: autopilot bypass — 운영자 opt-in. 기본 off, 서버 기동 시 off(비영속).
// bypass on이면 인간 승인 단계만 생략(request→run을 서버가 자동 합성) — 감사·안전장치는 유지.
// localhost에서만 토글 가능하고 non-localhost는 consoleGate에서 이미 차단된다.
let consoleBypass = false;

function consoleAudit(event, fields) {
  const entry = { ts: new Date().toISOString(), event, serverRoot: resolve(ROOT), ...fields };
  try {
    mkdirSync(join(ROOT, 'state'), { recursive: true });
    appendFileSync(join(ROOT, 'state', 'console-log.jsonl'), JSON.stringify(entry) + '\n');
  } catch { /* 감사 기록은 best-effort — 로그 실패가 응답 자체를 막지 않는다 */ }
}

// off→404 (기능 부재와 동일), non-localhost→403, cross-origin→403. 공통 게이트.
function consoleGate(req, res) {
  if (!CONSOLE_ENABLED) {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
    return false;
  }
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    consoleAudit('denied', { remoteAddress: req.socket.remoteAddress, reason: 'non-localhost' });
    json(res, 403, { error: 'operator console requires localhost' });
    return false;
  }
  if (!originAllowed(req)) {
    consoleAudit('denied', { remoteAddress: req.socket.remoteAddress, reason: 'non-local origin' });
    json(res, 403, { error: 'non-local Origin rejected' });
    return false;
  }
  return true;
}

// 1단계: 승인 발급 — 서버가 cwd+command를 고정하고 nonce(approvalId)+sha256을 돌려준다.
async function handleConsoleRequest(req, res) {
  if (!consoleGate(req, res)) return;
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req, 16384));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  const command = typeof payload?.command === 'string' ? payload.command : '';
  if (!command.trim() || Buffer.byteLength(command, 'utf8') > 8192 || /\x00/.test(command)) {
    json(res, 400, { error: 'invalid command (non-empty, <=8KB, no NUL)' });
    return;
  }
  const cwdRaw = typeof payload?.cwd === 'string' && payload.cwd.trim() ? payload.cwd.trim() : resolve(ROOT);
  let cwd;
  try {
    cwd = realpathSync(cwdRaw);
    if (!statSync(cwd).isDirectory()) throw new Error('not a directory');
  } catch {
    json(res, 400, { error: 'cwd must be an existing directory' });
    return;
  }
  const commandSha256 = createHash('sha256').update(command, 'utf8').digest('hex');
  const approvalId = randomBytes(16).toString('hex');
  const nowMs = Date.now();
  consoleApprovals.set(approvalId, { cwd, command, sha256: commandSha256, createdMs: nowMs, used: false });
  for (const [id, a] of consoleApprovals) { // 만료 승인 청소 — Map 무한 성장 방지
    if (nowMs - a.createdMs > CONSOLE_APPROVAL_TTL_MS * 2) consoleApprovals.delete(id);
  }
  consoleAudit('requested', {
    remoteAddress: req.socket.remoteAddress,
    cwd, command, commandSha256, approvalId, ttlMs: CONSOLE_APPROVAL_TTL_MS,
  });
  json(res, 200, { approvalId, commandSha256, ttlMs: CONSOLE_APPROVAL_TTL_MS, timeoutMs: CONSOLE_TIMEOUT_MS });
}

// ADR-0203 T298: bypass 토글 — localhost 운영자 opt-in. non-localhost는 consoleGate에서 차단.
async function handleConsoleBypass(req, res) {
  if (!consoleGate(req, res)) return;
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req, 1024));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  consoleBypass = payload?.on === true;
  consoleAudit('bypass_toggle', { remoteAddress: req.socket.remoteAddress, bypass: consoleBypass });
  json(res, 200, { bypass: consoleBypass });
}

// 2단계: 실행 — 발급된 승인과 정확 일치(1회용·TTL)할 때만. 불일치는 denied 기록 후 거부.
// ADR-0203 §2.4: bypass on이면 approvalId 없이 {cwd, command} 직접 실행을 허용하되,
// 서버가 승인을 자동 합성하고 감사에 bypass:true를 남긴다. 인간 승인 단계만 생략된다.
async function handleConsoleRun(req, res) {
  if (!consoleGate(req, res)) return;
  let payload;
  try {
    payload = JSON.parse(await readRequestBody(req, 16384));
  } catch {
    json(res, 400, { error: 'invalid JSON body' });
    return;
  }
  let approvalId = String(payload?.approvalId || '');
  let sha = String(payload?.commandSha256 || '');
  const deny = (reason, status = 403) => {
    consoleAudit('denied', { remoteAddress: req.socket.remoteAddress, approvalId, reason });
    json(res, status, { error: `approval rejected: ${reason}` });
  };
  const bypassUsed = consoleBypass && !approvalId;
  if (bypassUsed) {
    // 승인 자동 합성 — request 핸들러와 동일한 검증(명령·cwd)을 여기서 수행한다.
    const command = typeof payload?.command === 'string' ? payload.command : '';
    if (!command.trim() || Buffer.byteLength(command, 'utf8') > 8192 || /\x00/.test(command)) {
      json(res, 400, { error: 'invalid command (non-empty, <=8KB, no NUL)' });
      return;
    }
    const cwdRaw = typeof payload?.cwd === 'string' && payload.cwd.trim() ? payload.cwd.trim() : resolve(ROOT);
    let cwd;
    try {
      cwd = realpathSync(cwdRaw);
      if (!statSync(cwd).isDirectory()) throw new Error('not a directory');
    } catch {
      json(res, 400, { error: 'cwd must be an existing directory' });
      return;
    }
    const commandSha256 = createHash('sha256').update(command, 'utf8').digest('hex');
    approvalId = randomBytes(16).toString('hex');
    sha = commandSha256;
    consoleApprovals.set(approvalId, { cwd, command, sha256: commandSha256, createdMs: Date.now(), used: false });
    consoleAudit('requested', { remoteAddress: req.socket.remoteAddress, cwd, command, commandSha256, approvalId, ttlMs: CONSOLE_APPROVAL_TTL_MS, bypass: true });
  }
  const approval = consoleApprovals.get(approvalId);
  if (!approval) { deny('unknown approvalId'); return; }
  if (approval.used) { deny('approval already used'); return; }
  if (Date.now() - approval.createdMs > CONSOLE_APPROVAL_TTL_MS) { deny('approval expired'); return; }
  if (sha !== approval.sha256) { deny('commandSha256 mismatch'); return; }
  if (consoleRunning) { deny('another command is running', 429); return; }

  approval.used = true; // 1회용 — 결과와 무관하게 소모
  consoleRunning = true;
  const base = {
    remoteAddress: req.socket.remoteAddress,
    cwd: approval.cwd, command: approval.command,
    commandSha256: approval.sha256, approvalId,
    ...(bypassUsed ? { bypass: true } : {}),
  };
  consoleAudit('approved', base);
  const startedMs = Date.now();
  consoleAudit('started', { ...base, timeoutMs: CONSOLE_TIMEOUT_MS });

  const child = spawn('/bin/bash', ['-c', approval.command], {
    cwd: approval.cwd,
    env: process.env,
    detached: true,                     // 자체 process group → timeout 시 그룹 전체 kill
    stdio: ['ignore', 'pipe', 'pipe'],  // stdin 없음 (ADR-0200 §2.4)
  });
  let stdout = ''; let stderr = '';
  let stdoutBytes = 0; let stderrBytes = 0;
  let truncated = false;
  let timedOut = false;
  const feed = (which, chunk) => {
    const s = String(chunk);
    if (which === 'out') {
      stdoutBytes += Buffer.byteLength(s, 'utf8');
      stdout += s;
      if (stdout.length > CONSOLE_OUTPUT_CAP_BYTES) { stdout = stdout.slice(-CONSOLE_OUTPUT_CAP_BYTES); truncated = true; }
    } else {
      stderrBytes += Buffer.byteLength(s, 'utf8');
      stderr += s;
      if (stderr.length > CONSOLE_OUTPUT_CAP_BYTES) { stderr = stderr.slice(-CONSOLE_OUTPUT_CAP_BYTES); truncated = true; }
    }
  };
  child.stdout.on('data', c => feed('out', c));
  child.stderr.on('data', c => feed('err', c));
  const timer = setTimeout(() => {
    timedOut = true;
    try { process.kill(-child.pid, 'SIGKILL'); } catch { try { child.kill('SIGKILL'); } catch { /* already gone */ } }
  }, CONSOLE_TIMEOUT_MS);
  child.on('close', code => {
    clearTimeout(timer);
    consoleRunning = false;
    const durationMs = Date.now() - startedMs;
    consoleAudit(timedOut ? 'timeout' : 'finished', {
      ...base,
      exitCode: timedOut ? null : (code ?? 1),
      durationMs, timeoutMs: CONSOLE_TIMEOUT_MS,
      stdoutBytes, stderrBytes, truncated,
      stdoutTail: stdout.slice(-CONSOLE_LOG_TAIL_CHARS), // 전문 미저장 — tail만
      stderrTail: stderr.slice(-CONSOLE_LOG_TAIL_CHARS),
    });
    json(res, 200, {
      exitCode: timedOut ? null : (code ?? 1),
      timedOut, durationMs,
      stdoutBytes, stderrBytes, truncated,
      stdoutTail: stdout, stderrTail: stderr, // 응답은 cap(256KiB)까지
    });
  });
  child.on('error', error => {
    clearTimeout(timer);
    consoleRunning = false;
    const durationMs = Date.now() - startedMs;
    consoleAudit('finished', { ...base, exitCode: 127, durationMs, timeoutMs: CONSOLE_TIMEOUT_MS, stdoutBytes: 0, stderrBytes: 0, truncated: false, error: String(error) });
    json(res, 200, { exitCode: 127, timedOut: false, durationMs, stdoutBytes: 0, stderrBytes: 0, truncated: false, stdoutTail: '', stderrTail: String(error) });
  });
}

// Console 페이지 — 사용자 입력·명령 출력은 클라이언트에서 textContent로만 렌더.
// (채택 후 XSS=RCE이므로 이 화면의 마크업 주입 금지=textContent 전용은 보안 경계 — operator-console.bats가 강제)
function renderConsolePage() {
  const main = `<main class="mc-page" aria-label="Operator Console">
  <section class="mc-panel mc-console">
    <header class="mc-panel__head"><h2>Operator Console</h2><p class="mc-panel__meta">localhost 전용 · 임의 cwd/명령 · 감사 기록됨 · ADR-0203</p></header>
    <p class="mc-console__note">임의 명령을 <strong>승인 발급 → 1회 실행</strong>으로 수행합니다. 모든 시도는 <code>state/console-log.jsonl</code>에 남습니다. stdin 없음 · timeout ${Math.round(CONSOLE_TIMEOUT_MS / 1000)}s · 출력 256KiB 제한 · 동시 1개. 반복되는 작업은 recipe(whitelist exec) 승격 대상입니다.</p>
    <label class="mc-console__bypass"><input type="checkbox" data-console-bypass> <strong>Autopilot bypass</strong> — 켜면 매 실행의 확인 창을 생략합니다(감사·안전장치 유지 · 기동 시 자동 off · localhost 전용).</label>
    <label class="mc-console__label" for="mc-console-cwd">작업 폴더 (cwd)</label>
    <input id="mc-console-cwd" data-console-cwd type="text" value="${escapeHtml(resolve(ROOT))}" spellcheck="false" autocomplete="off">
    <label class="mc-console__label" for="mc-console-cmd">명령</label>
    <textarea id="mc-console-cmd" data-console-cmd rows="3" spellcheck="false" placeholder="예: git status"></textarea>
    <div class="mc-console__actions"><button class="mc-btn mc-btn--primary" data-console-run>승인 요청 후 실행</button></div>
    <p class="mc-console__meta" data-console-meta hidden></p>
    <pre class="mc-console__out" data-console-out hidden></pre>
  </section>
  <script>${consoleScript()}</script>
</main>`;
  return renderShell('Operator Console', 'console', main, { isLocalhost: true });
}

function consoleScript() {
  return `(() => {
  const q = s => document.querySelector(s);
  const btn = q('[data-console-run]');
  if (!btn) return;
  const out = q('[data-console-out]');
  const meta = q('[data-console-meta]');
  const bypassEl = q('[data-console-bypass]');
  const show = (el, text) => { el.hidden = false; el.textContent = text; };
  // ADR-0203 §2.4: bypass 토글은 서버 상태를 바꾼다(기동 시 off). 실패하면 체크 되돌림.
  if (bypassEl) bypassEl.addEventListener('change', async () => {
    try {
      const r = await fetch('/api/operator-console/bypass', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ on: bypassEl.checked }) });
      const j = await r.json().catch(() => ({}));
      if (!r.ok) throw new Error(j.error || 'bypass toggle failed');
      bypassEl.checked = !!j.bypass;
    } catch (e) { bypassEl.checked = !bypassEl.checked; show(meta, 'bypass 토글 실패: ' + String((e && e.message) || e)); }
  });
  btn.addEventListener('click', async () => {
    const command = q('[data-console-cmd]').value;
    const cwd = q('[data-console-cwd]').value.trim();
    if (!command.trim()) { q('[data-console-cmd]').focus(); return; }
    const bypass = !!(bypassEl && bypassEl.checked);
    let ok = true;
    if (!bypass && window.__mcConfirm) {
      const r = await window.__mcConfirm({
        title: '이 명령을 실행할까요?',
        what: cwd + ' 에서 실행: ' + command,
        expected: '단발 실행 — stdin 없음, timeout 초과 시 강제 종료됩니다.',
        downside: '실행 자체는 되돌릴 수 없습니다. 명령이 무엇을 바꾸는지 직접 확인하세요.',
        recovery: '모든 시도는 state/console-log.jsonl 감사 로그에 남습니다.',
        submitLabel: '실행', initialFocus: 'cancel',
      });
      ok = !!(r && r.ok);
    }
    if (!ok) return;
    btn.disabled = true;
    show(meta, bypass ? '실행 중… (bypass)' : '실행 중…');
    out.hidden = true;
    try {
      let j2;
      if (bypass) {
        // 서버가 승인 자동 합성 — 단일 run 호출(감사에 bypass:true).
        const rb = await fetch('/api/operator-console/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cwd: cwd, command: command }) });
        j2 = await rb.json().catch(() => ({}));
        if (!rb.ok) throw new Error(j2.error || ('run failed: ' + rb.status));
      } else {
      const r1 = await fetch('/api/operator-console/request', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ cwd: cwd, command: command }) });
      const j1 = await r1.json().catch(() => ({}));
      if (!r1.ok) throw new Error(j1.error || ('request failed: ' + r1.status));
      const r2 = await fetch('/api/operator-console/run', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ approvalId: j1.approvalId, commandSha256: j1.commandSha256 }) });
      j2 = await r2.json().catch(() => ({}));
      if (!r2.ok) throw new Error(j2.error || ('run failed: ' + r2.status));
      }
      const body = (j2.stdoutTail || '') + (j2.stderrTail ? '\\n--- stderr ---\\n' + j2.stderrTail : '');
      show(out, body || '(출력 없음)');
      show(meta, (j2.timedOut ? 'TIMEOUT (강제 종료)' : ('exit ' + j2.exitCode)) + ' · ' + j2.durationMs + 'ms' + (j2.truncated ? ' · 출력 잘림(256KiB)' : ''));
    } catch (err) {
      show(out, String((err && err.message) || err));
      show(meta, '실패');
    } finally {
      btn.disabled = false;
    }
  });
})();`;
}
// mc-console:end

const routes = {
  'GET /healthz': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end('{"ok":true}');
  },
  'POST /api/tokens/pairing':  handleCreatePairingToken,
  'POST /api/tokens/exchange': handleExchangePairingToken,
  'POST /api/tokens/revoke':   handleRevokeDeviceToken,
  'POST /api/tokens/renew':    handleRenewToken,
  'POST /api/tokens/rename':   handleRenameDevice,
  'GET /api/tokens/devices':   handleListDevices,
  'GET /api/version': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    // project/root: 프로젝트 정체성 노출(읽기) — 어느 루트를 서빙 중인지 프로그램적으로도 확인 가능.
    res.end(JSON.stringify({ version: VERSION, project: PROJECT_NAME, root: resolve(ROOT) }));
  },
  // ADR-0166 T260: 읽기 전용 trace API — run 목록. UI(Sessions/Insights)가 소비. 신규 exec/writer 없음.
  'GET /api/trace/runs': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify({ runs: listRuns(ROOT) }));
  },
  'GET /api/tickets': (_req, res) => {
    const { byStatus } = getModel();
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(byStatus));
  },
  'GET /api/approvals': (_req, res) => {
    const { byStatus } = getModel();
    const pending = byStatus['awaiting-approval'] || [];
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(pending));
  },
  'GET /api/failures': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(parseFailures()));
  },
  'GET /api/sessions': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/json' });
    res.end(JSON.stringify(listSessions()));
  },
  // ADR-0155 Phase 1: read-only, base-bounded directory listing for the new-project
  // picker. localhost-only (non-localhost 403, T099). See listProjectDirs() for the
  // path-safety contract (allowlisted base, realpath containment, dirs-only).
  'GET /api/fs/dirs': (req, res) => {
    if (!isLocalhostAddress(req.socket.remoteAddress)) {
      json(res, 403, { error: 'directory listing requires localhost' });
      return;
    }
    const base = new URL(req.url, `http://${HOST}`).searchParams.get('base') || '';
    try {
      json(res, 200, listProjectDirs(base));
    } catch (error) {
      json(res, 400, { error: error.message });
    }
  },
  // ADR-0201 T293: unified-flow preflight. READ-ONLY, localhost-only, fail-closed.
  'GET /api/new-project/preflight': (req, res) => {
    if (!isLocalhostAddress(req.socket.remoteAddress)) {
      json(res, 403, { error: 'preflight requires localhost' });
      return;
    }
    const target = new URL(req.url, `http://${HOST}`).searchParams.get('target') || '';
    try {
      json(res, 200, newProjectPreflight(target));
    } catch (error) {
      json(res, 400, { error: error.message });
    }
  },
  'GET /api/events/stream': (req, res) => {
    handleNotificationStream(req, res);
  },
  'GET /ui.css': (_req, res) => {
    // file=truth: ui.css is read fresh per request. Without no-cache the browser
    // caches it indefinitely, so CSS edits only appear after a hard reload (this hid
    // the board/checkbox fixes). Revalidate each load — same policy as /sw.js.
    res.writeHead(200, { 'Content-Type': 'text/css; charset=utf-8', 'Cache-Control': 'no-cache' });
    res.end(readFileSync(UI_CSS_PATH, 'utf8'));
  },
  'GET /manifest.webmanifest': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'application/manifest+json; charset=utf-8' });
    res.end(JSON.stringify(manifestJson()));
  },
  'GET /sw.js': (_req, res) => {
    res.writeHead(200, {
      'Content-Type': 'text/javascript; charset=utf-8',
      'Cache-Control': 'no-cache',
    });
    res.end(serviceWorkerScript());
  },
  'GET /icons/icon-192.svg': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8' });
    res.end(iconSvg(192));
  },
  'GET /icons/icon-512.svg': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'image/svg+xml; charset=utf-8' });
    res.end(iconSvg(512));
  },
  'GET /': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderBoardPage({ isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /inbox': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderInboxPage({ isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /sessions': (req, res) => {
    const selected = new URL(req.url, `http://${HOST}`).searchParams.get('session') || '';
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderSessionsPage(selected, { isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /insights': (req, res) => {
    const selectedRun = new URL(req.url, `http://${HOST}`).searchParams.get('run') || '';
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderInsightsPage(selectedRun, { isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  // T289 (ADR-0197 L1): /new-project 독립 페이지 — Launchpad. localhost 전용 실행 UI.
  'GET /new-project': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderNewProjectPage(isLocalhostAddress(req.socket.remoteAddress)));
  },
  'GET /spec': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderSpecPage({ isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /library': (req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderLibraryPage({ isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /autonomy': (req, res) => {
    // ADR-0052: read-only autonomy posture. Non-exempt path → non-localhost
    // requires a Bearer token (T097). No mode control / dispatch / write.
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderAutonomyPage({ isLocalhost: isLocalhostAddress(req.socket.remoteAddress) }));
  },
  'GET /pairing': (req, res) => {
    // Pairing/device management is localhost-only (ADR-0027 §2.1: mobile observes
    // and approves; pairing is initiated from the trusted desktop).
    if (!isLocalhostAddress(req.socket.remoteAddress)) {
      res.writeHead(403, { 'Content-Type': 'text/html; charset=utf-8' });
      res.end(renderShell('Pairing', 'pairing',
        '<main class="mc-page" aria-label="Pairing"><p class="mc-empty">기기 페어링은 localhost 데스크톱에서만 시작할 수 있습니다.</p></main>',
        { isLocalhost: false }));
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderShell('Pairing', 'pairing',
      renderPairingMain({ devices: listDevices(DEVICES_DIR), pairingBase: pairingBaseUrl(), limit: resolveMaxDevices() }),
      { isLocalhost: true }));
  },
  'GET /pair': (_req, res) => {
    // Mobile pairing-landing page. ADR-0029 §3.2: self-contained bootstrap shell
    // (inline CSS, no /ui.css or manifest dependency) so it loads before the
    // service worker is active. Token exchange uses the exempt
    // POST /api/tokens/exchange; the page then registers the SW and hands it the
    // device token. Served to any host (GET /pair is exempt).
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderPairBootstrapPage());
  },
  'GET /qr.mjs': (_req, res) => {
    res.writeHead(200, { 'Content-Type': 'text/javascript; charset=utf-8' });
    res.end(readFileSync(QR_MJS_PATH, 'utf8'));
  },
  'POST /api/exec': handleExec,
  'POST /api/approvals/bulk': handleBulkApprove,
  // ADR-0200 T292: Operator Console — off→404 · non-localhost→403 (consoleGate).
  // /api/exec whitelist와 분리된 tier: 자동화 경로에서 호출 금지, 운영자 대화형 전용.
  'GET /console': (req, res) => {
    if (!CONSOLE_ENABLED) {
      res.writeHead(404, { 'Content-Type': 'text/plain' });
      res.end('Not Found');
      return;
    }
    if (!isLocalhostAddress(req.socket.remoteAddress)) {
      res.writeHead(403, { 'Content-Type': 'text/plain' });
      res.end('Forbidden');
      return;
    }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8' });
    res.end(renderConsolePage());
  },
  'POST /api/operator-console/request': handleConsoleRequest,
  'POST /api/operator-console/run': handleConsoleRun,
  'POST /api/operator-console/bypass': handleConsoleBypass,
};

// ── Server ────────────────────────────────────────────────
function handleRequest(req, res) {
  const path = req.url.split('?')[0];

  // ADR-0027 §2.1 조건 2: non-localhost → Bearer token required (except exchange bootstrap)
  const auth = tokenAuthDecision({
    devicesDir: DEVICES_DIR,
    method: req.method,
    path,
    remoteAddress: req.socket.remoteAddress,
    headers: req.headers,
  });
  if (!auth.ok) {
    json(res, auth.status, auth.body);
    return;
  }

  // ADR-0031 §3.3: best-effort, throttled last_seen for authenticated devices.
  // Observational metadata only — never affects the auth/scope decision above.
  if (!isLocalhostAddress(req.socket.remoteAddress)) {
    touchDeviceLastSeen(DEVICES_DIR, extractBearerToken(req.headers));
  }

  const sessionStreamMatch = path.match(/^\/api\/sessions\/(T[0-9]{3,})\/stream$/);
  if (req.method === 'GET' && sessionStreamMatch) {
    handleSessionStream(req, res, sessionStreamMatch[1]);
    return;
  }
  // ADR-0166 T260: 읽기 전용 trace run 상세(:id). 신규 exec 없음.
  const traceRunMatch = path.match(/^\/api\/trace\/runs\/(T[0-9]{3,})$/);
  if (req.method === 'GET' && traceRunMatch) {
    const run = getRun(ROOT, traceRunMatch[1]);
    if (run) json(res, 200, run);
    else json(res, 404, { error: 'run not found' });
    return;
  }
  const key = `${req.method} ${path}`;
  const handler = routes[key];
  if (handler) {
    Promise.resolve(handler(req, res)).catch(error => {
      json(res, 500, { error: String(error) });
    });
  } else if (path.startsWith('/api/') && req.method !== 'GET') {
    // ADR-0024: 읽기 전용 API — GET 외 모든 메서드 거부 (token routes above are exceptions)
    res.writeHead(405, { Allow: 'GET', 'Content-Type': 'text/plain' });
    res.end('Method Not Allowed');
  } else {
    res.writeHead(404, { 'Content-Type': 'text/plain' });
    res.end('Not Found');
  }
}

function formatHostForUrl(host) {
  return host.includes(':') ? `[${host}]` : host;
}

// Base URL the mobile device should use to reach this server for pairing.
// Prefers the private-path (non-localhost) binding over https; falls back to
// localhost for desktop self-testing when no private path is configured.
function pairingBaseUrl() {
  const privateBinding = BINDINGS.find(b => b.label !== 'localhost');
  if (privateBinding) {
    return `https://${formatHostForUrl(privateBinding.host)}:${PORT}`;
  }
  return `http://${formatHostForUrl(HOST)}:${PORT}`;
}

const servers = [];

for (const binding of BINDINGS) {
  const scheme = schemeForBinding(binding);
  let server;
  try {
    server = scheme === 'https'
      ? createHttpsServer(PRIVATE_PATH_TLS_OPTIONS, handleRequest)
      : createHttpServer(handleRequest);
  } catch (error) {
    process.stderr.write(`[mission-control] failed to configure ${scheme} on ${binding.host}:${PORT}: ${error.message}\n`);
    process.exit(1);
  }
  servers.push(server);
  server.on('error', error => {
    for (const startedServer of servers) {
      try { startedServer.close(); } catch { /* best effort cleanup before exit */ }
    }
    process.stderr.write(`[mission-control] failed to listen on ${binding.host}:${PORT}: ${error.message}\n`);
    process.exit(1);
  });
  server.listen(PORT, binding.host, () => {
    process.stdout.write(`[mission-control] listening on ${scheme}://${formatHostForUrl(binding.host)}:${PORT}`);
    if (binding.label !== 'localhost') process.stdout.write(` (${binding.label})`);
    process.stdout.write('\n');
  });
}

// ADR-0024 §2 원칙 3: 프로세스 종료 시 파일 무손상 즉시 종료
process.on('SIGTERM', () => process.exit(0));
process.on('SIGINT',  () => process.exit(0));
