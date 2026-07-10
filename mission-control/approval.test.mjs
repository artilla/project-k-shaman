// mission-control/approval.test.mjs — 리뷰 2차 P1-7: 승인 마커 단일 검증기 회귀 테스트.
// 실행: node --test mission-control/approval.test.mjs (run_checks.sh가 자동 포함)

import { test } from 'node:test';
import assert from 'node:assert/strict';
import { mkdtempSync, mkdirSync, writeFileSync, rmSync, readFileSync, symlinkSync, linkSync } from 'node:fs';
import { join } from 'node:path';
import { tmpdir } from 'node:os';
import { execFileSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

import { validateApproval, parseMarker, extractSection, yamlEscapeCut } from './approval.mjs';

const VALIDATOR = fileURLToPath(new URL('./approval.mjs', import.meta.url));

function makeRoot() {
  const root = mkdtempSync(join(tmpdir(), 'approval-test-'));
  mkdirSync(join(root, 'docs', 'approvals'), { recursive: true });
  mkdirSync(join(root, 'docs', 'tickets', 'DONE'), { recursive: true });
  return root;
}

function writeTicket(root, id, scopeLine) {
  const body = scopeLine == null
    ? `---\nid: ${id}\nstatus: awaiting-approval\nsafe: false\n---\n\n# ${id}\n`
    : `---\nid: ${id}\nstatus: awaiting-approval\nsafe: false\n---\n\n# ${id}\n\n## 변경 범위\n\n- ${scopeLine}\n`;
  writeFileSync(join(root, 'docs', 'tickets', `${id}-test.md`), body);
}

function writeMarker(root, id, { by = 'Tester', at = '2026-07-10T10:00:00+09:00', scope = 'S', rollback = 'git revert HEAD' } = {}) {
  writeFileSync(
    join(root, 'docs', 'approvals', `${id}.md`),
    `approved_by: "${by}"\napproved_at: "${at}"\nscope_confirmation: "${scope}"\nrollback_plan: "${rollback}"\n`
  );
}

function cli(root, id) {
  try {
    const stdout = execFileSync(process.execPath, [VALIDATOR, root, id], { encoding: 'utf8' });
    return { code: 0, stdout: stdout.trim() };
  } catch (e) {
    return { code: e.status, stdout: String(e.stdout || '').trim() };
  }
}

test('마커 없음 → missing (필수 필드 전체 나열)', () => {
  const root = makeRoot();
  try {
    const v = validateApproval(root, 'T900');
    assert.equal(v.state, 'missing');
    assert.deepEqual(v.missing, ['approved_by', 'approved_at', 'scope_confirmation', 'rollback_plan']);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('필수 필드 빈 값 + ISO8601 위반 → malformed (누락 필드 식별)', () => {
  const root = makeRoot();
  try {
    writeFileSync(join(root, 'docs', 'approvals', 'T901.md'),
      'approved_by: ""\napproved_at: "not-a-date"\nrollback_plan: ""\n');
    const v = validateApproval(root, 'T901');
    assert.equal(v.state, 'malformed');
    assert.ok(v.missing.includes('approved_by'));
    assert.ok(v.missing.includes('scope_confirmation'));
    assert.ok(v.missing.includes('rollback_plan'));
    assert.ok(v.missing.includes('approved_at(ISO8601)'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('유효 마커 + scope 일치 → ok', () => {
  const root = makeRoot();
  try {
    writeTicket(root, 'T902', 'backend/app.py 한정 수정');
    writeMarker(root, 'T902', { scope: yamlEscapeCut('backend/app.py 한정 수정') });
    assert.equal(validateApproval(root, 'T902').state, 'ok');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('티켓 §변경 범위가 승인 후 변경 → stale', () => {
  const root = makeRoot();
  try {
    writeTicket(root, 'T903', '원래 승인된 범위');
    writeMarker(root, 'T903', { scope: yamlEscapeCut('원래 승인된 범위') });
    assert.equal(validateApproval(root, 'T903').state, 'ok');
    writeTicket(root, 'T903', '넓어진 새 범위'); // 승인 뒤 scope 변경
    assert.equal(validateApproval(root, 'T903').state, 'stale');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('검증 불가 → unverifiable (리뷰 3차: TODO scope·섹션 부재·티켓 부재는 ok가 아니다)', () => {
  // 이전에는 측정 불가를 보수적으로 ok로 돌려보냈지만, 그러면 Scope 섹션 삭제·헤딩
  // 변경·TODO 초안 마커로 stale 검사를 우회할 수 있었다 — 실행기는 unverifiable을 거부한다.
  const root = makeRoot();
  try {
    writeTicket(root, 'T904', '아무 범위');
    writeMarker(root, 'T904', { scope: 'TODO: confirm exact approved scope for T904' });
    const todo = validateApproval(root, 'T904');
    assert.equal(todo.state, 'unverifiable');
    assert.match(todo.reason, /TODO/);

    writeTicket(root, 'T905', null); // §변경 범위 섹션 없음
    writeMarker(root, 'T905', { scope: '어떤 범위든' });
    const noSection = validateApproval(root, 'T905');
    assert.equal(noSection.state, 'unverifiable');
    assert.match(noSection.reason, /변경 범위/);

    writeMarker(root, 'T906', { scope: '티켓 없음' }); // 티켓 본문 자체가 없음
    const noTicket = validateApproval(root, 'T906');
    assert.equal(noTicket.state, 'unverifiable');
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('parseMarker: 선두 `- ` 허용, 비따옴표 값 inline 주석 제거, escaped 형태 보존', () => {
  const fields = parseMarker([
    '- approved_by: "홍길동"',
    'approved_at: 2026-07-10T10:00:00Z  # 코멘트',
    'scope_confirmation: "escaped \\"quote\\" kept"',
    'rollback_plan: "git revert HEAD"',
  ].join('\n'));
  assert.equal(fields.approved_by, '홍길동');
  assert.equal(fields.approved_at, '2026-07-10T10:00:00Z');
  assert.equal(fields.scope_confirmation, 'escaped \\"quote\\" kept'); // 저장된 escaped 그대로
  assert.equal(fields.rollback_plan, 'git revert HEAD');
});

test('extractSection: `## ` 경계·첫 3줄 압축 (approve.sh section_oneline 미러)', () => {
  const text = '## 변경 범위\n\n- [x] `a.py` 수정\n- b 추가\n- c 삭제\n- 4번째는 무시\n\n## 다음 섹션\n- 다른 내용\n';
  assert.equal(extractSection(text, '변경 범위'), 'a.py 수정 b 추가 c 삭제');
  assert.equal(extractSection(text, '없는 키워드'), '');
});

test('CLI가 symlink 경유 경로로 실행돼도 판정한다 (macOS /var→/private/var fail-open 회귀)', () => {
  // main-module 판정이 pathToFileURL(argv[1])===import.meta.url 단순 비교면, symlink 경유
  // 실행 시 CLI 블록이 조용히 건너뛰어 exit 0(=승인 통과)이 된다. missing인데 0이 나오면 회귀.
  const base = mkdtempSync(join(tmpdir(), 'approval-symlink-'));
  try {
    const realDir = join(base, 'real');
    mkdirSync(realDir);
    writeFileSync(join(realDir, 'approval.mjs'), readFileSync(VALIDATOR));
    const linkDir = join(base, 'link');
    symlinkSync(realDir, linkDir);
    const root = makeRoot();
    try {
      let code = 0;
      try {
        execFileSync(process.execPath, [join(linkDir, 'approval.mjs'), root, 'T950'], { encoding: 'utf8' });
      } catch (e) { code = e.status; }
      assert.equal(code, 3); // missing — exit 0(fail-open)이면 회귀
    } finally { rmSync(root, { recursive: true, force: true }); }
  } finally { rmSync(base, { recursive: true, force: true }); }
});

test('hardlink 마커 → unverifiable (identity 불확실)', () => {
  const root = makeRoot();
  try {
    writeTicket(root, 'T907', '승인 범위');
    writeMarker(root, 'T907', { scope: yamlEscapeCut('승인 범위') });
    assert.equal(validateApproval(root, 'T907').state, 'ok');
    linkSync(join(root, 'docs', 'approvals', 'T907.md'), join(root, 'elsewhere.md'));
    const v = validateApproval(root, 'T907');
    assert.equal(v.state, 'unverifiable');
    assert.match(v.reason, /hardlink/);
  } finally { rmSync(root, { recursive: true, force: true }); }
});

test('CLI 종료 코드 계약: ok=0 / missing=3 / malformed=4 / stale=5', () => {
  const root = makeRoot();
  try {
    assert.equal(cli(root, 'T910').code, 3);

    writeFileSync(join(root, 'docs', 'approvals', 'T911.md'), 'approved_by: ""\n');
    const mal = cli(root, 'T911');
    assert.equal(mal.code, 4);
    assert.ok(mal.stdout.startsWith('malformed'));
    assert.ok(mal.stdout.includes('approved_by'));

    writeTicket(root, 'T912', '승인된 범위');
    writeMarker(root, 'T912', { scope: yamlEscapeCut('승인된 범위') });
    assert.equal(cli(root, 'T912').code, 0);

    writeTicket(root, 'T912', '바뀐 범위');
    const stale = cli(root, 'T912');
    assert.equal(stale.code, 5);
    assert.equal(stale.stdout, 'stale');

    // 리뷰 3차: unverifiable=6
    writeTicket(root, 'T913', null);
    writeMarker(root, 'T913', { scope: '어떤 범위든' });
    const unv = cli(root, 'T913');
    assert.equal(unv.code, 6);
    assert.ok(unv.stdout.startsWith('unverifiable'));
  } finally { rmSync(root, { recursive: true, force: true }); }
});
