// 상시 내비게이션 — 뒤로(스택), 로고=홈, 계정 바(US-8 로그인 진입점)
import type { AuthSession } from "../lib/types";

export function TopBar(props: {
  showBack: boolean;
  session: AuthSession;
  onBack: () => void;
  onHome: () => void;
  onLoginClick: () => void;
  onLogout: () => void;
}) {
  const { showBack, session, onBack, onHome, onLoginClick, onLogout } = props;
  return (
    <header className="top-bar">
      <div className="top-bar-left">
        {showBack && (
          <button className="glass-button glass-button--icon" type="button" aria-label="뒤로 가기" onClick={onBack}>
            <span className="back-glyph">‹</span>
          </button>
        )}
        <button className="logo-pill" type="button" aria-label="홈으로" onClick={onHome}>
          <span className="logo-mark">神</span>
          <span className="logo-name">오늘신당</span>
        </button>
      </div>
      <div className="account-bar">
        {session.loggedIn ? (
          <>
            <span className="account-status" aria-live="polite">
              {(session.nickname || "소셜 사용자") + "님"}
            </span>
            <button className="link-button" type="button" onClick={onLogout}>
              로그아웃
            </button>
          </>
        ) : (
          <button className="link-button" type="button" onClick={onLoginClick}>
            로그인
          </button>
        )}
      </div>
    </header>
  );
}
