// qr.mjs — 의존성 0 QR 코드 인코더 (byte mode) → 모듈 매트릭스 / 인라인 SVG.
//
// T100 모바일 페어링 UI용. 외부 라이브러리/네트워크 없이 동작한다 (R5 외부 의존 금지·
// PWA 오프라인 원칙 일치). 페어링 URL(~110 byte 이하)을 충분히 담는 version 1~10,
// byte mode, ECC L/M/Q/H, 표준 마스크 패널티 선택을 구현한다.
//
// 표준: ISO/IEC 18004. 출력 매트릭스는 reference QR 라이브러리(qrcode)의 매트릭스와
// 정확히 일치하도록 검증되었다 (qr.test.mjs의 golden 벡터).

// ── Galois Field GF(256), primitive 0x11d ────────────────────────────────────
const GF_EXP = new Uint8Array(512);
const GF_LOG = new Uint8Array(256);
(function initGalois() {
  let x = 1;
  for (let i = 0; i < 255; i++) {
    GF_EXP[i] = x;
    GF_LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) GF_EXP[i] = GF_EXP[i - 255];
})();

function gfMul(a, b) {
  if (a === 0 || b === 0) return 0;
  return GF_EXP[GF_LOG[a] + GF_LOG[b]];
}

// Reed–Solomon generator polynomial of given degree.
function rsGeneratorPoly(degree) {
  let poly = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(poly.length + 1).fill(0);
    for (let j = 0; j < poly.length; j++) {
      next[j] ^= poly[j];
      next[j + 1] ^= gfMul(poly[j], GF_EXP[i]);
    }
    poly = next;
  }
  return poly;
}

function rsEncode(data, ecLen) {
  const gen = rsGeneratorPoly(ecLen);
  const res = new Array(ecLen).fill(0);
  for (const byte of data) {
    const factor = byte ^ res[0];
    res.shift();
    res.push(0);
    for (let i = 0; i < ecLen; i++) res[i] ^= gfMul(gen[i + 1], factor);
  }
  return res;
}

// ── EC block table (version 1..10, level L/M/Q/H) ────────────────────────────
// [ecCodewordsPerBlock, [numBlocks, dataCodewords] groups...]
const EC_BLOCKS = {
  L: [
    [7, [1, 19]], [10, [1, 34]], [15, [1, 55]], [20, [1, 80]], [26, [1, 108]],
    [18, [2, 68]], [20, [2, 78]], [24, [2, 97]], [30, [2, 116]], [18, [2, 68], [2, 69]],
  ],
  M: [
    [10, [1, 16]], [16, [1, 28]], [26, [1, 44]], [18, [2, 32]], [24, [2, 43]],
    [16, [4, 27]], [18, [4, 31]], [22, [2, 38], [2, 39]], [22, [3, 36], [2, 37]], [26, [4, 43], [1, 44]],
  ],
  Q: [
    [13, [1, 13]], [22, [1, 22]], [18, [2, 17]], [26, [2, 24]], [18, [2, 15], [2, 16]],
    [24, [4, 19]], [18, [2, 14], [4, 15]], [22, [4, 18], [2, 19]], [20, [4, 16], [4, 17]], [24, [6, 19], [2, 20]],
  ],
  H: [
    [17, [1, 9]], [28, [1, 16]], [22, [2, 13]], [16, [4, 9]], [22, [2, 11], [2, 12]],
    [28, [4, 15]], [26, [4, 13], [1, 14]], [26, [4, 14], [2, 15]], [24, [4, 12], [4, 13]], [28, [6, 15], [2, 16]],
  ],
};

const ALIGNMENT_CENTERS = {
  1: [], 2: [6, 18], 3: [6, 22], 4: [6, 26], 5: [6, 30],
  6: [6, 34], 7: [6, 22, 38], 8: [6, 24, 42], 9: [6, 26, 46], 10: [6, 28, 50],
};

const ECL_BITS = { L: 0b01, M: 0b00, Q: 0b11, H: 0b10 };

function blockGroups(version, ecl) {
  const entry = EC_BLOCKS[ecl][version - 1];
  const ecLen = entry[0];
  const groups = entry.slice(1);
  let numBlocks = 0;
  let dataCodewords = 0;
  const blocks = [];
  for (const [count, dataLen] of groups) {
    for (let i = 0; i < count; i++) blocks.push(dataLen);
    numBlocks += count;
    dataCodewords += count * dataLen;
  }
  return { ecLen, numBlocks, dataCodewords, blocks };
}

function charCountBits(version) {
  return version <= 9 ? 8 : 16; // byte mode
}

// Smallest version (1..10) whose data capacity fits `byteLen` at level `ecl`.
function pickVersion(byteLen, ecl) {
  for (let v = 1; v <= 10; v++) {
    const { dataCodewords } = blockGroups(v, ecl);
    const headerBits = 4 + charCountBits(v);
    const needBits = headerBits + byteLen * 8;
    if (needBits <= dataCodewords * 8) return v;
  }
  throw new Error(`data too long for QR version<=10 at ECC ${ecl}: ${byteLen} bytes`);
}

// ── Bit buffer ───────────────────────────────────────────────────────────────
class BitBuffer {
  constructor() { this.bits = []; }
  put(value, length) {
    for (let i = length - 1; i >= 0; i--) this.bits.push((value >>> i) & 1);
  }
  get length() { return this.bits.length; }
}

function encodeData(bytes, version, ecl) {
  const { dataCodewords } = blockGroups(version, ecl);
  const totalBits = dataCodewords * 8;
  const bb = new BitBuffer();
  bb.put(0b0100, 4);                       // byte mode
  bb.put(bytes.length, charCountBits(version));
  for (const b of bytes) bb.put(b, 8);
  // terminator (up to 4 bits)
  const remain = totalBits - bb.length;
  bb.put(0, Math.min(4, remain));
  // pad to byte boundary
  while (bb.length % 8 !== 0) bb.bits.push(0);
  // pad bytes 0xEC, 0x11
  const codewords = [];
  for (let i = 0; i < bb.bits.length; i += 8) {
    let v = 0;
    for (let j = 0; j < 8; j++) v = (v << 1) | bb.bits[i + j];
    codewords.push(v);
  }
  const pads = [0xec, 0x11];
  let p = 0;
  while (codewords.length < dataCodewords) codewords.push(pads[p++ % 2]);
  return codewords;
}

// Split into blocks, RS-encode, interleave data then EC codewords.
function buildCodewords(dataCodewords, version, ecl) {
  const { ecLen, blocks } = blockGroups(version, ecl);
  const dataBlocks = [];
  const ecBlocks = [];
  let offset = 0;
  for (const dataLen of blocks) {
    const block = dataCodewords.slice(offset, offset + dataLen);
    offset += dataLen;
    dataBlocks.push(block);
    ecBlocks.push(rsEncode(block, ecLen));
  }
  const result = [];
  const maxData = Math.max(...dataBlocks.map(b => b.length));
  for (let i = 0; i < maxData; i++) {
    for (const block of dataBlocks) if (i < block.length) result.push(block[i]);
  }
  for (let i = 0; i < ecLen; i++) {
    for (const block of ecBlocks) result.push(block[i]);
  }
  return result;
}

// ── Matrix construction ──────────────────────────────────────────────────────
function makeMatrix(size) {
  const modules = Array.from({ length: size }, () => new Array(size).fill(null));
  return modules;
}

function placeFinder(m, row, col) {
  for (let r = -1; r <= 7; r++) {
    for (let c = -1; c <= 7; c++) {
      const rr = row + r;
      const cc = col + c;
      if (rr < 0 || rr >= m.length || cc < 0 || cc >= m.length) continue;
      const inRing = (r >= 0 && r <= 6 && (c === 0 || c === 6)) ||
                     (c >= 0 && c <= 6 && (r === 0 || r === 6));
      const inCore = r >= 2 && r <= 4 && c >= 2 && c <= 4;
      m[rr][cc] = inRing || inCore;
    }
  }
}

function placeFunctionPatterns(m, version) {
  const size = m.length;
  placeFinder(m, 0, 0);
  placeFinder(m, 0, size - 7);
  placeFinder(m, size - 7, 0);
  // timing patterns
  for (let i = 8; i < size - 8; i++) {
    const v = i % 2 === 0;
    if (m[6][i] === null) m[6][i] = v;
    if (m[i][6] === null) m[i][6] = v;
  }
  // alignment patterns
  const centers = ALIGNMENT_CENTERS[version];
  for (const r of centers) {
    for (const c of centers) {
      // skip those overlapping finder patterns
      if ((r === 6 && c === 6) || (r === 6 && c === size - 7) || (r === size - 7 && c === 6)) continue;
      for (let dr = -2; dr <= 2; dr++) {
        for (let dc = -2; dc <= 2; dc++) {
          const isDark = Math.max(Math.abs(dr), Math.abs(dc)) !== 1;
          m[r + dr][c + dc] = isDark;
        }
      }
    }
  }
  // dark module
  m[size - 8][8] = true;
  // reserve format info areas (set to false placeholder; filled later)
  reserveFormatAreas(m);
  if (version >= 7) reserveVersionAreas(m);
}

function reserveFormatAreas(m) {
  const size = m.length;
  for (let i = 0; i < 9; i++) {
    if (m[8][i] === null) m[8][i] = false;
    if (m[i][8] === null) m[i][8] = false;
  }
  for (let i = 0; i < 8; i++) {
    if (m[8][size - 1 - i] === null) m[8][size - 1 - i] = false;
    if (m[size - 1 - i][8] === null) m[size - 1 - i][8] = false;
  }
}

function reserveVersionAreas(m) {
  const size = m.length;
  for (let i = 0; i < 6; i++) {
    for (let j = 0; j < 3; j++) {
      m[i][size - 11 + j] = false;
      m[size - 11 + j][i] = false;
    }
  }
}

function isFunctionModule(m, version, row, col) {
  // Build a parallel reserved-mask via a fresh function matrix is costly; instead
  // we track function modules by re-deriving. Here we mark using a separate matrix.
  return functionMask[row][col];
}

let functionMask = null;

function buildFunctionMask(version, size) {
  const fm = Array.from({ length: size }, () => new Array(size).fill(false));
  const mark = (r, c) => { if (r >= 0 && c >= 0 && r < size && c < size) fm[r][c] = true; };
  const markFinder = (row, col) => {
    for (let r = -1; r <= 7; r++) for (let c = -1; c <= 7; c++) mark(row + r, col + c);
  };
  markFinder(0, 0);
  markFinder(0, size - 7);
  markFinder(size - 7, 0);
  for (let i = 0; i < size; i++) { mark(6, i); mark(i, 6); }
  const centers = ALIGNMENT_CENTERS[version];
  for (const r of centers) for (const c of centers) {
    if ((r === 6 && c === 6) || (r === 6 && c === size - 7) || (r === size - 7 && c === 6)) continue;
    for (let dr = -2; dr <= 2; dr++) for (let dc = -2; dc <= 2; dc++) mark(r + dr, c + dc);
  }
  mark(size - 8, 8);
  for (let i = 0; i < 9; i++) { mark(8, i); mark(i, 8); }
  for (let i = 0; i < 8; i++) { mark(8, size - 1 - i); mark(size - 1 - i, 8); }
  if (version >= 7) {
    for (let i = 0; i < 6; i++) for (let j = 0; j < 3; j++) {
      mark(i, size - 11 + j); mark(size - 11 + j, i);
    }
  }
  return fm;
}

function placeData(m, codewords, version) {
  const size = m.length;
  const bits = [];
  for (const cw of codewords) for (let i = 7; i >= 0; i--) bits.push((cw >> i) & 1);
  let bitIdx = 0;
  let upward = true;
  for (let col = size - 1; col > 0; col -= 2) {
    if (col === 6) col = 5; // skip timing column
    for (let i = 0; i < size; i++) {
      const row = upward ? size - 1 - i : i;
      for (let c = 0; c < 2; c++) {
        const cc = col - c;
        if (functionMask[row][cc]) continue;
        m[row][cc] = bitIdx < bits.length ? bits[bitIdx] === 1 : false;
        bitIdx++;
      }
    }
    upward = !upward;
  }
}

function maskFn(pattern, i, j) {
  switch (pattern) {
    case 0: return (i + j) % 2 === 0;
    case 1: return i % 2 === 0;
    case 2: return j % 3 === 0;
    case 3: return (i + j) % 3 === 0;
    case 4: return (Math.floor(i / 2) + Math.floor(j / 3)) % 2 === 0;
    case 5: return ((i * j) % 2) + ((i * j) % 3) === 0;
    case 6: return (((i * j) % 2) + ((i * j) % 3)) % 2 === 0;
    case 7: return (((i + j) % 2) + ((i * j) % 3)) % 2 === 0;
    default: return false;
  }
}

function applyMask(m, pattern) {
  const size = m.length;
  const out = m.map(row => row.slice());
  for (let i = 0; i < size; i++) {
    for (let j = 0; j < size; j++) {
      if (functionMask[i][j]) continue;
      if (maskFn(pattern, i, j)) out[i][j] = !out[i][j];
    }
  }
  return out;
}

// BCH(15,5) format info.
function formatBits(ecl, mask) {
  const data = (ECL_BITS[ecl] << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >> 9) & 1 ? 0b10100110111 : 0);
  const bits = ((data << 10) | (rem & 0x3ff)) ^ 0b101010000010010;
  return bits & 0x7fff;
}

function placeFormat(m, ecl, mask) {
  const size = m.length;
  const bits = formatBits(ecl, mask);
  for (let i = 0; i < 15; i++) {
    const bit = ((bits >> i) & 1) === 1;
    // vertical strip (column 8), skipping the timing row at index 6
    if (i < 6) m[i][8] = bit;
    else if (i < 8) m[i + 1][8] = bit;
    else m[size - 15 + i][8] = bit;
    // horizontal strip (row 8), skipping the timing column at index 6
    if (i < 8) m[8][size - 1 - i] = bit;
    else if (i < 9) m[8][7] = bit;
    else m[8][14 - i] = bit;
  }
  m[size - 8][8] = true; // dark module
}

function versionBits(version) {
  let rem = version;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >> 11) & 1 ? 0b1111100100101 : 0);
  return (version << 12) | (rem & 0xfff);
}

function placeVersion(m, version) {
  if (version < 7) return;
  const size = m.length;
  const bits = versionBits(version);
  for (let i = 0; i < 18; i++) {
    const bit = ((bits >> i) & 1) === 1;
    const a = Math.floor(i / 3);
    const b = i % 3;
    m[a][size - 11 + b] = bit;
    m[size - 11 + b][a] = bit;
  }
}

// Standard mask penalty.
function penalty(m) {
  const size = m.length;
  let score = 0;
  // Rule 1: runs of >=5 in rows and columns
  for (let i = 0; i < size; i++) {
    let runR = 1, runC = 1;
    for (let j = 1; j < size; j++) {
      if (m[i][j] === m[i][j - 1]) { runR++; } else { if (runR >= 5) score += 3 + (runR - 5); runR = 1; }
      if (m[j][i] === m[j - 1][i]) { runC++; } else { if (runC >= 5) score += 3 + (runC - 5); runC = 1; }
    }
    if (runR >= 5) score += 3 + (runR - 5);
    if (runC >= 5) score += 3 + (runC - 5);
  }
  // Rule 2: 2x2 blocks
  for (let i = 0; i < size - 1; i++) {
    for (let j = 0; j < size - 1; j++) {
      const v = m[i][j];
      if (v === m[i][j + 1] && v === m[i + 1][j] && v === m[i + 1][j + 1]) score += 3;
    }
  }
  // Rule 3: finder-like 1011101 0000 patterns
  const pat1 = [true, false, true, true, true, false, true, false, false, false, false];
  const pat2 = [false, false, false, false, true, false, true, true, true, false, true];
  const matches = (arr, k, pat) => pat.every((p, idx) => arr[k + idx] === p);
  for (let i = 0; i < size; i++) {
    for (let j = 0; j <= size - 11; j++) {
      const rowArr = m[i];
      if (matches(rowArr, j, pat1) || matches(rowArr, j, pat2)) score += 40;
      const colArr = m.map(r => r[i]);
      if (matches(colArr, j, pat1) || matches(colArr, j, pat2)) score += 40;
    }
  }
  // Rule 4: dark proportion
  let dark = 0;
  for (let i = 0; i < size; i++) for (let j = 0; j < size; j++) if (m[i][j]) dark++;
  const ratio = (dark * 100) / (size * size);
  const k = Math.floor(Math.abs(ratio - 50) / 5);
  score += k * 10;
  return score;
}

// ── Public API ───────────────────────────────────────────────────────────────
/**
 * Encode text into a QR module matrix.
 * @returns { version, size, modules: boolean[][], mask }
 */
export function encodeToMatrix(text, options = {}) {
  const ecl = options.ecl || 'M';
  if (!ECL_BITS.hasOwnProperty(ecl)) throw new Error(`unknown ECC level: ${ecl}`);
  const bytes = [...new TextEncoder().encode(String(text))];
  const version = options.version || pickVersion(bytes.length, ecl);
  const size = version * 4 + 17;

  const dataCw = encodeData(bytes, version, ecl);
  const allCw = buildCodewords(dataCw, version, ecl);

  functionMask = buildFunctionMask(version, size);
  const base = makeMatrix(size);
  placeFunctionPatterns(base, version);
  placeData(base, allCw, version);

  const candidateMasks = Number.isInteger(options.mask) ? [options.mask] : [0, 1, 2, 3, 4, 5, 6, 7];
  let best = null;
  for (const mask of candidateMasks) {
    const masked = applyMask(base, mask);
    placeFormat(masked, ecl, mask);
    placeVersion(masked, version);
    const score = penalty(masked);
    if (best === null || score < best.score) best = { score, mask, modules: masked };
  }
  return { version, size, modules: best.modules.map(r => r.map(Boolean)), mask: best.mask };
}

/**
 * Render text as a self-contained inline SVG QR code.
 * @param {string} text
 * @param {object} options { ecl, moduleSize, margin, title }
 */
export function toSvg(text, options = {}) {
  const { modules, size } = encodeToMatrix(text, options);
  const moduleSize = options.moduleSize || 6;
  const margin = options.margin ?? 4;
  const dim = (size + margin * 2) * moduleSize;
  const title = options.title || 'Pairing QR code';
  let rects = '';
  for (let r = 0; r < size; r++) {
    for (let c = 0; c < size; c++) {
      if (modules[r][c]) {
        const x = (c + margin) * moduleSize;
        const y = (r + margin) * moduleSize;
        rects += `<rect x="${x}" y="${y}" width="${moduleSize}" height="${moduleSize}"/>`;
      }
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" width="${dim}" height="${dim}" viewBox="0 0 ${dim} ${dim}" role="img" aria-label="${title}"><rect width="${dim}" height="${dim}" fill="#ffffff"/><g fill="#000000">${rects}</g></svg>`;
}
