// 꿈 해몽 — 타입 + API. 상징 풀이는 서버(backend/dream.py)가 조립한다 (게이트 + LLM 교체 지점).
import type { ScriptSegment } from "./types";

export const DREAM_SYMBOL_LABELS = [
  "뱀", "물", "이빨 빠짐", "추락", "시험", "돈", "불", "하늘을 낢",
] as const;

export const DREAM_MAX_TEXT = 300;
export const DREAM_MAX_SYMBOLS = 3;

export interface DreamSymbolReading {
  label: string;
  meaning: string;
}

export interface DreamReading {
  headline: string;
  symbols: DreamSymbolReading[];
  overall: string;
  todayLink: string;
  chips: string[];
  blessing: string;
}

export interface DreamResponse {
  dreamId: string;
  reading: DreamReading;
  script: ScriptSegment[];
  audioUrl: string;
}

export async function interpretDream(text: string, symbols: string[]): Promise<DreamResponse> {
  const res = await fetch("/api/dream/interpret", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ text, symbols }),
  });
  if (res.status === 401) throw new Error("LOGIN_REQUIRED");
  if (!res.ok) throw new Error(`해몽을 불러오지 못했어요 (${res.status})`);
  return res.json();
}
