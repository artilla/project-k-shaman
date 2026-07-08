// S4 캐릭터 스테이지 — 금선 부적 프레임 + 텍스트 카드(텍스트 먼저) + 글래스 플레이어
import { forwardRef } from "react";
import { LUCKY_COLOR_HEX, SCORE_LABELS, SCORE_ORDER, playerLabel, segmentLabel } from "../lib/constants";
import type { AvatarState, Fortune, PlayerPhase } from "../lib/types";

export const S4Stage = forwardRef<HTMLDivElement, {
  loading: boolean;
  fortune: Fortune | null;
  statusMessage: string | null;
  phase: PlayerPhase;
  avatarState: AvatarState;
  progressPct: number;
  live2dActive: boolean;
  onListen: () => void;
  onPlayPause: () => void;
  onReplay: () => void;
  onViewCard: () => void;
}>(function S4Stage(props, avatarRef) {
  const { fortune, phase, avatarState } = props;
  const assetState = avatarState === "idle" && phase === "done" ? "blessing" : avatarState;
  return (
    <div className="screen">
      <div className="stage-avatar-wrap">
        <div className="stage-avatar-glow" aria-hidden="true" />
        <div className="talisman-frame stage-avatar-frame">
          <div className="talisman-inner-line" aria-hidden="true" />
          <div
            ref={avatarRef}
            className={"avatar avatar--" + assetState + (props.live2dActive ? " avatar--live2d" : "")}
            aria-hidden="true"
          >
            <span className="avatar-emoji">🔮</span>
            <img className="avatar-image avatar-image--visible" src={`/static/assets/hongyeon-${assetState}.webp`} alt="" />
          </div>
        </div>
      </div>

      {props.loading && (
        <div className="stage-loading">
          <p className="stage-loading-text">홍연이 오늘의 기운을 읽고 있어요…</p>
          <div className="stage-loading-track"><div className="stage-loading-bar" /></div>
        </div>
      )}

      {props.statusMessage && <p className="status" aria-live="polite">{props.statusMessage}</p>}

      {fortune && (
        <section className="fortune-card">
          <p className="card-summary">{fortune.summary.join(" ")}</p>
          <p className="card-scores-line">{fortune.scores_line}</p>
          <ul className="card-scores">
            {SCORE_ORDER.map((key) => (
              <li key={key} className="score-row">
                <span className="score-label">{SCORE_LABELS[key]}</span>
                <span className="score-track">
                  <span className="score-bar" style={{ width: fortune.scores[key] + "%" }} />
                </span>
                <span className="score-value">{fortune.scores[key]}</span>
              </li>
            ))}
          </ul>
          <div className="card-lucky">
            <span className="lucky-swatch" style={{ backgroundColor: LUCKY_COLOR_HEX[fortune.lucky.color] || "#C9A24B" }} />
            <span className="lucky-text">행운 색: {fortune.lucky.color}</span>
            <span className="lucky-item">행운 아이템: {fortune.lucky.item}</span>
          </div>
          <p className="card-avoid">피하면 좋아요 — {fortune.avoid}</p>
        </section>
      )}

      {fortune && (
        <section className="player">
          <div className="player-head">
            <p className="player-state" aria-live="polite">{playerLabel(phase, avatarState)}</p>
            <span className="player-segment">{segmentLabel(phase, avatarState)}</span>
          </div>
          <div className="player-progress-track" aria-hidden="true">
            <div className="player-progress-bar" style={{ width: props.progressPct + "%" }} />
          </div>
          <div className="player-controls">
            {phase === "idle" && (
              <button className="cta-button cta-button--pill" type="button" onClick={props.onListen}>듣기</button>
            )}
            {(phase === "playing" || phase === "paused") && (
              <button className="ghost-button" type="button" onClick={props.onPlayPause}>
                {phase === "playing" ? "일시정지" : "재생"}
              </button>
            )}
            {phase === "done" && (
              <button className="gold-outline-button" type="button" onClick={props.onReplay}>다시 듣기</button>
            )}
            <button className="gold-fill-button" type="button" onClick={props.onViewCard}>결과 카드 보기</button>
          </div>
          <p className="tts-note">듣기를 탭하면 홍연의 목소리로 재생돼요. 자동 재생은 하지 않아요.</p>
        </section>
      )}
    </div>
  );
});
