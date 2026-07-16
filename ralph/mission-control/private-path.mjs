import { execFileSync } from 'node:child_process';
import { networkInterfaces as osNetworkInterfaces } from 'node:os';

const LOCALHOST_BINDING = Object.freeze({ host: '127.0.0.1', label: 'localhost' });
const UNSAFE_PRIVATE_PATH_TARGETS = new Set(['0.0.0.0', '::']);

function privatePathError(message) {
  const error = new Error(message);
  error.name = 'PrivatePathError';
  return error;
}

function normalizePrivatePath(value) {
  if (value === null || value === undefined) return null;
  const privatePath = String(value).trim();
  if (!privatePath) throw privatePathError('private path interface is required');
  return privatePath;
}

function isUsableInterfaceAddress(entry) {
  if (!entry || entry.internal || !entry.address) return false;
  const family = entry.family;
  return family === 'IPv4' || family === 4 || family === 'IPv6' || family === 6;
}

function isIpv4Address(entry) {
  return entry.family === 'IPv4' || entry.family === 4;
}

function runRouteCommand(command, args) {
  try {
    return execFileSync(command, args, {
      encoding: 'utf8',
      stdio: ['ignore', 'pipe', 'ignore'],
      timeout: 1000,
    });
  } catch {
    return '';
  }
}

function parseDefaultGatewayFromNetstat(output) {
  for (const line of output.split('\n')) {
    const fields = line.trim().split(/\s+/);
    if (fields.length < 4) continue;
    if (fields[0] === 'default') return fields[fields.length - 1];
    if (fields[0] === '0.0.0.0' && fields.length >= 8) return fields[7];
  }
  return null;
}

export function detectDefaultGatewayInterface() {
  const routeOutput = runRouteCommand('route', ['-n', 'get', 'default']);
  const routeMatch = routeOutput.match(/^\s*interface:\s*(\S+)/m);
  if (routeMatch) return routeMatch[1];

  const ipOutput = runRouteCommand('ip', ['route', 'show', 'default']);
  const ipMatch = ipOutput.match(/(?:^|\s)dev\s+(\S+)/);
  if (ipMatch) return ipMatch[1];

  return parseDefaultGatewayFromNetstat(runRouteCommand('netstat', ['-rn']));
}

export function resolvePrivatePathBindings(privatePathValue, options = {}) {
  const privatePath = normalizePrivatePath(privatePathValue);
  const bindings = [LOCALHOST_BINDING];
  if (!privatePath) return bindings;

  if (UNSAFE_PRIVATE_PATH_TARGETS.has(privatePath)) {
    throw privatePathError(`refusing unsafe private path target: ${privatePath}`);
  }

  const defaultGatewayInterface = options.defaultGatewayInterface ?? detectDefaultGatewayInterface;
  const gatewayInterface = defaultGatewayInterface();
  if (gatewayInterface && privatePath === gatewayInterface) {
    throw privatePathError(`refusing default gateway interface: ${privatePath}`);
  }

  const getNetworkInterfaces = options.networkInterfaces ?? osNetworkInterfaces;
  const interfaceEntries = getNetworkInterfaces()[privatePath];
  if (!Array.isArray(interfaceEntries) || interfaceEntries.length === 0) {
    throw privatePathError(`private path interface not found: ${privatePath}`);
  }

  const usableEntries = interfaceEntries.filter(isUsableInterfaceAddress);
  const entry = usableEntries.find(isIpv4Address) ?? usableEntries[0];
  if (!entry) {
    throw privatePathError(`private path interface has no usable non-local address: ${privatePath}`);
  }
  if (UNSAFE_PRIVATE_PATH_TARGETS.has(entry.address)) {
    throw privatePathError(`refusing unsafe private path address: ${entry.address}`);
  }

  return [...bindings, { host: entry.address, label: privatePath }];
}
