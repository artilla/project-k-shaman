// usage_capture.mjs — ADR-0050 토큰 텔레메트리 stream-json 필터.
//
// Claude CLI `--output-format stream-json` NDJSON을 stdin으로 읽어:
//   - assistant 텍스트는 stdout으로 그대로 흘려보내 로그가 사람이 읽을 수 있게 유지하고
//   - 최종 usage(input/output/cache 토큰)를 token_usage.log에 한 줄(TSV) append한다.
// 항상 exit 0 (fail-closed): 파싱 문제로 루프(claude exit code 전파)를 깨지 않는다.
//
// 사용: node usage_capture.mjs <logPath> <ticketId> <model>
import { appendFileSync } from 'node:fs';

const [logPath = '', ticket = '', model = ''] = process.argv.slice(2);
let buf = '';
let usage = null;

function handle(line) {
  const s = line.trim();
  if (!s) return;
  let ev;
  try { ev = JSON.parse(s); } catch { process.stdout.write(line + '\n'); return; }
  try {
    // 사람이 읽을 assistant 텍스트만 stdout으로
    if (ev.type === 'assistant' && ev.message && Array.isArray(ev.message.content)) {
      for (const c of ev.message.content) if (c && c.type === 'text' && c.text) process.stdout.write(c.text);
    } else if (ev.type === 'text' && typeof ev.text === 'string') {
      process.stdout.write(ev.text);
    }
    // 최종 usage 캡처 (result 이벤트 우선; usage 필드를 가진 마지막 이벤트)
    const u = (ev.type === 'result' && ev.usage) ? ev.usage
            : (ev.usage && (ev.usage.input_tokens != null || ev.usage.output_tokens != null)) ? ev.usage
            : null;
    if (u) usage = u;
  } catch { /* ignore malformed event, never throw */ }
}

function finish() {
  if (usage && logPath) {
    const row = [
      new Date().toISOString(),
      ticket || '-',
      model || '-',
      usage.input_tokens ?? 0,
      usage.output_tokens ?? 0,
      usage.cache_read_input_tokens ?? 0,
      usage.cache_creation_input_tokens ?? 0,
    ].join('\t');
    try { appendFileSync(logPath, row + '\n'); } catch { /* fail-closed */ }
  }
  process.exit(0);
}

process.stdin.setEncoding('utf8');
process.stdin.on('data', d => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) { handle(buf.slice(0, i)); buf = buf.slice(i + 1); }
});
process.stdin.on('end', () => { if (buf) handle(buf); finish(); });
process.stdin.on('error', () => finish());
