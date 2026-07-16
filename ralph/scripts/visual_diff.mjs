#!/usr/bin/env node
// ─────────────────────────────────────────────────────────────────────────────
// T302 (ADR-0206): 목업 ↔ 실화면 시각 회귀 대조 하네스.
//
// 정본 목업(docs/reviews/*.dc.html)과 Mission Control 실화면을 같은 뷰포트로
// 헤드리스 렌더 → 상태별 캡처 → 픽셀 diff 이미지 + 불일치율 리포트를 생성한다.
// bats(DOM 훅·문구 계약)가 못 잡는 "스킨 편차"를 기계적으로 드러내는 게 목적.
//
// 원칙:
//   - zero-dependency: Node 22+ 내장(zlib·WebSocket)만 사용. npm 설치 불필요.
//   - 정본 불변: 목업 파일은 절대 수정하지 않는다. CDN(unpkg) 의존은
//     docs/reviews/vendor/ 의 고정 사본을 CDP Fetch 인터셉트로 주입해 해소.
//   - 읽기 전용: 캡처·비교만 한다. 서버는 자체 기동(임시 포트) 후 종료.
//   - 게이트가 아니라 리포트: 불일치율은 사람이 ADR §3 "의도적 편차" 목록과
//     대조해 판정한다 (--gate N 을 주면 초과 시 exit 1).
//
// 사용:
//   node ralph/scripts/visual_diff.mjs                        # 기본: new-project 3개 상태
//   node ralph/scripts/visual_diff.mjs --gate 5               # 불일치율 5% 초과 시 실패
//   CHROME_BIN=/path/to/chrome node ralph/scripts/visual_diff.mjs
//   node ralph/scripts/visual_diff.mjs --live-url http://127.0.0.1:7474  # 떠있는 서버 사용
//
// 출력: state/visual-diff/<timestamp>/ 아래 {state}-mockup.png / {state}-live.png /
//       {state}-diff.png + report.md
// ─────────────────────────────────────────────────────────────────────────────
import { spawn, execFileSync } from 'node:child_process';
import { readFileSync, writeFileSync, mkdirSync, existsSync } from 'node:fs';
import { join, dirname, resolve } from 'node:path';
import { fileURLToPath, pathToFileURL } from 'node:url';
import zlib from 'node:zlib';

const ROOT = resolve(dirname(fileURLToPath(import.meta.url)), '..', '..');
const VENDOR_DIR = join(ROOT, 'docs', 'reviews', 'vendor');
const VIEWPORT = { width: 1280, height: 1600 };

// CDN 고정 사본 매핑 (정본 목업은 수정하지 않고 요청만 가로챈다)
const VENDOR_MAP = {
  'react@18.3.1/umd/react.production.min.js': 'react.production.min.js',
  'react-dom@18.3.1/umd/react-dom.production.min.js': 'react-dom.production.min.js',
  '@babel/standalone@7.29.0/babel.min.js': 'babel.min.js',
};

// ── 대조 대상 정의 ───────────────────────────────────────────────────────────
// clip: 셸 유무 차이를 제거하기 위해 콘텐츠 컬럼만 잘라 비교한다.
// React가 style 속성을 정규화(콜론 뒤 공백)하므로 두 표기 모두 매칭
const MOCKUP_CLIP = `document.querySelector('div[style*="max-width: 760px"], div[style*="max-width:760px"]')`;
const LIVE_CLIP = `document.querySelector('.mc-launchpad')`;
// 부팅 완료 판정: 목업(raw 템플릿)에도 같은 placeholder input이 존재하므로
// input 존재만으론 부족 — {{ }} 플레이스홀더가 사라져야 React 부팅 완료로 본다.
const READY = `(() => {
  const i = document.querySelector('input[placeholder*="프로젝트 이름"]');
  return !!i && !document.body.textContent.includes('{{');
})()`;
const TYPE_NAME = `(() => {
  const i = document.querySelector('input[placeholder*="프로젝트 이름"]');
  if (!i) return false;
  const set = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  set.call(i, 'payments-service');
  i.dispatchEvent(new Event('input', { bubbles: true }));
  return true;
})()`;
const OPEN_ADVANCED = `(() => {
  const s = [...document.querySelectorAll('summary')].find(e => e.textContent.includes('고급 설정'));
  if (s) s.click();
  return !!s;
})()`;

// normalize: ADR-0205 §3 "의도적 편차"로 문서화된 요소만 비교 전에 제거한다.
// 여기에 항목을 추가하려면 반드시 해당 ADR의 편차 목록에 먼저 문서화할 것.
const MOCKUP_NORMALIZE = `(() => {
  // §3.1 데모 칩 행(프로토타입 시뮬레이션 전용) — 실화면에 없음
  const demo = [...document.querySelectorAll('div')].find(d =>
    d.children.length && /^데모:/.test(d.textContent.trim()) && d.getBoundingClientRect().height < 80);
  if (demo) demo.remove();
  return true;
})()`;

const TARGETS = [{
  name: 'new-project',
  mockup: pathToFileURL(join(ROOT, 'docs', 'reviews', 'New Project.dc.html')).href,
  livePath: '/new-project',
  mockupNormalize: MOCKUP_NORMALIZE,
  states: [
    { name: 'initial', actions: [] },
    { name: 'typed-missing', actions: [{ eval: TYPE_NAME }, { wait: 1600 }] },
    { name: 'advanced-open', actions: [{ eval: OPEN_ADVANCED }, { wait: 700 }] },
  ],
}];

// ── CLI ──────────────────────────────────────────────────────────────────────
const args = process.argv.slice(2);
const argOf = (k) => { const i = args.indexOf(k); return i !== -1 ? args[i + 1] : null; };
const GATE = argOf('--gate') ? Number(argOf('--gate')) : null;
const LIVE_URL = argOf('--live-url');
const OUT_DIR = argOf('--out')
  || join(ROOT, 'state', 'visual-diff', new Date().toISOString().replace(/[:.]/g, '-').slice(0, 19));

// ── Chrome 탐색·기동 ─────────────────────────────────────────────────────────
function findChrome() {
  if (process.env.CHROME_BIN) return process.env.CHROME_BIN;
  const candidates = [
    '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome',
    '/Applications/Chromium.app/Contents/MacOS/Chromium',
    '/usr/bin/google-chrome', '/usr/bin/chromium', '/usr/bin/chromium-browser',
  ];
  const hit = candidates.find(p => existsSync(p));
  if (!hit) {
    console.error('✗ Chrome을 찾지 못했습니다. CHROME_BIN 환경변수로 경로를 지정하세요.');
    process.exit(2);
  }
  return hit;
}

function launchChrome(bin) {
  return new Promise((resolveWs, reject) => {
    const proc = spawn(bin, [
      '--headless=new', '--remote-debugging-port=0', '--no-first-run', '--no-default-browser-check',
      '--disable-gpu', '--hide-scrollbars', '--force-device-scale-factor=1',
      `--window-size=${VIEWPORT.width},${VIEWPORT.height}`,
      ...(process.env.CHROME_NO_SANDBOX ? ['--no-sandbox'] : []),
      'about:blank',
    ], { stdio: ['ignore', 'pipe', 'pipe'] });
    let buf = '';
    const onData = (d) => {
      buf += String(d);
      const m = buf.match(/DevTools listening on (ws:\/\/\S+)/);
      if (m) resolveWs({ proc, wsUrl: m[1] });
    };
    proc.stderr.on('data', onData);
    proc.stdout.on('data', onData);
    proc.on('exit', (c) => reject(new Error(`chrome exited early (code ${c})\n${buf.slice(0, 500)}`)));
    setTimeout(() => reject(new Error('chrome DevTools 엔드포인트 대기 시간 초과\n' + buf.slice(0, 500))), 15000);
  });
}

// ── 최소 CDP 클라이언트 (Node 22 내장 WebSocket) ─────────────────────────────
class Cdp {
  constructor(ws) { this.ws = ws; this.id = 0; this.pending = new Map(); this.listeners = []; }
  static async connect(url) {
    if (typeof WebSocket === 'undefined') {
      console.error('✗ Node 22+ 가 필요합니다 (내장 WebSocket).'); process.exit(2);
    }
    const ws = new WebSocket(url);
    await new Promise((res, rej) => { ws.onopen = res; ws.onerror = () => rej(new Error('CDP 접속 실패')); });
    const cdp = new Cdp(ws);
    ws.onmessage = (ev) => {
      const msg = JSON.parse(typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString());
      if (msg.id && cdp.pending.has(msg.id)) {
        const { res, rej } = cdp.pending.get(msg.id);
        cdp.pending.delete(msg.id);
        msg.error ? rej(new Error(msg.error.message)) : res(msg.result);
      } else if (msg.method) {
        cdp.listeners.forEach(fn => fn(msg));
      }
    };
    return cdp;
  }
  send(method, params = {}, sessionId = undefined) {
    const id = ++this.id;
    return new Promise((res, rej) => {
      this.pending.set(id, { res, rej });
      this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
    });
  }
  on(fn) { this.listeners.push(fn); }
  close() { try { this.ws.close(); } catch {} }
}

// ── 페이지 헬퍼 ──────────────────────────────────────────────────────────────
async function openPage(cdp, url) {
  const { targetId } = await cdp.send('Target.createTarget', { url: 'about:blank' });
  const { sessionId } = await cdp.send('Target.attachToTarget', { targetId, flatten: true });
  await cdp.send('Page.enable', {}, sessionId);
  await cdp.send('Runtime.enable', {}, sessionId);
  await cdp.send('Emulation.setDeviceMetricsOverride',
    { width: VIEWPORT.width, height: VIEWPORT.height, deviceScaleFactor: 1, mobile: false }, sessionId);
  // unpkg 인터셉트 → vendor 고정 사본 (정본 목업 무수정 원칙)
  await cdp.send('Fetch.enable', { patterns: [{ urlPattern: 'https://unpkg.com/*' }] }, sessionId);
  cdp.on(async (msg) => {
    if (msg.method !== 'Fetch.requestPaused' || msg.sessionId !== sessionId) return;
    const { requestId, request } = msg.params;
    const key = request.url.replace('https://unpkg.com/', '');
    const file = VENDOR_MAP[key] ? join(VENDOR_DIR, VENDOR_MAP[key]) : null;
    try {
      if (file && existsSync(file)) {
        await cdp.send('Fetch.fulfillRequest', {
          requestId, responseCode: 200,
          responseHeaders: [
            { name: 'Content-Type', value: 'application/javascript' },
            // 목업 로더가 crossorigin+SRI로 로드하므로 CORS 허용이 필수
            { name: 'Access-Control-Allow-Origin', value: '*' },
          ],
          body: readFileSync(file).toString('base64'),
        }, sessionId);
      } else {
        await cdp.send('Fetch.failRequest', { requestId, errorReason: 'ConnectionRefused' }, sessionId);
        console.error(`  ⚠ vendor 사본 없음: ${key} (docs/reviews/vendor/ 확인)`);
      }
    } catch {}
  });
  const loaded = new Promise((res) => {
    const fn = (msg) => { if (msg.method === 'Page.loadEventFired' && msg.sessionId === sessionId) res(); };
    cdp.on(fn);
  });
  await cdp.send('Page.navigate', { url }, sessionId);
  await Promise.race([loaded, sleep(10000)]);
  // React/앱 부팅 대기 (양쪽 공통 anchor)
  for (let i = 0; i < 60; i++) {
    if (await evalJson(cdp, sessionId, READY)) break;
    await sleep(250);
  }
  await sleep(800);
  return sessionId;
}

const sleep = (ms) => new Promise(r => setTimeout(r, ms));

async function evalJson(cdp, sessionId, expression) {
  const { result } = await cdp.send('Runtime.evaluate', { expression, returnByValue: true }, sessionId);
  return result ? result.value : undefined;
}

async function shoot(cdp, sessionId, clipSelExpr, path) {
  const rect = await evalJson(cdp, sessionId, `(() => {
    const el = ${clipSelExpr};
    if (!el) return null;
    const r = el.getBoundingClientRect();
    return { x: Math.max(0, r.x + scrollX - 12), y: Math.max(0, r.y + scrollY - 12),
             width: Math.ceil(r.width + 24), height: Math.ceil(r.height + 24) };
  })()`);
  if (!rect) throw new Error('clip 요소를 찾지 못했습니다: ' + clipSelExpr);
  const { data } = await cdp.send('Page.captureScreenshot', {
    format: 'png', captureBeyondViewport: true,
    clip: { ...rect, scale: 1 },
  }, sessionId);
  writeFileSync(path, Buffer.from(data, 'base64'));
  return rect;
}

// ── PNG decode/encode/diff (내장 zlib만 사용) ────────────────────────────────
const CRC_TABLE = (() => {
  const t = new Uint32Array(256);
  for (let n = 0; n < 256; n++) { let c = n; for (let k = 0; k < 8; k++) c = c & 1 ? 0xEDB88320 ^ (c >>> 1) : c >>> 1; t[n] = c >>> 0; }
  return t;
})();
const crc32 = (buf) => { let c = 0xFFFFFFFF; for (const b of buf) c = CRC_TABLE[(c ^ b) & 0xFF] ^ (c >>> 8); return (c ^ 0xFFFFFFFF) >>> 0; };

function pngDecode(buf) {
  if (buf.readUInt32BE(0) !== 0x89504E47) throw new Error('PNG 아님');
  let pos = 8, w = 0, h = 0, colorType = 0, idat = [];
  while (pos < buf.length) {
    const len = buf.readUInt32BE(pos), type = buf.toString('ascii', pos + 4, pos + 8);
    const data = buf.subarray(pos + 8, pos + 8 + len);
    if (type === 'IHDR') {
      w = data.readUInt32BE(0); h = data.readUInt32BE(4);
      if (data[8] !== 8 || data[12] !== 0) throw new Error('지원하지 않는 PNG 형식(8bit non-interlaced만)');
      colorType = data[9];
      if (colorType !== 2 && colorType !== 6) throw new Error('지원하지 않는 colorType: ' + colorType);
    } else if (type === 'IDAT') idat.push(data);
    else if (type === 'IEND') break;
    pos += 12 + len;
  }
  const raw = zlib.inflateSync(Buffer.concat(idat));
  const bpp = colorType === 6 ? 4 : 3, stride = w * bpp;
  const out = new Uint8Array(w * h * 4);
  const prev = new Uint8Array(stride);
  const paeth = (a, b, c) => { const p = a + b - c, pa = Math.abs(p - a), pb = Math.abs(p - b), pc = Math.abs(p - c); return pa <= pb && pa <= pc ? a : pb <= pc ? b : c; };
  for (let y = 0; y < h; y++) {
    const f = raw[y * (stride + 1)];
    const row = raw.subarray(y * (stride + 1) + 1, (y + 1) * (stride + 1));
    for (let i = 0; i < stride; i++) {
      const a = i >= bpp ? row[i - bpp] : 0, b = prev[i], c = i >= bpp ? prev[i - bpp] : 0;
      let v = row[i];
      if (f === 1) v = (v + a) & 0xFF; else if (f === 2) v = (v + b) & 0xFF;
      else if (f === 3) v = (v + ((a + b) >> 1)) & 0xFF; else if (f === 4) v = (v + paeth(a, b, c)) & 0xFF;
      row[i] = v;
    }
    prev.set(row);
    for (let x = 0; x < w; x++) {
      const s = x * bpp, d = (y * w + x) * 4;
      out[d] = row[s]; out[d + 1] = row[s + 1]; out[d + 2] = row[s + 2];
      out[d + 3] = bpp === 4 ? row[s + 3] : 255;
    }
  }
  return { width: w, height: h, data: out };
}

function pngEncode(rgba, w, h) {
  const stride = w * 4, raw = Buffer.alloc((stride + 1) * h);
  for (let y = 0; y < h; y++) { raw[y * (stride + 1)] = 0; Buffer.from(rgba.buffer, rgba.byteOffset + y * stride, stride).copy(raw, y * (stride + 1) + 1); }
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(w, 0); ihdr.writeUInt32BE(h, 4); ihdr[8] = 8; ihdr[9] = 6;
  const chunk = (type, data) => {
    const out = Buffer.alloc(12 + data.length);
    out.writeUInt32BE(data.length, 0); out.write(type, 4, 'ascii'); data.copy(out, 8);
    out.writeUInt32BE(crc32(out.subarray(4, 8 + data.length)), 8 + data.length);
    return out;
  };
  return Buffer.concat([
    Buffer.from([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]),
    chunk('IHDR', ihdr), chunk('IDAT', zlib.deflateSync(raw, { level: 6 })), chunk('IEND', Buffer.alloc(0)),
  ]);
}

function diffImages(a, b, outPath) {
  const W = Math.max(a.width, b.width), H = Math.max(a.height, b.height);
  const out = new Uint8Array(W * H * 4);
  let mismatch = 0;
  const TOL = 24; // 안티앨리어싱 허용 오차 (채널당)
  for (let y = 0; y < H; y++) for (let x = 0; x < W; x++) {
    const d = (y * W + x) * 4;
    const inA = x < a.width && y < a.height, inB = x < b.width && y < b.height;
    const sa = inA ? (y * a.width + x) * 4 : -1, sb = inB ? (y * b.width + x) * 4 : -1;
    if (inA && inB) {
      const dr = Math.abs(a.data[sa] - b.data[sb]), dg = Math.abs(a.data[sa + 1] - b.data[sb + 1]), db = Math.abs(a.data[sa + 2] - b.data[sb + 2]);
      if (dr > TOL || dg > TOL || db > TOL) {
        mismatch++; out[d] = 235; out[d + 1] = 45; out[d + 2] = 70; out[d + 3] = 255;
      } else {
        const g = Math.round((a.data[sa] * 0.299 + a.data[sa + 1] * 0.587 + a.data[sa + 2] * 0.114) * 0.28 + 16);
        out[d] = g; out[d + 1] = g; out[d + 2] = g; out[d + 3] = 255;
      }
    } else { // 한쪽에만 존재(높이/폭 차이) → 마젠타
      mismatch++; out[d] = 200; out[d + 1] = 60; out[d + 2] = 200; out[d + 3] = 255;
    }
  }
  writeFileSync(outPath, pngEncode(out, W, H));
  return { mismatch, total: W * H, pct: (mismatch / (W * H)) * 100 };
}

// ── 라이브 서버 (자체 기동) ──────────────────────────────────────────────────
async function startServer(port) {
  const proc = spawn(process.execPath, [join(ROOT, 'ralph', 'mission-control', 'server.mjs'), '--port', String(port)],
    { cwd: ROOT, env: { ...process.env, MC_CONSOLE: '0' }, stdio: ['ignore', 'pipe', 'pipe'] });
  for (let i = 0; i < 40; i++) {
    try { const r = await fetch(`http://127.0.0.1:${port}/new-project`); if (r.ok) return proc; } catch {}
    await sleep(250);
  }
  proc.kill();
  throw new Error('mission-control 서버 기동 실패 (port ' + port + ')');
}

// ── main ─────────────────────────────────────────────────────────────────────
(async () => {
  mkdirSync(OUT_DIR, { recursive: true });
  const missing = Object.values(VENDOR_MAP).filter(f => !existsSync(join(VENDOR_DIR, f)));
  if (missing.length) console.error('⚠ vendor 사본 누락: ' + missing.join(', ') + ' — 목업 렌더가 실패할 수 있습니다.');

  let server = null;
  const liveBase = LIVE_URL || await (async () => { server = await startServer(7998); return 'http://127.0.0.1:7998'; })();
  const { proc: chrome, wsUrl } = await launchChrome(findChrome());
  const cdp = await Cdp.connect(wsUrl);
  const rows = [];
  let worst = 0;

  try {
    for (const t of TARGETS) {
      const mockSession = await openPage(cdp, t.mockup);
      const liveSession = await openPage(cdp, liveBase + t.livePath);
      if (t.mockupNormalize) await evalJson(cdp, mockSession, t.mockupNormalize);
      if (t.liveNormalize) await evalJson(cdp, liveSession, t.liveNormalize);
      for (const state of t.states) {
        for (const [label, session] of [['mockup', mockSession], ['live', liveSession]]) {
          for (const act of state.actions) {
            if (act.eval) await evalJson(cdp, session, act.eval);
            if (act.wait) await sleep(act.wait);
          }
        }
        const mockPath = join(OUT_DIR, `${t.name}-${state.name}-mockup.png`);
        const livePath = join(OUT_DIR, `${t.name}-${state.name}-live.png`);
        await shoot(cdp, mockSession, MOCKUP_CLIP, mockPath);
        await shoot(cdp, liveSession, LIVE_CLIP, livePath);
        const r = diffImages(pngDecode(readFileSync(mockPath)), pngDecode(readFileSync(livePath)),
          join(OUT_DIR, `${t.name}-${state.name}-diff.png`));
        worst = Math.max(worst, r.pct);
        rows.push({ target: t.name, state: state.name, pct: r.pct, mismatch: r.mismatch });
        console.log(`  ${t.name}/${state.name}: 불일치 ${r.pct.toFixed(2)}% (${r.mismatch}px)`);
      }
    }
  } finally {
    cdp.close(); chrome.kill(); if (server) server.kill();
  }

  const report = [
    '# visual_diff 리포트', '',
    `- 생성: ${new Date().toISOString()}`,
    `- 뷰포트: ${VIEWPORT.width}px · clip: 콘텐츠 컬럼`,
    '- 판정 기준: 불일치 영역이 ADR-0205 §3 "의도적 편차" 목록으로 설명되는지 사람이 diff 이미지로 확인한다.',
    '', '| target | state | 불일치율 | 불일치 px |', '|---|---|---|---|',
    ...rows.map(r => `| ${r.target} | ${r.state} | ${r.pct.toFixed(2)}% | ${r.mismatch} |`),
    '', '빨강 = 양쪽 다 있으나 다른 픽셀 · 마젠타 = 한쪽에만 있는 영역(높이/폭 차이)', '',
  ].join('\n');
  writeFileSync(join(OUT_DIR, 'report.md'), report);
  console.log(`\n리포트: ${join(OUT_DIR, 'report.md')}`);

  if (GATE !== null && worst > GATE) {
    console.error(`✗ GATE 초과: 최대 불일치 ${worst.toFixed(2)}% > ${GATE}%`);
    process.exit(1);
  }
})().catch(e => { console.error('✗ visual_diff 실패:', e.message); process.exit(1); });
