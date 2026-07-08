// S0 온보딩 · S1 무당 확인 · S2 입력 · S3 주제 선택 (v2 디자인, 프레젠테이셔널)
import { forwardRef, useState } from "react";
import { TOPICS } from "../lib/constants";
import { NICKNAME_MAX_LENGTH, validateProfileInput, type ProfileErrors } from "../lib/profile";
import type { Profile } from "../lib/types";

export const S0Onboarding = forwardRef<HTMLDivElement, {
  providers: { google: boolean; kakao: boolean };
  loggedInLabel: string | null;
  onStart: () => void;
  onLogin: (provider: "google" | "kakao") => void;
  onLogout: () => void;
}>(function S0Onboarding({ providers, loggedInLabel, onStart, onLogin, onLogout }, heroRef) {
  return (
    <section className="screen screen--s0">
      <div ref={heroRef} className="s0-avatar" data-live2d-zoom="1.3" data-live2d-anchor-y="0.05">
        <img className="s0-hero" src="/static/assets/hongyeon-greeting.webp" alt="홍연" />
      </div>
      <div className="s0-scrim" aria-hidden="true" />
      <div className="s0-content">
        {loggedInLabel && (
          <p className="onboarding-account-status" aria-live="polite">{loggedInLabel}</p>
        )}
        <div className="s0-eyebrow">TODAY SHINDANG</div>
        <h1 className="s0-title">오늘신당</h1>
        <p className="s0-subtitle">
          오늘의 기운을 무대 위에서 듣다.<br />AI 무당 홍연의 1분 운세 공연.
        </p>
        <button className="cta-button" type="button" onClick={onStart}>운세 보러 가기</button>
        {!loggedInLabel && (
          <div className="s0-social-row">
            <button className="glass-button" type="button" disabled={!providers.google}
              title={providers.google ? "" : "관리자 설정 필요"} onClick={() => onLogin("google")}>
              Google로 계속
            </button>
            <button className="glass-button" type="button" disabled={!providers.kakao}
              title={providers.kakao ? "" : "관리자 설정 필요"} onClick={() => onLogin("kakao")}>
              카카오로 계속
            </button>
          </div>
        )}
        {loggedInLabel && (
          <button className="link-button" type="button" onClick={onLogout}>로그아웃</button>
        )}
        <p className="s0-guest-note">가입 없이 게스트로 첫 운세를 볼 수 있어요</p>
      </div>
    </section>
  );
});

export function S1CharIntro(props: { onNext: () => void }) {
  return (
    <section className="screen">
      <div className="step-pill">1 / 4 · 무당 확인</div>
      <h2 className="screen-title">홍연이 오늘의 무대를<br />준비하고 있어요</h2>
      <div className="charintro-frame talisman-frame">
        <div className="talisman-inner-line" aria-hidden="true" />
        <img className="charintro-image" src="/static/assets/hongyeon-idle.webp" alt="홍연" />
        <div className="charintro-caption">
          <div className="charintro-name-row">
            <span className="charintro-name">홍연</span>
            <span className="gold-badge">베타 단독</span>
          </div>
          <p className="charintro-desc">붉은 단청의 에너지형 퍼포머 · 연애운 · 자신감 · 대인관계</p>
        </div>
      </div>
      <button className="cta-button" type="button" onClick={props.onNext}>홍연에게 듣기</button>
    </section>
  );
}

const HOUR_OPTIONS: Array<[string, string]> = [
  ["", "모름"],
  ["0", "자시 (23:00–01:00)"], ["2", "축시 (01:00–03:00)"], ["4", "인시 (03:00–05:00)"],
  ["6", "묘시 (05:00–07:00)"], ["8", "진시 (07:00–09:00)"], ["10", "사시 (09:00–11:00)"],
  ["12", "오시 (11:00–13:00)"], ["14", "미시 (13:00–15:00)"], ["16", "신시 (15:00–17:00)"],
  ["18", "유시 (17:00–19:00)"], ["20", "술시 (19:00–21:00)"], ["22", "해시 (21:00–23:00)"],
];

export function S2ProfileForm(props: {
  stepLabel: string;
  initial: Profile | null;
  onSubmit: (profile: Profile) => void;
}) {
  const initial = props.initial;
  const [nickname, setNickname] = useState(initial?.nickname ?? "");
  const [birthDate, setBirthDate] = useState(
    initial && initial.birthYear
      ? `${String(initial.birthYear).padStart(4, "0")}-${String(initial.birthMonth).padStart(2, "0")}-${String(initial.birthDay).padStart(2, "0")}`
      : "",
  );
  const [birthHour, setBirthHour] = useState(
    initial?.birthHour === null || initial?.birthHour === undefined ? "" : String(initial.birthHour),
  );
  const [errors, setErrors] = useState<ProfileErrors>({});
  const [privacyOpen, setPrivacyOpen] = useState(false);

  const currentErrors = validateProfileInput(nickname, birthDate);
  const canNext = Object.keys(currentErrors).length === 0;

  const submit = () => {
    setErrors(currentErrors);
    if (!canNext) return;
    const parts = birthDate.split("-").map(Number);
    props.onSubmit({
      nickname: nickname.trim(),
      birthYear: parts[0],
      birthMonth: parts[1],
      birthDay: parts[2],
      birthHour: birthHour === "" ? null : Number(birthHour),
    });
  };

  return (
    <section className="screen">
      <div className="step-pill">{props.stepLabel}</div>
      <h2 className="screen-title">시작 전 몇 가지만<br />알려주세요</h2>

      <label className="field-label" htmlFor="profile-nickname">닉네임 (최대 {NICKNAME_MAX_LENGTH}자)</label>
      <input id="profile-nickname" className="field-input" type="text" autoComplete="off"
        placeholder="닉네임을 입력해주세요" value={nickname}
        onChange={(e) => setNickname(e.target.value.slice(0, NICKNAME_MAX_LENGTH))}
        onBlur={() => setErrors(currentErrors)} />
      {errors.nickname && <p className="field-error">{errors.nickname}</p>}

      <label className="field-label" htmlFor="profile-birth-date">생년월일</label>
      <input id="profile-birth-date" className="field-input" type="date" value={birthDate}
        onChange={(e) => setBirthDate(e.target.value)} onBlur={() => setErrors(currentErrors)} />
      {errors.birthDate && <p className="field-error">{errors.birthDate}</p>}

      <label className="field-label" htmlFor="profile-birth-hour">출생시간 (선택)</label>
      <select id="profile-birth-hour" className="field-input" value={birthHour}
        onChange={(e) => setBirthHour(e.target.value)}>
        {HOUR_OPTIONS.map(([value, label]) => (
          <option key={value} value={value}>{label}</option>
        ))}
      </select>

      <div className="screen-spacer" />

      <p className="privacy-banner">
        입력 정보는 오늘의 운세 생성에만 사용되며, 이 기기에만 저장됩니다.{" "}
        <a href="#" className="privacy-detail-link"
          onClick={(e) => { e.preventDefault(); setPrivacyOpen(!privacyOpen); }}>
          상세 보기
        </a>
      </p>
      {privacyOpen && (
        <p className="privacy-detail-text">
          닉네임·생년월일·출생시간은 서버로 전송되지 않고 이 기기의 localStorage에만 저장됩니다.
          운세를 생성할 때는 생년월일·출생시간 대신 해시로 변환된 값만 서버에 전달되며,
          원본 생년월일·출생시간은 화면이나 공유 카드 어디에도 다시 표시되지 않습니다.
        </p>
      )}

      <button className="cta-button" type="button" disabled={!canNext} onClick={submit}>다음</button>
    </section>
  );
}

export function S3TopicSelect(props: {
  stepLabel: string;
  nickname: string | null;
  selectedTopic: string;
  loading: boolean;
  onSelect: (key: string) => void;
  onEditProfile: () => void;
  onStart: () => void;
}) {
  return (
    <section className="screen">
      <div className="step-pill">{props.stepLabel}</div>
      <h2 className="screen-title">
        <span>{props.nickname || "오늘의 손님"}</span> 님,<br />오늘 어떤 기운이 궁금하세요?
      </h2>
      {props.nickname && (
        <p className="profile-summary">
          <span>{props.nickname}님</span>
          <button className="link-button" type="button" onClick={props.onEditProfile}>변경</button>
        </p>
      )}
      <div className="topic-list">
        {TOPICS.map((topic) => (
          <button key={topic.key} type="button"
            className={"topic-button" + (props.selectedTopic === topic.key ? " topic-button--selected" : "")}
            onClick={() => props.onSelect(topic.key)}>
            <span>{topic.label}</span>
            <span className="topic-desc">{topic.desc}</span>
          </button>
        ))}
      </div>
      <div className="screen-spacer" />
      <button className="cta-button" type="button" disabled={!props.selectedTopic || props.loading} onClick={props.onStart}>
        {props.loading ? "불러오는 중…" : "운세 보기"}
      </button>
    </section>
  );
}
