// ralph/mission-control/autonomy.mjs
// ADR-0176 T269 P2-Autonomy-a: 정책 projection 읽기 모델 (읽기 전용 · file=truth · 신규 writer/exec/게이트 0).
//
// 이 repo의 "정책"은 새 규칙 파일이 아니라 기존 enforcement 원시의 합이다(ADR-0052):
//   loop_mode(ADR-0054) · per-ticket safe(ADR-0007) · 승인 게이트 · exec scope(T099) · autopilot grant(ADR-0056).
// 본 모듈은 그 원시를 *읽어서* deny/ask/allow + provenance로 합성만 한다 — enforcement와 동일 결론(정직).
// 실제 실행을 막거나 허용하지 않는다(관측만, ADR-0052).

import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';
// 리뷰 M5: server.mjs와의 "동치 미러" 복제 제거 — 공용 원시(read-primitives.mjs) 단일 소스.
import { readLoopMode, readAutopilotGrant } from './read-primitives.mjs';

// 기존 공개 API 유지(테스트·server가 이 모듈에서 import) — 공용 원시를 재수출.
export { readLoopMode, readAutopilotGrant };

// ADR-0178 T271: grant 파일 raw 필드 읽기(분류용). 없으면 null.
function readGrantFields(root) {
  try {
    const p = join(root, 'state', 'autopilot_grant');
    if (!existsSync(p)) return null;
    const fields = {};
    for (const line of readFileSync(p, 'utf8').split('\n')) {
      const m = line.match(/^([a-z_]+)=(.*)$/);
      if (m) fields[m[1]] = m[2];
    }
    return fields;
  } catch { return null; }
}

/**
 * ADR-0178 T271: autopilot grant 포스처 분류(읽기). 파일이 기록한 필드에서만 도출(정직).
 *   none      — 파일 없음/측정 불가
 *   active    — budget>0 · 미만료 (+ bindsFirst: budget|expiry|null = default-tighten 임박 한계)
 *   revoked   — budget=0 · revoked_at 있음 (비상 정지/kill)
 *   expired   — budget>0 · expiry_epoch < now (시간 만료)
 *   exhausted — budget=0 · revoked_at 없음 (budget 소진 — orchestrator 차감)
 * bindsFirst는 한 한계가 floor에 임박할 때만 단정 — 둘 다 여유/동률은 null(추정 금지, ADR-0040).
 */
export function grantPosture(root) {
  const f = readGrantFields(root);
  if (!f) return { state: 'none' };
  const budget = Number(f.budget);
  const expiryEpoch = Number(f.expiry_epoch);
  const revokedAt = f.revoked_at || null;
  const issuedBy = f.issued_by || '?';
  const expiryHuman = f.expiry_human || '';
  if (!Number.isFinite(budget)) return { state: 'none' };           // 측정 불가 → 보수적 none
  if (budget > 0) {
    if (!Number.isFinite(expiryEpoch)) return { state: 'none' };    // 시간 검증 불가 → 보수적 none
    const minutesLeft = Math.floor((expiryEpoch - Math.floor(Date.now() / 1000)) / 60);
    if (minutesLeft < 0) return { state: 'expired', budget, expiryHuman, issuedBy };
    const budgetFloor = budget <= 1;       // 다음 1건이면 소진
    const expiryFloor = minutesLeft <= 1;  // 1분 이내 만료
    let bindsFirst = null;
    if (budgetFloor && !expiryFloor) bindsFirst = 'budget';
    else if (expiryFloor && !budgetFloor) bindsFirst = 'expiry';    // 둘 다 floor(동률)/둘 다 여유 → null
    return { state: 'active', budget, minutesLeft, expiryHuman, issuedBy, bindsFirst };
  }
  // budget <= 0
  if (revokedAt) return { state: 'revoked', revokedAt, issuedBy };
  return { state: 'exhausted', expiryHuman, issuedBy };
}

/**
 * 현재 자율성 포스처(읽기). mode(미설정은 governing 기본 co-pilot으로 표기) + grant 유효성.
 * effectiveMode는 enforcement 기본(--safe-only=co-pilot)과 동일 — 정직한 projection.
 */
export function policyPosture(root) {
  const mode = readLoopMode(root);
  const grant = readAutopilotGrant(root);
  return {
    mode,                                   // null = 파일 미설정
    effectiveMode: mode || 'co-pilot',      // 기본 Co-pilot(ADR-0052)
    grant,                                  // null = 없음/만료
    grantValid: !!grant,
  };
}

// ── 정책 판정 (기존 원시 projection — 새 규칙 아님) ──

function P(rule, source, detail) { return { rule, source, detail }; }

/**
 * ADR-0176 §2.2: 요청을 현재 포스처에 비추어 deny/ask/allow + provenance로 판정(순수).
 * request: { safe?:bool, command?:string, localhost?:bool(기본 true), unattended?:bool }
 * 반환: { decision:'deny'|'ask'|'allow', provenance:[{rule,source,detail}], reason }
 * 막거나 허용하지 않는다 — 기존 enforcement가 진실(관측만).
 */
export function evaluatePolicy(posture, request = {}) {
  const localhost = request.localhost !== false; // 기본 localhost
  const unattended = request.unattended === true;
  const command = typeof request.command === 'string' ? request.command : null;

  // 1) exec scope (T099): 비-localhost는 approve만.
  if (command && !localhost) {
    if (command === 'approve') {
      return { decision: 'allow', provenance: [P('exec-scope', 'execScopeDecision (ADR-0099/T099)', '비-localhost는 approve 허용')], reason: '비-localhost에서 approve는 허용된 유일한 exec' };
    }
    return { decision: 'deny', provenance: [P('exec-scope', 'execScopeDecision (ADR-0099/T099)', `비-localhost exec 차단(approve 외): ${command}`)], reason: '비-localhost는 approve only' };
  }

  // 2) 티켓 자동 실행 (safe 명시).
  if (typeof request.safe === 'boolean') {
    if (request.safe === false) {
      if (unattended) {
        return {
          decision: 'deny',
          provenance: [P('autopilot-grant', 'autopilot_grant (ADR-0056)', 'grant는 safe:false 자동 포지 미인가'), P('safe-gate', 'safe flag (ADR-0007)', 'safe:false')],
          reason: 'grant가 있어도 safe:false 무인 자동 포지는 차단',
        };
      }
      return {
        decision: 'ask',
        provenance: [P('safe-gate', 'validate_safe_false_approval (ADR-0007)', '승인 마커 필요')],
        reason: 'safe:false는 사람 승인 게이트',
      };
    }
    // safe:true
    if (posture.effectiveMode === 'suggest') {
      return { decision: 'ask', provenance: [P('loop-mode', 'state/loop_mode (ADR-0054)', 'suggest=dry-run·상시 확인')], reason: 'Suggest 모드는 매 실행 확인' };
    }
    if (unattended) {
      if (posture.grantValid) {
        return { decision: 'allow', provenance: [P('autopilot-grant', 'state/autopilot_grant (ADR-0056)', `budget=${posture.grant.budget}·${posture.grant.minutesLeft}분 남음`), P('safe-gate', 'safe flag', 'safe:true')], reason: '유효 grant 내 safe:true 무인 연속 허용' };
      }
      return { decision: 'deny', provenance: [P('autopilot-grant', 'autopilot_grant (ADR-0056)', 'grant 없음/만료 — default-tighten')], reason: '무인 연속은 유효 grant 필요' };
    }
    return { decision: 'allow', provenance: [P('loop-mode', `state/loop_mode (${posture.effectiveMode})`, 'safe:true 자동 가능'), P('safe-gate', 'safe flag', 'safe:true')], reason: `${posture.effectiveMode}에서 safe:true 자동 실행` };
  }

  // 3) 분류 불가 → 보수적 ask(사람 판단).
  return { decision: 'ask', provenance: [P('default', 'conservative', '분류 불가 — 사람 판단')], reason: '요청 분류 불가로 보수적 ask' };
}

// ADR-0176 §2: Autonomy 페이지가 표시할 대표 요청 클래스(읽기).
export const POLICY_REQUEST_CLASSES = [
  { id: 'safe-auto', label: 'safe:true 티켓 자동 실행', request: { safe: true, unattended: false } },
  { id: 'safe-unattended', label: 'safe:true 무인 연속(orchestrator)', request: { safe: true, unattended: true } },
  { id: 'unsafe-approve', label: 'safe:false 티켓 실행', request: { safe: false, unattended: false } },
  { id: 'unsafe-unattended', label: 'safe:false 무인 자동 포지', request: { safe: false, unattended: true } },
  { id: 'remote-exec', label: '비-localhost exec(approve 외)', request: { command: 'run_loop', localhost: false } },
];

/** 대표 클래스별 판정(읽기) — UI projection 표용. */
export function projectPolicy(root) {
  const posture = policyPosture(root);
  return {
    posture,
    rows: POLICY_REQUEST_CLASSES.map(c => ({ id: c.id, label: c.label, ...evaluatePolicy(posture, c.request) })),
  };
}
