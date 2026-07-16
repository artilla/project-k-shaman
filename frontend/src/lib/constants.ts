import type { AvatarState, PlayerPhase } from "./types";

// docs/product/character-sheet-hongyeon.md §6 lucky.color 팔레트 — domain/fortune_card.py와 동일 유지.
export const LUCKY_COLOR_HEX: Record<string, string> = {
  "코랄 핑크": "#ff6f91",
  "진홍": "#c9184a",
  "자수정 보라": "#7b2cbf",
  "청록": "#168aad",
  "살구색": "#ffb38a",
  "금빛": "#f2b705",
  "먹색": "#1f2933",
  "은백": "#f4f6f8",
};

export const SCORE_ORDER = ["love", "money", "work", "relationship", "condition"] as const;
export const SCORE_LABELS: Record<(typeof SCORE_ORDER)[number], string> = {
  love: "연애",
  money: "금전",
  work: "일",
  relationship: "관계",
  condition: "컨디션",
};

// v2 S3 주제 — canonical key는 fortune-schema.v1.1 enum과 동일 (리뷰 P1: 'rel' 별칭 제거)
export const TOPICS = [
  { key: "total", label: "총운", desc: "오늘 하루의 큰 흐름" },
  { key: "love", label: "연애", desc: "홍연의 강점 운세" },
  { key: "money", label: "금전", desc: "재물의 기운" },
  { key: "work", label: "일 / 학업", desc: "집중과 성취" },
  { key: "relationship", label: "인간관계", desc: "사람 사이의 온도" },
] as const;

export const TOPIC_NAMES: Record<string, string> = {
  total: "총운",
  love: "연애운",
  money: "금전운",
  work: "일 · 학업운",
  relationship: "인간관계운",
};

export const BLESSING_TEXT = "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.";

export function playerLabel(phase: PlayerPhase, avatarState: AvatarState): string {
  if (phase === "playing" || phase === "paused") {
    if (avatarState === "greeting") return "홍연 등장 중";
    if (avatarState === "blessing") return "축원 중";
    return "오늘의 운세 재생 중";
  }
  if (phase === "done") return "재생 완료";
  return "탭하면 홍연의 목소리로 들려드려요";
}

export function segmentLabel(phase: PlayerPhase, avatarState: AvatarState): string {
  if (phase === "done") return "공연 종료";
  if (phase === "playing" || phase === "paused") return avatarState;
  return "";
}
