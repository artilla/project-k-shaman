# safe:false Approval Markers

`safe: false` 티켓은 자동 picker가 실행하지 않습니다. 사람이 범위와 롤백을 확인한 뒤 `docs/approvals/<TXXX>.md` 승인 마커를 커밋해야 `run_loop.sh <TXXX>`가 실행됩니다.

필수 필드:

```yaml
approved_by: "이름 또는 계정"
approved_at: "2026-05-18T10:00:00+09:00"
scope_confirmation: "승인한 변경 범위 요약"
rollback_plan: "실패 시 되돌리는 방법"
```

`approved_at`은 ISO8601 형식(`YYYY-MM-DDTHH:MM:SSZ` 또는 `YYYY-MM-DDTHH:MM:SS+09:00`)이어야 합니다. 승인 마커가 없거나 필수 필드가 비어 있으면 `run_loop.sh`는 rc=14로 중단합니다.
