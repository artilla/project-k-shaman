// T025: Live2D 아바타 모듈 (L0 스파이크) — docs/research/live2d-avatar-research.md
//
// 자기완결 프로그레시브 인핸스먼트:
//   - 모델 파일이 없거나(404) 스크립트/모델 로드가 실패하면 조용히 비활성 —
//     기존 정지컷(hongyeon-*.webp)·플레이스홀더 폴백 체계(T024 불변식)를 건드리지 않는다.
//   - 활성 시 #avatar 안에 캔버스를 만들고 idle 모션을 재생하며,
//     app.js의 FSM(setState)·음량(setMouth) 신호를 받는다.
//
// 이식 출처: EmotiMate Live2DCanvas.web.tsx / useLipSync.ts 패턴
//   (pixi.js 6.5.10 + pixi-live2d-display 0.4.0 cubism4, ParamMouthOpenY 직접 주입).
// 벤더 라이선스: static/live2d/README.md 참조.
window.HongyeonLive2D = (function () {
  "use strict";

  var MODEL_URL = "/static/live2d/models/Mao/Mao.model3.json";
  var SCRIPTS = [
    "/static/live2d/live2dcubismcore.min.js",
    "/static/live2d/pixi.min.js",
    "/static/live2d/cubism4.min.js",
  ];
  // screen-ia S4 FSM → Mao 샘플 모델 표정/모션 매핑 (홍연 모델(L1) 도착 시 이 표만 교체)
  var STATE_MAP = {
    greeting: { expression: "happy", motion: "TapBody" },
    speaking: { expression: "smile", motion: null },
    blessing: { expression: "happy", motion: "TapBody" },
    idle: { expression: null, motion: null },
  };

  var active = false;
  var model = null;
  var app = null;
  var mouthLevel = 0;
  var lastState = "idle";

  function loadScript(src) {
    return new Promise(function (resolve, reject) {
      var s = document.createElement("script");
      s.src = src;
      s.async = false;
      s.onload = resolve;
      s.onerror = function () { reject(new Error("script load failed: " + src)); };
      document.head.appendChild(s);
    });
  }

  function detectModel() {
    return fetch(MODEL_URL, { method: "HEAD" })
      .then(function (res) { return res.ok; })
      .catch(function () { return false; });
  }

  function applyMouth() {
    if (!model || !model.internalModel || !model.internalModel.coreModel) {
      return;
    }
    var core = model.internalModel.coreModel;
    if (typeof core.setParameterValueById === "function") {
      // EmotiMate 패턴: 증폭 후 절대값 주입 (LipSync 그룹 = ParamMouthOpenY)
      core.setParameterValueById("ParamMouthOpenY", Math.min(1, mouthLevel * 1.8));
    }
  }

  function fitModel(container) {
    // 전신 모델을 상반신 중심으로 확대 배치 (스파이크 수준의 근사 크롭)
    var w = container.clientWidth;
    var h = container.clientHeight;
    var scale = (w / model.width) * 2.4;
    model.scale.set(scale);
    model.anchor.set(0.5, 0.12);
    model.x = w / 2;
    model.y = 0;
  }

  function init(container) {
    detectModel().then(function (exists) {
      if (!exists) {
        return; // 자산 없음 → 완전 비활성 (폴백 체계 무간섭)
      }
      return SCRIPTS.reduce(function (p, src) {
        return p.then(function () { return loadScript(src); });
      }, Promise.resolve())
        .then(function () {
          if (!window.PIXI || !window.PIXI.live2d || !window.Live2DCubismCore) {
            throw new Error("live2d runtime missing after script load");
          }
          var canvas = document.createElement("canvas");
          canvas.id = "avatar-live2d";
          canvas.className = "avatar-live2d";
          container.appendChild(canvas);

          app = new window.PIXI.Application({
            view: canvas,
            width: container.clientWidth,
            height: container.clientHeight,
            backgroundAlpha: 0,
            antialias: true,
            autoDensity: true,
            resolution: Math.min(2, window.devicePixelRatio || 1),
          });

          return window.PIXI.live2d.Live2DModel.from(MODEL_URL, { autoInteract: false });
        })
        .then(function (loaded) {
          model = loaded;
          fitModel(container);
          app.stage.addChild(model);
          // 립싱크: 모델 업데이트 뒤에 입 파라미터를 덮어쓴다 (LOW priority → 프레임 마지막)
          window.PIXI.Ticker.shared.add(applyMouth, null, window.PIXI.UPDATE_PRIORITY.LOW);
          active = true;
          container.classList.add("avatar--live2d");
          setState(lastState);
        })
        .catch(function (err) {
          // 어떤 실패든 폴백 유지 — 콘솔 경고만 남긴다.
          console.warn("[live2d] disabled:", err && err.message ? err.message : err);
          active = false;
        });
    });
  }

  function setState(state) {
    lastState = state;
    if (!active || !model) {
      return;
    }
    var map = STATE_MAP[state] || STATE_MAP.idle;
    try {
      if (map.expression) {
        model.expression(map.expression);
      } else if (model.internalModel.motionManager.expressionManager) {
        model.internalModel.motionManager.expressionManager.resetExpression();
      }
      if (map.motion) {
        model.motion(map.motion);
      }
    } catch (err) {
      console.warn("[live2d] setState failed:", err);
    }
  }

  function setMouth(level) {
    mouthLevel = typeof level === "number" && isFinite(level) ? Math.max(0, level) : 0;
  }

  function isActive() {
    return active;
  }

  return { init: init, setState: setState, setMouth: setMouth, isActive: isActive };
})();
