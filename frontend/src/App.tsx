// 오늘신당 SPA 오케스트레이션 (ADR-0003 이식) — vanilla app.js의 상태 머신과 동일 계약:
// 텍스트 먼저(v3 §11.1) · autoplay 금지(§11.2) · 프로필 로컬 우선(§12) ·
// 재생/부적 로그인 게이트(US-9, 서버 401 이중 차단) · 이벤트 훅 무회귀.
import { useCallback, useEffect, useRef, useState } from "react";
import { fetchFortune, fetchMe, fetchProviders, loginUrl, logout, markSessionStart, reportEvents, shareCardUrl } from "./lib/api";
import { computeStreak, loadStoredProfile, saveStoredProfile } from "./lib/profile";
import { usePlayer } from "./lib/usePlayer";
import type { AuthSession, FortuneResponse, Profile, ScreenName } from "./lib/types";
import { TopBar } from "./components/TopBar";
import { LoginPrompt, ShareSheet, Toast } from "./components/Overlays";
import { S0Onboarding, S1CharIntro, S2ProfileForm, S3TopicSelect } from "./components/Screens";
import { S4Stage } from "./components/Stage";
import { S5ResultCard } from "./components/ResultCard";

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

async function shareOrDownload(fortuneId: string, blob: Blob) {
  const fileName = `hongyeon-share-${fortuneId}.svg`;
  if (window.navigator.share) {
    const file = new File([blob], fileName, { type: "image/svg+xml" });
    const canShareFile = !window.navigator.canShare || window.navigator.canShare({ files: [file] });
    if (canShareFile) {
      try {
        await window.navigator.share({ files: [file], title: "오늘신당 홍연 부적" });
        return;
      } catch {
        /* 사용자가 취소하거나 미지원 → 다운로드 폴백 */
      }
    }
  }
  downloadBlob(blob, fileName);
}

export default function App() {
  const [screen, setScreen] = useState<ScreenName>("s0");
  const navHistory = useRef<ScreenName[]>([]);
  const [profile, setProfile] = useState<Profile | null>(() => loadStoredProfile());
  const [session, setSession] = useState<AuthSession>({ loggedIn: false });
  const [providers, setProviders] = useState({ google: false, kakao: false });
  const [authError, setAuthError] = useState(false);
  const [loginPromptOpen, setLoginPromptOpen] = useState(false);
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
  const live2dInitRequested = useRef(false);
  const [live2dActive, setLive2dActive] = useState(false);

  const player = usePlayer({
    onFirstPlay: () => reportEvents(fortuneData?.fortuneId ?? null, [{ event: "first_audio_play", clientTs: Date.now() }]),
    onLevel: (level) => {
      s4AvatarRef.current?.style.setProperty("--glow-level", level.toFixed(3));
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
      if (prev === "s4" && next !== "s4") player.stop();
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
      setLive2dActive(!!l2d.isActive());
    });
  }, [screen]);

  // ── 게이트 (재생·부적 로그인 필요) ──
  const requireLogin = useCallback((): boolean => {
    if (session.loggedIn) return true;
    setLoginPromptOpen(true);
    reportEvents(null, [{ event: "login_prompt_shown", clientTs: Date.now() }]);
    return false;
  }, [session.loggedIn]);

  const handleLogin = useCallback((provider: "google" | "kakao") => {
    reportEvents(null, [{ event: "login_" + provider, clientTs: Date.now() }]);
    window.location.href = loginUrl(provider);
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
    fetchFortune(profile, selectedTopic)
      .then((data) => {
        setFortuneData(data);
        // 텍스트 먼저 — 오디오를 기다리지 않고 즉시 노출, 이벤트 계약 유지
        reportEvents(data.fortuneId, [{ event: "first_text_visible", clientTs: Date.now() }], data.events ?? []);
        player.setSource(data.audioUrl, data.script);
      })
      .catch((err: Error) => {
        setStatusMessage("오류: " + err.message);
        console.error(err);
      })
      .finally(() => setFortuneLoading(false));
  }, [fortuneLoading, go, player, profile, selectedTopic]);

  const handleSaveImage = useCallback(() => {
    if (!requireLogin() || !fortuneData) return;
    setShareStatus("부적을 준비하는 중…");
    reportEvents(fortuneData.fortuneId, [{ event: "share_initiated", clientTs: Date.now() }]);
    fetch(shareCardUrl(fortuneData.fortuneId))
      .then((res) => {
        if (!res.ok) throw new Error("부적을 불러오지 못했어요");
        return res.blob();
      })
      .then((blob) => shareOrDownload(fortuneData.fortuneId, blob))
      .then(() => {
        setShareStatus(null);
        showToast("부적 카드를 받았어요");
        reportEvents(fortuneData.fortuneId, [{ event: "share_completed", clientTs: Date.now() }]);
      })
      .catch((err: Error) => setShareStatus("오류: " + err.message));
  }, [fortuneData, requireLogin, showToast]);

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
          onListen={() => { if (requireLogin()) player.listen(); }}
          onPlayPause={() => { if (requireLogin()) player.playPause(); }}
          onReplay={() => { if (requireLogin()) player.replay(); }}
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
          onOpenShare={() => { if (requireLogin()) setSheetOpen(true); }}
          onPush={() => { setPushOn(true); showToast("내일 아침, 홍연이 먼저 인사할게요"); }}
          onRestart={goHome}
        />
      )}

      <ShareSheet
        open={sheetOpen}
        onClose={() => setSheetOpen(false)}
        onSystemShare={handleSaveImage}
        onCopyLink={handleCopyLink}
        onMockShare={showToast}
      />
      <Toast message={toast?.message ?? null} nonce={toast?.nonce ?? 0} />
      <LoginPrompt
        open={loginPromptOpen}
        providers={providers}
        onClose={() => setLoginPromptOpen(false)}
        onLogin={handleLogin}
      />
    </main>
  );
}
