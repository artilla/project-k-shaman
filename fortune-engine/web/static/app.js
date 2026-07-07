// T022: S4 무대 재생 UX 최소판 — phase C 구조화 텍스트 카드 + phase D 플레이어 FSM
// (idle→greeting→speaking→blessing, screen-ia.md §2 S4 / §3). 텍스트 먼저(v3 §11.1),
// autoplay 금지(§11.2) 전제는 T019와 동일하게 유지한다: "듣기" 탭 전에는 오디오를 열지 않는다.
(function () {
  "use strict";

  // T026: 온보딩(S0)/입력(S2) 요소 — 게스트 우선 + 소셜 로그인 스캐폴드.
  const PROFILE_STORAGE_KEY = "shindang.profile";
  const PROFILE_NICKNAME_MAX_LENGTH = 10;

  const onboardingEl = document.getElementById("onboarding");
  const onboardingAccountStatusEl = document.getElementById("onboarding-account-status");
  const guestStartBtn = document.getElementById("guest-start-btn");
  const googleLoginBtn = document.getElementById("google-login-btn");
  const kakaoLoginBtn = document.getElementById("kakao-login-btn");
  const logoutBtn = document.getElementById("logout-btn");

  const profileFormEl = document.getElementById("profile-form");
  const profileNicknameInput = document.getElementById("profile-nickname");
  const profileNicknameErrorEl = document.getElementById("profile-nickname-error");
  const profileBirthDateInput = document.getElementById("profile-birth-date");
  const profileBirthDateErrorEl = document.getElementById("profile-birth-date-error");
  const profileBirthHourSelect = document.getElementById("profile-birth-hour");
  const profileNextBtn = document.getElementById("profile-next-btn");
  const privacyDetailLink = document.getElementById("privacy-detail-link");
  const privacyDetailTextEl = document.getElementById("privacy-detail-text");

  const mainStageEl = document.getElementById("main-stage");
  const profileSummaryEl = document.getElementById("profile-summary");
  const profileSummaryNicknameEl = document.getElementById("profile-summary-nickname");
  const editProfileBtn = document.getElementById("edit-profile-btn");

  let currentProfile = null;

  const startBtn = document.getElementById("start-btn");
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

  // T024/ADR-0002: 상태별 정지컷 에셋(hongyeon-{state}.webp) — 기능 감지 후 존재하는 것만 스왑,
  // 부재 시 현재 이모지 플레이스홀더 그대로 유지한다(폴백 불변식). 립싱크 아님.
  const AVATAR_ASSET_STATES = ["greeting", "idle", "speaking", "blessing"];
  const avatarAssetAvailable = {};

  let currentFortuneId = null;
  let currentScript = null;
  let currentAudioUrl = null;
  let sessionStartMs = null;
  let audioPlayReported = false;
  let audioEl = null;
  let segmentBoundaries = null; // narration 세그먼트별 누적 종료 시각(초)

  // speaking 음량 글로우용 WebAudio 배선 — AudioContext/AnalyserNode는 프로세스당 한 번만 만들어
  // 재사용한다(§11.2 autoplay 금지와 무관, 항상 사용자 제스처인 듣기/다시 듣기 탭 안에서만 생성).
  let audioCtx = null;
  let analyserNode = null;
  let glowRafId = null;

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
    playerStateEl.textContent = PLAYER_STATE_LABELS[state] || state;
    const avatarState = state === "done" ? "idle" : state;
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
      // T025: 같은 음량 신호를 Live2D 입 열림(ParamMouthOpenY)에도 공급
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
  // AnalyserNode 연결도 같은 사용자 제스처 안에서만 이뤄진다(§11.2 전제 무회귀).
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

  // T026: localStorage(shindang.profile)에만 저장 — 서버 미전송(v3 §12 로컬 우선 불변식).
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

  // 12시진 대표 시각(profile-birth-hour의 select value)이 이미 seed_builder._get_birth_time_bucket
  // 버킷 경계에 맞춰 선택돼 있으므로, 여기서는 그대로 쿼리에 실어 보내기만 한다.
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

  function renderProfileSummary() {
    if (currentProfile && currentProfile.nickname) {
      profileSummaryNicknameEl.textContent = currentProfile.nickname + "님";
      profileSummaryEl.hidden = false;
    } else {
      profileSummaryEl.hidden = true;
    }
  }

  function showMainStage() {
    onboardingEl.hidden = true;
    profileFormEl.hidden = true;
    mainStageEl.hidden = false;
    renderProfileSummary();
  }

  function onGuestStartTap() {
    onboardingEl.hidden = true;
    profileFormEl.hidden = false;
  }

  // 생년월일 원문은 여기서 로컬에만 저장되고, 이벤트 payload에는 존재 여부(hasBirthHour)만
  // 싣는다 — 원본 생년월일·출생시간을 이벤트 로그에 남기지 않는다(v3 §12, screen-ia S2).
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
    showMainStage();
  }

  function onEditProfileTap() {
    mainStageEl.hidden = true;
    prefillProfileForm(currentProfile);
    profileFormEl.hidden = false;
  }

  function onPrivacyDetailTap(event) {
    event.preventDefault();
    privacyDetailTextEl.hidden = !privacyDetailTextEl.hidden;
  }

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
      })
      .catch(function () {
        applyProviderButtonState(googleLoginBtn, false);
        applyProviderButtonState(kakaoLoginBtn, false);
      });
  }

  function showLoggedInState(session) {
    guestStartBtn.hidden = true;
    googleLoginBtn.hidden = true;
    kakaoLoginBtn.hidden = true;
    onboardingAccountStatusEl.textContent = (session.nickname || "소셜 사용자") + "님으로 로그인됨";
    onboardingAccountStatusEl.hidden = false;
    logoutBtn.hidden = false;
  }

  function fetchAuthMe() {
    fetch("/api/auth/me")
      .then(function (res) { return res.json(); })
      .then(function (data) {
        if (data.loggedIn) {
          showLoggedInState(data);
        }
      })
      .catch(function () {});
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

  function initOnboarding() {
    currentProfile = loadStoredProfile();
    fetchProviderStatus();
    fetchAuthMe();

    if (currentProfile) {
      showMainStage();
    } else {
      onboardingEl.hidden = false;
      reportEvents(null, [{ event: "onboarding_started", clientTs: Date.now() }], []);
    }
  }

  function onTap() {
    sessionStartMs = Date.now();
    audioPlayReported = false;
    segmentBoundaries = null;

    startBtn.disabled = true;
    startBtn.textContent = "불러오는 중…";
    statusEl.textContent = "";

    fetch("/api/fortune/today" + buildBirthQuery(currentProfile))
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
        // 에셋 preload는 첫 텍스트 노출 이후 지연 로드 — first_text_visible·first_audio_play
        // 지연에 영향 없음(§1.6-② 예산). fire-and-forget이며 완료를 기다리지 않는다.
        preloadAvatarAssets();

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

  guestStartBtn.addEventListener("click", onGuestStartTap);
  googleLoginBtn.addEventListener("click", function () { onSocialLoginTap("google"); });
  kakaoLoginBtn.addEventListener("click", function () { onSocialLoginTap("kakao"); });
  logoutBtn.addEventListener("click", onLogoutTap);
  profileNicknameInput.addEventListener("input", updateNextButtonState);
  profileNicknameInput.addEventListener("blur", function () { renderProfileErrors(validateProfileForm()); });
  profileBirthDateInput.addEventListener("input", updateNextButtonState);
  profileBirthDateInput.addEventListener("change", function () { renderProfileErrors(validateProfileForm()); });
  profileNextBtn.addEventListener("click", onProfileNextTap);
  editProfileBtn.addEventListener("click", onEditProfileTap);
  privacyDetailLink.addEventListener("click", onPrivacyDetailTap);

  initOnboarding();

  // T025: Live2D 아바타 초기화 — 자산 없으면 스스로 비활성(폴백 유지).
  // 탭 이전의 대기 화면에서 로드되므로 first_text_visible·first_audio_play
  // 경로(§1.6-② 예산)에 선행하지 않는다.
  if (window.HongyeonLive2D) {
    window.HongyeonLive2D.init(avatarEl);
  }
})();
