// v2 리디자인 — 프로토타입 v2(reference/design-prototype-v2) 기반 S0~S6 플로우.
// 유지 불변식: 텍스트 먼저(v3 §11.1), autoplay 금지(§11.2 — "듣기" 탭 전에는 오디오를 열지 않는다),
// 프로필 로컬 우선(v3 §12), 재생·부적 로그인 게이트(클라이언트+서버 401), 기존 이벤트 훅 무회귀.
(function () {
  "use strict";

  const PROFILE_STORAGE_KEY = "shindang.profile";
  const STREAK_STORAGE_KEY = "shindang.streak";
  const PROFILE_NICKNAME_MAX_LENGTH = 10;
  const BLESSING_TEXT = "오늘 하루, 홍연이 손님 곁에서 기운을 더해드릴게요.";

  // ── 요소 참조 ──
  const onboardingEl = document.getElementById("onboarding");
  const s0AvatarEl = document.getElementById("s0-avatar");
  const authErrorBannerEl = document.getElementById("auth-error-banner");
  const backBtn = document.getElementById("back-btn");
  const homeBtn = document.getElementById("home-btn");
  const accountStatusEl = document.getElementById("account-status");
  const accountLoginBtn = document.getElementById("account-login-btn");
  const accountLogoutBtn = document.getElementById("account-logout-btn");
  const loginPromptEl = document.getElementById("login-prompt");
  const loginPromptBackdropEl = document.getElementById("login-prompt-backdrop");
  const promptGoogleBtn = document.getElementById("prompt-google-btn");
  const promptKakaoBtn = document.getElementById("prompt-kakao-btn");
  const promptCloseBtn = document.getElementById("prompt-close-btn");
  const onboardingAccountStatusEl = document.getElementById("onboarding-account-status");
  const guestStartBtn = document.getElementById("guest-start-btn");
  const googleLoginBtn = document.getElementById("google-login-btn");
  const kakaoLoginBtn = document.getElementById("kakao-login-btn");
  const logoutBtn = document.getElementById("logout-btn");

  const charintroEl = document.getElementById("charintro");
  const charintroNextBtn = document.getElementById("charintro-next-btn");

  const profileFormEl = document.getElementById("profile-form");
  const profileNicknameInput = document.getElementById("profile-nickname");
  const profileNicknameErrorEl = document.getElementById("profile-nickname-error");
  const profileBirthDateInput = document.getElementById("profile-birth-date");
  const profileBirthDateErrorEl = document.getElementById("profile-birth-date-error");
  const profileBirthHourSelect = document.getElementById("profile-birth-hour");
  const profileNextBtn = document.getElementById("profile-next-btn");
  const privacyDetailLink = document.getElementById("privacy-detail-link");
  const privacyDetailTextEl = document.getElementById("privacy-detail-text");

  const s2StepPillEl = document.getElementById("s2-step-pill");
  const s3StepPillEl = document.getElementById("s3-step-pill");
  const topicSelectEl = document.getElementById("topic-select");
  const topicNicknameEl = document.getElementById("topic-nickname");
  const topicListEl = document.getElementById("topic-list");
  const profileSummaryEl = document.getElementById("profile-summary");
  const profileSummaryNicknameEl = document.getElementById("profile-summary-nickname");
  const editProfileBtn = document.getElementById("edit-profile-btn");
  const startBtn = document.getElementById("start-btn");

  const mainStageEl = document.getElementById("main-stage");
  const stageLoadingEl = document.getElementById("stage-loading");
  const statusEl = document.getElementById("status");
  const avatarEl = document.getElementById("avatar");
  const avatarImageEl = document.getElementById("avatar-image");

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
  const playerSegmentEl = document.getElementById("player-segment");
  const playerProgressBarEl = document.getElementById("player-progress-bar");
  const listenBtn = document.getElementById("listen-btn");
  const playPauseBtn = document.getElementById("play-pause-btn");
  const replayBtn = document.getElementById("replay-btn");
  const cardViewBtn = document.getElementById("card-view-btn");

  const resultCardEl = document.getElementById("result-card");
  const rcDateEl = document.getElementById("rc-date");
  const rcTopicEl = document.getElementById("rc-topic");
  const rcAvatarEl = document.getElementById("rc-avatar");
  const rcSummaryEl = document.getElementById("rc-summary");
  const rcNicknameEl = document.getElementById("rc-nickname");
  const rcLuckyColorEl = document.getElementById("rc-lucky-color");
  const rcLuckyItemEl = document.getElementById("rc-lucky-item");
  const rcBlessingEl = document.getElementById("rc-blessing");
  const shareBtn = document.getElementById("share-btn");
  const shareOpenBtn = document.getElementById("share-open-btn");
  const shareStatusEl = document.getElementById("share-status");
  const streakLabelEl = document.getElementById("streak-label");
  const pushBtn = document.getElementById("push-btn");
  const restartBtn = document.getElementById("restart-btn");

  const shareSheetEl = document.getElementById("share-sheet");
  const shareSheetBackdropEl = document.getElementById("share-sheet-backdrop");
  const shareTargetsEl = document.getElementById("share-targets");
  const copyLinkBtn = document.getElementById("copy-link-btn");
  const toastEl = document.getElementById("toast");

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

  // v2 S3 주제 선택 — 서버 /api/fortune/today?topic= 값과 1:1 (fortune-samples.v1.1).
  const TOPICS = [
    { key: "total", label: "총운", desc: "오늘 하루의 큰 흐름" },
    { key: "love", label: "연애", desc: "홍연의 강점 운세" },
    { key: "money", label: "금전", desc: "재물의 기운" },
    { key: "work", label: "일 / 학업", desc: "집중과 성취" },
    { key: "rel", label: "인간관계", desc: "사람 사이의 온도" },
  ];
  const TOPIC_NAMES = { total: "총운", love: "연애운", money: "금전운", work: "일 · 학업운", rel: "인간관계운" };

  const PLAYER_STATE_LABELS = {
    idle: "대기 중",
    greeting: "홍연 등장 중",
    speaking: "오늘의 운세 재생 중",
    blessing: "축원 중",
    done: "재생 완료",
  };
  const SEGMENT_LABELS = { idle: "", greeting: "greeting", speaking: "speaking", blessing: "blessing", done: "공연 종료" };

  // T024/ADR-0002: 상태별 정지컷 에셋(hongyeon-{state}.webp) — 기능 감지 후 존재하는 것만 스왑,
  // 부재 시 이모지 플레이스홀더 유지(폴백 불변식). 립싱크 아님.
  const AVATAR_ASSET_STATES = ["greeting", "idle", "speaking", "blessing"];
  const avatarAssetAvailable = {};

  // ── 상태 ──
  let currentProfile = null;
  let isLoggedIn = false;
  let selectedTopic = "";
  let currentFortuneId = null;
  let currentFortune = null;
  let currentScript = null;
  let currentAudioUrl = null;
  let sessionStartMs = null;
  let audioPlayReported = false;
  let audioEl = null;
  let segmentBoundaries = null; // narration 세그먼트별 누적 종료 시각(초)
  let pushOn = false;
  let toastTimer = null;
  let live2dInitRequested = false;
  // 단계 표시는 실제 밟는 경로 기준 — S1을 거친 첫 방문 퍼널에서만 "n / 4"를 쓴다.
  let inIntroFunnel = false;

  // speaking 음량 글로우용 WebAudio — AudioContext/AnalyserNode는 1회 생성 후 재사용
  // (항상 사용자 제스처인 듣기/다시 듣기 탭 안에서만 생성, §11.2 무회귀).
  let audioCtx = null;
  let analyserNode = null;
  let glowRafId = null;

  // ── 화면 라우터 (v2 S0~S5) ──
  const SCREENS = {
    s0: onboardingEl,
    s1: charintroEl,
    s2: profileFormEl,
    s3: topicSelectEl,
    s4: mainStageEl,
    s5: resultCardEl,
  };

  // 내비게이션 스택 — 로고(홈)·뒤로 버튼이 상시 내비 역할을 한다.
  let navHistory = [];
  let currentScreen = null;

  function showScreen(name, options) {
    const opts = options || {};
    if (currentScreen === name) {
      return;
    }
    if (currentScreen && opts.push !== false) {
      navHistory.push(currentScreen);
    }
    if (currentScreen === "s4" && name !== "s4") {
      stopAudioPlayback(); // 스테이지 이탈 시 재생 정지
    }
    currentScreen = name;
    backBtn.hidden = name === "s0";
    Object.keys(SCREENS).forEach(function (key) {
      SCREENS[key].hidden = key !== name;
    });
    closeShareSheet();
    if (name === "s3") {
      renderTopicScreen();
    }
    // v2(c): Live2D는 페이지 로드 시 S0 히어로에서 초기화되고, 화면 전환에 따라
    // 캔버스를 이동시킨다 (S0 히어로 ↔ S4 스테이지 프레임). requestAnimationFrame으로
    // hidden 해제 후 레이아웃이 잡힌 다음 크기를 재계산한다.
    if (window.HongyeonLive2D && window.HongyeonLive2D.moveTo) {
      if (name === "s0") {
        requestAnimationFrame(function () { window.HongyeonLive2D.moveTo(s0AvatarEl); });
      } else if (name === "s4") {
        requestAnimationFrame(function () { window.HongyeonLive2D.moveTo(avatarEl); });
      }
    }
    if (name === "s5") {
      renderResultCard();
    }
  }

  function goBack() {
    const prev = navHistory.pop();
    if (prev) {
      showScreen(prev, { push: false });
    } else {
      showScreen("s0", { push: false });
    }
  }

  function goHome() {
    navHistory = [];
    showScreen("s0", { push: false });
  }

  // ── 아바타 ──
  function avatarAssetUrl(state) {
    return "/static/assets/hongyeon-" + state + ".webp";
  }

  function preloadAvatarAssets() {
    AVATAR_ASSET_STATES.forEach(function (state) {
      if (state in avatarAssetAvailable) {
        return;
      }
      const img = new Image();
      img.onload = function () {
        avatarAssetAvailable[state] = true;
        if (avatarEl.className.indexOf("avatar--" + state) !== -1) {
          applyAvatarAsset(state);
        }
      };
      img.onerror = function () {
        // 에셋 부재는 정상 경로다(운영자 미배치) — 조용히 폴백만 유지한다.
        avatarAssetAvailable[state] = false;
      };
      img.src = avatarAssetUrl(state);
    });
  }

  function applyAvatarAsset(state) {
    if (!avatarAssetAvailable[state]) {
      avatarImageEl.hidden = true;
      avatarImageEl.classList.remove("avatar-image--visible");
      return;
    }
    avatarImageEl.classList.remove("avatar-image--visible");
    avatarImageEl.src = avatarAssetUrl(state);
    avatarImageEl.hidden = false;
    requestAnimationFrame(function () {
      avatarImageEl.classList.add("avatar-image--visible");
    });
  }

  function setPlayerState(state) {
    playerStateEl.textContent = state === "idle"
      ? "탭하면 홍연의 목소리로 들려드려요"
      : (PLAYER_STATE_LABELS[state] || state);
    playerSegmentEl.textContent = SEGMENT_LABELS[state] || "";
    const avatarState = state === "done" ? "blessing" : state;
    const live2dActive =
      window.HongyeonLive2D && window.HongyeonLive2D.isActive && window.HongyeonLive2D.isActive();
    avatarEl.className =
      "avatar avatar--" + avatarState + (live2dActive ? " avatar--live2d" : "");
    applyAvatarAsset(avatarState);
    // T025: Live2D 활성 시 FSM 상태를 표정/모션으로 전달 (비활성이면 no-op)
    if (window.HongyeonLive2D) {
      window.HongyeonLive2D.setState(avatarState);
    }
  }

  function ensureAudioAnalyser(audio) {
    if (analyserNode) {
      return analyserNode;
    }
    const AudioContextClass = window.AudioContext || window.webkitAudioContext;
    if (!AudioContextClass) {
      return null;
    }
    try {
      audioCtx = new AudioContextClass();
      const sourceNode = audioCtx.createMediaElementSource(audio);
      analyserNode = audioCtx.createAnalyser();
      analyserNode.fftSize = 256;
      sourceNode.connect(analyserNode);
      analyserNode.connect(audioCtx.destination);
    } catch (err) {
      analyserNode = null;
    }
    return analyserNode;
  }

  function startGlowLoop() {
    if (!analyserNode) {
      return;
    }
    const freqData = new Uint8Array(analyserNode.frequencyBinCount);
    (function tick() {
      if (!analyserNode) {
        return;
      }
      analyserNode.getByteFrequencyData(freqData);
      let sum = 0;
      for (let i = 0; i < freqData.length; i++) {
        sum += freqData[i];
      }
      const level = Math.min(1, sum / freqData.length / 128);
      avatarEl.style.setProperty("--glow-level", level.toFixed(3));
      if (window.HongyeonLive2D) {
        window.HongyeonLive2D.setMouth(level);
      }
      glowRafId = requestAnimationFrame(tick);
    })();
  }

  function stopGlowLoop() {
    if (glowRafId) {
      cancelAnimationFrame(glowRafId);
      glowRafId = null;
    }
    avatarEl.style.setProperty("--glow-level", "0");
    if (window.HongyeonLive2D) {
      window.HongyeonLive2D.setMouth(0);
    }
  }

  // ── 운세 텍스트 카드 ──
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
    cardLuckyColorEl.style.backgroundColor = LUCKY_COLOR_HEX[fortune.lucky.color] || "#C9A24B";
    cardLuckyTextEl.textContent = "행운 색: " + fortune.lucky.color;
    cardLuckyItemEl.textContent = "행운 아이템: " + fortune.lucky.item;
    cardAvoidEl.textContent = "피하면 좋아요 — " + fortune.avoid;
    fortuneCardEl.hidden = false;
  }

  // ── S5 부적 카드 ──
  function renderResultCard() {
    if (!currentFortune) {
      return;
    }
    const now = new Date();
    rcDateEl.textContent =
      now.getFullYear() + " . " +
      String(now.getMonth() + 1).padStart(2, "0") + " . " +
      String(now.getDate()).padStart(2, "0");
    rcTopicEl.textContent = TOPIC_NAMES[selectedTopic] || "총운";
    rcSummaryEl.textContent = currentFortune.summary[0];
    rcNicknameEl.textContent = (currentProfile && currentProfile.nickname) || "오늘의 손님";
    const luckyHex = LUCKY_COLOR_HEX[currentFortune.lucky.color] || "#C9A24B";
    rcAvatarEl.style.borderColor = luckyHex;
    rcLuckyColorEl.textContent = "행운 색 " + currentFortune.lucky.color;
    rcLuckyColorEl.style.color = luckyHex;
    rcLuckyColorEl.style.borderColor = luckyHex;
    rcLuckyItemEl.textContent = "행운 아이템 " + currentFortune.lucky.item;
    rcBlessingEl.textContent = "“" + BLESSING_TEXT + "”";
    streakLabelEl.textContent = computeStreak() + "일 연속 방문 중";
    pushBtn.textContent = pushOn ? "알림 예약됨" : "내일 알림 받기";
  }

  // ── streak (v2) — 프로필과 동일하게 이 기기에만 저장한다 ──
  function computeStreak() {
    try {
      const today = new Date().toISOString().slice(0, 10);
      const raw = JSON.parse(window.localStorage.getItem(STREAK_STORAGE_KEY) || "null");
      let count = 1;
      if (raw && raw.lastDate) {
        const diffDays = (new Date(today) - new Date(raw.lastDate)) / 86400000;
        count = diffDays === 0 ? raw.count : (diffDays === 1 ? raw.count + 1 : 1);
      }
      window.localStorage.setItem(STREAK_STORAGE_KEY, JSON.stringify({ count: count, lastDate: today }));
      return count;
    } catch (err) {
      return 1;
    }
  }

  // ── 토스트 (v2) ──
  function showToast(message) {
    if (toastTimer) {
      clearTimeout(toastTimer);
    }
    toastEl.hidden = true;
    toastEl.textContent = message;
    // 애니메이션 재시작을 위해 리플로우 강제
    void toastEl.offsetWidth;
    toastEl.hidden = false;
    toastTimer = setTimeout(function () {
      toastEl.hidden = true;
    }, 1900);
  }

  // ── 재생 진행률 근사 (세그먼트별 오디오 분할 재생은 non-goal, 단일 오디오 유지) ──
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

  // ── 부적 이미지 저장/공유 ──
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

  // 재생 리포트와 별도 시점에 눌리므로, 공유 이벤트는 매번 새 /api/event 호출로 보낸다.
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
        shareStatusEl.textContent = "";
        showToast("부적 카드를 받았어요");
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

  // ── S6 공유 바텀 시트 (v2) ──
  const SHARE_TARGETS = [
    { label: "카카오톡", initial: "K", bg: "#FEE500", fg: "#1B1029", toast: "카카오톡 공유는 곧 열려요" },
    { label: "인스타그램", initial: "IG", bg: "linear-gradient(135deg,#C9184A,#7B2CBF)", fg: "#FFF", toast: "인스타그램 공유는 곧 열려요" },
    { label: "X", initial: "X", bg: "rgba(255,255,255,.14)", fg: "#F5EEFC", toast: "X 공유는 곧 열려요" },
    { label: "더보기", initial: "⋯", bg: "rgba(255,255,255,.08)", fg: "#F5EEFC", system: true },
  ];

  function renderShareTargets() {
    shareTargetsEl.innerHTML = "";
    SHARE_TARGETS.forEach(function (target) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "share-target";
      const icon = document.createElement("span");
      icon.className = "share-target-icon";
      icon.style.background = target.bg;
      icon.style.color = target.fg;
      icon.textContent = target.initial;
      btn.appendChild(icon);
      btn.appendChild(document.createTextNode(target.label));
      btn.addEventListener("click", function () {
        closeShareSheet();
        if (target.system) {
          onShareTap(); // 시스템 공유 시트(Web Share) — share-card SVG 사용
        } else {
          showToast(target.toast);
        }
      });
      shareTargetsEl.appendChild(btn);
    });
  }

  function openShareSheet() {
    shareSheetEl.hidden = false;
  }

  function closeShareSheet() {
    shareSheetEl.hidden = true;
  }

  function onCopyLinkTap() {
    closeShareSheet();
    const url = window.location.origin + "/";
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(url).then(function () {
        showToast("링크가 복사되었어요");
      }).catch(function () {
        showToast("링크 복사에 실패했어요");
      });
    } else {
      showToast("이 브라우저에서는 링크 복사를 지원하지 않아요");
    }
  }

  // ── 플레이어 컨트롤 ──
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
    stopGlowLoop();
  }

  function onAudioError() {
    statusEl.textContent = "오디오 재생에 실패했어요. 다시 들어보세요.";
    showReplayControls();
    stopGlowLoop();
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
    ensureAudioAnalyser(audio);
    showPlayingControls();
    setPlayerState("greeting");
    audio.play().then(startGlowLoop).catch(onAudioError);
  }

  function onPlayPauseTap() {
    if (!audioEl) {
      return;
    }
    if (audioEl.paused) {
      audioEl.play().then(startGlowLoop).catch(onAudioError);
      playPauseBtn.textContent = "일시정지";
    } else {
      audioEl.pause();
      stopGlowLoop();
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
    audioEl.play().then(startGlowLoop).catch(onAudioError);
  }

  function stopAudioPlayback() {
    if (audioEl && !audioEl.paused) {
      audioEl.pause();
    }
    stopGlowLoop();
  }

  // ── 프로필 (localStorage 로컬 우선, v3 §12) ──
  function loadStoredProfile() {
    try {
      const raw = window.localStorage.getItem(PROFILE_STORAGE_KEY);
      if (!raw) {
        return null;
      }
      const parsed = JSON.parse(raw);
      return parsed && typeof parsed === "object" ? parsed : null;
    } catch (err) {
      return null;
    }
  }

  function saveStoredProfile(profile) {
    try {
      window.localStorage.setItem(PROFILE_STORAGE_KEY, JSON.stringify(profile));
    } catch (err) {
      // localStorage 사용 불가 환경(사파리 프라이빗 등) — 세션 내 진행 자체는 막지 않는다.
    }
  }

  // 12시진 대표 시각(profile-birth-hour의 select value)이 seed_builder._get_birth_time_bucket
  // 버킷 경계에 맞춰 있으므로 그대로 쿼리에 싣는다.
  function buildBirthQuery(profile) {
    if (!profile || !profile.birthYear || !profile.birthMonth || !profile.birthDay) {
      return "";
    }
    const params = new URLSearchParams();
    params.set("birth_year", profile.birthYear);
    params.set("birth_month", profile.birthMonth);
    params.set("birth_day", profile.birthDay);
    if (profile.birthHour !== null && profile.birthHour !== undefined) {
      params.set("birth_hour", profile.birthHour);
    }
    return "?" + params.toString();
  }

  function validateProfileForm() {
    const nickname = profileNicknameInput.value.trim();
    const birthDateRaw = profileBirthDateInput.value;
    const errors = {};

    if (!nickname) {
      errors.nickname = "닉네임을 입력해주세요.";
    } else if (nickname.length > PROFILE_NICKNAME_MAX_LENGTH) {
      errors.nickname = "닉네임은 최대 " + PROFILE_NICKNAME_MAX_LENGTH + "자까지 입력할 수 있어요.";
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

  function renderProfileErrors(errors) {
    profileNicknameErrorEl.textContent = errors.nickname || "";
    profileNicknameErrorEl.hidden = !errors.nickname;
    profileBirthDateErrorEl.textContent = errors.birthDate || "";
    profileBirthDateErrorEl.hidden = !errors.birthDate;
  }

  function updateNextButtonState() {
    const errors = validateProfileForm();
    profileNextBtn.disabled = Object.keys(errors).length > 0;
    return errors;
  }

  function prefillProfileForm(profile) {
    if (!profile) {
      return;
    }
    profileNicknameInput.value = profile.nickname || "";
    if (profile.birthYear && profile.birthMonth && profile.birthDay) {
      profileBirthDateInput.value =
        String(profile.birthYear).padStart(4, "0") + "-" +
        String(profile.birthMonth).padStart(2, "0") + "-" +
        String(profile.birthDay).padStart(2, "0");
    } else {
      profileBirthDateInput.value = "";
    }
    profileBirthHourSelect.value =
      profile.birthHour === null || profile.birthHour === undefined ? "" : String(profile.birthHour);
    updateNextButtonState();
  }

  // ── S3 주제 선택 ──
  function renderTopicScreen() {
    const nickname = (currentProfile && currentProfile.nickname) || "오늘의 손님";
    topicNicknameEl.textContent = nickname;
    // 첫 방문 퍼널(S1→S2→S3)에서만 단계 번호, 스킵 경로에선 라벨만.
    s3StepPillEl.textContent = inIntroFunnel ? "3 / 4 · 주제 선택" : "주제 선택";
    if (currentProfile && currentProfile.nickname) {
      profileSummaryNicknameEl.textContent = currentProfile.nickname + "님";
      profileSummaryEl.hidden = false;
    } else {
      profileSummaryEl.hidden = true;
    }
    renderTopicButtons();
    startBtn.disabled = !selectedTopic;
    startBtn.textContent = "운세 보기";
  }

  function renderTopicButtons() {
    topicListEl.innerHTML = "";
    TOPICS.forEach(function (topic) {
      const btn = document.createElement("button");
      btn.type = "button";
      btn.className = "topic-button" + (selectedTopic === topic.key ? " topic-button--selected" : "");
      const label = document.createElement("span");
      label.textContent = topic.label;
      const desc = document.createElement("span");
      desc.className = "topic-desc";
      desc.textContent = topic.desc;
      btn.appendChild(label);
      btn.appendChild(desc);
      btn.addEventListener("click", function () {
        selectedTopic = topic.key;
        renderTopicButtons();
        startBtn.disabled = false;
      });
      topicListEl.appendChild(btn);
    });
  }

  // ── 온보딩 진행 ──
  function onGuestStartTap() {
    // 재방문(프로필 보유) 시 S1·S2를 건너뛰고 주제 선택으로 — 첫 방문은 S1부터.
    inIntroFunnel = !currentProfile;
    showScreen(currentProfile ? "s3" : "s1");
  }

  function onCharintroNextTap() {
    if (!currentProfile) {
      s2StepPillEl.textContent = "2 / 4 · 정보 입력";
    }
    showScreen(currentProfile ? "s3" : "s2");
  }

  // 생년월일 원문은 로컬에만 저장하고, 이벤트 payload에는 존재 여부(hasBirthHour)만 싣는다(v3 §12).
  function onProfileNextTap() {
    const errors = validateProfileForm();
    renderProfileErrors(errors);
    if (Object.keys(errors).length > 0) {
      return;
    }
    const nickname = profileNicknameInput.value.trim();
    const parts = profileBirthDateInput.value.split("-").map(Number);
    const birthHourRaw = profileBirthHourSelect.value;
    const profile = {
      nickname: nickname,
      birthYear: parts[0],
      birthMonth: parts[1],
      birthDay: parts[2],
      birthHour: birthHourRaw === "" ? null : Number(birthHourRaw),
    };
    saveStoredProfile(profile);
    currentProfile = profile;
    reportEvents(null, [{
      event: "profile_saved",
      clientTs: Date.now(),
      hasBirthHour: profile.birthHour !== null,
    }], []);
    showScreen("s3");
  }

  function onEditProfileTap() {
    prefillProfileForm(currentProfile);
    s2StepPillEl.textContent = "프로필 수정";
    showScreen("s2");
  }

  function onPrivacyDetailTap(event) {
    event.preventDefault();
    privacyDetailTextEl.hidden = !privacyDetailTextEl.hidden;
  }

  // ── 인증 (T026 + 재생·부적 게이트) ──
  function applyProviderButtonState(btn, enabled) {
    btn.disabled = !enabled;
    btn.title = enabled ? "" : "관리자 설정 필요";
  }

  function fetchProviderStatus() {
    fetch("/api/auth/providers")
      .then(function (res) { return res.json(); })
      .then(function (data) {
        const providers = data.providers || {};
        applyProviderButtonState(googleLoginBtn, !!providers.google);
        applyProviderButtonState(kakaoLoginBtn, !!providers.kakao);
        applyProviderButtonState(promptGoogleBtn, !!providers.google);
        applyProviderButtonState(promptKakaoBtn, !!providers.kakao);
      })
      .catch(function () {
        applyProviderButtonState(googleLoginBtn, false);
        applyProviderButtonState(kakaoLoginBtn, false);
        applyProviderButtonState(promptGoogleBtn, false);
        applyProviderButtonState(promptKakaoBtn, false);
      });
  }

  function showLoggedInState(session) {
    googleLoginBtn.hidden = true;
    kakaoLoginBtn.hidden = true;
    onboardingAccountStatusEl.textContent = (session.nickname || "소셜 사용자") + "님으로 로그인됨";
    onboardingAccountStatusEl.hidden = false;
    logoutBtn.hidden = false;
  }

  // US-8: 상단 계정 바 — 재방문자의 로그인 진입점.
  function updateAccountBar(session) {
    if (session) {
      accountStatusEl.textContent = (session.nickname || "소셜 사용자") + "님";
      accountStatusEl.hidden = false;
      accountLoginBtn.hidden = true;
      accountLogoutBtn.hidden = false;
    } else {
      accountStatusEl.hidden = true;
      accountLoginBtn.hidden = false;
      accountLogoutBtn.hidden = true;
    }
  }

  function fetchAuthMe() {
    fetch("/api/auth/me")
      .then(function (res) { return res.json(); })
      .then(function (data) {
        isLoggedIn = !!data.loggedIn;
        if (data.loggedIn) {
          showLoggedInState(data);
          updateAccountBar(data);
        } else {
          updateAccountBar(null);
        }
      })
      .catch(function () {
        isLoggedIn = false;
        updateAccountBar(null);
      });
  }

  // 재생·부적 게이트 — 비로그인 시 로그인 유도 모달을 띄운다 (서버도 401로 이중 차단).
  function openLoginPrompt() {
    loginPromptEl.hidden = false;
    reportEvents(null, [{ event: "login_prompt_shown", clientTs: Date.now() }], []);
  }

  function closeLoginPrompt() {
    loginPromptEl.hidden = true;
  }

  function requireLogin() {
    if (isLoggedIn) return true;
    openLoginPrompt();
    return false;
  }

  function onSocialLoginTap(provider) {
    reportEvents(null, [{ event: "login_" + provider, clientTs: Date.now() }], []);
    window.location.href = "/api/auth/login/" + provider;
  }

  function onLogoutTap() {
    fetch("/api/auth/logout", { method: "POST" }).finally(function () {
      window.location.reload();
    });
  }

  function checkAuthError() {
    // 콜백 실패 시 서버가 /?auth_error=1로 리다이렉트 — 배너를 띄우고 URL을 정리한다.
    const params = new URLSearchParams(window.location.search);
    if (params.get("auth_error") !== "1") return;
    authErrorBannerEl.hidden = false;
    params.delete("auth_error");
    const rest = params.toString();
    window.history.replaceState(null, "", window.location.pathname + (rest ? "?" + rest : ""));
  }

  // ── S3 → S4: 운세 요청 ──
  function onTap() {
    if (!selectedTopic) {
      return;
    }
    sessionStartMs = Date.now();
    audioPlayReported = false;
    segmentBoundaries = null;
    stopAudioPlayback();

    startBtn.disabled = true;
    startBtn.textContent = "불러오는 중…";
    statusEl.textContent = "";
    fortuneCardEl.hidden = true;
    playerEl.hidden = true;
    cardViewBtn.hidden = true;
    stageLoadingEl.hidden = false;
    showScreen("s4");
    setPlayerState("idle");

    const birthQuery = buildBirthQuery(currentProfile);
    const url = "/api/fortune/today" +
      (birthQuery ? birthQuery + "&" : "?") + "topic=" + encodeURIComponent(selectedTopic);

    fetch(url)
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        currentFortuneId = data.fortuneId;
        currentFortune = data.fortune;
        currentScript = data.script;
        currentAudioUrl = data.audioUrl;

        // 텍스트 먼저: 오디오를 기다리지 않고 즉시 카드로 노출한다.
        stageLoadingEl.hidden = true;
        renderCard(data.fortune);
        statusEl.textContent = "";
        reportEvents(data.fortuneId, [{ event: "first_text_visible", clientTs: Date.now() }], data.events);
        // 에셋 preload는 첫 텍스트 노출 이후 지연 로드 — fire-and-forget.
        preloadAvatarAssets();

        // phase D 플레이어 — "듣기" 탭 전까지는 오디오를 열지 않는다.
        resetPlayerControlsForListen();
        playerEl.hidden = false;

        // v2: 결과 카드(부적)는 텍스트 노출 시점부터 진입 가능 — 게스트 경로 유지.
        cardViewBtn.hidden = false;
        shareStatusEl.textContent = "";
      })
      .catch(function (err) {
        stageLoadingEl.hidden = true;
        statusEl.textContent = "오류: " + err.message;
        console.error(err);
      })
      .finally(function () {
        startBtn.textContent = "운세 보기";
        startBtn.disabled = !selectedTopic;
      });
  }

  function onRestartTap() {
    stopAudioPlayback();
    goHome();
  }

  function onPushTap() {
    pushOn = true;
    pushBtn.textContent = "알림 예약됨";
    showToast("내일 아침, 홍연이 먼저 인사할게요");
  }

  // ── 이벤트 배선 ──
  backBtn.addEventListener("click", goBack);
  homeBtn.addEventListener("click", goHome);
  guestStartBtn.addEventListener("click", onGuestStartTap);
  charintroNextBtn.addEventListener("click", onCharintroNextTap);
  profileNextBtn.addEventListener("click", onProfileNextTap);
  editProfileBtn.addEventListener("click", onEditProfileTap);
  privacyDetailLink.addEventListener("click", onPrivacyDetailTap);
  startBtn.addEventListener("click", onTap);

  listenBtn.addEventListener("click", function () { if (!requireLogin()) return; onListenTap(); });
  playPauseBtn.addEventListener("click", function () { if (!requireLogin()) return; onPlayPauseTap(); });
  replayBtn.addEventListener("click", function () { if (!requireLogin()) return; onReplayTap(); });
  cardViewBtn.addEventListener("click", function () { showScreen("s5"); });

  shareBtn.addEventListener("click", function () { if (!requireLogin()) return; onShareTap(); });
  shareOpenBtn.addEventListener("click", function () { if (!requireLogin()) return; openShareSheet(); });
  shareSheetBackdropEl.addEventListener("click", closeShareSheet);
  copyLinkBtn.addEventListener("click", onCopyLinkTap);
  pushBtn.addEventListener("click", onPushTap);
  restartBtn.addEventListener("click", onRestartTap);

  accountLoginBtn.addEventListener("click", openLoginPrompt);
  accountLogoutBtn.addEventListener("click", onLogoutTap);
  loginPromptBackdropEl.addEventListener("click", closeLoginPrompt);
  promptCloseBtn.addEventListener("click", closeLoginPrompt);
  promptGoogleBtn.addEventListener("click", function () { onSocialLoginTap("google"); });
  promptKakaoBtn.addEventListener("click", function () { onSocialLoginTap("kakao"); });
  googleLoginBtn.addEventListener("click", function () { onSocialLoginTap("google"); });
  kakaoLoginBtn.addEventListener("click", function () { onSocialLoginTap("kakao"); });
  logoutBtn.addEventListener("click", onLogoutTap);

  profileNicknameInput.addEventListener("input", updateNextButtonState);
  profileNicknameInput.addEventListener("blur", function () { renderProfileErrors(validateProfileForm()); });
  profileBirthDateInput.addEventListener("input", updateNextButtonState);
  profileBirthDateInput.addEventListener("change", function () { renderProfileErrors(validateProfileForm()); });

  // ── 초기화 — v2는 매 방문 S0(무대 인사)부터 시작한다 ──
  function init() {
    currentProfile = loadStoredProfile();
    checkAuthError();
    fetchProviderStatus();
    fetchAuthMe();
    renderShareTargets();
    showScreen("s0");
    // v2(c): 첫 화면(S0)부터 Live2D 아바타 — 보이는 컨테이너에서 1회 초기화
    // (모델/런타임 부재 시 모듈이 조용히 비활성 → 정적 webp 히어로 폴백 유지).
    if (!live2dInitRequested && window.HongyeonLive2D) {
      live2dInitRequested = true;
      window.HongyeonLive2D.init(s0AvatarEl);
      window.HongyeonLive2D.setState("greeting");
    }
    if (!currentProfile) {
      reportEvents(null, [{ event: "onboarding_started", clientTs: Date.now() }], []);
    }
  }

  init();
})();
