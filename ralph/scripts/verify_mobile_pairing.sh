#!/usr/bin/env bash
# verify_mobile_pairing.sh — T107 데스크톱/ localhost 사전점검.
#
# 실기기/TLS 온디바이스 E2E(T107) 이전에, 실제 모바일 없이 localhost에서 검증
# 가능한 모든 경계를 자동 점검한다. 회귀를 조기에 잡아 온디바이스 세션을 깨끗한
# 기준선에서 시작하게 한다. 브라우저 서비스워커 런타임이 필요한 항목(navigation/SSE
# 주입의 실제 동작)은 여기서 다루지 않는다 — T107 §3 온디바이스 체크리스트 소관.
#
# 사용:
#   ./ralph/scripts/verify_mobile_pairing.sh
#
# exit 0: 모든 사전점검 PASS
# exit 1: 하나 이상 FAIL (요약에 표시)

set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

PORT="${MC_PORT:-$((7990 + (RANDOM % 50)))}"
HOST="127.0.0.1"
BASE="http://$HOST:$PORT"
SERVER_PID=""
TMP_STORE=""
SERVER_ROOT=""
PASS=0
FAIL=0

pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; PASS=$((PASS + 1)); }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; FAIL=$((FAIL + 1)); }
check() { if eval "$2" >/dev/null 2>&1; then pass "$1"; else fail "$1"; fi; }

cleanup() {
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  [ -n "$TMP_STORE" ] && rm -rf "$TMP_STORE" 2>/dev/null || true
  [ -n "$SERVER_ROOT" ] && rm -rf "$SERVER_ROOT" 2>/dev/null || true
}
trap cleanup EXIT

echo "── T107 사전점검 (localhost, port $PORT) ──"

# ── 1. 인증 경계 단위 점검 (서버 불요) ──────────────────────────
echo "[1] 인증 경계 / exec 스코프 단위 점검"
node --input-type=module -e "
import { requiresTokenAuth, execScopeDecision, tokenAuthDecision } from '$ROOT/ralph/mission-control/token-auth.mjs';
import assert from 'node:assert/strict';
// exempt 집합 정확히 {exchange, /pair, /sw.js}
assert.equal(requiresTokenAuth('POST','/api/tokens/exchange'), false);
assert.equal(requiresTokenAuth('GET','/pair'), false);
assert.equal(requiresTokenAuth('GET','/sw.js'), false);
for (const p of ['/inbox','/','/api/tickets','/ui.css','/sw.js.map']) {
  if (p === '/sw.js.map') continue;
}
assert.equal(requiresTokenAuth('GET','/inbox'), true);
assert.equal(requiresTokenAuth('GET','/'), true);
assert.equal(requiresTokenAuth('GET','/api/tickets'), true);
assert.equal(requiresTokenAuth('GET','/ui.css'), true);
// T099 불변식: 비-localhost run_loop/session_ctl 403, approve만 ok
const denied = { ok:false, status:403, body:{ error:'exec scope denied: approve only for non-localhost' } };
assert.deepEqual(execScopeDecision({ remoteAddress:'100.64.0.8', command:'run_loop' }), denied);
assert.deepEqual(execScopeDecision({ remoteAddress:'100.64.0.8', command:'session_ctl' }), denied);
assert.deepEqual(execScopeDecision({ remoteAddress:'100.64.0.8', command:'approve' }), { ok:true });
// localhost는 전권
assert.deepEqual(execScopeDecision({ remoteAddress:'127.0.0.1', command:'run_loop' }), { ok:true });
console.log('ok');
" && pass "exempt 집합 + exec 스코프 불변식(T099)" || fail "exempt 집합 + exec 스코프 불변식(T099)"

# ── 2. 서버 기동 ──────────────────────────────────────────────
# T120: 서버를 격리 temp root로 기동해 §5/§7 페어링·교환이 실제 repo state/devices를
# 오염시키지 않게 한다(누적 시 기기 상한 409로 사전점검이 깨짐). 서버 코드는 여전히
# 실제 ralph/mission-control/에서 로드되고(cwd=ROOT), 데이터 디렉터리만 --root를 따른다.
echo "[2] Mission Control 서버 기동 (localhost, 격리 root)"
SERVER_ROOT="$(mktemp -d)"
mkdir -p "$SERVER_ROOT/docs/tickets/DONE" "$SERVER_ROOT/docs/approvals" \
         "$SERVER_ROOT/ralph/scripts" "$SERVER_ROOT/state/reservations"
cp "$ROOT/ralph/scripts/approve.sh" "$SERVER_ROOT/ralph/scripts/approve.sh"
chmod +x "$SERVER_ROOT/ralph/scripts/approve.sh"
cat > "$SERVER_ROOT/docs/tickets/T001-fixture.md" <<'EOF'
---
id: T001
title: verify fixture
status: awaiting-approval
priority: P3
safe: false
persona: implementer
estimate: S
---

# T001 — verify fixture

## 2. 변경 범위
docs only fixture.

## 5. 롤백 방법 (Reversibility)
git revert <commit>
EOF
node "$ROOT/ralph/mission-control/server.mjs" --root "$SERVER_ROOT" --port "$PORT" >/tmp/t107-verify-server.log 2>&1 &
SERVER_PID=$!
ready=""
for _ in $(seq 1 30); do
  if curl -sf "$BASE/healthz" >/dev/null 2>&1; then ready=1; break; fi
  sleep 0.2
done
[ -n "$ready" ] && pass "서버 healthz 응답" || { fail "서버 기동"; echo "summary: $PASS pass / $FAIL fail"; exit 1; }

# ── 3. 부트스트랩 표면 (exempt + 자체 완결) ────────────────────
echo "[3] 부트스트랩 표면"
check "GET /pair 200" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $BASE/pair)\" = 200 ]"
check "GET /sw.js 200" "[ \"\$(curl -s -o /dev/null -w '%{http_code}' $BASE/sw.js)\" = 200 ]"
check "/pair 자체 완결(인라인 <style>)" "curl -s $BASE/pair | grep -q '<style>'"
check "/pair에 외부 stylesheet 링크 없음" "! curl -s $BASE/pair | grep -q 'rel=\"stylesheet\"'"
check "/pair 교환 흐름 포함" "curl -s $BASE/pair | grep -q '/api/tokens/exchange'"

# ── 4. 서비스워커 주입 + R5 ───────────────────────────────────
echo "[4] 서비스워커 Authorization 주입 / R5"
check "/sw.js Authorization 주입" "curl -s $BASE/sw.js | grep -q 'Authorization'"
check "/sw.js mc-set-token 메시지 핸들러" "curl -s $BASE/sw.js | grep -q 'mc-set-token'"
check "/sw.js IndexedDB 토큰 보관" "curl -s $BASE/sw.js | grep -q 'indexedDB'"
check "/sw.js /api 미캐시(R5)" "! curl -s $BASE/sw.js | grep -E \"cache\\.(add|addAll|put)\\([^)]*['\\\"]/api\""

# ── 5. 페어링 API 라운드트립 ───────────────────────────────────
echo "[5] 페어링 → 교환 → 목록 → 폐기 라운드트립 (localhost)"
PT=$(curl -s -X POST "$BASE/api/tokens/pairing" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).token)}catch(e){console.log('')}})")
[ -n "$PT" ] && pass "페어링 토큰 생성" || fail "페어링 토큰 생성"
DEV=$(curl -s -X POST "$BASE/api/tokens/exchange" -H 'Content-Type: application/json' -d "{\"token\":\"$PT\"}")
DID=$(printf '%s' "$DEV" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).device_id)}catch(e){console.log('')}})")
[ -n "$DID" ] && pass "토큰 교환 → 장기 기기 토큰 발급" || fail "토큰 교환"
check "기기 목록에 active + 수명주기 메타 노출" "curl -s $BASE/api/tokens/devices | grep -q '\"active\":true' && curl -s $BASE/api/tokens/devices | grep -q '\"renew_count\"'"
curl -s -X POST "$BASE/api/tokens/rename" -H 'Content-Type: application/json' -d "{\"device_id\":\"$DID\",\"label\":\"Verify Test Phone\"}" >/dev/null
check "rename(localhost) 라벨 반영" "curl -s $BASE/api/tokens/devices | grep -q '\"label\":\"Verify Test Phone\"'"
curl -s -X POST "$BASE/api/tokens/revoke" -H 'Content-Type: application/json' -d "{\"device_id\":\"$DID\"}" >/dev/null
check "폐기 후 active=false" "curl -s $BASE/api/tokens/devices | grep -q '\"active\":false'"

# ── 6. CLI 동등성 (pair.sh) ───────────────────────────────────
echo "[6] CLI 동등성 (pair.sh, 임시 store)"
TMP_STORE="$(mktemp -d)"
RALPH_STATE_ROOT="$TMP_STORE" ./ralph/scripts/pair.sh start >/dev/null 2>&1 && pass "pair.sh start" || fail "pair.sh start"
PT2=$(node --input-type=module -e "import { createPairingToken, exchangePairingToken } from '$ROOT/ralph/mission-control/token-store.mjs'; const t=createPairingToken('$TMP_STORE/state/devices'); const d=exchangePairingToken('$TMP_STORE/state/devices', t.token); process.stdout.write(d.device_id);")
RALPH_STATE_ROOT="$TMP_STORE" ./ralph/scripts/pair.sh list 2>/dev/null | grep -q "${PT2:0:12}" && pass "pair.sh list" || fail "pair.sh list"
RALPH_STATE_ROOT="$TMP_STORE" ./ralph/scripts/pair.sh rename "$PT2" "CLI Test Phone" >/dev/null 2>&1 && RALPH_STATE_ROOT="$TMP_STORE" ./ralph/scripts/pair.sh list 2>/dev/null | grep -q "CLI Test Phone" && pass "pair.sh rename" || fail "pair.sh rename"
RALPH_STATE_ROOT="$TMP_STORE" ./ralph/scripts/pair.sh revoke "$PT2" >/dev/null 2>&1 && pass "pair.sh revoke" || fail "pair.sh revoke"

# ── 7. P0 게이트 wire 검증 (비-localhost = 다른 loopback 출처) ──
# isLocalhostAddress는 127.0.0.1/::1만 localhost로 보므로, 127.0.0.2에서 연결하면
# 실기기·TLS 없이 비-localhost 서버 경로(401·exec 403)를 그대로 검증한다.
echo "[7] P0 게이트 wire 검증 (출처 127.0.0.2 = 비-localhost)"
if curl -s --interface 127.0.0.2 -o /dev/null "$BASE/healthz" 2>/dev/null; then
  WPT=$(curl -s -X POST "$BASE/api/tokens/pairing" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).token)}catch(e){console.log('')}})")
  WDEV=$(curl -s -X POST "$BASE/api/tokens/exchange" -H 'Content-Type: application/json' -d "{\"token\":\"$WPT\"}" | node -e "let s='';process.stdin.on('data',d=>s+=d).on('end',()=>{try{console.log(JSON.parse(s).token)}catch(e){console.log('')}})")
  check "비-localhost 무토큰 /inbox 401" "[ \"\$(curl -s --interface 127.0.0.2 -o /dev/null -w '%{http_code}' $BASE/inbox)\" = 401 ]"
  check "비-localhost /pair 부트스트랩 200" "[ \"\$(curl -s --interface 127.0.0.2 -o /dev/null -w '%{http_code}' $BASE/pair)\" = 200 ]"
  check "P0: 비-localhost run_loop(유효토큰) 403 scope-denied" "curl -s --interface 127.0.0.2 -X POST $BASE/api/exec -H 'Authorization: Bearer $WDEV' -H 'Content-Type: application/json' -d '{\"command\":\"run_loop\",\"ticketId\":\"T001\"}' | grep -q 'approve only for non-localhost'"
  check "P0: 비-localhost session_ctl(유효토큰) 403 scope-denied" "curl -s --interface 127.0.0.2 -X POST $BASE/api/exec -H 'Authorization: Bearer $WDEV' -H 'Content-Type: application/json' -d '{\"command\":\"session_ctl\",\"ticketId\":\"T001\",\"sessionAction\":\"pause\"}' | grep -q 'approve only for non-localhost'"
  check "비-localhost approve(유효토큰) 비-403 허용" "[ \"\$(curl -s --interface 127.0.0.2 -o /dev/null -w '%{http_code}' -X POST $BASE/api/exec -H 'Authorization: Bearer $WDEV' -H 'Content-Type: application/json' -d '{\"command\":\"approve\",\"ticketId\":\"T001\"}')\" != 403 ]"
  check "비-localhost renew(유효토큰, 창 밖) renewed:false no-op" "curl -s --interface 127.0.0.2 -X POST $BASE/api/tokens/renew -H 'Authorization: Bearer $WDEV' | grep -q '\"renewed\":false'"
  check "비-localhost renew(무토큰) 401" "[ \"\$(curl -s --interface 127.0.0.2 -o /dev/null -w '%{http_code}' -X POST $BASE/api/tokens/renew)\" = 401 ]"
else
  echo "  SKIP  127.0.0.2 출처 미가용 환경 — P0 wire 검증은 tests/mission_control_private_path_scope.bats로 수행"
fi

# ── 요약 ──────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════"
echo "  사전점검 결과: $PASS PASS / $FAIL FAIL"
echo "════════════════════════════════════════════"
if [ "$FAIL" -eq 0 ]; then
  echo "  ✅ 데스크톱 기준선 PASS — 이제 T107 §3 온디바이스 체크리스트(실기기+TLS)를 수행하세요."
  echo "     결과는 docs/reviews/T107-mobile-e2e.md에 기록합니다."
  exit 0
else
  echo "  ❌ FAIL 존재 — 온디바이스 검증 전에 회귀를 먼저 해소하세요."
  exit 1
fi
