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

export function buildFortuneUrl(profile: Profile | null, topic: string): string {
  const params = new URLSearchParams();
  if (profile && profile.birthYear && profile.birthMonth && profile.birthDay) {
    params.set("birth_year", String(profile.birthYear));
    params.set("birth_month", String(profile.birthMonth));
    params.set("birth_day", String(profile.birthDay));
    if (profile.birthHour !== null && profile.birthHour !== undefined) {
      params.set("birth_hour", String(profile.birthHour));
    }
  }
  params.set("topic", topic);
  return `/api/fortune/today?${params.toString()}`;
}

export async function fetchFortune(profile: Profile | null, topic: string): Promise<FortuneResponse> {
  const res = await fetch(buildFortuneUrl(profile, topic));
  if (res.status === 429) throw new Error("오늘 준비된 무대는 여기까지예요. 내일 다시 찾아주세요.");
  if (!res.ok) throw new Error(`운세를 불러오지 못했어요 (${res.status})`);
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
