import type { AuthSession, FortuneResponse, Profile } from "./types";

// 이벤트 계측 — 계약(이벤트명·payload)은 vanilla 구현과 동일. 실패는 재생 경험을 막지 않는다.
let sessionStartMs: number | null = null;

export function markSessionStart(): void {
  sessionStartMs = Date.now();
}

export function reportEvents(
  fortuneId: string | null,
  clientEvents: Array<Record<string, unknown>>,
  serverEvents: unknown[] = [],
): Promise<unknown> {
  return fetch("/api/event", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ fortuneId, sessionStartMs, clientEvents, serverEvents }),
  }).catch((err) => {
    console.warn("event report failed", err);
  });
}

/** 기기 로컬 기준 오늘 날짜 (리뷰 P1-1: 날짜 미전송으로 매일 같은 운세가 나오던 버그). */
export function localToday(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** 운세 요청 본문 — birth 원문은 URL이 아닌 POST body로만 보낸다 (리뷰 P1-2, URL·로그 노출 방지). */
export function buildFortuneBody(profile: Profile | null, topic: string): Record<string, unknown> {
  const body: Record<string, unknown> = { topic, date: localToday() };
  if (profile && profile.birthYear && profile.birthMonth && profile.birthDay) {
    body.birth_year = profile.birthYear;
    body.birth_month = profile.birthMonth;
    body.birth_day = profile.birthDay;
    if (profile.birthHour !== null && profile.birthHour !== undefined) {
      body.birth_hour = profile.birthHour;
    }
  }
  return body;
}

export async function fetchFortune(profile: Profile | null, topic: string): Promise<FortuneResponse> {
  const res = await fetch("/api/fortune/today", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(buildFortuneBody(profile, topic)),
  });
  if (res.status === 429) throw new Error("오늘 준비된 무대는 여기까지예요. 내일 다시 찾아주세요.");
  if (!res.ok) throw new Error(`운세를 불러오지 못했어요 (${res.status})`);
  return res.json();
}

/** 듣기 탭 시점의 실 TTS 준비 (리뷰 P1-3 text-first 분리 — 합성·과금은 로그인 게이트 뒤 여기서만). */
export async function prepareTts(profile: Profile | null, topic: string): Promise<{ audioUrl: string }> {
  const res = await fetch("/api/tts/prepare", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify(buildFortuneBody(profile, topic)),
  });
  if (res.status === 401) throw new Error("LOGIN_REQUIRED");
  if (res.status === 429) throw new Error("지금은 요청이 많아요. 잠시 후 다시 들어보세요.");
  if (!res.ok) throw new Error(`음성 준비에 실패했어요 (${res.status})`);
  return res.json();
}

export async function fetchProviders(): Promise<{ google: boolean; kakao: boolean }> {
  const res = await fetch("/api/auth/providers");
  const data = await res.json();
  return { google: !!data.providers?.google, kakao: !!data.providers?.kakao };
}

export async function fetchMe(): Promise<AuthSession> {
  const res = await fetch("/api/auth/me");
  return res.json();
}

export async function logout(): Promise<void> {
  await fetch("/api/auth/logout", { method: "POST" });
}

export function loginUrl(provider: "google" | "kakao"): string {
  return `/api/auth/login/${provider}`;
}

export function shareCardUrl(fortuneId: string): string {
  return `/api/share-card?fortuneId=${encodeURIComponent(fortuneId)}`;
}
