// fortune-schema.v1.1 계열 응답 타입 (backend /api/fortune/today)
export interface FortuneScores {
  love: number;
  money: number;
  work: number;
  relationship: number;
  condition: number;
}

export interface Fortune {
  summary: string[];
  scores_line: string;
  scores: FortuneScores;
  lucky: { color: string; item: string };
  avoid: string;
  meta?: Record<string, unknown>;
}

export interface ScriptSegment {
  text: string;
  [key: string]: unknown;
}

export interface FortuneResponse {
  fortuneId: string;
  fortune: Fortune;
  script: ScriptSegment[];
  audioUrl: string;
  durationSec?: number;
  events?: unknown[];
}

export interface Profile {
  nickname: string;
  birthYear: number;
  birthMonth: number;
  birthDay: number;
  birthHour: number | null;
}

export type ScreenName = "s0" | "s1" | "s2" | "s3" | "s4" | "s5";
export type AvatarState = "idle" | "greeting" | "speaking" | "blessing";
export type PlayerPhase = "idle" | "playing" | "paused" | "done";

export interface AuthSession {
  loggedIn: boolean;
  provider?: string;
  nickname?: string | null;
}

declare global {
  interface Window {
    HongyeonLive2D?: {
      init: (container: HTMLElement) => void;
      moveTo: (container: HTMLElement) => void;
      setState: (state: string) => void;
      setMouth: (level: number) => void;
      isActive: () => boolean;
    };
  }
}
