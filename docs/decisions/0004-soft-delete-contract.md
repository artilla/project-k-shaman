# 0004. 사용자 삭제(soft-delete) 계약 — 익명화·보존·재가입

- 상태: 확정 (2026-07-12, owner 승인; C2는 리뷰 16차 P1-9에 따라 fail-closed로 강화)
- 근거: 리뷰 16차 P1-8 — "provider_subject·last_login_at·events 연결·purchases 연결이
  삭제 후에도 유지된다. 보존 자체는 가능하지만 익명화 여부·보존기간·재가입 처리
  계약을 먼저 확정해야 한다."
- 구현: `db/migrations/004_soft_delete_contract.sql` (003은 공개본 불변 — 확장분은 004로 분리)
- 익명 토큰 판정: `deleted:` 접두사가 아니라 정확 형식(`deleted:` + uuid 36자) 매칭 —
  legacy provider_subject가 우연히 같은 접두사여도 오동작하지 않는다

## 결정

### C1. 재가입 = 새 계정 (provider_subject 익명화)

삭제 시 `users.provider_subject`를 복원 불가능한 익명 토큰 `deleted:<uuid>`로
대체한다. `UNIQUE(provider, provider_subject)`가 풀리므로 같은 OAuth 계정으로
다시 로그인하면 **완전히 새로운 사용자 행**이 생성된다. 이전 데이터와의 연결은
불가능하다 (§12 "삭제 제공" 취지).

### C2. events — user_id 절단 + payload 스크럽 + scrubbed_at 마커 (리뷰 16차 P1-9·4차 P1-7·8 반영)

삭제 시 해당 사용자의 events를 스크럽한다: `user_id` NULL, `payload` `{}`,
`scrubbed_at` 기록. 당초 "payload 무익명정보" 전제로 payload 유지를 승인했으나,
현재 `/api/event`는 임의 event 필드를 보존하고 payload schema 검증이 미구현이라
그 전제가 성립하지 않는다 — fail-closed로 payload까지 지운다.

- 대상은 `user_id` 귀속 events뿐 아니라 **삭제 사용자의 session으로만 귀속된
  events도 포함**하며, 세션 삭제 "전"에 수행한다 (4차 P1-7).
- 스크럽은 일회성 이벤트가 아니라 **영속 불변식**: `scrubbed_at`이 설정된 행은
  CHECK(`events_scrubbed_frozen`)로 `user_id IS NULL AND payload = '{}'`가
  강제된다 — 삭제와 동시(행 잠금 대기 후 재평가) 또는 삭제 후의 payload 재기입은
  거부된다 (4차 P1-8).

event_type·created_at 등 집계 축은 보존되어 익명 통계는 유지된다.
후속: `/api/event` payload schema 검증이 구현되어 "개인정보 미포함"이 스키마
수준에서 보장되면 별도 마이그레이션으로 payload 보존으로 완화할 수 있다.

### C3. purchases — 보존, 신규 유입 거부

구매 기록은 전자상거래 등에서의 소비자보호에 관한 법률상 거래기록 보존 의무
(대금결제·재화공급 기록 5년)를 근거로 사용자 행과의 연결을 유지한 채 보존한다.
사용자 행은 익명화된 골격(provider·id·created_at·deleted_at)만 남으므로 잔존
개인정보는 없다. 삭제된 사용자를 가리키는 **신규** purchases 행은 거부한다.

### C4. last_login_at — 스크럽

개인 행동 흔적이므로 삭제 시 NULL. (휴면 판정 등 운영 지표는 삭제된 계정에
적용될 일이 없다.)

### C5. 복구 금지

`deleted_at`을 다시 NULL로 되돌리는 UPDATE는 트리거가 거부한다. 삭제는
비가역이며, 돌아오는 사용자는 C1에 따라 새 계정이 된다. 재동의·재개인화도
새 계정에서 처음부터 시작한다.

## 불변식 (004가 스키마 수준에서 강제)

1. `deleted_at IS NOT NULL` ⇒ 모든 개인 필드 NULL + `consent=false` +
   `provider_subject ~ '^deleted:<uuid>$'` — 정확한 UUID 형식 매칭(4차 P1-9;
   접두사 매칭은 legacy subject 오인 위험) (CHECK — 재기입 UPDATE·삭제 상태
   INSERT 거부)
2. 삭제된 사용자를 가리키는 sessions/streaks/user_fortunes/events/purchases
   신규 행 거부 — 부모 행 FOR SHARE 잠금으로 미커밋 삭제와도 직렬화 (트리거)
3. `events.scrubbed_at IS NOT NULL` ⇒ `user_id IS NULL AND payload = '{}'`
   (CHECK — 스크럽의 영속성)
4. purchases.user_id 재배정 금지 — 거래기록 귀속 불변 (트리거)
5. 삭제 전이 시점: 개인 필드 스크럽·익명화 + 자식 행 정리 + events(세션 귀속
   포함) 스크럽 (트리거)

## 남은 후속 (P2, 별도 티켓)

- migration ledger checksum: 같은 version의 SQL 변경을 `applied`로 오인하는 문제
- purchases 5년 경과분 배치 파기 절차
