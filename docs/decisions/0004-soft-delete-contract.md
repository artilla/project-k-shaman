# 0004. 사용자 삭제(soft-delete) 계약 — 익명화·보존·재가입

- 상태: 확정 (2026-07-12, owner 승인)
- 근거: 리뷰 16차 P1-8 — "provider_subject·last_login_at·events 연결·purchases 연결이
  삭제 후에도 유지된다. 보존 자체는 가능하지만 익명화 여부·보존기간·재가입 처리
  계약을 먼저 확정해야 한다."
- 구현: `db/migrations/003_soft_delete_invariant.sql` (트리거 + CHECK 불변식)

## 결정

### C1. 재가입 = 새 계정 (provider_subject 익명화)

삭제 시 `users.provider_subject`를 복원 불가능한 익명 토큰 `deleted:<uuid>`로
대체한다. `UNIQUE(provider, provider_subject)`가 풀리므로 같은 OAuth 계정으로
다시 로그인하면 **완전히 새로운 사용자 행**이 생성된다. 이전 데이터와의 연결은
불가능하다 (§12 "삭제 제공" 취지).

### C2. events — user_id 절단, payload 유지

삭제 시 해당 사용자의 `events.user_id`를 NULL로 절단한다. payload는 유지한다 —
payload에 개인정보를 넣지 않는 것이 기존 계약이다(크기 상한 32KiB + 스키마 검증,
IP/UA 미저장 원칙). 절단된 events는 익명 통계 데이터로 보존기간 제한 없이 유지한다.

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

## 불변식 (003이 스키마 수준에서 강제)

1. `deleted_at IS NOT NULL` ⇒ 모든 개인 필드 NULL + `consent=false` +
   `provider_subject LIKE 'deleted:%'` (CHECK — 재기입 UPDATE·삭제 상태 INSERT 거부)
2. 삭제된 사용자를 가리키는 sessions/streaks/user_fortunes/events/purchases
   신규 행(INSERT 및 user_id 변경 UPDATE) 거부 (트리거)
3. 삭제 전이 시점: 개인 필드 스크럽 + 자식 행 정리 + events 절단 (트리거)

## 남은 후속 (P2, 별도 티켓)

- migration ledger checksum: 같은 version의 SQL 변경을 `applied`로 오인하는 문제
- purchases 5년 경과분 배치 파기 절차
