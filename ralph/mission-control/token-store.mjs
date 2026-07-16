// token-store.mjs — ADR-0027 §2.1 조건 2: 페어링·기기 토큰 store
// state/devices/<device_id> and state/devices/pairing-<pairing_id> are JSON files.
import { mkdirSync, readFileSync, writeFileSync, renameSync, unlinkSync, existsSync, readdirSync } from 'node:fs';
import { randomBytes, createHash, timingSafeEqual } from 'node:crypto';
import { join } from 'node:path';

export const PAIRING_TTL_MS = 5 * 60 * 1000;       // 5 minutes
export const DEVICE_TTL_MS  = 30 * 24 * 60 * 60 * 1000; // 30 days
// ADR-0031 §3.1: auto-renew is offered from 7 days before expiry.
export const RENEWAL_WINDOW_MS = 7 * 24 * 60 * 60 * 1000; // 7 days
// ADR-0031 §3.3: last_seen_at writes are throttled (observational metadata only).
export const LAST_SEEN_THROTTLE_MS = 60 * 60 * 1000;     // 1 hour
const DEVICE_ID_PATTERN = /^[0-9a-f]{32}$/;

function generateHex(bytes = 32) {
  return randomBytes(bytes).toString('hex');
}

function ensureDir(dir) {
  mkdirSync(dir, { recursive: true });
}

function tokenHash(token) {
  return createHash('sha256').update(String(token)).digest('hex');
}

function tokenHashesEqual(left, right) {
  const a = Buffer.from(left || '', 'hex');
  const b = Buffer.from(right || '', 'hex');
  return a.length === b.length && a.length > 0 && timingSafeEqual(a, b);
}

function tokenMatches(record, token) {
  return tokenHashesEqual(record?.token_hash, tokenHash(token));
}

function defaultLabel(deviceId) {
  return `Mobile device ${String(deviceId || '').slice(0, 8)}`;
}

function sanitizeLabel(label) {
  // strip control chars, trim, cap length — never used for security decisions.
  const cleaned = String(label ?? '').replace(/[\x00-\x1f\x7f]/g, '').trim();
  return cleaned ? cleaned.slice(0, 64) : '';
}

// Atomic write via unique temp-then-rename (mitigates concurrent-request races).
function atomicWrite(path, data) {
  const tmp = `${path}.${process.pid}.${generateHex(4)}.tmp`;
  writeFileSync(tmp, JSON.stringify(data, null, 2), { encoding: 'utf8', mode: 0o600 });
  renameSync(tmp, path);
}

function readJson(path) {
  try {
    return JSON.parse(readFileSync(path, 'utf8'));
  } catch {
    return null;
  }
}

function deviceFilePath(devicesDir, deviceId) {
  if (!DEVICE_ID_PATTERN.test(String(deviceId))) return null;
  return join(devicesDir, String(deviceId));
}

function jsonFiles(devicesDir) {
  return readdirSync(devicesDir).filter(filename => {
    if (filename.includes('.tmp') || filename.includes('.claimed-')) return false;
    return true;
  });
}

// ── Pairing tokens ─────────────────────────────────────

/**
 * Create a 1-use / 5-min pairing token.
 * Returns { id, token } — token is what goes in the QR code.
 */
export function createPairingToken(devicesDir, nowMs = Date.now()) {
  ensureDir(devicesDir);
  const id    = generateHex(16);
  const token = generateHex(32);
  const data  = {
    type:       'pairing',
    id,
    token_hash: tokenHash(token),
    created_at: new Date(nowMs).toISOString(),
    expires_at: new Date(nowMs + PAIRING_TTL_MS).toISOString(),
    used_at:    null,
  };
  atomicWrite(join(devicesDir, `pairing-${id}`), data);
  return { id, token, expires_at: data.expires_at };
}

/**
 * Exchange a pairing token for a device long-term token.
 * Invalidates the pairing token on first use.
 * Returns { device_id, token } or null on failure.
 */
export function exchangePairingToken(devicesDir, pairingToken, nowMs = Date.now()) {
  if (!pairingToken || !existsSync(devicesDir)) return null;

  for (const filename of jsonFiles(devicesDir)) {
    if (!filename.startsWith('pairing-')) continue;
    const filePath = join(devicesDir, filename);
    const data = readJson(filePath);
    if (!data || !tokenMatches(data, pairingToken)) continue;

    // Reject already-used tokens
    if (data.used_at) return null;

    // Reject expired tokens
    if (nowMs >= new Date(data.expires_at).getTime()) return null;

    // Claim the pairing file with atomic rename before issuing the long-term token.
    const claimPath = `${filePath}.claimed-${process.pid}-${generateHex(4)}`;
    try {
      renameSync(filePath, claimPath);
    } catch {
      continue;
    }

    // Issue device long-term token
    const deviceId  = generateHex(16);
    const devToken  = generateHex(32);
    const devData   = {
      type:       'device',
      device_id:  deviceId,
      token_hash: tokenHash(devToken),
      label:      defaultLabel(deviceId),
      created_at: new Date(nowMs).toISOString(),
      expires_at: new Date(nowMs + DEVICE_TTL_MS).toISOString(),
      revoked:    false,
      revoked_at: null,
      last_seen_at:    null,
      last_renewed_at: null,
      renew_count:     0,
    };
    atomicWrite(join(devicesDir, deviceId), devData);

    // Clean up consumed pairing token
    try { unlinkSync(claimPath); } catch { /* best-effort */ }

    return { device_id: deviceId, token: devToken, expires_at: devData.expires_at };
  }

  return null;
}

// ── Device tokens ──────────────────────────────────────

function findDeviceByToken(devicesDir, token) {
  if (!token || !existsSync(devicesDir)) return null;
  for (const filename of jsonFiles(devicesDir)) {
    if (filename.startsWith('pairing-') || !DEVICE_ID_PATTERN.test(filename)) continue;
    const data = readJson(join(devicesDir, filename));
    if (data && tokenMatches(data, token)) return { deviceId: filename, data };
  }
  return null;
}

/**
 * Race-safe device-record mutation (ADR-0031 §4). Claims the record via atomic
 * rename (compare-and-swap: only one concurrent mutator wins), applies `mutator`,
 * and writes the new record back. This is the SHARED path for revoke/renew/rename
 * so a concurrent revoke can never be resurrected by a renew, and vice versa.
 *
 * `mutator(record)` returns `{ data, value }` to commit (and return `value`), or a
 * falsy value to abort — on abort the record is restored unchanged and null is
 * returned.
 */
function mutateDeviceRecord(devicesDir, deviceId, mutator) {
  const filePath = deviceFilePath(devicesDir, deviceId);
  if (!filePath || !existsSync(filePath)) return null;
  const claimPath = `${filePath}.claimed-${process.pid}-${generateHex(4)}`;
  try {
    renameSync(filePath, claimPath);   // CAS: lose the race → throws → null
  } catch {
    return null;
  }
  const data = readJson(claimPath);
  let outcome = null;
  try {
    outcome = data ? mutator(data) : null;
  } catch {
    outcome = null;
  }
  if (!outcome) {
    try { renameSync(claimPath, filePath); } catch { /* best-effort restore */ }
    return null;
  }
  atomicWrite(filePath, outcome.data);
  try { unlinkSync(claimPath); } catch { /* best-effort; jsonFiles filters .claimed- */ }
  return outcome.value;
}

/**
 * Validate a device long-term token.
 * Returns true only if the token exists, is not revoked, and is not expired.
 */
export function validateDeviceToken(devicesDir, token, nowMs = Date.now()) {
  if (!token || !existsSync(devicesDir)) return false;

  for (const filename of jsonFiles(devicesDir)) {
    if (filename.startsWith('pairing-') || !DEVICE_ID_PATTERN.test(filename)) continue;
    const data = readJson(join(devicesDir, filename));
    if (!data || !tokenMatches(data, token)) continue;
    if (data.revoked) return false;
    if (nowMs >= new Date(data.expires_at).getTime()) return false;
    return true;
  }

  return false;
}

/**
 * Revoke a device token by device_id (race-safe via the shared mutation helper).
 * Revocation is immediate — next validateDeviceToken call returns false.
 * Returns true if the device file was found and updated, false otherwise.
 */
export function revokeDeviceToken(devicesDir, deviceId, nowMs = Date.now()) {
  return mutateDeviceRecord(devicesDir, deviceId, (cur) => ({
    data: { ...cur, revoked: true, revoked_at: cur.revoked_at || new Date(nowMs).toISOString() },
    value: true,
  })) === true;
}

/**
 * Renew (rotate) a device token presented by its current bearer (ADR-0031 §3.1-2).
 * - invalid / expired / revoked token  → null (caller returns 401)
 * - valid but outside the renewal window → { renewed: false, device_id, expires_at } (no-op)
 * - valid and within window             → rotate under CAS, old token hash replaced
 *     → { renewed: true, device_id, token, expires_at }
 * The rotation re-checks token match + not-revoked + not-expired INSIDE the claim,
 * so a concurrent revoke is never resurrected and a lost rotation race returns null.
 */
export function renewDeviceToken(devicesDir, token, nowMs = Date.now()) {
  const found = findDeviceByToken(devicesDir, token);
  if (!found) return null;
  const { deviceId, data } = found;
  if (data.revoked) return null;
  const expiresMs = new Date(data.expires_at).getTime();
  if (nowMs >= expiresMs) return null;
  if (expiresMs - nowMs > RENEWAL_WINDOW_MS) {
    return { renewed: false, device_id: deviceId, expires_at: data.expires_at };
  }
  const newToken = generateHex(32);
  return mutateDeviceRecord(devicesDir, deviceId, (cur) => {
    if (!tokenMatches(cur, token)) return null;            // already rotated by a concurrent renew
    if (cur.revoked) return null;                          // revoked between find and claim → abort
    if (nowMs >= new Date(cur.expires_at).getTime()) return null;
    const newData = {
      ...cur,
      token_hash:      tokenHash(newToken),
      expires_at:      new Date(nowMs + DEVICE_TTL_MS).toISOString(),
      last_renewed_at: new Date(nowMs).toISOString(),
      renew_count:     (cur.renew_count || 0) + 1,
    };
    return { data: newData, value: { renewed: true, device_id: deviceId, token: newToken, expires_at: newData.expires_at } };
  });
}

/**
 * Rename a device's label (localhost-only management action). Best-effort, never
 * a security decision. Returns true if updated, false otherwise.
 */
export function renameDevice(devicesDir, deviceId, label) {
  const clean = sanitizeLabel(label);
  if (!clean) return false;
  return mutateDeviceRecord(devicesDir, deviceId, (cur) => ({
    data: { ...cur, label: clean },
    value: true,
  })) === true;
}

/**
 * Throttled, best-effort update of last_seen_at for an authenticated bearer.
 * Observational metadata only — never affects auth/scope and never throws.
 */
export function touchDeviceLastSeen(devicesDir, token, nowMs = Date.now()) {
  try {
    const found = findDeviceByToken(devicesDir, token);
    if (!found || found.data.revoked) return;
    const last = found.data.last_seen_at ? new Date(found.data.last_seen_at).getTime() : 0;
    if (nowMs - last < LAST_SEEN_THROTTLE_MS) return;
    mutateDeviceRecord(devicesDir, found.deviceId, (cur) => {
      if (!tokenMatches(cur, token)) return null;
      return { data: { ...cur, last_seen_at: new Date(nowMs).toISOString() }, value: true };
    });
  } catch { /* best-effort */ }
}

/**
 * List registered device tokens (not pairing tokens) for the management UI.
 * Returns a summary per device — never the token or its hash.
 * Sorted newest-first by created_at.
 */
export function listDevices(devicesDir, nowMs = Date.now()) {
  if (!existsSync(devicesDir)) return [];
  const devices = [];
  for (const filename of jsonFiles(devicesDir)) {
    if (filename.startsWith('pairing-') || !DEVICE_ID_PATTERN.test(filename)) continue;
    const data = readJson(join(devicesDir, filename));
    if (!data) continue;
    const expiresMs = new Date(data.expires_at).getTime();
    const expired = nowMs >= expiresMs;
    const active = !data.revoked && !expired;
    devices.push({
      device_id: data.device_id,
      label: data.label || defaultLabel(data.device_id),
      created_at: data.created_at,
      expires_at: data.expires_at,
      revoked: Boolean(data.revoked),
      revoked_at: data.revoked_at || null,
      expired,
      active,
      last_seen_at: data.last_seen_at || null,
      last_renewed_at: data.last_renewed_at || null,
      renew_count: data.renew_count || 0,
      renewable: active && (expiresMs - nowMs <= RENEWAL_WINDOW_MS),
    });
  }
  devices.sort((a, b) => new Date(b.created_at).getTime() - new Date(a.created_at).getTime());
  return devices;
}

// ── Device limit policy (ADR-0033) ─────────────────────

export const DEFAULT_MAX_DEVICES = 10;

/**
 * Resolve the max active-device limit from env (MISSION_CONTROL_MAX_DEVICES).
 * Invalid / non-positive values fall back to the default. The limit is an
 * issuance hygiene bound, never an auth/scope decision.
 */
export function resolveMaxDevices(env = process.env) {
  const raw = env?.MISSION_CONTROL_MAX_DEVICES;
  if (raw === undefined || raw === null || String(raw).trim() === '') return DEFAULT_MAX_DEVICES;
  const n = Number.parseInt(String(raw), 10);
  return Number.isInteger(n) && n > 0 ? n : DEFAULT_MAX_DEVICES;
}

/**
 * Count currently-active devices (!revoked && !expired). Revoked/expired
 * devices free their slot automatically.
 */
export function countActiveDevices(devicesDir, nowMs = Date.now()) {
  return listDevices(devicesDir, nowMs).filter(d => d.active).length;
}

// ── Localhost detection ────────────────────────────────

/**
 * Returns true if the given remote address is a loopback address.
 * Handles IPv4, IPv6, and IPv4-mapped IPv6 (::ffff:127.0.0.1).
 */
export function isLocalhostAddress(addr) {
  if (!addr) return false;
  const normalized = String(addr).replace(/^::ffff:/i, '');
  return normalized === '127.0.0.1' || normalized === '::1';
}
