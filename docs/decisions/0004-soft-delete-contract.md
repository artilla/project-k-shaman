# 0004. 사용자 삭제(soft-delete) 계약 — 익명화·보존·재가입

- 상태: 확정 (2026-07-12, owner 승인; C2는 리뷰 16차 P1-9에 따라 fail-closed로 강화.
  2026-07-13 리뷰 16차 8라운드 후속: write contract를 단일 전역 잠금 순서
  (child→users)로 통일, 진입점 증거를 GUC에서 role 권한 경계로 교체)
- 근거: 리뷰 16차 P1-8 — "provider_subject·last_login_at·events 연결·purchases 연결이
  삭제 후에도 유지된다. 보존 자체는 가능하지만 익명화 여부·보존기간·재가입 처리
  계약을 먼저 확정해야 한다."
- 구현: `db/migrations/004_soft_delete_contract.sql`(공개본 불변) +
  `db/migrations/005_ownership_repair_and_lock_contract.sql` — 이미 공개된
  003·004는 재작성하지 않는다(같은 version 변경은 기적용 DB에서 skip되어 새
  계약이 설치되지 않음; 리뷰 16차 7차 P1-1 실측). 4~7차 라운드의 계약 확장·
  기존 데이터 repair·write contract는 전부 005에 있다.
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

- **legacy orphan 정책 (5차 P1-4)**: 002 시절의 삭제는 세션을 먼저 지워
  session-only event의 소유 증거가 이미 끊겼다. 005는 소유 증거가 없는 이중
  orphan(user_id·session_id 모두 NULL)의 payload를 **전부** 스크럽한다 —
  fail-closed. 정당한 익명 orphan payload도 함께 지워지는 트레이드오프를
  감수한다 (1회성 backfill; 이후의 orphan은 삭제 시점 트리거가 처리).
- scrub의 session 링크 절단: 스크럽 시점에 `session_id`도 NULL — frozen CHECK가
  재연결(UPDATE session_id)을 거부한다 (5차 P1-5). `scrubbed_at` 해제(non-NULL→
  NULL)는 트리거가 거부한다 (5차 P1-2).

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

## 불변식 (004 공개본 + 005가 스키마 수준에서 강제)

1. `deleted_at IS NOT NULL` ⇒ 모든 개인 필드 NULL + `consent=false` +
   `provider_subject ~ '^deleted:<uuid>$'` — 정확한 UUID 형식 매칭(4차 P1-9;
   접두사 매칭은 legacy subject 오인 위험) (CHECK — 재기입 UPDATE·삭제 상태
   INSERT 거부)
2. 삭제된 사용자를 가리키는 sessions/streaks/user_fortunes/events/purchases
   신규 행 거부 — 부모 행 FOR SHARE 잠금으로 미커밋 삭제와도 직렬화 (트리거)
   - sessions 소유자 재배정 금지 (6차): user가 있는 세션의 user_id 변경(NULL
     포함)은 거부 — 삭제 시 event 스캔(session_id IN 소유 세션)의 우회를
     차단한다. 허용 전이는 익명 세션의 로그인 바인딩(NULL→user, 삭제 사용자
     검사 포함)뿐이다.
   - events 교차 귀속 금지 (6차): event의 user_id와 session 소유자가 다르면
     거부 — 교차 귀속은 삭제 스캔의 사각을 만든다. events_guard의 잠금 순서는
     전역 순서(child→users)를 따른다: 대상 event 행(암묵) → session FOR SHARE
     → users FOR SHARE. session 행을 먼저 잠그므로 소유자가 검사 중 바뀔 수
     없다 (8라운드 후속 — 과거의 "무잠금 선독 → users → sessions → 재검증"은
     삭제 경로와 역전을 만들었다).
3. `events.scrubbed_at IS NOT NULL` ⇒ `user_id IS NULL AND session_id IS NULL
   AND payload = '{}'` (CHECK — 스크럽의 영속성. `session_id IS NULL`까지가
   frozen 불변식이다 — 이것이 빠지면 스크럽된 event의 세션 재연결(UPDATE
   session_id)이 CHECK를 통과한다; 5차 P1-5·7차 P2)
4. purchases.user_id 재배정 금지 — 거래기록 귀속 불변 (트리거)
5. 삭제 전이 시점: 개인 필드 스크럽·익명화 + 자식 행 정리 + events(세션 귀속
   포함) 스크럽 (트리거)

## 기존 교차 귀속 데이터 repair (7차 P1-4 — 005)

001~004 시절에는 `event.user_id ≠ session.owner`(guest 세션 포함)인 교차 귀속
행을 막는 계약이 없었다. 이런 행이 남으면 guest 세션이 이후 다른 사용자에게
바인딩된 뒤 그 사용자를 삭제할 때, 세션 스캔이 제3자 귀속 payload까지 스크럽
했다 (실측). 005는 migration 시점에 이를 **repair**한다: 명시적 `user_id`를
귀속의 근거로 삼아 불일치 행의 `session_id`를 절단한다 — 교차 스크럽의 사각은
제거되고 원 귀속·payload는 보존된다. 이후의 신규 교차 귀속은 트리거(불변식 2)가
거부하므로 이 repair는 1회성이다.

## Write contract — 단일 전역 잠금 순서·진입점 권한 경계 (7차 P1-5 → 8라운드 후속 — 005)

PostgreSQL은 child row lock "후" BEFORE UPDATE 트리거를 실행하므로, 직접 child
DML 경로는 구조적으로 child→users 순서이고 이는 바꿀 수 없다. 따라서 **전역
잠금 순서는 하나뿐이다**:

    events → sessions → streaks → user_fortunes → users   (child→users)

- 직접 child DML: PG가 child 행을 먼저 잠그고 guard 트리거가 users FOR SHARE —
  사전 잠금 helper 없이 구조적으로 순서를 따른다. 여러 child 행/테이블을
  갱신하는 writer는 위 테이블 순서와 id 오름차순을 따른다.
- `events_guard`: 대상 event 행(암묵) → session FOR SHARE → users FOR SHARE.
- `app_soft_delete_user(BIGINT)`: 같은 순서로 child 행을 결정적(id 오름차순)으로
  잠근 뒤 users를 잠근다.
- 구 `app_lock_user_rows()`(users-first)는 **제거됐다** — users를 먼저 잠그는
  helper가 남아 있는 한 역전이 사라지지 않는다 (8라운드 후속 실측: helper를
  따른 writer가 deadlock victim). users를 먼저 잠그는 어떤 경로도 만들지 않는다.
- 잔여 deadlock(외부 도구의 임의 순서 잠금)은 `app_soft_delete_user`의 bounded
  retry(subtransaction rollback → 최대 5회)가 삭제 쪽에서 흡수한다.

### 진입점 권한 경계 (8라운드 후속 P1 — GUC 증거 폐기)

과거의 transaction-local GUC(`app.soft_delete_user`)는 일반 app role도 정확한
ID로 `set_config`할 수 있어 **증거가 아니었다** (실측: 위조 후 직접 UPDATE로
삭제 성공). 현재 경계:

- `shaman_softdelete`: NOLOGIN 정의자 role. `app_soft_delete_user()`는 이 role
  소유의 **SECURITY DEFINER** 함수(생성 시점 고정 search_path)다.
- 스크럽 트리거는 `deleted_at` 전이 시점의 `current_user = shaman_softdelete`를
  요구한다 — 이 컨텍스트는 진입점 함수 안에서만 성립하고, membership 없는
  role은 SET ROLE로 사칭할 수 없다. superuser 여부와 무관하게 트리거가
  강제된다 (직접 UPDATE는 postgres도 거부된다).
- app role 배포 계약: `users`에 대한 UPDATE는 **컬럼 목록 grant**로 부여하고
  `deleted_at`을 제외한다 — 권한층에서도 직접 DML이 차단된다 (트리거 경계는
  그 위의 스키마 강제층).
- 운영 전제: migration 실행 role은 role 생성/소유권 이전 권한(superuser 또는
  CREATEROLE+membership)이 필요하다.

## 남은 후속 (P2, 별도 티켓)

- migration ledger checksum: 같은 version의 SQL 변경을 `applied`로 오인하는 문제
- purchases 5년 경과분 배치 파기 절차
