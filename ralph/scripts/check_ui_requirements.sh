#!/usr/bin/env bash
# check_ui_requirements.sh — Mission Control R1~R5 static/runtime UI checks.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HTML_FILES=()
CSS_FILES=()
MANIFEST_FILES=()
SW_FILES=()
UI_JS_FILES=()
TEMP_DIR=""
SERVER_PID=""
DEFAULT_MODE=0

usage() {
  cat <<'EOF'
usage: ralph/scripts/check_ui_requirements.sh [--html FILE ...] [--css FILE ...] [--manifest FILE ...] [--sw FILE ...] [--ui-js FILE ...]

Without --html/--css, starts ralph/mission-control/server.mjs on localhost and checks
rendered /, /inbox, /sessions, /ui.css, /manifest.webmanifest, /sw.js,
ralph/mission-control/ui.mjs, plus docs/assets/*.html.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --html)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      HTML_FILES+=("$2")
      shift 2
      ;;
    --css)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      CSS_FILES+=("$2")
      shift 2
      ;;
    --manifest)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      MANIFEST_FILES+=("$2")
      shift 2
      ;;
    --sw)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      SW_FILES+=("$2")
      shift 2
      ;;
    --ui-js)
      [ "$#" -ge 2 ] || { usage >&2; exit 2; }
      UI_JS_FILES+=("$2")
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

cleanup() {
  if [ -n "$SERVER_PID" ]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  if [ -n "$TEMP_DIR" ]; then
    rm -rf "$TEMP_DIR"
  fi
}
trap cleanup EXIT

fetch_url() {
  local url="$1"
  local out="$2"
  node - "$url" "$out" <<'NODE'
const [url, out] = process.argv.slice(2);
const fs = require('fs');
fetch(url)
  .then(async response => {
    if (!response.ok) {
      console.error(`${url} returned HTTP ${response.status}`);
      process.exit(1);
    }
    fs.writeFileSync(out, await response.text());
  })
  .catch(error => {
    console.error(String(error));
    process.exit(1);
  });
NODE
}

if [ "${#HTML_FILES[@]}" -eq 0 ] && [ "${#CSS_FILES[@]}" -eq 0 ] && [ "${#MANIFEST_FILES[@]}" -eq 0 ] && [ "${#SW_FILES[@]}" -eq 0 ] && [ "${#UI_JS_FILES[@]}" -eq 0 ]; then
  DEFAULT_MODE=1
  TEMP_DIR="$(mktemp -d)"
  PORT="${MC_PORT:-$((7900 + ($$ % 80)))}"
  node "$ROOT/ralph/mission-control/server.mjs" --root "${MC_ROOT:-$ROOT}" --port "$PORT" >"$TEMP_DIR/server.log" 2>&1 &
  SERVER_PID=$!
  sleep 0.6
  fetch_url "http://127.0.0.1:$PORT/" "$TEMP_DIR/board.html"
  fetch_url "http://127.0.0.1:$PORT/inbox" "$TEMP_DIR/inbox.html"
  fetch_url "http://127.0.0.1:$PORT/sessions" "$TEMP_DIR/sessions.html"
  fetch_url "http://127.0.0.1:$PORT/ui.css" "$TEMP_DIR/ui.css"
  fetch_url "http://127.0.0.1:$PORT/manifest.webmanifest" "$TEMP_DIR/manifest.webmanifest"
  fetch_url "http://127.0.0.1:$PORT/sw.js" "$TEMP_DIR/sw.js"
  HTML_FILES+=("$TEMP_DIR/board.html" "$TEMP_DIR/inbox.html" "$TEMP_DIR/sessions.html")
  CSS_FILES+=("$TEMP_DIR/ui.css")
  MANIFEST_FILES+=("$TEMP_DIR/manifest.webmanifest")
  SW_FILES+=("$TEMP_DIR/sw.js")
  UI_JS_FILES+=("$ROOT/ralph/mission-control/ui.mjs")
  if compgen -G "$ROOT/docs/assets/*.html" >/dev/null; then
    for f in "$ROOT"/docs/assets/*.html; do
      HTML_FILES+=("$f")
    done
  fi
fi

NODE_ARGS=()
if [ "${#HTML_FILES[@]}" -gt 0 ]; then NODE_ARGS+=("${HTML_FILES[@]}"); fi
NODE_ARGS+=(--css)
if [ "${#CSS_FILES[@]}" -gt 0 ]; then NODE_ARGS+=("${CSS_FILES[@]}"); fi
NODE_ARGS+=(--manifest)
if [ "${#MANIFEST_FILES[@]}" -gt 0 ]; then NODE_ARGS+=("${MANIFEST_FILES[@]}"); fi
NODE_ARGS+=(--sw)
if [ "${#SW_FILES[@]}" -gt 0 ]; then NODE_ARGS+=("${SW_FILES[@]}"); fi
NODE_ARGS+=(--ui-js)
if [ "${#UI_JS_FILES[@]}" -gt 0 ]; then NODE_ARGS+=("${UI_JS_FILES[@]}"); fi

node - "${NODE_ARGS[@]}" <<'NODE'
const fs = require('fs');

const argv = process.argv.slice(2);
const sections = {
  html: [],
  css: [],
  manifest: [],
  sw: [],
  uiJs: [],
};
let current = 'html';
for (const arg of argv) {
  if (arg === '--css') {
    current = 'css';
  } else if (arg === '--manifest') {
    current = 'manifest';
  } else if (arg === '--sw') {
    current = 'sw';
  } else if (arg === '--ui-js') {
    current = 'uiJs';
  } else {
    sections[current].push(arg);
  }
}
const { html: htmlFiles, css: cssFiles, manifest: manifestFiles, sw: swFiles, uiJs: uiJsFiles } = sections;

function fail(message) {
  console.error(`UI requirement failed: ${message}`);
  process.exit(1);
}

function readAll(files) {
  return files.map(file => {
    try {
      return { file, text: fs.readFileSync(file, 'utf8') };
    } catch (error) {
      fail(`cannot read ${file}: ${error.message}`);
    }
  });
}

const htmlDocs = readAll(htmlFiles);
const cssDocs = readAll(cssFiles);
const manifestDocs = readAll(manifestFiles);
const swDocs = readAll(swFiles);
const uiJsDocs = readAll(uiJsFiles);
const html = htmlDocs.map(d => d.text).join('\n');
const css = cssDocs.map(d => d.text).join('\n') + '\n' + html;
const manifestText = manifestDocs.map(d => d.text).join('\n');
const swText = swDocs.map(d => d.text).join('\n');
const uiJsText = uiJsDocs.map(d => d.text).join('\n');
const r5Enabled = manifestFiles.length > 0 || swFiles.length > 0 || uiJsFiles.length > 0;

if (!htmlDocs.length) fail('no HTML inputs');
if (!cssDocs.length) fail('no CSS inputs');

// R1: mobile single-column behavior and mobile nav rule.
if (!/@media\s*\(\s*max-width\s*:\s*768px\s*\)/i.test(css)) {
  fail('R1 missing @media (max-width: 768px)');
}
if (!/grid-template-columns\s*:\s*1fr\b/i.test(css)) {
  fail('R1 missing single-column grid-template-columns: 1fr');
}
if (!/@media\s*\(\s*max-width\s*:\s*768px\s*\)[\s\S]*\.mc-nav[\s\S]*(overflow-x|position\s*:\s*sticky)/i.test(css)) {
  fail('R1 missing mobile nav transition rule');
}

// R2: no div/span onclick-only controls, and live region exists.
if (/<(?:div|span|section|article)\b[^>]*\bonclick\s*=/i.test(html)) {
  fail('R2 non-semantic onclick control found');
}
if (!/\baria-live\s*=/i.test(html)) {
  fail('R2 missing aria-live region');
}

// R3: command buttons must expose the CLI in title and data-cmd.
const commandButtons = html.match(/<button\b[^>]*\bdata-cmd\s*=\s*"[^"]+"[^>]*>/gi) || [];
for (const button of commandButtons) {
  const cmd = button.match(/\bdata-cmd\s*=\s*"([^"]+)"/i)?.[1];
  const title = button.match(/\btitle\s*=\s*"([^"]+)"/i)?.[1] || '';
  if (!cmd) fail(`R3 command button missing data-cmd: ${button}`);
  if (!title.includes(cmd)) fail(`R3 command button title does not include data-cmd ${cmd}`);
  if (!/^\$\s+/.test(title)) fail(`R3 command button title must start with "$ ": ${title}`);
}

// R4: CSS token contrast for small text pairs must be >= 4.5:1.
const vars = new Map();
for (const match of css.matchAll(/(--[A-Za-z0-9_-]+)\s*:\s*(#[0-9A-Fa-f]{6})\b/g)) {
  vars.set(match[1], match[2]);
}

function rgb(hex) {
  const n = Number.parseInt(hex.slice(1), 16);
  return [(n >> 16) & 255, (n >> 8) & 255, n & 255];
}

function channel(value) {
  const v = value / 255;
  return v <= 0.03928 ? v / 12.92 : Math.pow((v + 0.055) / 1.055, 2.4);
}

function luminance(hex) {
  const [r, g, b] = rgb(hex).map(channel);
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function contrast(fg, bg) {
  const a = luminance(fg);
  const b = luminance(bg);
  const light = Math.max(a, b);
  const dark = Math.min(a, b);
  return (light + 0.05) / (dark + 0.05);
}

const pairs = [
  ['--text', '--bg'],
  ['--dim', '--bg'],
  ['--navy-text', '--bg'],
  ['--text', '--surface'],
  ['--navy-text', '--surface'],
  ['--ember-2', '--surface'],
];

for (const [fgName, bgName] of pairs) {
  const fg = vars.get(fgName);
  const bg = vars.get(bgName);
  if (!fg || !bg) fail(`R4 missing CSS token ${fgName} or ${bgName}`);
  const ratio = contrast(fg, bg);
  if (ratio < 4.5) {
    fail(`R4 contrast ${fgName} on ${bgName} is ${ratio.toFixed(2)}:1`);
  }
}

// R5: PWA integrity. Only enabled for default runtime checks or explicit R5 inputs.
if (r5Enabled) {
  if (!manifestDocs.length) fail('R5 missing manifest input');
  if (!swDocs.length) fail('R5 missing service worker input');
  if (!uiJsDocs.length) fail('R5 missing UI JS input');

  for (const doc of manifestDocs) {
    let manifest;
    try {
      manifest = JSON.parse(doc.text);
    } catch (error) {
      fail(`R5 manifest is not valid JSON (${doc.file}): ${error.message}`);
    }
    if (manifest.display !== 'standalone') fail('R5 manifest display must be standalone');
    if (manifest.theme_color !== '#0E1116') fail('R5 manifest theme_color must be #0E1116');
    const iconSizes = new Set((manifest.icons || []).map(icon => String(icon.sizes || '')));
    if (!iconSizes.has('192x192') || !iconSizes.has('512x512')) {
      fail('R5 manifest must include 192x192 and 512x512 icons');
    }
  }

  if (!/STATIC_CACHE_URLS/.test(swText)) fail('R5 service worker missing STATIC_CACHE_URLS whitelist');
  if (!/\/manifest\.webmanifest/.test(swText) || !/\/ui\.css/.test(swText)) {
    fail('R5 service worker whitelist missing app shell assets');
  }
  const staticList = swText.match(/STATIC_CACHE_URLS\s*=\s*(\[[\s\S]*?\])/);
  if (!staticList) fail('R5 service worker STATIC_CACHE_URLS must be a static array');
  if (/["']\/api\//.test(staticList[1]) || /["']\/["']/.test(staticList[1])) {
    fail('R5 service worker must not cache data routes or page root');
  }
  if (/cache\.(?:add|addAll|put)\([\s\S]*["']\/api\//i.test(swText)) {
    fail('R5 service worker must not cache /api/ responses');
  }

  const offlineText = `${html}\n${uiJsText}`;
  if (!/mc-offline-badge/.test(offlineText) || !/\/healthz/.test(offlineText)) {
    fail('R5 offline snapshot badge and health check are required');
  }
  if (!/data-offline-was-enabled/.test(offlineText) || !/aria-disabled/.test(offlineText) || !/서버 연결 필요/.test(offlineText)) {
    fail('R5 offline write buttons must be disabled with server connection tooltip');
  }

  const pushSurface = `${html}\n${swText}\n${uiJsText}\n${manifestText}`;
  if (/(fcm\.googleapis\.com|firebase|onesignal|api\.push\.apple\.com|webpush|PushManager|pushManager|addEventListener\(['"]push['"])/i.test(pushSurface)) {
    fail('R5 external push service/API usage is not allowed');
  }
}

console.log(r5Enabled ? 'UI requirements R1-R5 passed' : 'UI requirements R1-R4 passed');
NODE
