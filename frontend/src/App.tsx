// 오늘신당 SPA 오케스트레이션 (ADR-0003 이식) — vanilla app.js의 상태 머신과 동일 계약:
// 텍스트 먼저(v3 §11.1) · autoplay 금지(§11.2) · 프로필 로컬 우선(§12) ·
// 재생/부적 로그인 게이트(US-9, 서버 401 이중 차단) · 이벤트 훅 무회귀.
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchFortune, fetchMe, fetchProviders, loginUrl, logout, markSessionStart, prepareTts, reportEvents, shareCardUrl } from "./lib/api";
import { computeStreak, loadStoredProfile, saveStoredProfile } from "./lib/profile";
import { usePlayer } from "./lib/usePlayer";
import type { AuthSession, FortuneResponse, Profile, ScreenName } from "./lib/types";
import { TopBar } from "./components/TopBar";
import { LoginPrompt, ShareSheet, Toast } from "./components/Overlays";
import { S0Onboarding, S1CharIntro, S2ProfileForm, S3TopicSelect } from "./components/Screens";
import { S4Stage } from "./components/Stage";
import { S5ResultCard } from "./components/ResultCard";
import { D1DreamInput, D2DreamStage, D3DreamTalisman } from "./components/DreamScreens";
import { dreamShareCardUrl, interpretDream, type DreamResponse } from "./lib/dream";

function downloadBlob(blob: Blob, fileName: string) {
  const url = URL.createObjectURL(blob);
  const a = document.createElement("a");
  a.href = url;
  a.download = fileName;
  document.body.appendChild(a);
  a.click();
  a.remove();
  URL.revokeObjectURL(url);
}

async function shareOrDownload(fortuneId: string, blob: Blob): Promise<"shared" | "downloaded" | "cancelled"> {
  const fileName = `hongyeon-share-${fortuneId}.svg`;
  if (window.navigator.share) {
    const file = new File([blob], fileName, { type: "image/svg+xml" });
    const canShareFile = !window.navigator.canShare || window.navigator.canShare({ files: [file] });
    if (canShareFile) {
      try {
        await window.navigator.share({ files: [file], title: "오늘신당 홍연 부적" });
        return "shared";
      } catch (err) {
        // 리뷰 P3: 사용자 취소(AbortError)는 실패가 아니다 — 다운로드 폴백·완료 계측 금지
        if ((err as DOMException)?.name === "AbortError") return "cancelled";
      }
    }
  }
  downloadBlob(blob, fileName);
  return "downloaded";
}

export default function App() {
  const [screen, setScreen] = useState<ScreenName>("s0");
  const navHistory = useRef<ScreenName[]>([]);
  const [profile, setProfile] = useState<Profile | null>(() => loadStoredProfile());
  const [session, setSession] = useState<AuthSession>({ loggedIn: false });
  const [providers, setProviders] = useState({ google: false, kakao: false });
  const [authError, setAuthError] = useState(false);
  const [loginPromptOpen, setLoginPromptOpen] = useState(false);
  const [loginPromptMessage, setLoginPromptMessage] = useState<string | undefined>(undefined);
  const [dreamData, setDreamData] = useState<DreamResponse | null>(null);
  const [dreamLoading, setDreamLoading] = useState(false);
  const [dreamStatus, setDreamStatus] = useState<string | null>(null);
  const [selectedTopic, setSelectedTopic] = useState("");
  const [fortuneLoading, setFortuneLoading] = useState(false);
  const [fortuneData, setFortuneData] = useState<FortuneResponse | null>(null);
  const [statusMessage, setStatusMessage] = useState<string | null>(null);
  const [inIntroFunnel, setInIntroFunnel] = useState(false);
  const [editingProfile, setEditingProfile] = useState(false);
  const [sheetOpen, setSheetOpen] = useState(false);
  const [shareStatus, setShareStatus] = useState<string | null>(null);
  const [pushOn, setPushOn] = useState(false);
  const [streak] = useState(() => computeStreak());
  const [toast, setToast] = useState<{ message: string; nonce: number } | null>(null);
  const toastTimer = useRef<number | null>(null);

  const s0HeroRef = useRef<HTMLDivElement | null>(null);
  const s4AvatarRef = useRef<HTMLDivElement | null>(null);
  const d2AvatarRef = useRef<HTMLDivElement | null>(null);
  // 리뷰 P1-4: 요청 세대 토큰 — 늦게 도착한 응답이 다른 화면의 플레이어를 덮지 않도록
  const requestGen = useRef(0);
  // 리뷰 2차 P1-4: setSession 직후 같은 렌더의 requireLogin이 이전 세션을 보던 stale 클로저 —
  // 로그인 여부는 ref로 동기 추적한다
  const sessionRef = useRef(session);
  useEffect(() => { sessionRef.current = session; }, [session]);
  // 리뷰 2차 P1-3: 게이트를 연 작업(듣기/공유/꿈)을 기억해 OAuth 복귀 시 복원
  const pendingLoginRef = useRef<{ action?: "listen" | "share" | "dream"; topic?: string } | null>(null);
  const live2dInitRequested = useRef(false);
  const [live2dActive, setLive2dActive] = useState(false);

  const player = usePlayer({
    onFirstPlay: () => reportEvents(fortuneData?.fortuneId ?? null, [{ event: "first_audio_play", clientTs: Date.now() }]),
    onLevel: (level) => {
      s4AvatarRef.current?.style.setProperty("--glow-level", level.toFixed(3));
      d2AvatarRef.current?.style.setProperty("--glow-level", level.toFixed(3));
      window.HongyeonLive2D?.setMouth(level);
    },
  });

  // Live2D FSM 연동
  useEffect(() => {
    window.HongyeonLive2D?.setState(player.avatarState);
    setLive2dActive(!!window.HongyeonLive2D?.isActive());
  }, [player.avatarState]);

  const showToast = useCallback((message: string) => {
    if (toastTimer.current) window.clearTimeout(toastTimer.current);
    setToast((prev) => ({ message, nonce: (prev?.nonce ?? 0) + 1 }));
    toastTimer.current = window.setTimeout(() => setToast(null), 1900);
  }, []);

  // ── 내비게이션 (뒤로 스택 + 홈) ──
  const go = useCallback((next: ScreenName, push = true) => {
    setScreen((prev) => {
      if (prev === next) return prev;
      if (push) navHistory.current.push(prev);
      if ((prev === "s4" || prev === "d2") && prev !== next) {
        player.stop();
        requestGen.current += 1; // 재생 화면 이탈 → 진행 중 요청 응답 무효화 (P1-4)
      }
      return next;
    });
    setSheetOpen(false);
  }, [player]);

  const goBack = useCallback(() => {
    const prev = navHistory.current.pop() ?? "s0";
    go(prev, false);
  }, [go]);

  const goHome = useCallback(() => {
    navHistory.current = [];
    go("s0", false);
  }, [go]);

  // ── 초기화: auth 상태·auth_error 배너·Live2D(S0 히어로) ──
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    if (params.get("auth_error") === "1") {
      setAuthError(true);
      params.delete("auth_error");
      const rest = params.toString();
      window.history.replaceState(null, "", window.location.pathname + (rest ? "?" + rest : ""));
    }
    fetchProviders().then(setProviders).catch(() => setProviders({ google: false, kakao: false }));
    fetchMe().then(setSession).catch(() => setSession({ loggedIn: false }));
    if (!loadStoredProfile()) {
      reportEvents(null, [{ event: "onboarding_started", clientTs: Date.now() }]);
    }
  }, []);

  useEffect(() => {
    // v2(c): 첫 화면부터 Live2D — 보이는 컨테이너에서 1회 초기화 (실패 시 webp 폴백 유지)
    if (!live2dInitRequested.current && window.HongyeonLive2D && s0HeroRef.current) {
      live2dInitRequested.current = true;
      window.HongyeonLive2D.init(s0HeroRef.current);
      window.HongyeonLive2D.setState("greeting");
    }
  }, []);

  useEffect(() => {
    // 화면 전환에 따라 Live2D 캔버스 이동 (S0 히어로 ↔ S4 스테이지 프레임)
    const l2d = window.HongyeonLive2D;
    if (!l2d?.moveTo) return;
    requestAnimationFrame(() => {
      if (screen === "s0" && s0HeroRef.current) l2d.moveTo(s0HeroRef.current);
      else if (screen === "s4" && s4AvatarRef.current) l2d.moveTo(s4AvatarRef.current);
      else if (screen === "d2" && d2AvatarRef.current) l2d.moveTo(d2AvatarRef.current);
      setLive2dActive(!!l2d.isActive());
    });
  }, [screen]);

  // 세션 소멸을 동기 반영 — 직후 requireLogin이 곧바로 모달을 열 수 있게 (2차 P1-4)
  const markLoggedOut = useCallback(() => {
    sessionRef.current = { loggedIn: false };
    setSession({ loggedIn: false });
  }, []);

  // ── 게이트 (재생·부적·꿈 해몽 로그인 필요) ──
  const requireLogin = useCallback(
    (message?: string, pending?: { action: "listen" | "share" | "dream"; topic?: string }): boolean => {
      if (sessionRef.current.loggedIn) return true;
      pendingLoginRef.current = pending ?? null;
      setLoginPromptMessage(message);
      setLoginPromptOpen(true);
      reportEvents(null, [{ event: "login_prompt_shown", clientTs: Date.now() }]);
      return false;
    },
    [],
  );

  const handleLogin = useCallback((provider: "google" | "kakao") => {
    reportEvents(null, [{ event: "login_" + provider, clientTs: Date.now() }]);
    // 리뷰 P1-5 + 2차 P1-3: 화면·주제에 더해 게이트를 연 작업(action)까지 저장해 복귀 시 복원
    // (꿈 원문은 프라이버시상 미보존 — D1로 복귀)
    try {
      sessionStorage.setItem("shindang.pendingReturn", JSON.stringify({
        screen,
        topic: pendingLoginRef.current?.topic ?? selectedTopic,
        action: pendingLoginRef.current?.action,
      }));
    } catch { /* 저장 불가 환경 — 복원 없이 진행 */ }
    window.location.href = loginUrl(provider);
  }, [screen, selectedTopic]);

  // OAuth 복귀용 운세 복원 — 결정적 재요청으로 fortuneData까지 되살린다 (2차 P1-3)
  const restoreFortune = useCallback((topic: string, action?: string) => {
    setSelectedTopic(topic);
    markSessionStart();
    setFortuneLoading(true);
    setFortuneData(null);
    setStatusMessage(null);
    player.reset();
    go("s4", false);
    const gen = ++requestGen.current;
    fetchFortune(loadStoredProfile(), topic)
      .then((data) => {
        if (requestGen.current !== gen) return;
        setFortuneData(data);
        reportEvents(data.fortuneId, [{ event: "first_text_visible", clientTs: Date.now() }], data.events ?? []);
        player.setSource(data.audioUrl, data.script);
        if (action === "share") go("s5", false); // 부적 저장/공유하러 가던 사용자는 카드까지 복원
      })
      .catch((err: Error) => {
        if (requestGen.current !== gen) return;
        setStatusMessage("오류: " + err.message);
      })
      .finally(() => setFortuneLoading(false));
  }, [go, player]);

  // OAuth 성공 복귀 — 저장해 둔 작업·화면·주제 복원 (P1-5 / 2차 P1-3)
  useEffect(() => {
    if (!session.loggedIn) return;
    let raw: string | null = null;
    try {
      raw = sessionStorage.getItem("shindang.pendingReturn");
      if (raw) sessionStorage.removeItem("shindang.pendingReturn");
    } catch { return; }
    if (!raw) return;
    try {
      const pending = JSON.parse(raw) as { screen?: string; topic?: string; action?: string };
      if (pending.action === "dream" || (pending.screen && pending.screen.startsWith("d"))) {
        go("d1", false);
        showToast("로그인되었어요 — 꿈을 들려주세요");
      } else if (pending.action === "listen" || pending.action === "share") {
        restoreFortune(pending.topic || "total", pending.action);
        showToast(
          pending.action === "share"
            ? "로그인되었어요 — 부적을 이어서 받아보세요"
            : "로그인되었어요 — 듣기를 탭하면 들려드려요", // autoplay 금지: 자동 재생은 하지 않는다
        );
      } else if (pending.screen && pending.screen !== "s0") {
        if (pending.topic) setSelectedTopic(pending.topic);
        go("s3", false);
        showToast("로그인되었어요 — 이어서 운세를 보세요");
      }
    } catch { /* 손상된 값은 무시 */ }
  }, [session.loggedIn, go, restoreFortune, showToast]);

  // 리뷰 P2: 서버 세션 소멸(재시작 등) 후에도 최초 boolean을 신뢰하던 문제 — 포커스 시 재검증
  useEffect(() => {
    const revalidate = () => fetchMe().then(setSession).catch(() => {});
    window.addEventListener("focus", revalidate);
    return () => window.removeEventListener("focus", revalidate);
  }, []);

  const handleLogout = useCallback(() => {
    logout().finally(() => window.location.reload());
  }, []);

  // ── 플로우 핸들러 ──
  const handleStart = useCallback(() => {
    setInIntroFunnel(!profile);
    go(profile ? "s3" : "s1");
  }, [go, profile]);

  const handleProfileSubmit = useCallback((next: Profile) => {
    saveStoredProfile(next);
    setProfile(next);
    setEditingProfile(false);
    reportEvents(null, [{ event: "profile_saved", clientTs: Date.now(), hasBirthHour: next.birthHour !== null }]);
    go("s3");
  }, [go]);

  const handleFortuneStart = useCallback(() => {
    if (!selectedTopic || fortuneLoading) return;
    markSessionStart();
    setFortuneLoading(true);
    setFortuneData(null);
    setStatusMessage(null);
    player.reset();
    go("s4");
    const gen = ++requestGen.current; // P1-4: go()의 이탈 무효화 이후에 세대 발급
    fetchFortune(profile, selectedTopic)
      .then((data) => {
        if (requestGen.current !== gen) return; // 화면 이탈·후속 요청 발생 → 늦은 응답 폐기
        setFortuneData(data);
        // 텍스트 먼저 — 오디오를 기다리지 않고 즉시 노출, 이벤트 계약 유지
        reportEvents(data.fortuneId, [{ event: "first_text_visible", clientTs: Date.now() }], data.events ?? []);
        player.setSource(data.audioUrl, data.script);
      })
      .catch((err: Error) => {
        if (requestGen.current !== gen) return;
        setStatusMessage("오류: " + err.message);
        console.error(err);
      })
      .finally(() => setFortuneLoading(false));
  }, [fortuneLoading, go, player, profile, selectedTopic]);

  // 듣기 — 실 TTS 합성·과금은 이 시점에만 (리뷰 P1-3 text-first 분리)
  const handleListen = useCallback(() => {
    if (!requireLogin(undefined, { action: "listen", topic: selectedTopic }) || !fortuneData) return;
    const gen = requestGen.current;
    prepareTts(profile, selectedTopic || "total")
      .then(({ audioUrl }) => {
        if (requestGen.current !== gen || !fortuneData) return;
        if (audioUrl !== fortuneData.audioUrl) {
          player.setSource(audioUrl, fortuneData.script);
        }
        player.listen();
      })
      .catch((err: Error) => {
        if (err.message === "LOGIN_REQUIRED") {
          markLoggedOut(); // 동기 반영 → 아래 requireLogin이 첫 실패에서 즉시 모달을 연다 (2차 P1-4)
          requireLogin("세션이 만료됐어요. 다시 로그인하면 이어서 들려드릴게요.", {
            action: "listen",
            topic: selectedTopic,
          });
        } else {
          showToast(err.message);
        }
      });
  }, [fortuneData, markLoggedOut, player, profile, requireLogin, selectedTopic, showToast]);

  const handleSaveImage = useCallback(() => {
    if (!requireLogin(undefined, { action: "share", topic: selectedTopic }) || !fortuneData) return;
    setShareStatus("부적을 준비하는 중…");
    reportEvents(fortuneData.fortuneId, [{ event: "share_initiated", clientTs: Date.now() }]);
    fetch(shareCardUrl(fortuneData.fortuneId))
      .then((res) => {
        if (!res.ok) throw new Error("부적을 불러오지 못했어요");
        return res.blob();
      })
      .then((blob) => shareOrDownload(fortuneData.fortuneId, blob))
      .then((outcome) => {
        setShareStatus(null);
        if (outcome === "cancelled") return; // 사용자 취소 — 완료 계측·토스트 없음 (P3)
        showToast("부적 카드를 받았어요");
        reportEvents(fortuneData.fortuneId, [{ event: "share_completed", clientTs: Date.now() }]);
      })
      .catch((err: Error) => setShareStatus("오류: " + err.message));
  }, [fortuneData, requireLogin, selectedTopic, showToast]);

  // ── 꿈 해몽 (D1~D3) ──
  const handleDreamEntry = useCallback(() => {
    if (!requireLogin("꿈 해몽은 손님을 기억해야 풀 수 있는 깊은 풀이라, 로그인 후에 홍연이 맞이할 수 있어요.", { action: "dream" })) return;
    reportEvents(null, [{ event: "dream_started", clientTs: Date.now() }]);
    setDreamData(null);
    setDreamStatus(null);
    go("d1");
  }, [go, requireLogin]);

  const handleDreamSubmit = useCallback((text: string, symbols: string[]) => {
    if (dreamLoading) return;
    markSessionStart();
    setDreamLoading(true);
    setDreamData(null);
    setDreamStatus(null);
    player.reset();
    go("d2");
    const gen = ++requestGen.current; // P1-4
    interpretDream(text, symbols)
      .then((data) => {
        if (requestGen.current !== gen) return;
        setDreamData(data);
        // 프라이버시: 이벤트에는 상징 라벨만 — 꿈 원문은 어디에도 남기지 않는다
        reportEvents(null, [{
          event: "dream_interpreted",
          clientTs: Date.now(),
          symbols: data.reading.symbols.map((s) => s.label),
        }]);
        player.setSource(data.audioUrl, data.script);
      })
      .catch((err: Error) => {
        if (requestGen.current !== gen) return;
        if (err.message === "LOGIN_REQUIRED") {
          markLoggedOut(); // 2차 P1-4
          go("d1", false); // 꿈 맥락 유지 — 재로그인 후 D1로 복귀 (2차 P1-3)
          requireLogin("세션이 만료됐어요. 다시 로그인하면 홍연이 이어서 풀어드릴게요.", { action: "dream" });
        } else {
          setDreamStatus("오류: " + err.message);
        }
      })
      .finally(() => setDreamLoading(false));
  }, [dreamLoading, go, markLoggedOut, player, requireLogin]);

  const handleDreamSaveImage = useCallback(() => {
    if (!requireLogin(undefined, { action: "dream" }) || !dreamData) return;
    const labels = dreamData.reading.symbols.map((s) => s.label);
    fetch(dreamShareCardUrl(labels))
      .then((res) => {
        if (!res.ok) throw new Error("꿈 부적을 불러오지 못했어요");
        return res.blob();
      })
      .then((blob) => shareOrDownload(dreamData.dreamId, blob))
      .then((outcome) => {
        if (outcome === "cancelled") return; // 사용자 취소는 실패가 아니다 (P3)
        showToast("꿈 부적을 받았어요");
      })
      .catch((err: Error) => showToast(err.message)); // D3는 토스트가 유일한 피드백 채널
  }, [dreamData, requireLogin, showToast]);

  const handleCopyLink = useCallback(() => {
    setSheetOpen(false);
    const url = window.location.origin + "/";
    if (navigator.clipboard?.writeText) {
      navigator.clipboard.writeText(url)
        .then(() => showToast("링크가 복사되었어요"))
        .catch(() => showToast("링크 복사에 실패했어요"));
    } else {
      showToast("이 브라우저에서는 링크 복사를 지원하지 않아요");
    }
  }, [showToast]);

  const nickname = profile?.nickname ?? null;
  const s3StepLabel = inIntroFunnel ? "3 / 4 · 주제 선택" : "주제 선택";
  const s2StepLabel = editingProfile ? "프로필 수정" : "2 / 4 · 정보 입력";

  return (
    <main className="stage">
      <div className="stage-lighting" aria-hidden="true" />
      <TopBar
        showBack={screen !== "s0"}
        session={session}
        onBack={goBack}
        onHome={goHome}
        onLoginClick={() => setLoginPromptOpen(true)}
        onLogout={handleLogout}
      />
      {authError && (
        <p className="auth-error-banner" role="alert">로그인에 실패했어요. 게스트로 이용할 수 있어요.</p>
      )}

      {screen === "s0" && (
        <S0Onboarding
          ref={s0HeroRef}
          providers={providers}
          loggedInLabel={session.loggedIn ? (session.nickname || "소셜 사용자") + "님으로 로그인됨" : null}
          onStart={handleStart}
          onLogin={handleLogin}
          onLogout={handleLogout}
        />
      )}
      {screen === "s1" && <S1CharIntro onNext={() => go(profile ? "s3" : "s2")} />}
      {screen === "s2" && (
        <S2ProfileForm stepLabel={s2StepLabel} initial={profile} onSubmit={handleProfileSubmit} />
      )}
      {screen === "s3" && (
        <S3TopicSelect
          stepLabel={s3StepLabel}
          nickname={nickname}
          selectedTopic={selectedTopic}
          loading={fortuneLoading}
          onSelect={setSelectedTopic}
          onEditProfile={() => { setEditingProfile(true); go("s2"); }}
          onStart={handleFortuneStart}
          onDream={handleDreamEntry}
        />
      )}
      {screen === "d1" && (
        <D1DreamInput loading={dreamLoading} onSubmit={handleDreamSubmit} />
      )}
      {screen === "d2" && (
        <D2DreamStage
          ref={d2AvatarRef}
          loading={dreamLoading}
          reading={dreamData?.reading ?? null}
          statusMessage={dreamStatus ?? player.error}
          phase={player.phase}
          avatarState={player.avatarState}
          progressPct={player.progressPct}
          live2dActive={live2dActive}
          onListen={player.listen}
          onPlayPause={player.playPause}
          onReplay={player.replay}
          onTalisman={() => go("d3")}
        />
      )}
      {screen === "d3" && dreamData && (
        <D3DreamTalisman
          reading={dreamData.reading}
          nickname={nickname}
          onSaveImage={handleDreamSaveImage}
          onOpenShare={() => setSheetOpen(true)}
          onRestart={() => { setDreamData(null); go("d1", false); }}
        />
      )}
      {screen === "s4" && (
        <S4Stage
          ref={s4AvatarRef}
          loading={fortuneLoading}
          fortune={fortuneData?.fortune ?? null}
          statusMessage={statusMessage ?? player.error}
          phase={player.phase}
          avatarState={player.avatarState}
          progressPct={player.progressPct}
          live2dActive={live2dActive}
          onListen={handleListen}
          onPlayPause={() => { if (requireLogin(undefined, { action: "listen", topic: selectedTopic })) player.playPause(); }}
          onReplay={() => { if (requireLogin(undefined, { action: "listen", topic: selectedTopic })) player.replay(); }}
          onViewCard={() => go("s5")}
        />
      )}
      {screen === "s5" && fortuneData && (
        <S5ResultCard
          fortune={fortuneData.fortune}
          topic={selectedTopic || "total"}
          nickname={nickname}
          streak={streak}
          pushOn={pushOn}
          shareStatus={shareStatus}
          onSaveImage={handleSaveImage}
          onOpenShare={() => { if (requireLogin(undefined, { action: "share", topic: selectedTopic })) setSheetOpen(true); }}
          onPush={() => { setPushOn(true); showToast("내일 아침, 홍연이 먼저 인사할게요"); }}
          onRestart={goHome}
        />
      )}

      <ShareSheet
        open={sheetOpen}
        onClose={() => setSheetOpen(false)}
        onSystemShare={screen === "d3" ? handleDreamSaveImage : handleSaveImage}
        onCopyLink={handleCopyLink}
        onMockShare={showToast}
      />
      <Toast message={toast?.message ?? null} nonce={toast?.nonce ?? 0} />
      <LoginPrompt
        open={loginPromptOpen}
        providers={providers}
        message={loginPromptMessage}
        onClose={() => setLoginPromptOpen(false)}
        onLogin={handleLogin}
      />
    </main>
  );
}
