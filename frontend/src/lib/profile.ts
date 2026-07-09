// 프로필·streak — localStorage 로컬 우선 (v3 §12). 키는 vanilla 구현과 동일(마이그레이션 불필요).
import type { Profile } from "./types";

const PROFILE_STORAGE_KEY = "shindang.profile";
const STREAK_STORAGE_KEY = "shindang.streak";
export const NICKNAME_MAX_LENGTH = 10;

export function loadStoredProfile(): Profile | null {
  try {
    const raw = window.localStorage.getItem(PROFILE_STORAGE_KEY);
    if (!raw) return null;
    const parsed = JSON.parse(raw);
    return parsed && typeof parsed === "object" ? (parsed as Profile) : null;
  } catch {
    return null;
  }
}

export function saveStoredProfile(profile: Profile): void {
  try {
    window.localStorage.setItem(PROFILE_STORAGE_KEY, JSON.stringify(profile));
  } catch {
    // localStorage 불가 환경(사파리 프라이빗 등) — 세션 내 진행은 막지 않는다.
  }
}

export interface ProfileErrors {
  nickname?: string;
  birthDate?: string;
}

export function validateProfileInput(nickname: string, birthDateRaw: string): ProfileErrors {
  const errors: ProfileErrors = {};
  const trimmed = nickname.trim();
  if (!trimmed) {
    errors.nickname = "닉네임을 입력해주세요.";
  } else if (trimmed.length > NICKNAME_MAX_LENGTH) {
    errors.nickname = `닉네임은 최대 ${NICKNAME_MAX_LENGTH}자까지 입력할 수 있어요.`;
  }
  if (!birthDateRaw) {
    errors.birthDate = "생년월일을 입력해주세요.";
  } else {
    const parsed = new Date(birthDateRaw + "T00:00:00");
    const todayStr = new Date().toISOString().slice(0, 10);
    if (isNaN(parsed.getTime())) {
      errors.birthDate = "올바른 날짜 형식이 아니에요.";
    } else if (birthDateRaw > todayStr) {
      errors.birthDate = "미래 날짜는 입력할 수 없어요.";
    }
  }
  return errors;
}

function localDateString(): string {
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
}

/** 당일 재방문 유지, 하루 차이 +1, 그 외 1로 리셋 — v2 프로토타입과 동일 규칙.
 *  리뷰 P2: UTC(toISOString) 기준이라 KST 오전 9시에 날짜가 바뀌던 문제 → 기기 로컬 날짜 사용. */
export function computeStreak(): number {
  try {
    const today = localDateString();
    const raw = JSON.parse(window.localStorage.getItem(STREAK_STORAGE_KEY) || "null");
    let count = 1;
    if (raw && raw.lastDate) {
      const diffDays = (new Date(today).getTime() - new Date(raw.lastDate).getTime()) / 86400000;
      count = diffDays === 0 ? raw.count : diffDays === 1 ? raw.count + 1 : 1;
    }
    window.localStorage.setItem(STREAK_STORAGE_KEY, JSON.stringify({ count, lastDate: today }));
    return count;
  } catch {
    return 1;
  }
}
