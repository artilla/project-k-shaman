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
  var currentContainer = null; // v2: S0 히어로 ↔ S4 스테이지 프레임 간 이동 지원

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
    // GET 사용: 이 서버(http.server BaseHTTPRequestHandler)는 do_HEAD 미구현이라
    // HEAD가 501을 반환한다. model3.json은 ~3KB라 GET 감지 비용이 무시 가능하다.
    return fetch(MODEL_URL)
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
    // 전신 모델을 상반신 중심으로 확대 배치 (스파이크 수준의 근사 크롭).
    // v2: 컨테이너마다 배율이 다르다 — S4 소형 프레임 기본 2.4, S0 대형 히어로는
    // data-live2d-zoom / data-live2d-anchor-y 로 조절한다.
    var w = container.clientWidth;
    var h = container.clientHeight;
    var zoom = parseFloat(container.dataset.live2dZoom || "2.4");
    var anchorY = parseFloat(container.dataset.live2dAnchorY || "0.12");
    // model.width는 현재 스케일 반영값 — 재호출(moveTo) 시 복리 확대를 막기 위해
    // 자연 크기(스케일 1) 기준으로 측정한다.
    model.scale.set(1);
    var scale = (w / model.width) * zoom;
    model.scale.set(scale);
    model.anchor.set(0.5, anchorY);
    model.x = w / 2;
    model.y = 0;
  }

  function init(container) {
    currentContainer = container;
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
          // 캔버스/앱 생성 전에 컨테이너를 무대 크기로 확장한다 — 96px 상태에서 만들면
          // PIXI가 96×96으로 고정돼 좌상단에 작게 붙는다 (실측). 실패 시 catch에서 원복.
          // v2: 로드 중 moveTo()가 호출됐을 수 있으므로 항상 currentContainer 기준으로 부착한다.
          // FOUC 수정: avatar--live2d 클래스(정지컷 숨김)는 모델 로드 완료 후에만 붙인다 —
          // 여기서 붙이면 모델 로드 1~2초 동안 히어로가 사라져 검은 빈 영역이 보인다.
          var target = currentContainer;
          var canvas = document.createElement("canvas");
          canvas.id = "avatar-live2d";
          canvas.className = "avatar-live2d";
          target.appendChild(canvas);

          app = new window.PIXI.Application({
            view: canvas,
            width: target.clientWidth,
            height: target.clientHeight,
            backgroundAlpha: 0,
            antialias: true,
            autoDensity: true,
            resolution: Math.min(2, window.devicePixelRatio || 1),
          });

          return window.PIXI.live2d.Live2DModel.from(MODEL_URL, { autoInteract: false });
        })
        .then(function (loaded) {
          model = loaded;
          // 로드 완료 시점의 컨테이너로 최종 배치 (로드 중 화면 전환 대응)
          if (app.view.parentElement !== currentContainer) {
            moveTo(currentContainer);
          } else {
            fitModel(currentContainer);
          }
          app.stage.addChild(model);
          // 립싱크: 모델 업데이트 뒤에 입 파라미터를 덮어쓴다 (LOW priority → 프레임 마지막)
          window.PIXI.Ticker.shared.add(applyMouth, null, window.PIXI.UPDATE_PRIORITY.LOW);
          active = true;
          currentContainer.classList.add("avatar--live2d"); // 이제부터 정지컷 대신 캔버스
          setState(lastState);
          // 창 리사이즈 대응 — 렌더러 크기·모델 fit이 stale해지는 레이아웃 버그 수정
          window.addEventListener("resize", function () {
            if (active && currentContainer) {
              app.renderer.resize(currentContainer.clientWidth, currentContainer.clientHeight);
              fitModel(currentContainer);
            }
          });
        })
        .catch(function (err) {
          // 어떤 실패든 폴백 유지 — 콘솔 경고만 남기고 컨테이너 확장을 원복한다.
          console.warn("[live2d] disabled:", err && err.message ? err.message : err);
          if (currentContainer) {
            currentContainer.classList.remove("avatar--live2d");
          }
          active = false;
        });
    });
  }

  // v2: 캔버스를 다른 컨테이너로 이동 (S0 온보딩 히어로 ↔ S4 스테이지 프레임).
  // WebGL 컨텍스트는 DOM 이동에서 유지된다 — 렌더러 크기와 모델 배치만 새 컨테이너에 맞춘다.
  function moveTo(container) {
    var prev = currentContainer;
    currentContainer = container;
    if (!app || !app.view) {
      return; // 아직 로드 전 — init/로드 완료 시 currentContainer 기준으로 부착된다.
    }
    if (prev && prev !== container) {
      prev.classList.remove("avatar--live2d");
    }
    if (active) {
      container.classList.add("avatar--live2d"); // 로드 전이면 정지컷 유지 (FOUC 방지)
    }
    if (app.view.parentElement !== container) {
      container.appendChild(app.view);
    }
    app.renderer.resize(container.clientWidth, container.clientHeight);
    if (model) {
      fitModel(container);
    }
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

  return { init: init, moveTo: moveTo, setState: setState, setMouth: setMouth, isActive: isActive };
})();
