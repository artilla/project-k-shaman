// S5 부적 카드 — 금선 카드 + streak + 공유/저장
import { BLESSING_TEXT, LUCKY_COLOR_HEX, TOPIC_NAMES } from "../lib/constants";
import type { Fortune } from "../lib/types";

export function S5ResultCard(props: {
  fortune: Fortune;
  topic: string;
  nickname: string | null;
  streak: number;
  pushOn: boolean;
  shareStatus: string | null;
  onSaveImage: () => void;
  onOpenShare: () => void;
  onPush: () => void;
  onRestart: () => void;
}) {
  const { fortune } = props;
  const luckyHex = LUCKY_COLOR_HEX[fortune.lucky.color] || "#C9A24B";
  const now = new Date();
  const dateLabel =
    now.getFullYear() + " . " + String(now.getMonth() + 1).padStart(2, "0") + " . " + String(now.getDate()).padStart(2, "0");

  return (
    <section className="screen">
      <h2 className="screen-title screen-title--sm">오늘의 부적 카드</h2>

      <div className="talisman-card">
        <div className="talisman-inner-line talisman-inner-line--card" aria-hidden="true" />
        <div className="talisman-card-head">
          <span>{dateLabel}</span>
          <span>{TOPIC_NAMES[props.topic] || "총운"}</span>
        </div>
        <div className="talisman-card-body">
          <img src="/static/assets/hongyeon-share-card.webp" alt="홍연" style={{ borderColor: luckyHex }} />
          <div className="talisman-card-text">
            <p id="rc-summary">{fortune.summary[0]}</p>
            <p className="talisman-card-for">
              <span>{props.nickname || "오늘의 손님"}</span> 님을 위한 홍연의 축원
            </p>
          </div>
        </div>
        <div className="talisman-card-chips">
          <span className="chip" style={{ color: luckyHex, borderColor: luckyHex }}>행운 색 {fortune.lucky.color}</span>
          <span className="chip chip--gold">행운 아이템 {fortune.lucky.item}</span>
        </div>
        <div className="talisman-card-brand">오늘신당</div>
      </div>

      <p className="rc-blessing">“{BLESSING_TEXT}”</p>

      <div className="rc-actions">
        <button className="gold-outline-button" type="button" onClick={props.onSaveImage}>이미지 저장</button>
        <button className="cta-button cta-button--pill" type="button" onClick={props.onOpenShare}>공유하기</button>
      </div>
      {props.shareStatus && <p className="status" aria-live="polite">{props.shareStatus}</p>}

      <div className="streak-box">
        <div className="streak-text">
          <span className="streak-label">{props.streak}일 연속 방문 중</span>
          <span className="streak-sub">내일도 홍연의 무대가 열려요</span>
        </div>
        <button className="gold-pill-button" type="button" onClick={props.onPush}>
          {props.pushOn ? "알림 예약됨" : "내일 알림 받기"}
        </button>
      </div>
      <button className="link-button link-button--center" type="button" onClick={props.onRestart}>
        처음부터 다시 보기
      </button>
    </section>
  );
}
