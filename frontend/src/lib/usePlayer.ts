// phase D 플레이어 FSM — autoplay 금지(v3 §11.2): 오디오는 오직 사용자 제스처(듣기/다시 듣기)
// 안에서만 열리고, AnalyserNode 연결도 같은 제스처 안에서 1회만 생성해 재사용한다.
import { useCallback, useRef, useState } from "react";
import { computeSegmentBoundaries, currentSegmentIndex, stateForSegmentIndex } from "./segments";
import type { AvatarState, PlayerPhase, ScriptSegment } from "./types";

export interface PlayerApi {
  phase: PlayerPhase;
  avatarState: AvatarState;
  progressPct: number;
  error: string | null;
  listen: () => void;
  playPause: () => void;
  replay: () => void;
  stop: () => void;
  setSource: (audioUrl: string, script: ScriptSegment[]) => void;
  reset: () => void;
}

export function usePlayer(options: {
  onFirstPlay: () => void;
  onLevel: (level: number) => void; // 음량 글로우 + Live2D 입 (0~1)
}): PlayerApi {
  const [phase, setPhase] = useState<PlayerPhase>("idle");
  const [avatarState, setAvatarState] = useState<AvatarState>("idle");
  const [progressPct, setProgressPct] = useState(0);
  const [error, setError] = useState<string | null>(null);

  const audioRef = useRef<HTMLAudioElement | null>(null);
  const audioCtxRef = useRef<AudioContext | null>(null);
  const analyserRef = useRef<AnalyserNode | null>(null);
  const rafRef = useRef<number | null>(null);
  const audioUrlRef = useRef<string | null>(null);
  const boundariesRef = useRef<number[] | null>(null);
  const scriptRef = useRef<ScriptSegment[]>([]);
  const firstPlayReportedRef = useRef(false);
  const optionsRef = useRef(options);
  optionsRef.current = options;

  const stopGlowLoop = useCallback(() => {
    if (rafRef.current) {
      cancelAnimationFrame(rafRef.current);
      rafRef.current = null;
    }
    optionsRef.current.onLevel(0);
  }, []);

  const startGlowLoop = useCallback(() => {
    const analyser = analyserRef.current;
    if (!analyser) return;
    const freqData = new Uint8Array(analyser.frequencyBinCount);
    const tick = () => {
      if (!analyserRef.current) return;
      analyserRef.current.getByteFrequencyData(freqData);
      let sum = 0;
      for (let i = 0; i < freqData.length; i++) sum += freqData[i];
      optionsRef.current.onLevel(Math.min(1, sum / freqData.length / 128));
      rafRef.current = requestAnimationFrame(tick);
    };
    tick();
  }, []);

  const ensureAnalyser = useCallback((audio: HTMLAudioElement) => {
    if (analyserRef.current) return;
    const AudioContextClass =
      window.AudioContext || (window as unknown as { webkitAudioContext?: typeof AudioContext }).webkitAudioContext;
    if (!AudioContextClass) return;
    try {
      // AudioContext/MediaElementSource는 오디오 요소당 1회만 (중복 생성 금지 불변식)
      audioCtxRef.current = new AudioContextClass();
      const sourceNode = audioCtxRef.current.createMediaElementSource(audio);
      const analyser = audioCtxRef.current.createAnalyser();
      analyser.fftSize = 256;
      sourceNode.connect(analyser);
      analyser.connect(audioCtxRef.current.destination);
      analyserRef.current = analyser;
    } catch {
      analyserRef.current = null;
    }
  }, []);

  const ensureAudio = useCallback((): HTMLAudioElement => {
    if (!audioRef.current) {
      const audio = new Audio();
      audio.addEventListener("timeupdate", () => {
        const duration = isFinite(audio.duration) && audio.duration > 0 ? audio.duration : null;
        if (!duration) return;
        if (!boundariesRef.current) {
          boundariesRef.current = computeSegmentBoundaries(scriptRef.current, duration);
        }
        const idx = currentSegmentIndex(audio.currentTime, boundariesRef.current);
        setAvatarState(stateForSegmentIndex(idx));
        setProgressPct(Math.min(100, (audio.currentTime / duration) * 100));
      });
      audio.addEventListener("playing", () => {
        if (!firstPlayReportedRef.current) {
          firstPlayReportedRef.current = true;
          optionsRef.current.onFirstPlay();
        }
      });
      audio.addEventListener("ended", () => {
        setProgressPct(100);
        setPhase("done");
        setAvatarState("blessing");
        stopGlowLoop();
      });
      audio.addEventListener("error", () => {
        setError("오디오 재생에 실패했어요. 다시 들어보세요.");
        setPhase("done");
        stopGlowLoop();
      });
      audioRef.current = audio;
    }
    return audioRef.current;
  }, [stopGlowLoop]);

  const setSource = useCallback(
    (audioUrl: string, script: ScriptSegment[]) => {
      audioUrlRef.current = audioUrl;
      scriptRef.current = script;
      firstPlayReportedRef.current = false;
      boundariesRef.current = null;
      setPhase("idle");
      setAvatarState("idle");
      setProgressPct(0);
      setError(null);
    },
    [],
  );

  const play = useCallback(() => {
    const audioUrl = audioUrlRef.current;
    if (!audioUrl) return;
    const audio = ensureAudio();
    const absoluteUrl = new URL(audioUrl, window.location.origin).href;
    if (audio.src !== absoluteUrl) {
      audio.src = audioUrl;
      boundariesRef.current = null;
    }
    ensureAnalyser(audio);
    setPhase("playing");
    setAvatarState("greeting");
    setError(null);
    audio
      .play()
      .then(startGlowLoop)
      .catch(() => {
        setError("오디오 재생에 실패했어요. 다시 들어보세요.");
        setPhase("done");
        stopGlowLoop();
      });
  }, [ensureAnalyser, ensureAudio, startGlowLoop, stopGlowLoop]);

  const listen = useCallback(() => play(), [play]);

  const replay = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    audio.currentTime = 0;
    play();
  }, [play]);

  const playPause = useCallback(() => {
    const audio = audioRef.current;
    if (!audio) return;
    if (audio.paused) {
      setPhase("playing");
      audio.play().then(startGlowLoop).catch(() => setPhase("paused"));
    } else {
      audio.pause();
      stopGlowLoop();
      setPhase("paused");
    }
  }, [startGlowLoop, stopGlowLoop]);

  const stop = useCallback(() => {
    const audio = audioRef.current;
    if (audio && !audio.paused) {
      audio.pause();
      setPhase("paused"); // 리뷰 P2: 화면 이탈 정지 후 phase가 playing으로 남던 불일치 수정
    }
    stopGlowLoop();
  }, [stopGlowLoop]);

  const reset = useCallback(() => {
    stop();
    setPhase("idle");
    setAvatarState("idle");
    setProgressPct(0);
    setError(null);
  }, [stop]);

  return { phase, avatarState, progressPct, error, listen, playPause, replay, stop, setSource, reset };
}
