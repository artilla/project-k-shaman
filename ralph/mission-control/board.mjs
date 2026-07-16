// ralph/mission-control/board.mjs
// ADR-0180 T273 P3-Board-aging-a: card aging 읽기 모델 (읽기 전용 · file=truth · 신규 writer/exec 0).
//
// Board는 forging에만 시간 신호가 있다. backlog/open/awaiting-approval에서 오래 대기하는 티켓을
// 가시화하기 위해, frontmatter `created`(271/271 존재)에서 *생성 후 경과*를 도출한다.
//   - mtime이 아니라 created를 쓴다(git checkout이 mtime을 흔듦 — 거짓 aging 방지, ADR-0040).
//   - active(비종결) 상태만 aging 대상. done/parked(skipped/blocked)는 지연이 아니다.
//   - age 불명(created 없음/파싱 불가)은 null — 거짓 aging 금지.
//   - aging은 관측 신호일 뿐, 실행 게이트가 아니다(ADR-0038 stuck 동급).

const DAY_MS = 86400000;

// aging 대상이 되는 active(비종결) 상태. done/skipped/blocked는 제외.
const ACTIVE_STATES = new Set(['backlog', 'open', 'forging', 'verify', 'awaiting-approval']);

/**
 * frontmatter `created`(YYYY-MM-DD 또는 ISO)에서 생성 후 경과 일수(정수, floor).
 * 없음/파싱 불가 → null. 음수(미래 날짜)는 0으로 클램프.
 *
 * 알려진 한계(리뷰 M4): 날짜-전용 문자열은 Date.parse가 UTC 자정으로 해석하므로
 * KST(+9) 환경에서 경계 시간대에 최대 ±1일 오차가 날 수 있다. aging/lead-time은
 * 관측 신호(게이트 아님)이고 임계가 3/7일이라 허용 — 정밀 계측이 필요해지면
 * 날짜-전용 입력을 로컬 자정으로 정규화할 것.
 */
export function ticketAgeDays(created, nowMs) {
  if (!created || typeof created !== 'string') return null;
  const t = Date.parse(created.trim());
  if (!Number.isFinite(t)) return null;
  const days = Math.floor((nowMs - t) / DAY_MS);
  return days < 0 ? 0 : days;
}

/**
 * ADR-0180 §2.1: 티켓 aging 레벨(읽기). active 상태에서만 fresh/aging/stale.
 *   - done/parked(skipped/blocked) 등 비-active → null (종결은 지연 아님)
 *   - age 불명(created 없음/파싱 불가) → null (거짓 aging 금지)
 *   - age ≥ staleDays → 'stale' · ≥ agingDays → 'aging' · 그 외 → 'fresh'
 * 임계는 관측 신호 기본값(게이트 아님): agingDays=3, staleDays=7.
 */
export function agingLevel(ticket, nowMs, opts = {}) {
  const agingDays = Number.isFinite(opts.agingDays) ? opts.agingDays : 3;
  const staleDays = Number.isFinite(opts.staleDays) ? opts.staleDays : 7;
  const status = (ticket && ticket.status) || '';
  if (!ACTIVE_STATES.has(status)) return null;           // 종결/비-active는 aging 아님
  const age = ticketAgeDays(ticket && ticket.created, nowMs);
  if (age == null) return null;                          // age 불명 → 거짓 aging 금지
  if (age >= staleDays) return 'stale';
  if (age >= agingDays) return 'aging';
  return 'fresh';
}

// 두 날짜(created, end) 사이 일수(floor). 파싱 불가/음수(end<created)면 null.
function spanDays(created, end) {
  if (!created || !end || typeof created !== 'string' || typeof end !== 'string') return null;
  const cr = Date.parse(created.trim());
  const ed = Date.parse(end.trim());
  if (!Number.isFinite(cr) || !Number.isFinite(ed)) return null;
  if (ed < cr) return null;                              // completed < created 가드
  return Math.floor((ed - cr) / DAY_MS);
}

/**
 * ADR-0182 T275: done 티켓 lead-time(생성→완료 일수, 읽기). measured/estimated 분리(ADR-0048).
 *   - created + completed_at(≥created) → { days, basis: 'measured' }
 *   - 아니면 created + completed_at_est(≥created) → { days, basis: 'estimated' }
 *   - 둘 다 불가(계측 이전·created 없음) → null
 * measured 우선 — 추정이 측정으로 둔갑하지 않게. completed_at 재계산/backfill 없음.
 */
export function leadTimeDays(ticket) {
  if (!ticket) return null;
  const measured = spanDays(ticket.created, ticket.completed_at);
  if (measured != null) return { days: measured, basis: 'measured' };
  const estimated = spanDays(ticket.created, ticket.completed_at_est);
  if (estimated != null) return { days: estimated, basis: 'estimated' };
  return null;
}

/**
 * ADR-0184 T277: 컬럼 흐름 요약(읽기). per-card 모델(agingLevel/leadTimeDays)을 *집계*만 한다.
 *   { aging, stale, leadMeasured, leadEstimated } — 모두 카운트.
 * active 상태 티켓은 aging/stale로, done 티켓은 lead-time basis로 누적. median/평균 없음(Insights 소관).
 * 카드 신호와 동일 결론 — 새 데이터·writer/exec 0.
 */
export function columnFlowSummary(tickets, nowMs) {
  const out = { aging: 0, stale: 0, leadMeasured: 0, leadEstimated: 0 };
  if (!Array.isArray(tickets)) return out;
  for (const t of tickets) {
    const lvl = agingLevel(t, nowMs);          // active만 non-null
    if (lvl === 'aging') out.aging += 1;
    else if (lvl === 'stale') out.stale += 1;
    if ((t && t.status) === 'done') {
      const lead = leadTimeDays(t);            // 계측 이전이면 null
      if (lead && lead.basis === 'measured') out.leadMeasured += 1;
      else if (lead && lead.basis === 'estimated') out.leadEstimated += 1;
    }
  }
  return out;
}

// ADR-0190 T283: 의존 체인 명료화(읽기 전용). depends_on의 각 ID를 이미 로드된 모델
// (id→{title,status})에 *대조*만 한다 — 티켓 파일·게이트·blocked 판정을 바꾸지 않는다.
// missing(맵에 없는 ID)은 오타/삭제된 티켓을 가리키는 무결성 신호다(ADR-0040: 파일이
// 기록한 사실만 정직하게). depends_on 순서를 보존하고, 충족된 dep도 met:true로 포함한다.
export function resolveDeps(dependsOn, ticketsById) {
  if (!Array.isArray(dependsOn)) return [];
  const byId = ticketsById && typeof ticketsById === 'object' ? ticketsById : {};
  return dependsOn.map((raw) => {
    const id = String(raw);
    const found = Object.prototype.hasOwnProperty.call(byId, id) ? byId[id] : null;
    if (!found) {
      return { id, title: '', status: 'missing', met: false, missing: true };
    }
    const status = found.status ? String(found.status) : '';
    return {
      id,
      title: found.title ? String(found.title) : '',
      status,
      met: status === 'done',
      missing: false,
    };
  });
}

// ADR-0192 T285: 역방향 의존(downstream) 읽기 전용. "이 티켓을 depends_on에 적은
// 티켓들"을 실제 엣지에서 역집계한다 — 저자 선언 `blocks` 필드가 아니라 depends_on이
// 지상 진실이다(ADR-0040). 티켓 파일·게이트·blocked 판정을 바꾸지 않는다.
// openCount는 아직 이 티켓을 기다리는(status!=='done') downstream 수 — "이걸 끝내면
// N개가 진전"이라는 우선순위 신호(정렬·게이트 아님).
export function reverseDeps(ticketId, tickets) {
  const out = { downstream: [], openCount: 0, total: 0 };
  if (!Array.isArray(tickets)) return out;
  const target = String(ticketId ?? '');
  if (!target) return out;
  for (const t of tickets) {
    if (!t || t.id == null) continue;
    const tid = String(t.id);
    if (tid === target) continue;                     // 자기참조 방어
    const deps = Array.isArray(t.depends_on) ? t.depends_on : [];
    if (!deps.some(d => String(d) === target)) continue;
    const status = t.status ? String(t.status) : '';
    out.downstream.push({ id: tid, title: t.title ? String(t.title) : '', status });
    out.total += 1;
    if (status !== 'done') out.openCount += 1;
  }
  return out;
}

// 리뷰 M7: reverseDeps를 카드마다 호출하면 O(N²)라, Board 렌더가 티켓 전체를 1회
// 순회해 역엣지 인덱스를 만들 수 있게 한다. reverseDeps와 동일 결론(동일 순서·동일
// 필드) — per-ID 조회용 index(Map)와 존재 집합 exists(Set)를 함께 반환한다. 읽기 전용.
export function reverseDepsIndex(tickets) {
  const index = new Map();
  const exists = new Set();
  if (!Array.isArray(tickets)) return { index, exists };
  for (const t of tickets) {
    if (t && t.id != null) exists.add(String(t.id));
  }
  for (const t of tickets) {
    if (!t || t.id == null) continue;
    const tid = String(t.id);
    const status = t.status ? String(t.status) : '';
    const deps = Array.isArray(t.depends_on) ? t.depends_on : [];
    const seen = new Set();                              // 중복 dep 선언 1회만(reverseDeps의 some과 동치)
    for (const raw of deps) {
      const target = String(raw);
      if (target === tid || seen.has(target)) continue;  // 자기참조 방어 + 중복 제거
      seen.add(target);
      let entry = index.get(target);
      if (!entry) { entry = { downstream: [], openCount: 0, total: 0 }; index.set(target, entry); }
      entry.downstream.push({ id: tid, title: t.title ? String(t.title) : '', status });
      entry.total += 1;
      if (status !== 'done') entry.openCount += 1;
    }
  }
  return { index, exists };
}

/** index에서 단일 티켓의 역방향 의존 조회 — reverseDeps와 동일 형태. 없으면 빈 결과. */
export function reverseDepsFromIndex(ticketId, prebuilt) {
  const entry = prebuilt && prebuilt.index ? prebuilt.index.get(String(ticketId ?? '')) : null;
  return entry || { downstream: [], openCount: 0, total: 0 };
}

// ADR-0194 T287: blocks 선언 정합성(읽기 전용 무결성 신호). 저자가 declared `blocks`에
// 적은 항목 중 실제 depends_on 역엣지가 없는 stale 선언만 검출한다(declared-not-actual).
// actual-not-declared(적지 않았지만 실제 엣지 있음)는 이 저장소의 규범이므로 경보하지
// 않는다 — depends_on이 소스, blocks는 선택(ADR-0040: 결함인 사실만 표면화·노이즈 배제).
// reverseDeps로 실제 downstream을 구해 declared와 대조할 뿐 — 티켓 파일·blocks 필드
// 무변경. missing(대상 티켓 부재)/no-edge(대상 있으나 이 티켓을 depend 안 함) 구분.
// prebuilt(선택, 리뷰 M7): reverseDepsIndex() 결과를 주입하면 tickets 재순회 없이 O(deps)로
// 판정한다. 미주입이면 종전과 동일하게 tickets에서 직접 계산(동일 결론).
export function blocksConsistency(declaredBlocks, ticketId, tickets, prebuilt = null) {
  const out = { stale: [], staleCount: 0, consistent: true };
  if (!Array.isArray(declaredBlocks) || declaredBlocks.length === 0) return out;
  const rev = prebuilt ? reverseDepsFromIndex(ticketId, prebuilt) : reverseDeps(ticketId, tickets);
  const actual = new Set(rev.downstream.map(d => d.id));
  const exists = prebuilt && prebuilt.exists
    ? prebuilt.exists
    : new Set(
      (Array.isArray(tickets) ? tickets : [])
        .filter(t => t && t.id != null)
        .map(t => String(t.id)),
    );
  const seen = new Set();
  for (const raw of declaredBlocks) {
    const id = String(raw);
    if (seen.has(id)) continue;                 // 중복 제거
    seen.add(id);
    if (actual.has(id)) continue;               // 정합 — 실제 역엣지 있음
    out.stale.push({ id, reason: exists.has(id) ? 'no-edge' : 'missing' });
  }
  out.staleCount = out.stale.length;
  out.consistent = out.staleCount === 0;
  return out;
}
