// ralph/mission-control/library.mjs
// ADR-0186 T279 P3-Library-coverage-a: playbook coverage 읽기 모델 (읽기 전용 · 파싱만 · writer/exec 0).
//
// 각 skill의 구조 필드(description·when_to_invoke 유무)로 완전성을 분류한다.
//   - 품질 점수·AI 평가 없음 — 존재/개수만(정직·검증가능, ADR-0040).
//   - when_to_invoke가 비면 트리거 자동 호출 불가 → 관측 신호(게이트 아님).

/**
 * ADR-0186 §2.1: 단일 skill coverage(순수).
 *   { hasDescription, triggerCount, hasForbidden, level }
 *   level: complete(desc + 트리거≥1) · partial(둘 중 하나) · sparse(둘 다 없음)
 */
export function skillCoverage(skill) {
  const desc = skill && typeof skill.description === 'string' ? skill.description.trim() : '';
  const triggers = skill && Array.isArray(skill.when_to_invoke) ? skill.when_to_invoke : [];
  const forbidden = skill && Array.isArray(skill.forbidden) ? skill.forbidden : [];
  const hasDescription = desc.length > 0;
  const triggerCount = triggers.length;
  const hasTriggers = triggerCount > 0;
  let level;
  if (hasDescription && hasTriggers) level = 'complete';
  else if (hasDescription || hasTriggers) level = 'partial';
  else level = 'sparse';
  return { hasDescription, triggerCount, hasForbidden: forbidden.length > 0, level };
}

/**
 * ADR-0186 §2.1: skill 목록 coverage 요약(순수). level별 + 트리거 0 카운트.
 *   { complete, partial, sparse, noTrigger, total }
 */
export function coverageSummary(skills) {
  const out = { complete: 0, partial: 0, sparse: 0, noTrigger: 0, total: 0 };
  if (!Array.isArray(skills)) return out;
  for (const s of skills) {
    const c = skillCoverage(s);
    out.total += 1;
    out[c.level] += 1;
    if (c.triggerCount === 0) out.noTrigger += 1;
  }
  return out;
}
