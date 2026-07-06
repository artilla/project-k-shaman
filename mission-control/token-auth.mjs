import { isLocalhostAddress, validateDeviceToken } from './token-store.mjs';

// ADR-0029 §3.2: minimal pre-auth bootstrap surface. None of these serve
// sensitive data — the pairing page (token arrives via URL fragment, never the
// server) and the static service-worker script the browser must fetch during
// registration (no Authorization header is possible on SW registration).
const TOKEN_AUTH_EXEMPT = new Set([
  'POST /api/tokens/exchange',
  'GET /pair',
  'GET /sw.js',
]);

// ADR-0027 §2.1-5: only 'approve' is permitted for non-localhost exec connections.
const NON_LOCALHOST_EXEC_ALLOW = new Set(['approve']);

export function extractBearerToken(headers = {}) {
  const auth = headers.authorization || headers.Authorization || '';
  return typeof auth === 'string' && auth.startsWith('Bearer ') ? auth.slice(7).trim() : '';
}

export function requiresTokenAuth(method, path) {
  return !TOKEN_AUTH_EXEMPT.has(`${method} ${path}`);
}

export function tokenAuthDecision({ devicesDir, method, path, remoteAddress, headers = {}, nowMs = Date.now() }) {
  if (isLocalhostAddress(remoteAddress) || !requiresTokenAuth(method, path)) {
    return { ok: true };
  }

  if (!validateDeviceToken(devicesDir, extractBearerToken(headers), nowMs)) {
    return { ok: false, status: 401, body: { error: 'Unauthorized' } };
  }

  return { ok: true };
}

/**
 * ADR-0027 §2.1-5: exec scope guard for non-localhost connections.
 * Non-localhost connections only have approve scope; session_ctl and run_loop
 * are restricted to localhost. Uses socket peer address (not headers) to
 * prevent X-Forwarded-For spoofing.
 */
export function execScopeDecision({ remoteAddress, command }) {
  if (isLocalhostAddress(remoteAddress)) return { ok: true };
  if (NON_LOCALHOST_EXEC_ALLOW.has(String(command || ''))) return { ok: true };
  return { ok: false, status: 403, body: { error: 'exec scope denied: approve only for non-localhost' } };
}
