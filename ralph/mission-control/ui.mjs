// ralph/mission-control/ui.mjs — render helpers with CLI tooltip contract.

import { fleetPosture } from './device-posture.mjs'; // ADR-0188 T282: device fleet posture(읽기)

export function escapeHtml(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

export function renderWriteButton(options = {}) {
  const {
    label,
    ariaLabel = '',
    cliCommand,
    execCommand,
    ticketId,
    reject = false,
    className = '',
    data = {},
  } = options;

  if (!cliCommand) {
    throw new Error('renderWriteButton requires cliCommand');
  }
  if (!execCommand) {
    throw new Error('renderWriteButton requires execCommand');
  }
  if (!ticketId) {
    throw new Error('renderWriteButton requires ticketId');
  }

  const tooltip = `$ ${cliCommand}`;
  const rejectAttr = reject ? ' data-reject="true"' : '';
  const ariaLabelAttr = ariaLabel ? ` aria-label="${escapeHtml(ariaLabel)}"` : '';
  const dataAttrs = Object.entries(data).map(([key, value]) => {
    if (!/^[a-z][a-z0-9-]*$/.test(key)) {
      throw new Error(`renderWriteButton invalid data attribute: ${key}`);
    }
    if (value === undefined || value === null || value === false) return '';
    return ` data-${escapeHtml(key)}="${escapeHtml(value === true ? 'true' : value)}"`;
  }).join('');
  const classes = `mc-write ${className}`.trim();
  return `<button type="button" class="${escapeHtml(classes)}" title="${escapeHtml(tooltip)}" aria-description="${escapeHtml(tooltip)}"${ariaLabelAttr} data-cmd="${escapeHtml(cliCommand)}" data-exec-command="${escapeHtml(execCommand)}" data-ticket-id="${escapeHtml(ticketId)}"${rejectAttr}${dataAttrs}>${escapeHtml(label || 'Run')}</button>`;
}

function validPgid(pgid) {
  return /^[0-9]+$/.test(String(pgid || ''));
}

function shellQuote(value) {
  return `"${String(value ?? '').replace(/(["\\$`])/g, '\\$1')}"`;
}

function disabledSessionButton({ label, ariaLabel, cliCommand, reason }) {
  const tooltip = `$ ${cliCommand} — ${reason}`;
  return `<button type="button" class="mc-write mc-write--compact mc-session-action is-disabled" title="${escapeHtml(tooltip)}" aria-description="${escapeHtml(tooltip)}" aria-label="${escapeHtml(ariaLabel)}" data-cmd="${escapeHtml(cliCommand)}" disabled aria-disabled="true">${escapeHtml(label)}</button>`;
}

export function renderSessionInterventionBar(session = {}, { isLocalhost = true } = {}) {
  const id = String(session.id || '');
  if (!/^T[0-9]{3,}$/.test(id)) {
    throw new Error('renderSessionInterventionBar requires TXXX id');
  }

  // ADR-0027 §2.1: non-localhost (mobile) is observe + approve/reject only.
  // session_ctl (pause/resume/abort/redirect) is denied server-side (T099, 403);
  // hide the controls so the mobile UI matches. The server stays authoritative —
  // this is presentation only, not an enforcement boundary.
  if (!isLocalhost) {
    return `<div class="mc-session-actions mc-session-actions--observe" role="note">관측 전용 — pause/abort는 localhost 데스크톱에서만 가능합니다.</div>`;
  }

  const backend = String(session.timeout_backend || 'unknown');
  const pgid = String(session.pgid || 'unknown');
  const canSignalClock = backend === 'bash-group' && validPgid(pgid);
  const signalReason = `pause/resume requires timeout_backend=bash-group and numeric pgid (current: ${backend}, pgid=${pgid})`;
  const recovery = `git -C ${shellQuote(session.root || '.')} reset --hard cycle/${id}-pre`;
  const actionButton = (action, label, extra = {}) => renderWriteButton({
    label,
    ariaLabel: `${id} ${action}`,
    cliCommand: `./ralph/scripts/session_ctl.sh ${action} ${id}`,
    execCommand: 'session_ctl',
    ticketId: id,
    className: `mc-write--compact mc-session-action ${extra.className || ''}`.trim(),
    data: {
      'session-action': action,
      ...extra.data,
    },
  });

  const pause = canSignalClock
    ? actionButton('pause', '⏸')
    : disabledSessionButton({
        label: '⏸',
        ariaLabel: `${id} pause disabled`,
        cliCommand: `./ralph/scripts/session_ctl.sh pause ${id}`,
        reason: signalReason,
      });
  const resume = canSignalClock
    ? actionButton('resume', '▶')
    : disabledSessionButton({
        label: '▶',
        ariaLabel: `${id} resume disabled`,
        cliCommand: `./ralph/scripts/session_ctl.sh resume ${id}`,
        reason: signalReason,
      });
  const redirect = renderWriteButton({
    label: '지시 후 재시작',
    ariaLabel: `${id} redirect with instruction`,
    cliCommand: `./ralph/scripts/session_ctl.sh redirect ${id} "<instruction>"`,
    execCommand: 'session_ctl',
    ticketId: id,
    className: 'mc-write--compact mc-session-action',
    data: {
      'session-action': 'redirect',
      confirm: 'session-action',
      'confirm-title': `${id} 지시 후 재시작`,
      'confirm-what': `session_ctl redirect ${id} "<instruction>"`,
      'confirm-expected': '현재 세션을 중단하고 운영자 지시를 티켓에 남긴 뒤 동일 티켓을 다시 디스패치합니다.',
      'confirm-downside': '진행 중인 미커밋 작업은 잃을 수 있고, 새 세션은 이전 컨텍스트를 상속하지 않습니다.',
      'confirm-recovery': recovery,
      'requires-instruction': 'true',
    },
  });
  const abort = renderWriteButton({
    label: '⏹',
    ariaLabel: `${id} abort`,
    cliCommand: `./ralph/scripts/session_ctl.sh abort ${id}`,
    execCommand: 'session_ctl',
    ticketId: id,
    className: 'mc-write--compact mc-session-action mc-write--danger',
    data: {
      'session-action': 'abort',
      confirm: 'session-action',
      'confirm-title': `${id} abort`,
      'confirm-what': `session_ctl abort ${id}`,
      'confirm-expected': 'TERM 이후 필요 시 KILL로 세션을 중단하고 reservation을 해제합니다.',
      'confirm-downside': '진행 중인 미커밋 작업은 잃을 수 있습니다.',
      'confirm-recovery': recovery,
    },
  });

  return `<div class="mc-session-actions" aria-label="${escapeHtml(id)} interventions">
    ${pause}
    ${resume}
    ${redirect}
    ${abort}
  </div>`;
}

// ADR-0172 T266: Inbox respond 버튼 — HITL respond 결정을 기존 session_ctl redirect
// exec로 배선한다. 새 exec/스크립트/writer 0: renderSessionInterventionBar의 redirect와
// 동일한 data 계약(session-action redirect + requires-instruction + 기존 확인 모달)을
// 재사용한다. 호출부(server.mjs)가 localhost && respondable일 때만 렌더 — 비-localhost는
// 미렌더 + 서버 execScopeDecision이 redirect 403(T099)으로 이중 방어.
export function renderRespondButton(id) {
  const tid = String(id || '');
  if (!/^T[0-9]{3,}$/.test(tid)) {
    throw new Error('renderRespondButton requires TXXX id');
  }
  const recovery = `git reset --hard cycle/${tid}-pre`;
  return renderWriteButton({
    label: '지시 후 재시작',
    ariaLabel: `${tid} respond with instruction`,
    cliCommand: `./ralph/scripts/session_ctl.sh redirect ${tid} "<instruction>"`,
    execCommand: 'session_ctl',
    ticketId: tid,
    className: 'mc-write--compact mc-respond',
    data: {
      'session-action': 'redirect',
      confirm: 'session-action',
      'confirm-title': `${tid} 지시 후 재시작 (respond)`,
      'confirm-what': `session_ctl redirect ${tid} "<instruction>"`,
      'confirm-expected': '현재 세션을 중단하고 운영자 지시를 티켓에 남긴 뒤 동일 티켓을 다시 디스패치합니다.',
      'confirm-downside': '진행 중인 미커밋 작업은 잃을 수 있고, 새 세션은 이전 컨텍스트를 상속하지 않습니다.',
      'confirm-recovery': recovery,
      'requires-instruction': 'true',
    },
  });
}

export function renderOfflineBadge() {
  return `<div id="mc-offline-badge" class="mc-offline-badge" role="status" aria-live="polite" hidden></div>`;
}

export function renderConfirmModal() {
  return `<div id="mc-confirm-modal" class="mc-modal" role="dialog" aria-modal="true" aria-labelledby="mc-confirm-title" hidden>
  <div class="mc-modal__panel">
    <h2 id="mc-confirm-title"></h2>
    <div class="mc-modal__grid">
      <section><h3>무엇이</h3><p data-confirm-what></p></section>
      <section><h3>예상 결과</h3><p data-confirm-expected></p></section>
      <section><h3>잘못되면</h3><p data-confirm-downside></p><pre data-confirm-recovery></pre></section>
    </div>
    <label class="mc-modal__instruction" data-confirm-instruction-wrap for="mc-confirm-instruction">
      <span>지시</span>
      <textarea id="mc-confirm-instruction" data-confirm-instruction maxlength="1000" rows="4"></textarea>
    </label>
    <div class="mc-modal__actions">
      <button type="button" class="mc-modal__button" data-confirm-cancel>Cancel</button>
      <button type="button" class="mc-write mc-write--danger" data-confirm-submit>Run</button>
    </div>
  </div>
</div>`;
}

function formatDate(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return '—';
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
}

// Plain (non-exec) command button that still satisfies the R3 CLI-tooltip
// contract (title starts with "$ " and contains the data-cmd). These trigger
// client-side fetches, not the /api/exec handler, so they carry no
// data-exec-command attribute.
function pairCommandButton({ label, cliCommand, action, deviceId = '', className = '', danger = false }) {
  const tooltip = `$ ${cliCommand}`;
  const cls = `mc-write mc-write--compact ${danger ? 'mc-write--danger ' : ''}${className}`.trim();
  const deviceAttr = deviceId ? ` data-device-id="${escapeHtml(deviceId)}"` : '';
  return `<button type="button" class="${escapeHtml(cls)}" title="${escapeHtml(tooltip)}" aria-description="${escapeHtml(tooltip)}" data-cmd="${escapeHtml(cliCommand)}" data-pair-action="${escapeHtml(action)}"${deviceAttr}>${escapeHtml(label)}</button>`;
}

function renderDeviceRow(device) {
  const id = String(device.device_id || '');
  const shortId = id.slice(0, 12);
  const label = String(device.label || '');
  const status = device.revoked ? '폐기됨' : device.expired ? '만료됨' : '활성';
  const statusClass = device.active ? 'mc-safe' : 'mc-unsafe';
  const renewInfo = device.renew_count
    ? `${escapeHtml(formatDate(device.last_renewed_at))} (×${escapeHtml(device.renew_count)})`
    : '—';
  let actions = '';
  if (device.active) {
    actions = `<span class="mc-rename"><input type="text" class="mc-rename-input" data-rename-input data-device-id="${escapeHtml(id)}" value="${escapeHtml(label)}" maxlength="64" aria-label="기기 라벨"></span>`
      + pairCommandButton({ label: '이름변경', cliCommand: `./ralph/scripts/pair.sh rename ${id} <new-label>`, action: 'rename', deviceId: id, className: 'mc-device-rename' })
      + pairCommandButton({ label: '폐기', cliCommand: `./ralph/scripts/pair.sh revoke ${id}`, action: 'revoke', deviceId: id, danger: true, className: 'mc-device-revoke' });
  }
  return `<tr class="mc-device-row">
    <td>${escapeHtml(label)}</td>
    <td><code>${escapeHtml(shortId)}…</code></td>
    <td>${escapeHtml(formatDate(device.created_at))}</td>
    <td>${escapeHtml(formatDate(device.expires_at))}</td>
    <td>${escapeHtml(formatDate(device.last_seen_at))}</td>
    <td>${renewInfo}</td>
    <td><span class="${statusClass}">${escapeHtml(status)}</span></td>
    <td>${actions}</td>
  </tr>`;
}

/**
 * Pairing + device management page main (localhost-only surface).
 * @param {object} opts { devices: DeviceSummary[], pairingBase: string }
 */
// ADR-0188 T282: device fleet posture 요약 칩(읽기 신호). fleetPosture(읽기 모델)을
// *표시*만 — 점수·평가 아님. cap 배지는 신호이지 발급 게이트가 아니다(ADR-0033 무변경).
function renderFleetSummary(devices, limit) {
  const max = limit ? Number(limit) : null;
  const fp = fleetPosture(devices, Date.now(), { max: Number.isInteger(max) && max > 0 ? max : null });
  if (!fp.total) return '';
  const chip = (n, label, mod) =>
    n > 0 ? `<span class="mc-fleet mc-fleet--${mod}">${label} ${n}</span>` : '';
  const chips = [
    chip(fp.active, '정상', 'ok'),
    chip(fp.renewSoon, '갱신 임박', 'renew'),
    chip(fp.stale, '미사용', 'stale'),
    chip(fp.inactive, '비활성', 'inactive'),
  ].join('');
  let cap = '';
  if (fp.atCap) cap = `<span class="mc-fleet mc-fleet--atcap" title="활성 기기가 상한에 도달 — 새 기기 등록 전 폐기 필요">상한 도달 ${fp.activeTotal}/${fp.max}</span>`;
  else if (fp.nearCap) cap = `<span class="mc-fleet mc-fleet--nearcap" title="활성 기기가 상한에 근접">상한 근접 ${fp.activeTotal}/${fp.max}</span>`;
  return `<div class="mc-fleet-summary" aria-label="기기 posture 요약">${chips}${cap}</div>`;
}

export function renderPairingMain({ devices = [], pairingBase = '', limit = null } = {}) {
  const activeCount = devices.filter(d => d.active).length;
  const limitLabel = limit ? `활성 ${activeCount} / 상한 ${escapeHtml(limit)}` : `${devices.length}`;
  const fleetSummary = renderFleetSummary(devices, limit);
  const rows = devices.length
    ? devices.map(renderDeviceRow).join('\n')
    : '<tr><td colspan="5" class="mc-empty">등록된 기기가 없습니다</td></tr>';
  const startButton = pairCommandButton({
    label: '페어링 시작',
    cliCommand: './ralph/scripts/pair.sh start',
    action: 'start',
    className: 'mc-pair-start',
  });
  const baseAttr = pairingBase ? ` data-pairing-base="${escapeHtml(pairingBase)}"` : '';
  return `<main class="mc-page mc-page--pairing" aria-label="Pairing" data-pairing-root${baseAttr}>
  <section class="mc-pairing-panel" aria-labelledby="mc-pairing-title">
    <div class="mc-panel__head">
      <h2 id="mc-pairing-title">모바일 기기 페어링</h2>
    </div>
    <p class="mc-pairing-hint">QR을 모바일 카메라로 스캔하거나 아래 코드를 모바일 브라우저에 직접 입력하세요. 토큰은 1회용이며 5분 후 만료됩니다.</p>
    ${startButton}
    <div class="mc-pairing-output" hidden data-pairing-output>
      <div class="mc-pairing-qr" data-pairing-qr role="img" aria-label="페어링 QR 코드"></div>
      <div class="mc-pairing-code">
        <label for="mc-pairing-url">페어링 URL (수동 입력용)</label>
        <input id="mc-pairing-url" type="text" readonly data-pairing-url aria-describedby="mc-pairing-expiry">
        ${pairCommandButton({ label: '복사', cliCommand: './ralph/scripts/pair.sh start', action: 'copy', className: 'mc-pairing-copy' })}
        <p id="mc-pairing-expiry" class="mc-pairing-expiry" aria-live="polite" data-pairing-expiry></p>
      </div>
    </div>
    <p class="mc-pairing-warning" role="note">⚠ QR/URL에는 1회용 토큰이 포함됩니다. 화면 공유 시 노출에 주의하세요.</p>
  </section>
  <section class="mc-pairing-panel" aria-labelledby="mc-devices-title">
    <div class="mc-panel__head">
      <h2 id="mc-devices-title">등록된 기기</h2>
      <span data-device-count>${limitLabel}</span>
    </div>
    ${fleetSummary}
    <table class="mc-device-table">
      <thead><tr><th>라벨</th><th>기기 ID</th><th>등록일</th><th>만료일</th><th>마지막 사용</th><th>갱신</th><th>상태</th><th>관리</th></tr></thead>
      <tbody data-device-tbody aria-live="polite">
        ${rows}
      </tbody>
    </table>
  </section>
  ${pairingScript()}
</main>`;
}

function pairingScript() {
  return `<script type="module">
import { toSvg } from '/qr.mjs';
const root = document.querySelector('[data-pairing-root]');
if (root) {
  const out = root.querySelector('[data-pairing-output]');
  const qrBox = root.querySelector('[data-pairing-qr]');
  const urlInput = root.querySelector('[data-pairing-url]');
  const expiry = root.querySelector('[data-pairing-expiry]');
  const base = root.dataset.pairingBase || window.location.origin;
  let timer = null;
  const showToast = (msg) => { const t = document.getElementById('mc-toast'); if (t) { t.textContent = msg; t.classList.add('is-visible'); setTimeout(() => t.classList.remove('is-visible'), 4000); } };
  async function startPairing() {
    try {
      const res = await fetch('/api/tokens/pairing', { method: 'POST' });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { showToast(data.error || '페어링 토큰 생성 실패'); return; }
      const url = base.replace(/\\/$/, '') + '/pair#' + data.token;
      qrBox.innerHTML = toSvg(url, { ecl: 'M', moduleSize: 6 });
      urlInput.value = url;
      out.hidden = false;
      if (timer) clearInterval(timer);
      const expMs = new Date(data.expires_at).getTime();
      const tick = () => {
        const left = Math.max(0, Math.floor((expMs - Date.now()) / 1000));
        expiry.textContent = left > 0 ? '만료까지 ' + Math.floor(left / 60) + '분 ' + (left % 60) + '초' : '만료됨 — 다시 시작하세요';
        if (left <= 0 && timer) { clearInterval(timer); }
      };
      tick(); timer = setInterval(tick, 1000);
    } catch (e) { showToast(String(e)); }
  }
  async function revokeDevice(deviceId) {
    if (!window.confirm('이 기기의 토큰을 즉시 폐기할까요?')) return;
    try {
      const res = await fetch('/api/tokens/revoke', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ device_id: deviceId }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { showToast(data.error || '폐기 실패'); return; }
      showToast('기기 토큰을 폐기했습니다'); window.location.reload();
    } catch (e) { showToast(String(e)); }
  }
  async function renameDevice(deviceId) {
    const input = root.querySelector('input[data-rename-input][data-device-id="' + deviceId + '"]');
    const label = input ? input.value.trim() : '';
    if (!label) { showToast('라벨을 입력하세요'); return; }
    try {
      const res = await fetch('/api/tokens/rename', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ device_id: deviceId, label: label }) });
      const data = await res.json().catch(() => ({}));
      if (!res.ok) { showToast(data.error || '이름변경 실패'); return; }
      showToast('이름을 변경했습니다'); window.location.reload();
    } catch (e) { showToast(String(e)); }
  }
  root.addEventListener('click', (event) => {
    const button = event.target.closest('button[data-pair-action]');
    if (!button) return;
    event.preventDefault();
    const action = button.dataset.pairAction;
    if (action === 'start') startPairing();
    else if (action === 'revoke') revokeDevice(button.dataset.deviceId);
    else if (action === 'rename') renameDevice(button.dataset.deviceId);
    else if (action === 'copy') { urlInput.select(); navigator.clipboard && navigator.clipboard.writeText(urlInput.value).then(() => showToast('복사되었습니다')); }
  });
}
</script>`;
}

/**
 * Mobile pairing landing page main (/pair). Reads the one-time token from the
 * URL fragment, exchanges it for a long-term device token, and stores it.
 */
export function renderPairExchangeMain() {
  return `<main class="mc-page mc-page--pair" aria-label="기기 페어링">
  <section class="mc-pairing-panel">
    <div class="mc-panel__head"><h2>기기 페어링</h2></div>
    <p class="mc-pairing-status" data-pair-status aria-live="polite">페어링을 진행하는 중…</p>
    <a class="mc-nav__item" href="/inbox" data-pair-continue hidden>승인 인박스로 이동</a>
  </section>
  ${pairExchangeScript()}
</main>`;
}

function pairExchangeScript() {
  return `<script type="module">
const status = document.querySelector('[data-pair-status]');
const cont = document.querySelector('[data-pair-continue]');
const token = (window.location.hash || '').replace(/^#/, '').trim();
async function run() {
  if (!token) { status.textContent = '페어링 토큰이 없습니다. QR을 다시 스캔하세요.'; return; }
  try {
    const res = await fetch('/api/tokens/exchange', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ token }) });
    const data = await res.json().catch(() => ({}));
    if (res.status === 409) { status.textContent = '기기 한도(' + (data.limit || '') + ')에 도달했습니다. 데스크톱 Pairing 화면에서 기존 기기를 폐기한 뒤 다시 시도하세요.'; return; }
    if (!res.ok) { status.textContent = data.error || '페어링에 실패했습니다. 토큰이 만료되었거나 이미 사용되었을 수 있습니다.'; return; }
    try {
      localStorage.setItem('mc_device_token', data.token);
      localStorage.setItem('mc_device_id', data.device_id);
      if (data.expires_at) localStorage.setItem('mc_device_expires', data.expires_at);
    } catch (_e) {}
    // Register the service worker and hand it the device token + expiry so
    // subsequent navigation / fetch / SSE carry Authorization and the SW can
    // auto-renew within the window (ADR-0029 §3.1, ADR-0031 §3).
    if ('serviceWorker' in navigator) {
      try {
        const reg = await navigator.serviceWorker.register('/sw.js');
        await navigator.serviceWorker.ready;
        const target = navigator.serviceWorker.controller || reg.active;
        if (target) target.postMessage({ type: 'mc-set-token', token: data.token, expires_at: data.expires_at });
      } catch (_e) { /* SW optional; localStorage token still re-arms on next load */ }
    }
    history.replaceState(null, '', '/pair');
    status.textContent = '페어링이 완료되었습니다. 이 기기는 승인/거부만 수행할 수 있습니다.';
    if (cont) cont.hidden = false;
  } catch (e) { status.textContent = String(e); }
}
run();
</script>`;
}

/**
 * Self-contained mobile pairing bootstrap page (GET /pair). Inlines its own
 * critical CSS so it renders before any service worker is active and requires
 * no other unauthenticated GET (ADR-0029 §3.2). The only extra fetch it triggers
 * is the SW registration of /sw.js, which is part of the bootstrap exempt set.
 */
export function renderPairBootstrapPage() {
  return `<!DOCTYPE html>
<html lang="ko">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>기기 페어링 — Hephaestus Mission Control</title>
<meta name="theme-color" content="#0E1116">
<style>
:root{--bg:#0E1116;--surface:#161B22;--text:#E6EDF3;--dim:#9AA7B8;--navy-text:#6CB6F0;--border:#2A2F3A;--focus:#8BD3FF}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--text);font:15px/1.6 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif;padding:24px}
.mc-pairing-panel{max-width:520px;margin:0 auto;background:var(--surface);border:1px solid var(--border);border-radius:10px;padding:20px}
.mc-panel__head h2{margin:0 0 12px}
.mc-pairing-status{color:var(--dim)}
a.mc-nav__item{display:inline-block;margin-top:16px;color:var(--navy-text);text-decoration:none;border:1px solid var(--border);border-radius:6px;padding:8px 14px}
:focus-visible{outline:2px solid var(--focus)}
@media (max-width:768px){body{padding:16px}}
</style>
</head>
<body>
${renderPairExchangeMain()}
</body>
</html>`;
}

export function clientScript() {
  return `<script>
(() => {
  const toast = document.getElementById('mc-toast');
  const showToast = (message, failed = false) => {
    if (!toast) return;
    toast.textContent = message;
    toast.classList.toggle('is-error', failed);
    toast.classList.add('is-visible');
    window.setTimeout(() => toast.classList.remove('is-visible'), 5000);
  };

  // ADR-0164 T257: 모바일 오프캔버스 내비 — 토글 + backdrop + ESC + focus trap + 포커스 복귀 + 데스크톱 접기.
  (() => {
    const app = document.querySelector('.mc-app');
    const sidenav = document.querySelector('.mc-sidenav');
    const toggle = document.querySelector('[data-nav-toggle]');
    const backdrop = document.querySelector('[data-nav-backdrop]');
    if (!app || !sidenav || !toggle) return;
    let opener = null;
    const focusables = () => Array.prototype.slice
      .call(sidenav.querySelectorAll('a[href],button:not([disabled])'))
      .filter(el => el.offsetParent !== null);
    const onKey = (e) => {
      if (e.key === 'Escape') { e.preventDefault(); closeNav(); return; }
      if (e.key !== 'Tab') return;
      const f = focusables(); if (!f.length) return;
      const first = f[0], last = f[f.length - 1];
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    function openNav() {
      opener = document.activeElement;
      app.classList.add('nav-open'); toggle.setAttribute('aria-expanded', 'true');
      if (backdrop) backdrop.hidden = false;
      const f = focusables(); if (f[0]) f[0].focus();
      document.addEventListener('keydown', onKey, true);
    }
    function closeNav() {
      app.classList.remove('nav-open'); toggle.setAttribute('aria-expanded', 'false');
      if (backdrop) backdrop.hidden = true;
      document.removeEventListener('keydown', onKey, true);
      if (opener && opener.focus) opener.focus();
    }
    toggle.addEventListener('click', () => app.classList.contains('nav-open') ? closeNav() : openNav());
    if (backdrop) backdrop.addEventListener('click', closeNav);
    sidenav.addEventListener('click', (e) => { if (e.target.closest('a.mc-nav__item') && app.classList.contains('nav-open')) closeNav(); });
    const collapse = document.querySelector('[data-nav-collapse]');
    if (collapse) collapse.addEventListener('click', () => {
      app.classList.toggle('nav-collapsed');
      collapse.setAttribute('aria-pressed', app.classList.contains('nav-collapsed') ? 'true' : 'false');
    });
  })();

  // ADR-0164 T258: 커맨드 팔레트(⌘K) 뼈대 — ARIA combobox/listbox + 키보드 + focus trap + 포커스 복귀.
  // 항목은 렌더된 내비 링크(기존 페이지)에서 도출 — localhost 노출 그대로 반영, 신규 exec 없음.
  // 리스트는 createElement + textContent로만 빌드(escape-first — DOM 텍스트만).
  (() => {
    const scrim = document.querySelector('[data-cmd-scrim]');
    const input = document.querySelector('[data-cmd-input]');
    const list = document.querySelector('[data-cmd-list]');
    const openBtn = document.querySelector('[data-cmd-open]');
    if (!scrim || !input || !list) return;
    const cmds = [];
    Array.prototype.forEach.call(document.querySelectorAll('.mc-nav__item'), (a) => {
      const labelEl = a.querySelector('.mc-nav__label');
      const label = (labelEl ? labelEl.textContent : a.textContent).trim();
      const href = a.getAttribute('href') || '/';
      cmds[cmds.length] = { label: label + ' 열기', href, cli: 'open ' + href };
    });
    // 기존 액션(신규 exec 없음 — 해당 페이지로 이동만).
    cmds[cmds.length] = { label: '대기 승인 검토', href: '/inbox', cli: 'session_ctl approve <id>' };
    cmds[cmds.length] = { label: '다음 safe 티켓 실행 (가이드)', href: '/autonomy', cli: 'run_loop.sh --safe-only' };
    let filtered = cmds.slice(), sel = 0, opener = null;
    function render() {
      while (list.firstChild) list.removeChild(list.firstChild);
      filtered.forEach((c, i) => {
        const li = document.createElement('li');
        li.id = 'mc-cmd-opt-' + i;
        li.className = 'mc-cmd__opt';
        li.setAttribute('role', 'option');
        li.setAttribute('aria-selected', i === sel ? 'true' : 'false');
        const lab = document.createElement('span'); lab.className = 'mc-cmd__lab'; lab.textContent = c.label;
        const cli = document.createElement('span'); cli.className = 'mc-cmd__cli'; cli.textContent = c.cli;
        li.appendChild(lab); li.appendChild(cli);
        li.addEventListener('click', () => activate(c));
        list.appendChild(li);
      });
      input.setAttribute('aria-activedescendant', filtered.length ? ('mc-cmd-opt-' + sel) : '');
    }
    function activate(c) { closePalette(); if (c && c.href) window.location.href = c.href; }
    function openPalette() {
      opener = document.activeElement;
      scrim.hidden = false; input.value = '';
      filtered = cmds.slice(); sel = 0; render(); input.focus();
    }
    function closePalette() {
      scrim.hidden = true;
      if (opener && opener.focus) opener.focus();
    }
    input.addEventListener('input', () => {
      const q = input.value.toLowerCase();
      filtered = cmds.filter(c => c.label.toLowerCase().indexOf(q) >= 0 || c.cli.toLowerCase().indexOf(q) >= 0);
      sel = 0; render();
    });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { sel = Math.min(sel + 1, filtered.length - 1); render(); e.preventDefault(); }
      else if (e.key === 'ArrowUp') { sel = Math.max(sel - 1, 0); render(); e.preventDefault(); }
      else if (e.key === 'Enter') { if (filtered[sel]) activate(filtered[sel]); e.preventDefault(); }
      else if (e.key === 'Escape') { closePalette(); }
      else if (e.key === 'Tab') { e.preventDefault(); } // focus trap: input만 포커스 대상
    });
    scrim.addEventListener('click', (e) => { if (e.target === scrim) closePalette(); });
    if (openBtn) openBtn.addEventListener('click', openPalette);
    document.addEventListener('keydown', (e) => {
      if ((e.metaKey || e.ctrlKey) && (e.key === 'k' || e.key === 'K')) {
        e.preventDefault();
        scrim.hidden ? openPalette() : closePalette();
      }
    });
  })();

  if (window.matchMedia && window.matchMedia('(display-mode: standalone)').matches && window.location.pathname === '/') {
    window.location.replace('/inbox');
    return;
  }

  // ADR-0029 §3.1: re-arm the service worker with the stored device token on
  // every load so navigation/fetch/SSE carry Authorization even after a SW
  // restart. No-op on localhost (no token stored).
  function mcArmServiceWorker(registration) {
    let token = null;
    let expires = null;
    try {
      token = localStorage.getItem('mc_device_token');
      expires = localStorage.getItem('mc_device_expires');
    } catch (_e) { token = null; }
    if (!token) return;
    const target = navigator.serviceWorker.controller || (registration && registration.active);
    if (target) target.postMessage({ type: 'mc-set-token', token, expires_at: expires });
  }
  // ADR-0031 §3: when the SW auto-renews the token it broadcasts the new value;
  // mirror it into localStorage so future loads re-arm with the current token.
  if ('serviceWorker' in navigator) {
    navigator.serviceWorker.addEventListener('message', event => {
      const data = event.data || {};
      if (data.type === 'mc-token-renewed' && data.token) {
        try {
          localStorage.setItem('mc_device_token', data.token);
          if (data.expires_at) localStorage.setItem('mc_device_expires', data.expires_at);
        } catch (_e) {}
      }
    });
  }
  function mcHandleUnauthorized() {
    try { localStorage.removeItem('mc_device_token'); localStorage.removeItem('mc_device_id'); localStorage.removeItem('mc_device_expires'); } catch (_e) {}
    if (navigator.serviceWorker && navigator.serviceWorker.controller) {
      navigator.serviceWorker.controller.postMessage({ type: 'mc-clear-token' });
    }
    if (window.location.pathname !== '/pair') window.location.href = '/pair';
  }
  if ('serviceWorker' in navigator) {
    window.addEventListener('load', () => {
      navigator.serviceWorker.register('/sw.js')
        .then(registration => mcArmServiceWorker(registration))
        .catch(error => {
          console.warn('Mission Control service worker registration failed', error);
        });
    });
  }

  let installPrompt = null;
  const installButton = document.querySelector('[data-install-app]');
  window.addEventListener('beforeinstallprompt', event => {
    event.preventDefault();
    installPrompt = event;
    if (installButton) installButton.hidden = false;
  });
  window.addEventListener('appinstalled', () => {
    installPrompt = null;
    if (installButton) installButton.hidden = true;
  });
  if (installButton) {
    installButton.addEventListener('click', async () => {
      if (!installPrompt) return;
      installButton.disabled = true;
      try {
        await installPrompt.prompt();
        await installPrompt.userChoice.catch(() => undefined);
      } finally {
        installPrompt = null;
        installButton.hidden = true;
        installButton.disabled = false;
      }
    });
  }

  const notifyButton = document.querySelector('[data-open-notifications]');
  let openNotificationsEnabled = false;
  const notificationSupported = 'Notification' in window;
  const updateNotifyButton = () => {
    if (!notifyButton) return;
    notifyButton.hidden = !notificationSupported;
    if (!notificationSupported) return;
    if (Notification.permission === 'denied') {
      notifyButton.textContent = '앱이 열려 있을 때 알림 차단됨';
      notifyButton.disabled = true;
      return;
    }
    notifyButton.disabled = false;
    notifyButton.textContent = openNotificationsEnabled
      ? '앱이 열려 있을 때 알림 켜짐'
      : '앱이 열려 있을 때 알림';
  };
  updateNotifyButton();
  if (notifyButton) {
    notifyButton.addEventListener('click', async () => {
      if (!notificationSupported) return;
      let permission = Notification.permission;
      if (permission === 'default') {
        permission = await Notification.requestPermission();
      }
      openNotificationsEnabled = permission === 'granted';
      updateNotifyButton();
      showToast(openNotificationsEnabled ? '알림이 켜졌습니다' : '알림 권한이 필요합니다', !openNotificationsEnabled);
    });
  }

  const focusNotificationTarget = payload => {
    const href = payload.href || '/';
    const targetUrl = new URL(href, window.location.origin);
    if (window.location.pathname !== targetUrl.pathname || window.location.search !== targetUrl.search) {
      window.location.href = targetUrl.pathname + targetUrl.search + targetUrl.hash;
      return;
    }
    const target = payload.focusId ? document.getElementById(payload.focusId) : null;
    if (!target) return;
    target.scrollIntoView({ block: 'center' });
    target.focus({ preventScroll: true });
  };

  const showOpenNotification = (title, options, payload) => {
    if (!openNotificationsEnabled || !notificationSupported || Notification.permission !== 'granted') return;
    const notice = new Notification(title, options);
    notice.addEventListener('click', () => {
      notice.close();
      window.focus();
      focusNotificationTarget(payload);
    });
  };

  const confirmSessionAction = button => new Promise(resolve => {
    if (!button.dataset.confirm) {
      resolve({ ok: true });
      return;
    }

    const fallback = () => {
      if (!window.confirm(button.dataset.confirmExpected || 'Run command?')) {
        resolve({ ok: false });
        return;
      }
      if (button.dataset.requiresInstruction === 'true') {
        const instruction = window.prompt('Instruction') || '';
        resolve({ ok: Boolean(instruction.trim()), instruction: instruction.trim() });
        return;
      }
      resolve({ ok: true });
    };

    const modal = document.getElementById('mc-confirm-modal');
    if (!modal) {
      fallback();
      return;
    }

    const title = modal.querySelector('#mc-confirm-title');
    const what = modal.querySelector('[data-confirm-what]');
    const expected = modal.querySelector('[data-confirm-expected]');
    const downside = modal.querySelector('[data-confirm-downside]');
    const recovery = modal.querySelector('[data-confirm-recovery]');
    const instructionWrap = modal.querySelector('[data-confirm-instruction-wrap]');
    const instruction = modal.querySelector('[data-confirm-instruction]');
    const cancel = modal.querySelector('[data-confirm-cancel]');
    const submit = modal.querySelector('[data-confirm-submit]');
    const needsInstruction = button.dataset.requiresInstruction === 'true';

    title.textContent = button.dataset.confirmTitle || 'Confirm';
    what.textContent = button.dataset.confirmWhat || '';
    expected.textContent = button.dataset.confirmExpected || '';
    downside.textContent = button.dataset.confirmDownside || '';
    recovery.textContent = button.dataset.confirmRecovery || '';
    if (instructionWrap) instructionWrap.hidden = !needsInstruction;
    if (instruction) instruction.value = '';

    let settled = false;
    const close = result => {
      if (settled) return;
      settled = true;
      modal.hidden = true;
      modal.classList.remove('is-visible');
      cancel.removeEventListener('click', onCancel);
      submit.removeEventListener('click', onSubmit);
      document.removeEventListener('keydown', onKeydown);
      resolve(result);
    };
    const onCancel = () => close({ ok: false });
    const onKeydown = event => {
      if (event.key === 'Escape') close({ ok: false });
    };
    const onSubmit = () => {
      const text = instruction ? instruction.value.trim() : '';
      if (needsInstruction && !text) {
        showToast('Instruction required', true);
        return;
      }
      close({ ok: true, instruction: text });
    };

    cancel.addEventListener('click', onCancel);
    submit.addEventListener('click', onSubmit);
    document.addEventListener('keydown', onKeydown);
    modal.hidden = false;
    modal.classList.add('is-visible');
    (needsInstruction && instruction ? instruction : submit).focus();
  });

  // ADR-0158 T251: accessible confirm opener that REUSES the shared #mc-confirm-modal
  // element (no new modal). Danger actions can request initial focus on Cancel; adds
  // focus trap, ESC + backdrop close, background inert, and focus return to the opener.
  // confirmSessionAction (session flow) is unchanged. Resolves { ok: boolean }.
  window.__mcConfirm = (opts) => new Promise(resolve => {
    opts = opts || {};
    const modal = document.getElementById('mc-confirm-modal');
    if (!modal) { resolve({ ok: window.confirm(opts.what || opts.title || '계속할까요?') }); return; }
    const opener = document.activeElement;
    const title = modal.querySelector('#mc-confirm-title');
    const what = modal.querySelector('[data-confirm-what]');
    const expected = modal.querySelector('[data-confirm-expected]');
    const downside = modal.querySelector('[data-confirm-downside]');
    const recovery = modal.querySelector('[data-confirm-recovery]');
    const instructionWrap = modal.querySelector('[data-confirm-instruction-wrap]');
    const cancel = modal.querySelector('[data-confirm-cancel]');
    const submit = modal.querySelector('[data-confirm-submit]');
    if (title) title.textContent = opts.title || 'Confirm';
    if (what) what.textContent = opts.what || '';
    if (expected) expected.textContent = opts.expected || '';
    if (downside) downside.textContent = opts.downside || '';
    if (recovery) recovery.textContent = opts.recovery || '';
    if (instructionWrap) instructionWrap.hidden = true;
    const origSubmit = submit ? submit.textContent : '';
    if (submit && opts.submitLabel) submit.textContent = opts.submitLabel;
    const inerted = Array.prototype.filter.call(document.body.children, el => el !== modal && el.id !== 'mc-toast');
    inerted.forEach(el => el.setAttribute('inert', ''));
    let settled = false;
    const focusables = () => [cancel, submit].filter(Boolean);
    const onKeydown = event => {
      if (event.key === 'Escape') { close({ ok: false }); return; }
      if (event.key === 'Tab') {
        const f = focusables(); if (!f.length) return;
        const first = f[0], last = f[f.length - 1];
        if (event.shiftKey && document.activeElement === first) { event.preventDefault(); last.focus(); }
        else if (!event.shiftKey && document.activeElement === last) { event.preventDefault(); first.focus(); }
      }
    };
    const onBackdrop = event => { if (event.target === modal) close({ ok: false }); };
    function close(result) {
      if (settled) return; settled = true;
      modal.hidden = true; modal.classList.remove('is-visible');
      if (cancel) cancel.removeEventListener('click', onCancel);
      if (submit) submit.removeEventListener('click', onSubmit);
      modal.removeEventListener('click', onBackdrop);
      document.removeEventListener('keydown', onKeydown);
      inerted.forEach(el => el.removeAttribute('inert'));
      if (submit) submit.textContent = origSubmit;
      if (opener && opener.focus) opener.focus();   // focus return
      resolve(result);
    }
    const onCancel = () => close({ ok: false });
    const onSubmit = () => close({ ok: true });
    if (cancel) cancel.addEventListener('click', onCancel);
    if (submit) submit.addEventListener('click', onSubmit);
    modal.addEventListener('click', onBackdrop);
    document.addEventListener('keydown', onKeydown);
    modal.hidden = false; modal.classList.add('is-visible');
    const initial = (opts.initialFocus === 'cancel' ? cancel : submit) || cancel || submit;
    if (initial) initial.focus();   // danger → cancel
  });

  document.addEventListener('click', async event => {
    const button = event.target.closest('button[data-exec-command]');
    if (!button) return;
    event.preventDefault();
    event.stopPropagation();
    if (button.disabled) return;

    const payload = {
      command: button.dataset.execCommand,
      ticketId: button.dataset.ticketId,
    };
    if (button.dataset.reject === 'true') {
      const reason = window.prompt('Reject reason');
      if (!reason) return;
      payload.rejectReason = reason;
    }
    if (button.dataset.sessionAction) {
      payload.sessionAction = button.dataset.sessionAction;
    }

    const confirmed = await confirmSessionAction(button);
    if (!confirmed.ok) return;
    if (confirmed.instruction) {
      payload.instruction = confirmed.instruction;
    }

    button.disabled = true;
    try {
      const response = await fetch('/api/exec', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (response.status === 401) {
        showToast('인증이 만료되었습니다. 다시 페어링하세요.', true);
        mcHandleUnauthorized();
        return;
      }
      const data = await response.json().catch(() => ({}));
      if (!response.ok) {
        showToast(data.error || 'Command rejected', true);
        return;
      }
      showToast(data.exitCode === 0 ? 'Command completed' : 'Command failed: ' + data.exitCode, data.exitCode !== 0);
    } catch (error) {
      showToast(String(error), true);
    } finally {
      button.disabled = false;
    }
  });

  const offlineBadge = document.getElementById('mc-offline-badge');
  let mcOffline = false;

  function mcSetOffline(snapshotTime) {
    if (offlineBadge) {
      const hhmm = snapshotTime.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
      offlineBadge.textContent = '오프라인 — ' + hhmm + ' 기준 스냅샷';
      offlineBadge.removeAttribute('hidden');
    }
    document.querySelectorAll('button.mc-write').forEach(btn => {
      if (!btn.hasAttribute('data-offline-saved-title')) {
        const title = btn.getAttribute('title') || '';
        const ariaDescription = btn.getAttribute('aria-description') || '';
        btn.setAttribute('data-offline-saved-title', title);
        btn.setAttribute('data-offline-saved-aria-description', ariaDescription);
        btn.setAttribute('title', title ? title + ' — 서버 연결 필요' : '서버 연결 필요');
        btn.setAttribute('aria-description', ariaDescription ? ariaDescription + ' — 서버 연결 필요' : '서버 연결 필요');
        if (!btn.disabled) btn.setAttribute('data-offline-was-enabled', '');
      }
      btn.disabled = true;
      btn.setAttribute('aria-disabled', 'true');
    });
    mcOffline = true;
  }

  function mcSetOnline() {
    if (offlineBadge) offlineBadge.setAttribute('hidden', '');
    document.querySelectorAll('button.mc-write[data-offline-saved-title]').forEach(btn => {
      btn.setAttribute('title', btn.getAttribute('data-offline-saved-title'));
      btn.setAttribute('aria-description', btn.getAttribute('data-offline-saved-aria-description'));
      btn.removeAttribute('data-offline-saved-title');
      btn.removeAttribute('data-offline-saved-aria-description');
      if (btn.hasAttribute('data-offline-was-enabled')) {
        btn.removeAttribute('data-offline-was-enabled');
        btn.disabled = false;
        btn.removeAttribute('aria-disabled');
      }
    });
    mcOffline = false;
  }

  async function mcCheckHealth() {
    try {
      const response = await fetch('/healthz', { method: 'GET', cache: 'no-store' });
      if (response.ok) {
        if (mcOffline) { mcSetOnline(); window.location.reload(); }
      } else {
        if (!mcOffline) mcSetOffline(new Date());
      }
    } catch (_error) {
      if (!mcOffline) mcSetOffline(new Date());
    }
  }

  mcCheckHealth();
  window.setInterval(mcCheckHealth, 10000);
  window.addEventListener('offline', () => { if (!mcOffline) mcSetOffline(new Date()); });
  window.addEventListener('online', mcCheckHealth);

  if (window.EventSource) {
    const eventSource = new EventSource('/api/events/stream');
    eventSource.addEventListener('approval-required', event => {
      const payload = JSON.parse(event.data);
      showOpenNotification('승인 대기: ' + payload.id, {
        body: payload.title || '승인이 필요한 티켓이 있습니다',
        tag: 'approval-' + payload.id,
      }, payload);
    });
    eventSource.addEventListener('session-failure', event => {
      const payload = JSON.parse(event.data);
      showOpenNotification('세션 실패: ' + payload.id, {
        body: payload.stage + (payload.message ? ' — ' + payload.message : ''),
        tag: 'session-failure-' + payload.id,
      }, payload);
    });
  }

  const log = document.querySelector('[data-session-stream]');
  if (log && window.EventSource) {
    const sessionId = log.dataset.sessionStream;
    const events = document.getElementById('mc-session-events');
    let streamPrimed = false;
    const primeStream = () => {
      if (streamPrimed) return;
      streamPrimed = true;
      log.textContent = '';
      if (events) events.replaceChildren();
    };
    const source = new EventSource('/api/sessions/' + encodeURIComponent(sessionId) + '/stream');
    source.addEventListener('log', event => {
      primeStream();
      const payload = JSON.parse(event.data);
      log.textContent += (log.textContent ? '\\n' : '') + payload.line;
      log.scrollTop = log.scrollHeight;
    });
    source.addEventListener('event', event => {
      primeStream();
      if (!events) return;
      const payload = JSON.parse(event.data).event || {};
      const item = document.createElement('li');
      const ts = document.createElement('span');
      const actor = document.createElement('strong');
      const action = document.createElement('em');
      const detail = document.createElement('p');
      ts.textContent = payload.ts || '';
      actor.textContent = payload.actor || 'system';
      action.textContent = payload.action || '';
      detail.textContent = payload.detail || '';
      item.append(ts, actor, action, detail);
      events.appendChild(item);
    });
  }
})();
  </script>`;
}
