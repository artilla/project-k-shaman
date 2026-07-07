// T019: 재생 프론트 스켈레톤 — 탭 1회로 오디오 컨텍스트를 연 뒤, 텍스트를 먼저 보여주고
// 오디오는 준비되는 대로 재생한다 (자동 재생 금지 전제, v3 §11.1-2).
(function () {
  "use strict";

  const startBtn = document.getElementById("start-btn");
  const textEl = document.getElementById("fortune-text");
  const statusEl = document.getElementById("status");

  function renderText(script) {
    textEl.innerHTML = "";
    for (const seg of script) {
      const p = document.createElement("p");
      p.className = "segment segment-" + seg.segment;
      p.textContent = seg.text;
      textEl.appendChild(p);
    }
  }

  function reportEvents(fortuneId, sessionStartMs, clientEvents, serverEvents) {
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

  function onTap() {
    const sessionStartMs = Date.now();

    // 첫 재생은 사용자 탭으로 오디오 컨텍스트를 연다 (자동 재생 금지 전제).
    const AudioContextCtor = window.AudioContext || window.webkitAudioContext;
    const audioCtx = new AudioContextCtor();
    audioCtx.resume();

    startBtn.disabled = true;
    startBtn.textContent = "불러오는 중…";
    statusEl.textContent = "";

    const clientEvents = [];

    fetch("/api/fortune/today")
      .then(function (res) {
        return res.json();
      })
      .then(function (data) {
        // 텍스트 먼저: 오디오를 기다리지 않고 즉시 노출한다.
        renderText(data.script);
        clientEvents.push({ event: "first_text_visible", clientTs: Date.now() });
        statusEl.textContent = "음성을 불러오는 중…";

        return fetch(data.audioUrl)
          .then(function (res) {
            return res.arrayBuffer();
          })
          .then(function (buf) {
            return audioCtx.decodeAudioData(buf);
          })
          .then(function (audioBuffer) {
            const src = audioCtx.createBufferSource();
            src.buffer = audioBuffer;
            src.connect(audioCtx.destination);
            src.start(0);
            clientEvents.push({ event: "first_audio_play", clientTs: Date.now() });
            statusEl.textContent = "재생 중";
            return reportEvents(data.fortuneId, sessionStartMs, clientEvents, data.events);
          });
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
})();
