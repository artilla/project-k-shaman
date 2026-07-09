// 꿈 해몽 D1(입력) · D2(공연) · D3(꿈 부적) — 원본: reference/design-prototype-dream
import { forwardRef, useState } from "react";
import { DREAM_MAX_SYMBOLS, DREAM_MAX_TEXT, DREAM_SYMBOL_LABELS, type DreamReading } from "../lib/dream";
import { playerLabel } from "../lib/constants";
import type { AvatarState, PlayerPhase } from "../lib/types";

export function D1DreamInput(props: {
  onSubmit: (text: string, symbols: string[]) => void;
  loading: boolean;
}) {
  const [text, setText] = useState("");
  const [selected, setSelected] = useState<string[]>([]);
  const canSubmit = (text.trim().length > 0 || selected.length > 0) && !props.loading;

  const toggle = (label: string) => {
    setSelected((prev) =>
      prev.includes(label) ? prev.filter((x) => x !== label) : [...prev, label].slice(-DREAM_MAX_SYMBOLS),
    );
  };

  return (
    <section className="screen">
      <div className="step-pill">꿈 해몽 1 / 3 · 꿈 들려주기</div>
      <h2 className="screen-title">간밤에 어떤 꿈을<br />꾸셨나요?</h2>
      <p className="dream-hint">기억나는 대로 적어주세요. 상징 칩을 탭하면 더 정확해져요.</p>

      <textarea
        className="dream-textarea"
        rows={5}
        placeholder="예) 커다란 구렁이가 집 안으로 들어와 품에 안기는 꿈을 꿨어요…"
        value={text}
        onChange={(e) => setText(e.target.value.slice(0, DREAM_MAX_TEXT))}
      />
      <div className={"dream-charcount" + (text.length >= DREAM_MAX_TEXT ? " dream-charcount--limit" : "")}>
        {text.length} / {DREAM_MAX_TEXT}
      </div>

      <p className="dream-chip-label">자주 나오는 꿈 상징</p>
      <div className="dream-chips">
        {DREAM_SYMBOL_LABELS.map((label) => (
          <button key={label} type="button"
            className={"dream-chip" + (selected.includes(label) ? " dream-chip--on" : "")}
            onClick={() => toggle(label)}>
            {label}
          </button>
        ))}
      </div>

      <div className="screen-spacer" />
      <div className="dream-privacy">
        <span className="dream-privacy-mark">i</span>
        <span>꿈 내용은 해몽 생성에만 사용되고 서버에 저장되지 않아요. 해몽이 끝나면 이 기기에서도 바로 지워집니다.</span>
      </div>
      <button className="cta-button" type="button" disabled={!canSubmit}
        onClick={() => props.onSubmit(text, selected)}>
        {props.loading ? "청하는 중…" : "홍연에게 해몽 청하기"}
      </button>
    </section>
  );
}

export const D2DreamStage = forwardRef<HTMLDivElement, {
  loading: boolean;
  reading: DreamReading | null;
  statusMessage: string | null;
  phase: PlayerPhase;
  avatarState: AvatarState;
  progressPct: number;
  live2dActive: boolean;
  onListen: () => void;
  onPlayPause: () => void;
  onReplay: () => void;
  onTalisman: () => void;
}>(function D2DreamStage(props, avatarRef) {
  const { reading, phase, avatarState } = props;
  const assetState = avatarState === "idle" && phase === "done" ? "blessing" : avatarState;
  return (
    <div className="screen">
      <div className="step-pill">꿈 해몽 2 / 3 · 홍연의 풀이</div>
      <div className="stage-avatar-wrap">
        <div className="stage-avatar-glow" aria-hidden="true" />
        <div className="talisman-frame stage-avatar-frame stage-avatar-frame--dream">
          <div className="talisman-inner-line" aria-hidden="true" />
          <div ref={avatarRef}
            className={"avatar avatar--" + assetState + (props.live2dActive ? " avatar--live2d" : "")}
            aria-hidden="true">
            <span className="avatar-emoji">🔮</span>
            <img className="avatar-image avatar-image--visible" src={`/static/assets/hongyeon-${assetState}.webp`} alt="" />
          </div>
        </div>
      </div>

      {props.loading && (
        <div className="stage-loading">
          <p className="stage-loading-text">홍연이 꿈의 상징을 읽고 있어요…</p>
          <div className="stage-loading-track"><div className="stage-loading-bar" /></div>
        </div>
      )}
      {props.statusMessage && <p className="status" aria-live="polite">{props.statusMessage}</p>}

      {reading && (
        <>
          <section className="fortune-card">
            <p className="card-summary">{reading.headline}</p>
            <div className="dream-section">
              <p className="dream-section-title">상징별 해석</p>
              {reading.symbols.map((sym) => (
                <div key={sym.label} className="dream-symbol-row">
                  <span className="dream-symbol-chip">{sym.label}</span>
                  <span className="dream-symbol-meaning">{sym.meaning}</span>
                </div>
              ))}
            </div>
            <div className="dream-section">
              <p className="dream-section-title">전체 풀이</p>
              <p className="dream-overall">{reading.overall}</p>
            </div>
            <div className="dream-today">
              <span className="dream-today-chip">오늘 운세</span>
              <span className="dream-today-text">{reading.todayLink}</span>
            </div>
          </section>

          <section className="player">
            <div className="player-head">
              <p className="player-state" aria-live="polite">
                {phase === "playing" || phase === "paused" ? "홍연의 해몽 낭독 중" : playerLabel(phase, avatarState)}
              </p>
              <span className="player-segment">{phase === "done" ? "풀이 종료" : ""}</span>
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
              <button className="gold-fill-button" type="button" onClick={props.onTalisman}>꿈 부적 받기</button>
            </div>
            <p className="tts-note">듣기를 탭하면 홍연의 목소리로 재생돼요. 자동 재생은 하지 않아요.</p>
          </section>
        </>
      )}
    </div>
  );
});

export function D3DreamTalisman(props: {
  reading: DreamReading;
  nickname: string | null;
  onSaveImage: () => void;
  onOpenShare: () => void;
  onRestart: () => void;
}) {
  const { reading } = props;
  const now = new Date();
  const dateLabel =
    now.getFullYear() + " . " + String(now.getMonth() + 1).padStart(2, "0") + " . " + String(now.getDate()).padStart(2, "0");
  return (
    <section className="screen">
      <div className="step-pill">꿈 해몽 3 / 3 · 꿈 부적</div>
      <h2 className="screen-title screen-title--sm">오늘의 꿈 부적</h2>

      <div className="talisman-card talisman-card--dream">
        <div className="talisman-inner-line talisman-inner-line--card" aria-hidden="true" />
        <div className="talisman-card-head">
          <span>{dateLabel}</span>
          <span>꿈 해몽</span>
        </div>
        <div className="talisman-card-body">
          <img src="/static/assets/hongyeon-share-card.webp" alt="홍연" />
          <div className="talisman-card-text">
            <p id="rc-summary">{reading.headline.replace(/"/g, "")}</p>
            <p className="talisman-card-for">
              <span>{props.nickname || "오늘의 손님"}</span> 님의 꿈을 풀어낸 홍연의 축원
            </p>
          </div>
        </div>
        <div className="talisman-card-chips">
          {reading.chips.map((chip) => (
            <span key={chip} className="chip chip--gold">{chip}</span>
          ))}
        </div>
        <div className="talisman-card-brand">오늘신당 · 꿈부적</div>
      </div>

      <p className="rc-blessing">“{reading.blessing}”</p>

      <div className="rc-actions">
        <button className="gold-outline-button" type="button" onClick={props.onSaveImage}>이미지 저장</button>
        <button className="cta-button cta-button--pill" type="button" onClick={props.onOpenShare}>공유하기</button>
      </div>
      <button className="link-button link-button--center" type="button" onClick={props.onRestart}>
        다른 꿈 해몽하기
      </button>
    </section>
  );
}
