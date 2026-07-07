// heartbeat_capture.mjs — T305 스트림 하트비트 필터.
//
// Claude CLI `--output-format stream-json --verbose` NDJSON을 stdin으로 읽어
// bash-watchdog idle 워치독이 관찰하는 output_file에 사람이 읽을 로그로 변환한다:
//   - assistant 텍스트는 그대로 stdout으로 흘려 최종 응답 가독성을 유지한다(기존 계약).
//   - 텍스트가 없는 이벤트(tool_use/tool_result/system/result 등)는 짧은 `[hb] ...` 한
//     줄을 stdout에 남긴다 — claude -p가 도구 호출 중 최종 출력만 버퍼링해도 output_file
//     바이트가 흘러 idle 워치독의 "output 없음" 오탐(§2, T017/T018)을 막는다.
// 파싱 실패 줄(NDJSON이 아닌 일반 텍스트 포함)은 그대로 통과시켜 stream-json을 모르는
// 호출자(테스트 더블 등)와의 호환성을 유지한다. 항상 exit 0 (fail-closed) — claude의
// 종료 코드 전파를 이 필터가 깨지 않는다.
//
// 사용: node heartbeat_capture.mjs

function toolNames(content) {
  return content
    .filter(c => c && c.type === 'tool_use')
    .map(c => c.name || 'tool');
}

function toolResultCount(content) {
  return content.filter(c => c && c.type === 'tool_result').length;
}

function heartbeatFor(ev) {
  if (ev.type === 'assistant' && ev.message && Array.isArray(ev.message.content)) {
    const tools = toolNames(ev.message.content);
    if (tools.length) return `[hb] tool_use:${tools.join(',')}`;
    return `[hb] assistant`;
  }
  if (ev.type === 'user' && ev.message && Array.isArray(ev.message.content)) {
    const n = toolResultCount(ev.message.content);
    if (n) return `[hb] tool_result:${n}`;
    return `[hb] user`;
  }
  if (ev.type === 'system') return `[hb] system:${ev.subtype || 'init'}`;
  if (ev.type === 'result') return `[hb] result`;
  return `[hb] ${ev.type || 'event'}`;
}

function handle(line) {
  const s = line.trim();
  if (!s) return;
  let ev;
  try { ev = JSON.parse(s); } catch { process.stdout.write(line + '\n'); return; }
  try {
    let wroteText = false;
    if (ev.type === 'assistant' && ev.message && Array.isArray(ev.message.content)) {
      for (const c of ev.message.content) {
        if (c && c.type === 'text' && c.text) { process.stdout.write(c.text); wroteText = true; }
      }
    } else if (ev.type === 'text' && typeof ev.text === 'string') {
      process.stdout.write(ev.text);
      wroteText = true;
    }
    if (!wroteText) process.stdout.write(heartbeatFor(ev) + '\n');
  } catch { /* malformed event — never throw, no output for this line */ }
}

let buf = '';
process.stdin.setEncoding('utf8');
process.stdin.on('data', d => {
  buf += d;
  let i;
  while ((i = buf.indexOf('\n')) >= 0) { handle(buf.slice(0, i)); buf = buf.slice(i + 1); }
});
process.stdin.on('end', () => { if (buf) handle(buf); process.exit(0); });
process.stdin.on('error', () => process.exit(0));
