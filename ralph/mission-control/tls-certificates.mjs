import { existsSync, readFileSync } from 'node:fs';
import { isAbsolute, join, resolve } from 'node:path';

const EXPLICIT_SOURCES = Object.freeze([
  {
    name: 'tunnel-env',
    certEnv: 'MISSION_CONTROL_TUNNEL_CERT_FILE',
    keyEnv: 'MISSION_CONTROL_TUNNEL_KEY_FILE',
  },
  {
    name: 'tls-env',
    certEnv: 'MISSION_CONTROL_TLS_CERT_FILE',
    keyEnv: 'MISSION_CONTROL_TLS_KEY_FILE',
  },
  {
    name: 'mkcert-env',
    certEnv: 'MISSION_CONTROL_MKCERT_CERT_FILE',
    keyEnv: 'MISSION_CONTROL_MKCERT_KEY_FILE',
  },
]);

const CONVENTIONAL_SOURCES = Object.freeze([
  { name: 'tunnel', cert: ['state', 'certs', 'tunnel.crt'], key: ['state', 'certs', 'tunnel.key'] },
  { name: 'tailscale', cert: ['state', 'certs', 'tailscale.crt'], key: ['state', 'certs', 'tailscale.key'] },
  { name: 'mkcert', cert: ['state', 'certs', 'mkcert.crt'], key: ['state', 'certs', 'mkcert.key'] },
  { name: 'mkcert-pem', cert: ['state', 'certs', 'mkcert.pem'], key: ['state', 'certs', 'mkcert-key.pem'] },
]);

export class TlsCertificateError extends Error {
  constructor(message) {
    super(message);
    this.name = 'TlsCertificateError';
  }
}

function pathFromRoot(root, value) {
  if (!value) return null;
  return isAbsolute(value) ? value : resolve(root, value);
}

function fileExists(path) {
  return Boolean(path) && existsSync(path);
}

function explicitCandidate(root, env, source) {
  const certFile = pathFromRoot(root, env[source.certEnv]);
  const keyFile = pathFromRoot(root, env[source.keyEnv]);
  if (!certFile && !keyFile) return null;
  if (!certFile || !keyFile) {
    throw new TlsCertificateError(
      `${source.certEnv} and ${source.keyEnv} must be set together for --private-path TLS`
    );
  }
  if (!fileExists(certFile) || !fileExists(keyFile)) {
    throw new TlsCertificateError(
      `TLS certificate source ${source.name} is configured but files are missing: ${certFile}, ${keyFile}`
    );
  }
  return { source: source.name, certFile, keyFile };
}

function conventionalCandidate(root, source) {
  const certFile = join(root, ...source.cert);
  const keyFile = join(root, ...source.key);
  if (!fileExists(certFile) || !fileExists(keyFile)) return null;
  return { source: source.name, certFile, keyFile };
}

export function resolvePrivatePathTlsCandidate(root, env = process.env) {
  for (const source of EXPLICIT_SOURCES) {
    const candidate = explicitCandidate(root, env, source);
    if (candidate) return candidate;
  }
  for (const source of CONVENTIONAL_SOURCES) {
    const candidate = conventionalCandidate(root, source);
    if (candidate) return candidate;
  }
  return null;
}

export function loadPrivatePathTlsOptions(root, env = process.env) {
  const candidate = resolvePrivatePathTlsCandidate(root, env);
  if (!candidate) {
    throw new TlsCertificateError(
      '--private-path requires TLS certificate files; set MISSION_CONTROL_TUNNEL_CERT_FILE/MISSION_CONTROL_TUNNEL_KEY_FILE, set MISSION_CONTROL_MKCERT_CERT_FILE/MISSION_CONTROL_MKCERT_KEY_FILE, or place a pair under state/certs/'
    );
  }
  return {
    key: readFileSync(candidate.keyFile),
    cert: readFileSync(candidate.certFile),
    source: candidate.source,
    certFile: candidate.certFile,
    keyFile: candidate.keyFile,
  };
}

export function schemeForBinding(binding) {
  return binding?.label === 'localhost' ? 'http' : 'https';
}
