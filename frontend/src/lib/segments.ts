// 재생 코어 (프레임워크 무관) — 세그먼트별 오디오 분할 재생은 non-goal(단일 오디오 유지),
// 텍스트 길이 비중으로 근사한 진행률 경계를 계산해 FSM 전이 타이밍을 시뮬레이션한다.
import type { AvatarState, ScriptSegment } from "./types";

export function computeSegmentBoundaries(script: ScriptSegment[], totalDurationSec: number): number[] {
  const weights = script.map((seg) => Math.max((seg.text || "").length, 1));
  const totalWeight = weights.reduce((a, b) => a + b, 0);
  let acc = 0;
  return weights.map((w) => {
    acc += w;
    return (acc / totalWeight) * totalDurationSec;
  });
}

/** screen-ia.md §3.2 narration 세그먼트 순서 → 아바타/플레이어 상태 매핑. */
export function stateForSegmentIndex(idx: number): AvatarState {
  if (idx <= 0) return "greeting";
  if (idx >= 6) return "blessing";
  return "speaking";
}

export function currentSegmentIndex(currentTime: number, boundaries: number[]): number {
  for (let i = 0; i < boundaries.length; i++) {
    if (currentTime <= boundaries[i]) return i;
  }
  return boundaries.length - 1;
}
