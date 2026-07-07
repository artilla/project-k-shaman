// T022: S4 무대 재생 UX 최소판 — phase C 구조화 텍스트 카드 + phase D 플레이어 FSM
// (idle→greeting→speaking→blessing, screen-ia.md §2 S4 / §3). 텍스트 먼저(v3 §11.1),
// autoplay 금지(§11.2) 전제는 T019와 동일하게 유지한다: "듣기" 탭 전에는 오디오를 열지 않는다.
(function () {
  "use strict";

  const startBtn = document.getElementById("start-btn");
  const statusEl = document.getElementById("status");
  const avatarEl = document.getElementById("avatar");

  const fortuneCardEl = document.getElementById("fortune-card");
  const cardSummaryEl = document.getElementById("card-summary");
  const cardScoresLineEl = document.getElementById("card-scores-line");
  const cardScoresEl = document.getElementById("card-scores");
  const cardLuckyColorEl = document.getElementById("card-lucky-color");
  const cardLuckyTextEl = document.getElementById("card-lucky-text");
  const cardLuckyItemEl = document.getElementById("card-lucky-item");
  const cardAvoidEl = document.getElementById("card-avoid");

  const playerEl = document.getElementById("player");
  const playerStateEl = document.getElementById("player-state");
  const playerProgressBarEl = document.getElementById("player-progress-bar");
  const listenBtn = document.getElementById("listen-btn");
  const playPauseBtn = document.getElementById("play-pause-btn");
  const replayBtn = document.getElementById("replay-btn");

  const shareBtn = document.getElementById("share-btn");
  const shareStatusEl = document.getElementById("share-status");

  // character-sheet-hongyeon.md §6 lucky.color 팔레트 — share_card.py PALETTE와 동일하게 유지한다.
  const LUCKY_COLOR_HEX = {
    "코랄 핑크": "#ff6f91",
    "진홍": "#c9184a",
    "자수정 보라": "#7b2cbf",
    "청록": "#168aad",
    "살구색": "#ffb38a",
    "금빛": "#f2b705",
    "먹색": "#1f2933",
    "은백": "#f4f6f8",
  };
  const SCORE_ORDER = ["love", "money", "work", "relationship", "condition"];
  const SCORE_LABELS = { love: "연애", money: "금전", work: "일", relationship: "관계", condition: "컨디션" };

  // 아바타 상태 레이블 (character-sheet §6 "아바타 상태").
  const PLAYER_STATE_LABELS = {
    idle: "대기 중",
    greeting: "인사하는 중",
    speaking: "이야기하는 중",
    blessing: "축원하는 중",
    done: "다 들었어요",
  };

  let currentFortuneId = null;
  let currentScript = null;
  let currentAudioUrl = null;
  let sessionStartMs = null;
  let audioPlayReported = false;
  let audioEl = null;
  let segmentBoundaries = null; // narration 세그먼트별 누적 종료 시각(초)

  function setPlayerState(state) {
    playerStateEl.textContent = PLAYER_STATE_LABELS[state] || state;
    avatarEl.className = "avatar avatar--" + (state === "done" ? "idle" : state);
  }

  function renderScoreBars(scores) {
    cardScoresEl.innerHTML = "";
    SCORE_ORDER.forEach(function (key) {
      const value = scores[key];
      const li = document.createElement("li");
      li.className = "score-row";

      const label = document.createElement("span");
      label.className = "score-label";
      label.textContent = SCORE_LABELS[key];

      const track = document.createElement("span");
      track.className = "score-track";
      const bar = document.createElement("span");
      bar.className = "score-bar";
      bar.style.width = value + "%";
      track.appendChild(bar);

      const valueEl = document.createElement("span");
      valueEl.className = "score-value";
      valueEl.textContent = value;

      li.appendChild(label);
      li.appendChild(track);
      li.appendChild(valueEl);
      cardScoresEl.appendChild(li);
    });
  }

  function renderCard(fortune) {
    cardSummaryEl.textContent = fortune.summary.join(" ");
    cardScoresLineEl.textContent = fortune.scores_line;
    renderScoreBars(fortune.scores);
    cardLuckyColorEl.style.backgroundColor = LUCKY_COLOR_HEX[fortune.lucky.color] || "#e6a0ff";
    cardLuckyTextEl.textContent = "행운의 색: " + fortune.lucky.color;
    cardLuckyItemEl.textContent = "행운의 아이템: " + fortune.lucky.item;
    cardAvoidEl.textContent = "이건 피해보세요: " + fortune.avoid;
    fortuneCardEl.hidden = false;
  }

  // 세그먼트별 오디오 분할 재생은 non-goal(단일 오디오 유지) — 텍스트 길이 비중으로 근사한
  // 재생 진행률 경계를 계산해 FSM 전이 타이밍을 시뮬레이션한다 (§7 위험 완화).
  function computeSegmentBoundaries(script, totalDurationSec) {
    const weights = script.map(function (seg) {
      return Math.max((seg.text || "").length, 1);
    });
    const totalWeight = weights.reduce(function (a, b) { return a + b; }, 0);
    let acc = 0;
    return weights.map(function (w) {
      acc += w;
      return (acc / totalWeight) * totalDurationSec;
    });
  }

  // screen-ia.md §3.2 narration 세그먼트 순서 → 아바타/플레이어 상태 매핑.
  function stateForSegmentIndex(idx) {
    if (idx <= 0) {
      return "greeting";
    }
    if (idx >= 6) {
      return "blessing";
    }
    return "speaking";
  }

  function currentSegmentIndex(currentTime, boundaries) {
    for (let i = 0; i < boundaries.length; i++) {
      if (currentTime <= boundaries[i]) {
        return i;
      }
    }
    return boundaries.length - 1;
  }

  function reportEvents(fortuneId, clientEvents, serverEvents) {
    return fetch("/api/event", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        fortuneId: fortuneId,
        sessionStartMs: sessionStartMs,
        clientEvents: clientEvents,
        serverEvents: serverEvents,
      }),
    }).catch(function (err) {
      // 계측 실패는 재생 경험을 막지 않는다 — 콘솔에만 남긴다.
      console.warn("event report failed", err);
    });
  }

  function downloadBlob(blob, fileName) {
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = fileName;
    document.body.appendChild(a);
    a.click();
    a.remove();
    URL.revokeObjectURL(url);
  }

  function shareOrDownload(fortuneId, blob) {
    const fileName = "hongyeon-share-" + fortuneId + ".svg";
    if (window.navigator.share) {
      const file = new File([blob], fileName, { type: "image/svg+xml" });
      const canShareFile = !window.navigator.canShare || window.navigator.canShare({ files: [file] });
      if (canShareFile) {
        return window.navigator
          .share({ files: [file], title: "오늘신당 홍연 부적" })
          .catch(function () {
            return downloadBlob(blob, fileName);
          });
      }
    }
    downloadBlob(blob, fileName);
    return Promise.resolve();
  }

  // 재생 리포트(reportEvents)와 별도 시점에 눌리므로, 공유 이벤트는 매번 새 /api/event 호출로 보낸다.
  function onShareTap() {
    if (!currentFortuneId) {
      return;
    }
    const fortuneId = currentFortuneId;
    shareBtn.disabled = true;
    shareStatusEl.textContent = "부적을 준비하는 중…";
    reportEvents(fortuneId, [{ event: "share_initiated", clientTs: Date.now() }], []);

    fetch("/api/share-card?fortuneId=" + encodeURIComponent(fortuneId))
      .then(function (res) {
        if (!res.ok) {
          throw new Error("부적을 불러오지 못했어요");
        }
        return res.blob();
      })
      .then(function (blob) {
        return shareOrDownload(fortuneId, blob);
      })
      .then(function () {
        shareStatusEl.textContent = "부적을 받았어요";
        reportEvents(fortuneId, [{ event: "share_completed", clientTs: Date.now() }], []);
      })
      .catch(function (err) {
        shareStatusEl.textContent = "오류: " + err.message;
        console.error(err);
      })
      .finally(function () {
        shareBtn.disabled = false;
      });
  }

  function resetPlayerControlsForListen() {
    listenBtn.hidden = false;
    listenBtn.disabled = false;
    listenBtn.textContent = "듣기";
    playPauseBtn.hidden = true;
    replayBtn.hidden = true;
    playerProgressBarEl.style.width = "0%";
    setPlayerState("idle");
  }

  function showPlayingControls() {
    listenBtn.hidden = true;
    playPauseBtn.hidden = false;
    playPauseBtn.textContent = "일시정지";
    replayBtn.hidden = true;
  }

  function showReplayControls() {
    playPauseBtn.hidden = true;
    replayBtn.hidden = false;
  }

  function onAudioTimeUpdate() {
    const duration = isFinite(audioEl.duration) && audioEl.duration > 0 ? audioEl.duration : null;
    if (!duration) {
      return;
    }
    if (!segmentBoundaries) {
      segmentBoundaries = computeSegmentBoundaries(currentScript, duration);
    }
    const idx = currentSegmentIndex(audioEl.currentTime, segmentBoundaries);
    setPlayerState(stateForSegmentIndex(idx));
    playerProgressBarEl.style.width = Math.min(100, (audioEl.currentTime / duration) * 100) + "%";
  }

  function onAudioPlaying() {
    if (!audioPlayReported) {
      audioPlayReported = true;
      reportEvents(currentFortuneId, [{ event: "first_audio_play", clientTs: Date.now() }], []);
    }
  }

  function onAudioEnded() {
    playerProgressBarEl.style.width = "100%";
    setPlayerState("done");
    showReplayControls();
  }

  function onAudioError() {
    statusEl.textContent = "오디오 재생에 실패했어요. 다시 들어보세요.";
    showReplayControls();
  }

  function ensureAudioElement(audioUrl) {
    if (!audioEl) {
      audioEl = new Audio();
      audioEl.addEventListener("timeupdate", onAudioTimeUpdate);
      audioEl.addEventListener("playing", onAudioPlaying);
      audioEl.addEventListener("ended", onAudioEnded);
      audioEl.addEventListener("error", onAudioError);
    }
    if (audioEl.src !== audioUrl) {
      audioEl.src = audioUrl;
      segmentBoundaries = null;
    }
    return audioEl;
  }

  // "듣기" 탭 = phase D 진입점. 여기서만 오디오를 실제로 연다 (autoplay 금지, v3 §11.2).
  function onListenTap() {
    if (!currentFortuneId || !currentAudioUrl) {
      return;
    }
    const audio = ensureAudioElement(currentAudioUrl);
    showPlayingControls();
    setPlayerState("greeting");
    audio.play().catch(onAudioError);
  }

  function onPlayPauseTap() {
    if (!audioEl) {
      return;
    }
    if (audioEl.paused) {
      audioEl.play().catch(onAudioError);
      playPauseBtn.textContent = "일시정지";
    } else {
      audioEl.pause();
      playPauseBtn.textContent = "재생";
    }
  }

  function onReplayTap() {
    if (!audioEl) {
      return;
    }
    audioEl.currentTime = 0;
    showPlayingControls();
    setPlayerState("greeting");
    audioEl.play().catch(onAudioError);
  }

  function onTap() {
    sessionStartMs = Date.now();
    audioPlayReported = false;
    segmentBoundaries = null;

    startBtn.disabled = true;
    startBtn.textContent = "불러오는 중…";
    statusEl.textContent = "";

    fetch("/api/fortune/today")
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        currentFortuneId = data.fortuneId;
        currentScript = data.script;
        currentAudioUrl = data.audioUrl;

        // 텍스트 먼저: 오디오를 기다리지 않고 즉시 카드로 노출한다.
        renderCard(data.fortune);
        statusEl.textContent = "";
        reportEvents(data.fortuneId, [{ event: "first_text_visible", clientTs: Date.now() }], data.events);

        // phase D 플레이어 — "듣기" 탭 전까지는 오디오를 열지 않는다.
        resetPlayerControlsForListen();
        playerEl.hidden = false;

        // 텍스트 노출 시점에 "부적 받기"를 노출한다 — 오디오 재생 성공 여부와 무관하다.
        shareStatusEl.textContent = "";
        shareBtn.hidden = false;
      })
      .catch(function (err) {
        statusEl.textContent = "오류: " + err.message;
        console.error(err);
      })
      .finally(function () {
        startBtn.textContent = "다시 보기";
        startBtn.disabled = false;
      });
  }

  startBtn.addEventListener("click", onTap);
  listenBtn.addEventListener("click", onListenTap);
  playPauseBtn.addEventListener("click", onPlayPauseTap);
  replayBtn.addEventListener("click", onReplayTap);
  shareBtn.addEventListener("click", onShareTap);
})();
