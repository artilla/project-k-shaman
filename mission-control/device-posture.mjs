// mission-control/device-posture.mjs — ADR-0188 T281: device fleet posture(읽기 전용).
//
// listDevices()(token-store.mjs)가 내보내는 레코드를 *분류·집계*만 한다. 토큰 발급/
// 회전/폐기/인증/QR/엔드포인트를 일절 건드리지 않는다 — 새 writer/exec/endpoint 0.
// expires_at·last_seen_at·revoked라는 파일이 정직하게 기록한 사실만 사용한다(ADR-0040).
// 점수·평가가 아니라 위생 신호(갱신 임박·미사용·상한 근접)일 뿐이며, 인증 결정
// (token-auth.mjs)이나 발급 상한(ADR-0033)을 바꾸지 않는다(신호이지 게이트 아님).

const DAY_MS = 24 * 60 * 60 * 1000;
export const DEFAULT_STALE_DAYS = 14;

/**
 * 단일 기기의 posture를 분류한다. 입력은 listDevices() 레코드(또는 그 부분집합).
 * 우선순위(위생 위험 높은 순): inactive → renew-soon → stale → active.
 *
 * @returns {{ level:'inactive'|'renew-soon'|'stale'|'active',
 *             expiresInDays:number, staleDays:(number|null), neverSeen:boolean }}
 */
export function devicePosture(device, nowMs = Date.now(), { staleDays = DEFAULT_STALE_DAYS } = {}) {
  const d = device && typeof device === 'object' ? device : {};
  const active = Boolean(d.active);

  // 만료까지 일수(active만 의미). 음수 없음(만료된 기기는 inactive로 분류됨).
  const expiresMs = d.expires_at ? new Date(d.expires_at).getTime() : NaN;
  const expiresInDays = Number.isFinite(expiresMs)
    ? Math.max(0, Math.floor((expiresMs - nowMs) / DAY_MS))
    : 0;

  // last_seen 이후 경과 일수. 기록이 없으면 neverSeen.
  const lastSeenMs = d.last_seen_at ? new Date(d.last_seen_at).getTime() : NaN;
  const neverSeen = !Number.isFinite(lastSeenMs);
  const sinceSeenDays = neverSeen ? null : Math.max(0, Math.floor((nowMs - lastSeenMs) / DAY_MS));

  let level;
  if (!active) {
    level = 'inactive';                       // revoked/expired — 슬롯 이미 비움, posture 관심 밖
  } else if (d.renewable) {
    level = 'renew-soon';                      // 만료 7일 내(token-store가 계산한 기존 플래그)
  } else if (neverSeen || sinceSeenDays > staleDays) {
    level = 'stale';                           // 오래 미사용/한 번도 안 봄 — 폐기 후보(위생)
  } else {
    level = 'active';                          // 정상
  }

  return { level, expiresInDays, staleDays: sinceSeenDays, neverSeen };
}

/**
 * 기기 목록의 fleet posture를 집계한다. 카운트만(점수·평균 없음).
 * max가 주어지면(server가 resolveMaxDevices 주입) 상한 근접/도달을 표시한다.
 * activeTotal은 활성 기기 수(active + renew-soon + stale) — 상한 정책과 동일한
 * "활성" 정의(!revoked && !expired). nearCap/atCap은 신호일 뿐 발급을 막지 않는다.
 *
 * @returns {{ active:number, renewSoon:number, stale:number, inactive:number,
 *             total:number, activeTotal:number, max:(number|null),
 *             nearCap:boolean, atCap:boolean }}
 */
export function fleetPosture(devices, nowMs = Date.now(), { staleDays = DEFAULT_STALE_DAYS, max = null } = {}) {
  const out = {
    active: 0, renewSoon: 0, stale: 0, inactive: 0,
    total: 0, activeTotal: 0,
    max: Number.isInteger(max) && max > 0 ? max : null,
    nearCap: false, atCap: false,
  };
  if (!Array.isArray(devices)) return out;

  for (const dev of devices) {
    const { level } = devicePosture(dev, nowMs, { staleDays });
    out.total += 1;
    if (level === 'inactive') {
      out.inactive += 1;
    } else {
      out.activeTotal += 1;                    // active + renew-soon + stale = 활성
      if (level === 'renew-soon') out.renewSoon += 1;
      else if (level === 'stale') out.stale += 1;
      else out.active += 1;
    }
  }

  if (out.max) {
    out.atCap = out.activeTotal >= out.max;
    // 리뷰 M3: 활성 0대에서 "상한 근접" 오신호 방지 — 근접은 활성 ≥1대일 때만 의미.
    // (max=1이면 활성 1대 = atCap이므로 nearCap 단독 표시는 발생하지 않는다.)
    out.nearCap = out.activeTotal > 0 && out.activeTotal >= out.max - 1; // 도달도 근접에 포함(atCap이 우선 표시)
  }
  return out;
}
