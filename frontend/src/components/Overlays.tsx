// 로그인 유도 모달(재생·부적 게이트) · 공유 바텀 시트 · 토스트
import { loginUrl } from "../lib/api";

export function LoginPrompt(props: {
  open: boolean;
  providers: { google: boolean; kakao: boolean };
  message?: string;
  onClose: () => void;
  onLogin: (provider: "google" | "kakao") => void;
}) {
  if (!props.open) return null;
  return (
    <div className="login-prompt">
      <div className="login-prompt-backdrop" onClick={props.onClose} />
      <div className="login-prompt-card" role="dialog" aria-modal="true" aria-labelledby="login-prompt-title">
        <h2 id="login-prompt-title" className="login-prompt-title">로그인이 필요해요</h2>
        <p className="login-prompt-text">
          {props.message ?? "홍연의 목소리 재생과 부적 받기는 로그인 후 이용할 수 있어요. 운세 보기는 로그인 없이 계속 가능해요."}
        </p>
        <button
          className="glass-button glass-button--wide"
          type="button"
          disabled={!props.providers.google}
          title={props.providers.google ? "" : "관리자 설정 필요"}
          onClick={() => props.onLogin("google")}
        >
          Google로 계속
        </button>
        <button
          className="glass-button glass-button--wide"
          type="button"
          disabled={!props.providers.kakao}
          title={props.providers.kakao ? "" : "관리자 설정 필요"}
          onClick={() => props.onLogin("kakao")}
        >
          카카오로 계속
        </button>
        <button className="link-button link-button--center" type="button" onClick={props.onClose}>
          나중에 할게요
        </button>
      </div>
    </div>
  );
}

const SHARE_TARGETS = [
  { label: "카카오톡", initial: "K", bg: "#FEE500", fg: "#1B1029", toast: "카카오톡 공유는 곧 열려요" },
  { label: "인스타그램", initial: "IG", bg: "linear-gradient(135deg,#C9184A,#7B2CBF)", fg: "#FFF", toast: "인스타그램 공유는 곧 열려요" },
  { label: "X", initial: "X", bg: "rgba(255,255,255,.14)", fg: "#F5EEFC", toast: "X 공유는 곧 열려요" },
  { label: "더보기", initial: "⋯", bg: "rgba(255,255,255,.08)", fg: "#F5EEFC", system: true as const },
];

export function ShareSheet(props: {
  open: boolean;
  onClose: () => void;
  onSystemShare: () => void;
  onCopyLink: () => void;
  onMockShare: (message: string) => void;
}) {
  if (!props.open) return null;
  return (
    <div className="share-sheet">
      <div className="sheet-backdrop" onClick={props.onClose} />
      <div className="sheet-panel" role="dialog" aria-modal="true" aria-label="부적 카드 공유">
        <div className="sheet-handle" aria-hidden="true" />
        <p className="sheet-title">부적 카드 공유</p>
        <div className="share-targets">
          {SHARE_TARGETS.map((target) => (
            <button
              key={target.label}
              type="button"
              className="share-target"
              onClick={() => {
                props.onClose();
                if ("system" in target && target.system) props.onSystemShare();
                else props.onMockShare(target.toast!);
              }}
            >
              <span className="share-target-icon" style={{ background: target.bg, color: target.fg }}>
                {target.initial}
              </span>
              {target.label}
            </button>
          ))}
        </div>
        <button className="glass-button glass-button--wide" type="button" onClick={props.onCopyLink}>
          링크 복사
        </button>
      </div>
    </div>
  );
}

export function Toast(props: { message: string | null; nonce: number }) {
  if (!props.message) return null;
  // key로 재마운트 → ts-toast 애니메이션 재시작
  return (
    <div key={props.nonce} className="toast">
      {props.message}
    </div>
  );
}

export { loginUrl };
