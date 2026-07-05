#!/usr/bin/env bash
# pair.sh — 모바일 기기 페어링 CLI (Mission Control 페어링 UI의 CLI 등가물).
#
# ADR-0024 §2 원칙 3(CLI 동등성): 페어링 화면의 모든 write 동작은 동등한 CLI를 가진다.
# 이 스크립트는 실행 중인 서버 없이 state/devices/ 토큰 store를 직접 조작한다
# (token-store.mjs 재사용). 서버 엔드포인트와 동일한 결과를 만든다.
#
# 사용:
#   pair.sh start              # 1회용 페어링 토큰 생성 → 토큰/만료 출력
#   pair.sh list               # 등록된 기기 목록(요약, 비밀값 없음)
#   pair.sh revoke <device_id> # 기기 토큰 즉시 폐기
#
# 환경 변수:
#   RALPH_STATE_ROOT  state/ 루트 (기본: 저장소 루트)

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STATE_ROOT="${RALPH_STATE_ROOT:-$ROOT}"
DEVICES_DIR="$STATE_ROOT/state/devices"
STORE="$ROOT/mission-control/token-store.mjs"

CMD="${1:-}"

usage() {
  echo "Usage: pair.sh start | pair.sh list | pair.sh revoke <device_id> | pair.sh rename <device_id> <label>" >&2
  exit 2
}

case "$CMD" in
  start)
    node --input-type=module -e "
      import { createPairingToken, PAIRING_TTL_MS } from '$STORE';
      const r = createPairingToken('$DEVICES_DIR');
      console.log('pairing token:', r.token);
      console.log('expires_at   :', r.expires_at);
      console.log('pair URL     : <private-base>/pair#' + r.token);
      console.log('(QR로 표시하려면 Mission Control → Pairing 화면을 사용하세요. 토큰은 1회용·' + (PAIRING_TTL_MS/60000) + '분 만료.)');
    "
    ;;
  list)
    node --input-type=module -e "
      import { listDevices, countActiveDevices, resolveMaxDevices } from '$STORE';
      const devices = listDevices('$DEVICES_DIR');
      console.log('활성 ' + countActiveDevices('$DEVICES_DIR') + ' / 상한 ' + resolveMaxDevices());
      if (!devices.length) { console.log('(등록된 기기 없음)'); process.exit(0); }
      for (const d of devices) {
        const status = d.revoked ? 'revoked' : d.expired ? 'expired' : 'active';
        const renew = d.renew_count ? ('renew×' + d.renew_count) : 'renew×0';
        const seen = d.last_seen_at || '-';
        console.log([d.device_id.slice(0,12)+'…', JSON.stringify(d.label), status, renew, 'seen='+seen].join('  '));
      }
    "
    ;;
  revoke)
    DEVICE_ID="${2:-}"
    [ -n "$DEVICE_ID" ] || { echo "ERROR: revoke requires <device_id>" >&2; usage; }
    node --input-type=module -e "
      import { revokeDeviceToken } from '$STORE';
      const ok = revokeDeviceToken('$DEVICES_DIR', process.argv[1]);
      if (!ok) { console.error('device not found'); process.exit(1); }
      console.log('revoked: ' + process.argv[1]);
    " "$DEVICE_ID"
    ;;
  rename)
    DEVICE_ID="${2:-}"
    shift 2 2>/dev/null || true
    LABEL="$*"
    [ -n "$DEVICE_ID" ] && [ -n "$LABEL" ] || { echo "ERROR: rename requires <device_id> <label>" >&2; usage; }
    node --input-type=module -e "
      import { renameDevice } from '$STORE';
      const ok = renameDevice('$DEVICES_DIR', process.argv[1], process.argv[2]);
      if (!ok) { console.error('rename failed: device not found or invalid label'); process.exit(1); }
      console.log('renamed: ' + process.argv[1]);
    " "$DEVICE_ID" "$LABEL"
    ;;
  *)
    usage
    ;;
esac
