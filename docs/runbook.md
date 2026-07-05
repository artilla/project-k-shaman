# Ralph Loop 운영 가이드 (Runbook)

이 문서는 **언제 무엇을 실행할지**, **무엇이 실패했을 때 어떻게 복구할지**를 정의합니다. 자동화의 신뢰는 코드보다 이 문서에서 옵니다.

## 1. 단계별 실행 명령

> **처음 시작하는 경우**: 티켓 작성 방법(TEMPLATE 위치, 필수 필드, 파일명 규칙, 페르소나 선택)은 [README.md — 첫 티켓 작성하기](../README.md#첫-티켓-작성하기-getting-started)를 먼저 읽으세요.
>
> **새 프로젝트에 이식하는 경우**: 이 하네스를 다른 프로젝트에 적용하려면 [`새_프로젝트_적용_가이드.md`](../새_프로젝트_적용_가이드.md) 또는 `./scripts/init_new_project.sh`(대화형 위저드)를 보세요.

### Step 1 — 수동 보조 (혼자 호출)

```bash
# 명세 점검
$EDITOR docs/master-spec.md

# 티켓 만들기 (TEMPLATE 위치·필수 필드·파일명 규칙은 README Getting Started 참조)
cp docs/tickets/TEMPLATE.md docs/tickets/T001-feature-x.md

# 검증만 수동 실행
./scripts/run_checks.sh
```

### Step 2 — 반자율 1티켓 사이클

```bash
./scripts/run_loop.sh                    # 다음 티켓 자동 선택, 1 사이클
./scripts/run_loop.sh T002-something     # 특정 티켓 지정
./scripts/run_loop.sh --safe-only        # safe: true 라벨 티켓만 처리
./scripts/run_loop.sh --dry-run          # 프롬프트만 출력하고 종료
```

루프 흐름: `Reset → Ingest → Act → Verify → Commit → Reset`

### Step 2.1 — `safe: false` 승인 마커

`safe: false` 티켓은 자동 picker가 실행하지 않습니다. `--safe-only`에서 발견되면 picker가 다음 로그를 남기고 티켓을 `awaiting-approval` 상태로 바꿉니다.

```text
[SKIP] TXXX — safe:false, 승인 필요. awaiting-approval 상태로 변경됨.
```

실행하려면 사람이 `docs/approvals/<TXXX>.md` 승인 마커를 작성·commit한 뒤 특정 티켓을 명시 호출합니다.

```bash
./scripts/run_loop.sh TXXX
```

승인 마커 필수 필드는 `approved_by`, `approved_at`, `scope_confirmation`, `rollback_plan` 입니다. 형식은 [`docs/approvals/README.md`](approvals/README.md)를 따릅니다.

### Step 3 — 헤드리스 + worktree 병렬

```bash
./scripts/orchestrator.sh                # 메인 오케스트레이터, 백그라운드 워커 N개 spawn
./scripts/orchestrator.sh --max 3        # 동시 실행 워커 수 제한
./scripts/orchestrator.sh --once         # 한 라운드만 돌고 종료
```

### Step 4 — 운영 루프

```cron
# crontab -e (예시)
*/30 * * * * cd /path/to/ProjectHephaestus && ./scripts/run_loop.sh --safe-only >> state/cron.log 2>&1
```

## 2. 자동/수동 분기 표

| 작업 | Step 2 자동 | Step 3 자동 | 인간 승인 |
|---|:---:|:---:|:---:|
| 로컬 코드 리팩토링 | O | O | |
| 테스트 추가/수정 | O | O | |
| 문서·주석 수정 | O | O | |
| 의존성 패치 버전 업 | O | O | |
| 의존성 마이너 업 | | O (PR draft) | merge 전 |
| `safe: false` 티켓 | | | **승인 마커 필수** |
| **의존성 메이저 업** | | | **항상** |
| 풀 리퀘스트 draft 생성 | O | O | merge 전 |
| **메인 브랜치 직접 push** | | | **항상 금지** |
| 이메일/SMS 초안 작성 | O | O | |
| **실제 이메일/SMS 발송** | | | **항상** |
| **운영 DB 변경** | | | **항상** |
| **결제·송금** | | | **항상** |
| **비밀키 접근/출력** | | | **항상 금지** |

판단 기준 한 줄: **"잘못됐을 때 인간이 당황하지 않고 즉시 되돌릴 수 있는가?"**

## 3. 실패 처리 규칙 (Recovery State)

### 3.0 safe:false 승인 실패 (rc=14)

증상:

```text
❌ TXXX는 safe:false. 승인이 필요합니다. docs/approvals/TXXX.md를 작성하세요.
```

조치:

1. 티켓 §2 Scope와 §5 롤백 방법을 사람이 직접 확인합니다.
2. `docs/runbook.md` §4 보안 3요소 룰과 `skills/security-reviewer.md` 체크리스트를 통과하는지 확인합니다.
3. `docs/approvals/TXXX.md` 승인 마커를 작성하고 commit합니다.
4. `./scripts/run_loop.sh TXXX`로 특정 티켓을 다시 호출합니다.

승인을 거부하면 티켓을 `blocked`로 바꾸고 `docs/tickets/ARCHIVE/`로 이동한 뒤, 거부 사유를 `docs/reviews/<TXXX>-rejected.md`에 남깁니다.

### 3.1 단일 티켓 실패 — 워크트리 종류에 따라 분기

**isolated worktree (`.ralph/wt-*`) 안에서 실행 중인 경우**

```
실패 1회 → 동일 티켓 재시도 (Reset 후)
실패 2회 → 마지막 변경사항 git diff 검토 + 새 sub-agent에 cross-review
실패 3회 → git reset --hard HEAD + git clean -fd (자동 폐기 허용)
         → 티켓 status: blocked, ARCHIVE/ 이동 → 다음 티켓
```

**메인 워크트리에서 실행 중인 경우 (Step 2 반자율 모드)**

```
실패 1회 → 동일 티켓 재시도 (Reset 후)
실패 2회 → diff 검토 + cross-review
실패 3회 → 자동 폐기 절대 안 함 (사용자 변경 보호)
         → git diff > docs/reviews/<TXXX>-failed.diff 보존
         → 티켓 status: blocked, 메모에 사유 적기
         → 사람이 폐기/적용/추가작업을 결정할 때까지 대기
```

판단 기준: **메인 워크트리는 인간 소유**. `git checkout .` / `git reset --hard`는 isolated worktree에서만.

> **한정**: 위 "실패 3회 → 자동 폐기 허용" 규칙은 **실패 횟수(3회) 누적 기반**이며, **단일 rc=5 timeout + WIP** 경우엔 적용하지 않는다. rc=5 timeout 후 미커밋 WIP가 남아 있으면 §3.7(ADR-0017 결정 2)이 우선한다.

### 3.2 워킹 트리가 더러워도 테스트 통과 시
- 통과로 간주, 단 단일 commit 의무는 그대로. (Designing Ralph Loops p.11 Recovery State)

### 3.3 동일 실패가 3티켓 연속 발생
- 자동 루프 즉시 정지 (`state/lock` 생성)
- 인간이 `state/failures.log` 확인 후 명시적으로 `rm state/lock` 해야 재개

### 3.4 Step 0 전제 (모든 실행의 사전 조건)
- 실제 자동 사이클은 **git 저장소**를 요구합니다 (`commit`·`git mv` 사용).
  ```bash
  git init && git add . && git commit -m "init: Ralph Loop template"
  ```
- `--dry-run`은 git 없이도 가능 (프롬프트만 미리 보기).

### 3.5 Reservation 모델 (티켓 동시성)
- 예약은 **git commit이 아니라** `state/reservations/<TXXX>.d/` 디렉터리(`mkdir`로 atomic)로 표현됩니다.
- 따라서 dry-run·실패·중단 모두 git history에 흔적을 남기지 않습니다.
- 디렉터리 안의 `meta` 파일에 `pid`, `mode`(standalone|orchestrated), `started_at`, `root` 가 기록됩니다.
- 충돌 시 → `pick_next_ticket.sh`가 자동으로 후보에서 제외.
- 비정상 종료로 lock이 남았을 때 정리:
  ```bash
  rm -rf state/reservations/T001.d   # pid가 죽었음을 직접 확인 후
  ```

### 3.6 Worker 결과 통합 (Step 3 헤드리스 모드)
- orchestrator는 **자동 merge를 하지 않습니다** (가역성 원칙).
- 각 worker는 `ralph/<TXXX>` 브랜치에 단일 commit을 남깁니다.
- 라운드 종료 시 orchestrator가 각 브랜치의 결과를 요약 출력합니다.
- 사람이 검토 후 직접:
  ```bash
  git diff main..ralph/T001         # 변경 검토
  git merge --no-ff ralph/T001      # 만족스러우면 merge
  # 또는 PR 생성
  ```
- **merge 책임·검토 SLA·누적 한도** 정책: [`ADR-0006`](decisions/0006-worktree-merge-sla.md) 참조.
  - 검토 담당자: 이훈 (v0.4 1인 개발자 환경)
  - merge 기준: acceptance criteria 범위 확인 + bats 재실행 PASS/명시적 SKIP + single commit 의무
  - SLA: `safe: true` 티켓 24h 이내
  - 누적 한도: 미검토 `ralph/*` 브랜치 5개 초과 시 신규 orchestrator 실행 중단 (v0.4 수동 경고)

### 3.7 rc=5 timeout 후 WIP 분기 (ADR-0017 결정 2)

worker가 `CLAUDE_TIMEOUT_SECONDS` 초과로 rc=5를 반환한 경우, **§3.1 "실패 3회 자동 폐기"를 즉시 적용하지 않는다**. 미커밋 WIP가 남아 있을 수 있으므로 다음 3-way 분기를 먼저 수행한다.

> **확인 우선**: rc=5 후 항상 `.ralph/wt-<id>` worktree diff를 먼저 확인한다.
> ```bash
> git -C .ralph/wt-<id> diff HEAD
> ```

**분기 1 — WIP 있음 (회수 가능)**

- `git diff` / `run_checks` / 티켓 scope 검토 후 WIP를 회수한다.
- 회수 내용이 티켓 수용 기준 범위 내이면 단일 commit으로 보강 후 정상 완료 처리.
- 선례: T049, T051, T053, T054.

**분기 2 — WIP 없음**

- operator가 직접 WIP를 작성하거나, `CLAUDE_TIMEOUT_SECONDS` 상향 후 재시도한다.
- 선례: T052 (타임아웃, WIP 없음 → 수동 재시도).
- `CLAUDE_TIMEOUT_SECONDS` 현재 기본값: **1200** (T056, ADR-0017).
- `run_loop.sh`는 operator가 `CLAUDE_TIMEOUT_SECONDS`를 명시하지 않은 경우에만 티켓 frontmatter 기반 정책을 적용한다. 우선순위는 **명시 env override > `estimate: L`/UI label 정책 > 기본 1200초**다.
- `estimate: L` 또는 `ui`/`frontend`/`mission-control` label 티켓은 기본 1200초 대신 2400초로 실행한다. 적용 시 headless log에 `headless timeout: <초>s (<근거>)`가 남는다.
- Live Sessions pause/resume은 `timeout_backend=bash-group` 세션에서만 허용한다. `timeout`/`gtimeout` backend 또는 `pgid=unknown` 세션은 `session_ctl.sh pause|resume`이 시그널 없이 거부하고 `*-rejected` 이벤트를 남긴다.
- `bash-group` backend는 `events.jsonl`의 `pause`/`resume` 이벤트를 기준으로 timeout 예산을 active 실행 시간에만 차감한다. 장시간 정지는 API 연결 만료 가능성이 있으므로 운영자는 10분 내 resume하거나 abort/redirect로 재디스패치한다.
- `run_headless.sh` bash-group watchdog은 `CLAUDE_IDLE_SECONDS`(기본 300초) 동안 출력과 작업 트리 변화가 모두 없으면 idle-exit로 종료한다. run_loop는 이를 timeout rc=5와 구분해 rc=15로 보고하고, `state/failures.log` stage는 `idle-exit`로 남긴다. WIP가 있으면 §3.7 분기 1처럼 회수하고, WIP가 없으면 T088 이후 재현 데이터로 보고한다.
- `CLAUDE_IDLE_SECONDS=0`은 idle 감지를 비활성화한다. pause 상태 세션은 의도적 무출력으로 보아 idle 시계가 진행되지 않는다.

**분기 3 — WIP 있으나 위험·범위 초과**

- **회수 금지**. `.ralph/wt-<id>` worktree를 폐기하고 티켓을 `blocked`로 변경.
- 범위 확장 WIP는 새 티켓으로 분리해 planner에게 위임.
- 선례 개념: T053 트립와이어 조건.

참조: [ADR-0017](decisions/0017-v0.12-timeout-wip-recovery.md)

### 3.7.1 pause-timeout 시계 정책 (T086 확정)

**원칙**: pause는 **bash-group backend 세션에서만 허용**하며, 10분 이내 resume을 권고한다.

| backend | pause 허용 | 이유 |
|---|:---:|---|
| `bash-group` | **O** | `kill -STOP -- -<pgid>`가 프로세스 그룹 전체를 동결 — watchdog도 같은 그룹에 있으므로 timeout 시계가 자연히 멈춤 (커널 보장) |
| `timeout` | X | 외부 `timeout` 바이너리는 자식 프로세스 그룹 밖에 있어 STOP을 보내도 타이머가 계속 흐름 → 정지했는데 timeout으로 죽는 사고 위험 |
| `gtimeout` | X | `timeout`과 동일 이유 |

**운영 메모**:

- pause 후 resume까지 경과 시간은 watchdog 예산에서 소비되지 않는다 (bash-group 경로에서 STOP이 프로세스 그룹 전체를 동결하므로).
- **10분 초과 pause 시 API 연결 만료 위험**이 있다. UI에서 paused 경과 시간이 강조 표시되므로 10분 이내 resume을 권고한다.
- pause 시 `events.jsonl`에 `{"action":"pause", "ts":"..."}` 이벤트가 기록된다. `ts` 값이 사실상 `paused_at`이므로 별도 필드 없이 예산 계산에 활용할 수 있다.
- timeout/gtimeout backend에서 pause를 시도하면 `session_ctl.sh`이 nonzero exit + `pause-rejected` 이벤트를 기록하고 시그널을 보내지 않는다 (T083 가드, `tests/pause_timeout_clock.bats`로 고정).

## 4. 보안 경계 (3요소 룰)

다음 셋 중 **2개 이상이 동시에** 같은 컨텍스트에 있으면 자율 실행 금지:

1. 신뢰할 수 없는 입력 (외부 사용자 데이터, 외부 URL, 미신뢰 토큰)
2. 인터넷 연결 권한
3. 기밀 데이터 (비밀키, PII, 회사 비공개 자료)

자율 루프는 위 조합을 만들면 안 됩니다. 필요하면 분리된 sandbox + 인간 승인.

## 5. Cognitive Debt 방지

- 매 N건의 자동 PR마다 인간이 1회 코드베이스 walkthrough를 강제 (예: PR 10개당 1회).
- 자동 PR이 누적될수록 "이 시스템이 어떻게 돌아가는지 인간이 모름" 상태가 깊어짐.
- 주간 Friday 30분: 최근 변경 요약 읽기 + 임의 1파일 직접 수정.

## 6. 병목 점검 (TOC)

루프가 빨라져도 다음이 병목이면 의미 없음. 매주 점검:

- 배포 빈도가 PR 생성 속도를 따라가는가?
- QA가 자동 PR을 한 번씩 보고 있는가?
- 사용자 피드백이 티켓으로 들어오는 경로가 살아 있는가?

병목이 된 단계에 AI 노력을 집중. (예: 배포가 느리면 새 기능 PR이 아니라 배포 자동화에 사이클 투입.)

## 7. 모드별 권한 매트릭스

| 모드 | 파일 쓰기 | git commit | git push | shell | 외부 네트워크 |
|---|:---:|:---:|:---:|:---:|:---:|
| Step 1 (수동) | 인간 | 인간 | 인간 | 인간 | 인간 |
| Step 2 (반자율) | O | O (브랜치) | X | 화이트리스트 | X |
| Step 3 (헤드리스) | O (worktree) | O (브랜치) | O (PR draft) | 화이트리스트 | 제한적 |
| Step 4 (cron) | safe-only | safe-only | X | safe-only | X |

> **런타임 모드 전환(ADR-0054)**: 실행 중에도 `./scripts/set_mode.sh co-pilot|suggest` 또는 Mission Control(localhost)로 모드를 조일 수 있다 — `state/loop_mode`가 진실이며 루프가 사이클 경계에서 적용한다(§11.16). **Autopilot(무인 연속 운영)**은 유한·자기만료 grant로 인가한다 — `./scripts/autopilot_grant.sh issue` 또는 Mission Control(localhost), budget·expiry 소진 시 자동 정지(§11.17). 어떤 모드·grant도 safe:false 자동 포징이나 승인 게이트 우회를 하지 않는다.

## 8. 일일 체크리스트 (자율 루프 운영자용)

매일 아침:
- [ ] `state/failures.log` 비어 있는가?
- [ ] `state/lock` 없는가?
- [ ] 어제 자동 생성된 PR 중 검토 누락된 것은?
- [ ] `docs/tickets/` 잔여 큐 길이는 적정한가?
- [ ] `docs/decisions/` 새 ADR 필요 여부?

## 9. reviewer 결과 프로토콜

reviewer 페르소나가 사이클 내에서 생성하는 결과 파일의 위치·형식·후속 처리를 규정한다.

### 결과 파일 위치

`docs/reviews/<TXXX>-review.md` (예: `docs/reviews/T027-review.md`)

### 결과값

`PASS` / `REQUEST CHANGES` / `REJECT` 셋 중 정확히 하나를 파일 첫 줄에 명시한다.

### 결과 파일 필수 섹션

`skills/reviewer.md` §3 체크리스트를 기준으로 다음 5개 항목을 각각 작성한다. 각 항목마다 **PASS/FAIL** 판정과 이유 1~2줄을 포함한다. A 항목은 범위 초과·누락 양쪽을 검사한다 (자세한 절차는 `skills/reviewer.md` §3 참조).

| 항목 | 내용 |
|---|---|
| A. 명세 적합성 | 티켓 수용 기준 대비 구현 범위 일치 여부 |
| B. 정확성 | 코드/문서 로직의 오류 여부 |
| C. 보안 가드레일 | `docs/runbook.md` §4 보안 3요소 룰 위반 여부 |
| D. 가역성 | 변경이 되돌릴 수 있는가 (롤백 가능 여부) |
| E. Cognitive Debt | 자율 루프 누적 복잡도·이해 가능성 저하 위험 |

### 검토 범위

reviewer는 `git diff main..ralph/<TXXX>` 또는 명시된 commit 범위만 본다. 그 외 코드베이스는 검토 범위 밖이다.

### 후속 처리 규칙

| 결과 | 처리 |
|---|---|
| **PASS** | 사람이 검토 결과 확인 후 `git merge --no-ff` (ADR-0006 §merge 기준 (a)·(c) 통과 가정) |
| **REQUEST CHANGES** | 원본 implementer 티켓을 `status: open`으로 되돌리거나 새 implementer 후속 티켓 작성. 기존 `ralph/<TXXX>` 브랜치는 유지 (폐기 금지). |
| **REJECT** | 원본 implementer 티켓을 `status: blocked`로 변경하고 `docs/tickets/ARCHIVE/`로 이동. `ralph/<TXXX>` 브랜치 삭제 권장. |

### 재귀 금지 규칙

reviewer 자신의 사이클을 reviewer가 다시 검토하지 않는다 (무한 재귀 방지). 동일 사이클의 재검토가 필요한 경우 새 티켓으로 처리한다.

## 10. watch 모드 운영 절차

`orchestrator.sh --watch`는 새 티켓을 자동 감지·spawn하지만 main merge는 operator가 직접 수행한다. T028 5시간 운영 중 발견한 자체 발견 #12/#13/#14를 정식 절차로 기록한다.

### §10.1 watch 모델의 자동 경계 (자체 발견 #14 정식 기록)

**invariant**: watch = `detection + spawn`만 자동. **operator merge gate가 필수**.

즉:
- 자동: 새 ticket 감지 → `ralph/<TXXX>` worktree 생성 → worker 사이클 실행 → ralph 브랜치에 단일 commit
- 수동: ralph 브랜치 → main merge (ADR-0006 §merge 기준 (a)~(c) 통과 후)

이 경계는 ADR-0010과 ADR-0006이 함께 정의하는 v0.6 핵심 invariant이며, "완전 무인 자동화"라는 흔한 오해를 깨는 의도된 설계.

### §10.2 fixture / ticket 명명 규칙 (자체 발견 #12 정식 기록)

**invariant**: 모든 ticket의 `id`는 `T<숫자>` 형식이어야 한다. alphanumeric (예: `T-watch-01`)은 현재 ticket ID parser가 첫 하이픈 앞부분만 ID로 해석해 `T`가 되므로 reservation·worktree·DONE 경로가 모두 깨질 수 있다.

watch fixture를 미리 만들 때는 다음 형식으로:
- `docs/tickets/T<NNN>-<kebab-case-title>.md` 패턴
- 숫자는 현재 사용 중인 ID 다음 번호부터 (충돌 방지를 위해 `ls docs/tickets/ docs/tickets/DONE/ | grep -oE 'T[0-9]+' | sort -u | tail -1`로 확인)
- alphanumeric suffix 절대 사용 금지 (현재 `pick_next_ticket.sh` 정규식 기준. 정규식 변경 시 이 섹션도 함께 갱신)

### §10.3 fixture 투입 절차 (자체 발견 #13 정식 기록)

**invariant**: ticket file은 반드시 main 브랜치에 **commit된 상태**여야 worker worktree가 인식한다. untracked file (단순 `cp`만)은 worktree에 보이지 않는다.

올바른 투입 절차:
```bash
cp /tmp/T<NNN>.md docs/tickets/
git add docs/tickets/T<NNN>-*.md
git commit -m "chore: queue T<NNN> for watch"
```

watch가 다음 detection cycle에 `git status`로 새 ticket을 보는 것이 아니라, `pick_next_ticket.sh`가 ls로 ticket file을 찾고 그 file이 git에 등록돼야 worker worktree에서 cd 후 보이기 때문. 잘못된 절차(untracked `cp`만)는 spawn은 되지만 worker가 ticket file을 못 읽고 실패함.

### §10.4 watch 운영 사전 체크리스트

다음 모든 항목이 만족돼야 watch 운영 시작:

- [ ] **시간 확보**: 최소 1h, 권장 4~5h. 시간 기반 검증이므로 시작·종료 시각이 산출물의 일부
- [ ] **host 환경 정리**: `rm -f state/lock state/current_ticket; rm -rf state/reservations`
- [x] **timeout 확인**: macOS는 `gtimeout` 또는 OS `timeout`으로 orchestrator를 감싸고, worker `CLAUDE_TIMEOUT_SECONDS` 기본값 **1200s** (T056, ADR-0017)이 운영 시나리오에 맞는지 확인. rc=5 발생 시 §3.7 WIP 분기 절차를 따른다.
- [ ] **fixture 사전 준비**: §10.2 명명 규칙 + §10.3 commit 절차로 미리 host에서 작성·commit. Phase 2 cp 대상은 별도 디렉터리(예: `/tmp/watch-fixtures/`)에
- [ ] **메인 워크트리 청결**: untracked 비운영 파일은 화이트리스트 정리됨(T017)이지만, 운영 파일 dirty는 watch 시작 자체를 차단함. 시작 전 `git status -s`로 확인
- [ ] **operator merge gate 인지**: watch 완료 후 `ralph/<TXXX>` 브랜치 검토 및 main merge는 §10.1 기준에 따라 operator가 수동 수행

## 11. Mission Control 운영 절차

Mission Control은 ADR-0024의 3원칙을 따르고, 기본값으로 localhost 전용인 단일 사용자 UI다. 상태의 truth는 계속 `docs/tickets/`·`state/`·git이며, UI는 파일을 읽고 기존 셸 스크립트를 호출하는 래퍼다. UI가 죽어도 아래 CLI 경로로 같은 운영을 수행할 수 있어야 한다.

### §11.1 시작/중지

```bash
./scripts/mission_control.sh start
./scripts/mission_control.sh start --port 7474
./scripts/mission_control.sh status
./scripts/mission_control.sh stop
```

기본 접속 주소는 `http://127.0.0.1:7474`다. `--private-path`를 지정하지 않으면 Mission Control은 기존처럼 localhost HTTP만 연다.

ADR-0027 private path는 공개 인터넷 노출이 아니라 사용자가 소유한 사설/터널 인터페이스에 한정된 옵트인 경로다. 비-localhost 바인딩은 TLS가 필수이며, 인증서가 없으면 서버가 시작하지 않는다. 인증서 파일은 `state/certs/` 또는 환경 변수로만 제공하고 저장소에 커밋하지 않는다.

터널 제공 인증서 우선:

```bash
mkdir -p state/certs
tailscale cert --cert-file state/certs/tailscale.crt --key-file state/certs/tailscale.key <machine>.<tailnet>.ts.net
./scripts/mission_control.sh start --private-path tailscale0
```

환경 변수 오버라이드:

```bash
MISSION_CONTROL_TUNNEL_CERT_FILE=/path/to/tunnel.crt \
MISSION_CONTROL_TUNNEL_KEY_FILE=/path/to/tunnel.key \
./scripts/mission_control.sh start --private-path tailscale0
```

mkcert 폴백:

```bash
MISSION_CONTROL_MKCERT_CERT_FILE=/path/to/mkcert.crt \
MISSION_CONTROL_MKCERT_KEY_FILE=/path/to/mkcert.key \
./scripts/mission_control.sh start --private-path tailscale0
```

`--private-path` 대상은 `0.0.0.0`, `::`, 기본 게이트웨이 인터페이스가 아니어야 한다. localhost 요청은 토큰 없이 유지되며, private path 요청은 T097 기기 토큰 인증 경계를 통과해야 한다.

### §11.2 쓰기 액션과 동등 CLI

모든 쓰기 버튼은 tooltip과 `aria-description`에 동등 CLI를 노출해야 한다. `mission-control/ui.mjs`의 `renderWriteButton()`은 `cliCommand`가 없으면 렌더 단계에서 예외를 던진다.

| UI 액션 | 동등 CLI | 실패 시 복구 |
|---|---|---|
| Board 티켓 실행 | `./scripts/run_loop.sh TXXX` | 터미널에서 동일 명령 재실행 |
| Inbox 승인 | `./scripts/approve.sh TXXX` | 마커 확인 후 `./scripts/run_loop.sh TXXX` |
| Inbox 거부 | `./scripts/approve.sh TXXX --reject "reason"` | 티켓 본문의 Rejection 섹션 확인 |
| Sessions 일시정지 | `./scripts/session_ctl.sh pause TXXX` | `./scripts/session_ctl.sh resume TXXX` |
| Sessions 재개 | `./scripts/session_ctl.sh resume TXXX` | 이벤트 로그 확인 |
| Sessions 중단 | `./scripts/session_ctl.sh abort TXXX` | 출력된 `restore:`/`cleanup:` 안내 확인 |
| Sessions 지시 후 재시작 | `./scripts/session_ctl.sh redirect TXXX "instruction"` | 해당 worktree의 티켓 append/재디스패치 로그 확인 |
| 롤백 | UI 없음(V1) | `./scripts/rollback.sh TXXX` |

### §11.3 `/api/exec` 화이트리스트

`POST /api/exec`는 임의 셸 실행기가 아니다. 허용되는 명령은 아래 화이트리스트뿐이다.

- `{"command":"run_loop","ticketId":"TXXX"}` -> `./scripts/run_loop.sh TXXX`
- `{"command":"approve","ticketId":"TXXX"}` -> `./scripts/approve.sh TXXX`
- `{"command":"approve","ticketId":"TXXX","rejectReason":"..."}` -> `./scripts/approve.sh TXXX --reject "..."`
- `{"command":"session_ctl","ticketId":"TXXX","sessionAction":"pause"}` -> `./scripts/session_ctl.sh pause TXXX`
- `{"command":"session_ctl","ticketId":"TXXX","sessionAction":"resume"}` -> `./scripts/session_ctl.sh resume TXXX`
- `{"command":"session_ctl","ticketId":"TXXX","sessionAction":"abort"}` -> `./scripts/session_ctl.sh abort TXXX`
- `{"command":"session_ctl","ticketId":"TXXX","sessionAction":"redirect","instruction":"..."}` -> `./scripts/session_ctl.sh redirect TXXX "..."`

서버는 티켓 ID를 `^T[0-9]{3,}$`로 검증하고, localhost가 아닌 `Origin` 요청을 거부한다. `session_ctl`은 `pause|resume|abort|redirect` 서브커맨드만 허용하며, redirect 지시문은 길이와 제어문자를 검증한 뒤 argv로 전달한다. 새 쓰기 액션을 추가하려면 먼저 동등 CLI를 만들고, 그 CLI만 `/api/exec` 화이트리스트에 추가한다. UI가 직접 파일을 쓰는 경로는 금지한다.

### §11.4 승인/롤백 CLI

승인:

```bash
./scripts/approve.sh TXXX
$EDITOR docs/approvals/TXXX.md
./scripts/run_loop.sh TXXX
```

거부:

```bash
./scripts/approve.sh TXXX --reject "scope too broad for current baseline"
```

롤백:

```bash
./scripts/rollback.sh TXXX
```

`rollback.sh`는 `cycle/TXXX-pre` 태그가 있으면 해당 시점으로 복원한다. 태그가 없고 티켓 커밋을 찾으면 `git revert <commit>` 명령을 안내한다. 메인 워크트리에 사용자 변경이 섞여 있으면 먼저 `git status -s`와 `git diff`를 확인하고, 필요한 경우 사람이 직접 stash/commit/분리 여부를 결정한다.

### §11.5 Live Sessions 개입

Sessions 화면은 `state/reservations/<TXXX>.d/meta`, `events.jsonl`, `.ralph/logs/<TXXX>.log`를 읽어 실행 중 세션을 표시한다. 관측은 SSE이고, 개입은 항상 `session_ctl.sh` CLI의 UI 별명이다.

```bash
./scripts/session_ctl.sh pause TXXX
./scripts/session_ctl.sh resume TXXX
./scripts/session_ctl.sh abort TXXX
./scripts/session_ctl.sh redirect TXXX "운영자 지시"
```

운영 기준:

- pause/resume은 `timeout_backend=bash-group`이고 `pgid`가 숫자인 세션에서만 허용한다. `timeout`, `gtimeout`, `pgid=unknown` 세션은 UI에서 disabled로 표시되고 CLI도 nonzero exit + `*-rejected` 이벤트를 남긴다.
- pause는 10분 이내 resume을 권장한다. 장시간 정지가 필요하면 abort 또는 redirect로 재디스패치한다.
- abort/redirect는 진행 중 미커밋 작업을 잃을 수 있다. UI confirm 모달과 CLI 출력의 `restore:` 명령을 먼저 읽고 실행한다.
- redirect는 실행 중 세션에 지시를 주입하지 않는다. 현재 세션을 중단하고 티켓에 `## 운영자 지시` 항목을 append한 뒤 같은 티켓을 다시 dispatch한다.
- abort/redirect 후 `.ralph/wt-*` worktree 폐기는 자동 실행되지 않는다. CLI가 출력한 `cleanup:` 명령을 사람이 확인 후 실행한다.

### §11.6 운영 전 체크리스트

- [ ] `./scripts/mission_control.sh status` 결과가 의도한 상태인가?
- [ ] `http://127.0.0.1:7474` 외 주소로 노출되지 않는가?
- [ ] Board/Inbox/Sessions의 쓰기 버튼 tooltip이 동등 CLI를 보여주는가?
- [ ] `./scripts/check_ui_requirements.sh`가 통과하는가?
- [ ] `/api/exec` 변경 후 `bats tests/mission_control_exec.bats`, `bats tests/mission_control_exec_session_ctl.bats`, `node --test mission-control/*.test.mjs`가 통과하는가?

## §11.7 private-path 모바일 접근 + T107 온디바이스 검증 (V3, ADR-0027/0029)

> v0.18(V3) baseline부터 신뢰된 사설 경로(예: Tailscale)의 모바일 기기가 승인/거부를 수행할 수 있다. 기본값은 여전히 **localhost 전용**이며, `--private-path`를 명시할 때만 사설 인터페이스 1개가 추가 바인딩된다.

### §11.7.1 보안 경계 (재확인)

ADR-0027/0028 §5 invariant — 변경 금지:

1. **공인 노출 금지** (T096): `--private-path`는 `0.0.0.0`/`::`/기본 게이트웨이 인터페이스를 거부한다.
2. **평문 거부 — TLS 필수** (T098): 비-localhost 바인딩은 https로만 열린다. 인증서가 없으면 시작을 거부한다.
3. **토큰 없는 비-localhost는 401** (T097): 부트스트랩(`POST /api/tokens/exchange`, `GET /pair`, `GET /sw.js`)만 예외.
4. **비-localhost exec는 approve only** (T099, authoritative): socket peer 주소 기준으로 `session_ctl`/`run_loop`는 403. UI 숨김이 아니라 **서버 차단**이다. 서비스워커가 Bearer를 주입해도 이 판정은 불변(ADR-0029 §4).

### §11.7.2 기동 (사설 경로 + TLS)

```bash
# 인증서 출처: 명시적 env 또는 state/certs/ 관례 (tunnel.crt/key, mkcert.* 등)
MISSION_CONTROL_TUNNEL_CERT_FILE=state/certs/tunnel.crt \
MISSION_CONTROL_TUNNEL_KEY_FILE=state/certs/tunnel.key \
  node mission-control/server.mjs --root "$PWD" --private-path <tunnel-iface>
# 기본(localhost 전용)으로 되돌리려면 --private-path 없이 기동.
```

### §11.7.3 페어링 / 기기 관리

- 데스크톱 `http://127.0.0.1:7474/pairing`(localhost 전용)에서 "페어링 시작" → QR + 수동 URL. 토큰은 1회용·5분 만료.
- 모바일이 QR 스캔 → `https://<private>/pair#<token>` → 자동 교환 → 장기 기기 토큰 발급, 서비스워커가 이후 navigation/SSE에 Authorization 주입.
- 폐기: `/pairing` 화면의 폐기 버튼 또는 CLI `./scripts/pair.sh revoke <device_id>`. 폐기는 즉시 적용(다음 요청 401).
- CLI 동등성: `./scripts/pair.sh start|list|revoke` (서버 없이 token-store 직접 조작).

### §11.7.4 검증 절차 (T107)

1. **데스크톱 사전점검** (실기기 전, 기준선):
   ```bash
   ./scripts/verify_mobile_pairing.sh   # exempt·exec 스코프·/pair·/sw.js·페어링 라운드트립·pair.sh
   ```
   `N PASS / 0 FAIL`이어야 온디바이스로 진행한다.
2. **온디바이스 E2E** (실기기 + TLS): `docs/tickets/DONE/T107-mobile-e2e-verification.md` §3 체크리스트 수행. 브라우저 서비스워커 런타임이 필요한 항목(navigation/SSE 주입의 실제 동작)은 여기서만 확인 가능하다.
3. **결과 기록**: `docs/reviews/T107-mobile-e2e.md` 템플릿에 PASS/FAIL·근거를 채우고 첫 줄 RESULT를 확정한다(runbook §9 프로토콜).
4. **핵심 게이트**: 모바일에서 `run_loop`/`session_ctl` 강제 호출 시 서버 403(§11.7.1-4). FAIL이면 P0 bug 티켓 선행, v0.19 봉인 보류.

### §11.7.5 운영 전 체크리스트 (사설 경로)

- [ ] `--private-path` 인터페이스가 `0.0.0.0`/게이트웨이가 아닌가? (시작 거부 로그 확인)
- [ ] 비-localhost 바인딩이 https인가? 평문 http 요청이 거부되는가?
- [ ] `./scripts/verify_mobile_pairing.sh`가 `0 FAIL`인가?
- [ ] 페어링 토큰/기기 토큰이 `state/devices/`에만 있고 git에 커밋되지 않는가? (gitignore 확인)
- [ ] 모바일에서 승인/거부 외 쓰기(run_loop/session_ctl)가 서버에서 403인가?

### §11.7.6 기기 토큰 수명주기 — 자동 갱신·회전·라벨 (v0.20, ADR-0031/0032)

v0.20부터 기기 토큰은 30일 고정 만료에서 **자동 갱신·회전 + 다중 기기 관리**로 바뀌었다. 운영자 수동 조치는 라벨 변경과 폐기뿐이고, 갱신은 브라우저/서버 프로토콜로 자동 수행된다.

**자동 갱신 (수동 조치 불요)**

- 서비스워커가 만료 **7일 전**부터 single-flight로 `POST /api/tokens/renew`(현재 bearer 인증)를 호출해 토큰을 갱신·회전한다. 성공 시 새 토큰이 IDB/localStorage에 반영되고 열린 탭에 브로드캐스트된다. 갱신 창 밖이면 no-op(`{renewed:false}`).
- 갱신은 raw bearer가 필요하므로 **CLI 비대상**이다(`pair.sh renew` 없음 — shell history/process list 노출 회피). 강제 회전이 필요하면 `revoke` 후 재페어링한다.
- 이미 **만료·폐기**된 토큰은 갱신 불가 → 사용자는 다시 페어링한다.

**회전 즉시성 (보안 불변식)**

- 갱신 시 서버가 old token hash를 즉시 교체한다. **grace window 없음** → old token은 다음 요청부터 401. 운영자 조치 불필요.
- renew와 revoke는 같은 race-safe mutation을 쓴다. "renew 후 revoke" 경합이 폐기를 되살리지 않는다(폐기 즉시성 유지).
- **갱신된 토큰도 비-localhost exec는 approve only(403)**다. renew는 `/api/exec`가 아니며, exec 스코프는 socket 주소 기준이라 토큰 갱신과 무관하다(T099 authoritative).

**다중 기기 관리**

- `/pairing` 목록은 라벨·등록/만료·**마지막 사용(last_seen)**·**갱신 횟수**·상태를 보여 준다. `last_seen`은 1시간 throttle 관측값이며 **보안 판단에 쓰지 않는다**.
- 라벨 변경(localhost 전용): `/pairing` 화면의 라벨 입력 또는 CLI `./scripts/pair.sh rename <device_id> <label>`.
- 폐기는 §11.7.3과 동일(`/pairing` 폐기 버튼 또는 `pair.sh revoke`). 폐기·갱신 모두 다음 요청부터 즉시 반영.

**운영 전 추가 체크리스트 (수명주기)**

- [ ] 갱신(회전) 후에도 모바일 `run_loop`/`session_ctl`이 서버에서 403인가? (`r6-security-boundaries`/`mission_control_private_path_scope` 회귀)
- [ ] old token이 회전 직후 401인가? (grace window 없음)
- [ ] `./scripts/verify_mobile_pairing.sh`의 renew 케이스(`renewed:false` no-op, 무토큰 401)가 통과하는가?

### §11.7.7 기기 수 상한 + 동시 페어링 원자성 (v0.21, ADR-0033/0034/0035)

v0.21부터 동시 활성 기기 수에 **상한**이 있다(`MISSION_CONTROL_MAX_DEVICES`, 기본 10).

**상한 동작**

- 활성("`!revoked && !expired`") 기기 수가 상한 이상이면 페어링 교환(`POST /api/tokens/exchange`)이 **409 `device limit reached`**로 거부된다. 새 토큰은 발급되지 않고 **페어링 토큰은 소비되지 않는다**(슬롯이 열리면 같은 토큰으로 재시도 가능).
- 슬롯 확보는 **명시적 폐기**로만: `/pairing` 폐기 버튼 또는 `./scripts/pair.sh revoke <device_id>`. 폐기는 다음 요청부터 즉시 슬롯을 비운다. 만료도 자동으로 슬롯을 비운다.
- 현재 활성 수/상한은 `/pairing` 헤더와 `./scripts/pair.sh list`(`활성 N / 상한 M`)에서 확인한다. 상한 조정은 서버 기동 시 env로: `MISSION_CONTROL_MAX_DEVICES=20 node mission-control/server.mjs …`.
- **409는 인증 실패(401)·무효 요청(무토큰 400)과 구분된다.** 상한은 발급 게이트일 뿐 인증/exec 경계가 아니다 — 발급된 토큰의 비-localhost exec는 계속 approve only(403).

**단일 프로세스 전제 (운영 제약)**

- 상한 게이트의 `count → 검사 → 발급`은 **단일 동기 임계 구역**으로 원자적이다(ADR-0035 INV-ATOMIC-GATE). Node 단일 스레드 이벤트 루프 + 구간 내 `await` 없음에 의존한다.
- **`state/devices/`를 공유하는 다중 서버 인스턴스는 지원하지 않는다.** 같은 state 디렉터리에 두 개 이상의 `server.mjs`를 동시 기동하면 게이트 원자성이 보장되지 않아(프로세스 간 over-count 가능) 상한을 초과해 발급될 수 있다. Mission Control은 **state당 단일 프로세스**로 운영한다.
- 동시 페어링 회귀는 `tests/mission_control_device_limit.bats`(병렬 N 교환 → 200 정확히 1회·나머지 409·활성 정확히 1)로 고정돼 있다.

### §11.8 Approval Inbox v2 — 3요소 카드·검증 배지·저위험 묶음 승인 (ADR-0037)

`/inbox`의 safe:false 승인 카드는 v2부터 다음을 보인다.

**3요소 카드 + 검증 배지**

- 카드는 **근거**(티켓 §목표)·**예상 결과**(티켓 §수용 기준)·**다운사이드**(티켓 §롤백 + 자동 도출 복구 명령 `mc-recovery`)를 조립한다. 모두 **읽기 전용** 표시이며, 카드 렌더 시 검사를 즉석 실행하지 않는다.
- **검증 배지**: `docs/reviews/<ticket>*.md` 기록이 있으면 그 결과(run_checks/security)를 배지로 노출하고, 없으면 "검증 기록 없음"을 명시한다. 배지는 정보 제공일 뿐 승인 게이트가 아니다 — 게이트는 사람의 클릭이다.
- 단건 승인 마커(`approve.sh`)의 `scope_confirmation`/`rollback_plan`은 티켓 §변경 범위/§롤백에서 **초안 자동 생성**된다(과거 TODO 플레이스홀더 대체). 초안은 출발점이며 사람이 확인·수정한다.

**저위험 묶음 승인 (localhost 전용)**

- 인박스는 **docs-only 저위험** 후보를 묶음 행으로 모은다. 판정은 기계적·fail-closed: safe:false + 라벨에 `docs` 포함 + 위험 라벨(security/auth/code/ui/test/server/…) 없음 + §변경 범위가 코드/스크립트/테스트 경로(`mission-control/`·`scripts/`·`tests/`·코드 확장자)를 참조하지 않음. 하나라도 모호하면 후보에서 빠지고 개별 카드로만 승인된다.
- 일괄 승인은 `POST /api/approvals/bulk`(**localhost 전용** — 모바일은 403)로, 각 id를 POST 시점에 재판정(fail-closed)한 뒤 **티켓별 개별 마커**를 생성한다. 단일 포괄 승인이 아니다 — 감사 추적은 v1과 동일하게 티켓당 `docs/approvals/<T>.md` 1개다.
- 모바일(사설 경로)은 계속 **단건 approve/reject만** 가능하다(T099). 묶음 행·엔드포인트는 모바일에 노출/허용되지 않는다.
- 회귀: `tests/mission_control_approval_inbox_v2.bats`(검증 배지·복구 명령·묶음 후보 판정·티켓별 마커·fail-closed·localhost 전용 403·marker 초안).

### §11.9 Forge Board v2 — Backlog 분리·조건부 Verify·stuck 신호·필터 (ADR-0038)

`/`(보드)는 파일(tickets/·reservations·failures)을 watch하는 **읽기 전용 조망**이며, v2부터 다음을 보인다.

**컬럼**

- **Backlog vs Open(Ready)**: `status:open` 티켓을 미충족 의존성 유무로 렌더 시점에 나눈다 — 미충족이 있으면 **Backlog**(아직 준비 안 됨), 없으면 **Open(Ready, 지금 디스패치 가능)**. 티켓 파일·frontmatter는 무변경(파생 분류).
- **Run(run_loop) 디스패치 버튼은 Open(Ready)·localhost 카드에만** 붙는다. Backlog/forging/approval/done·비-localhost(모바일)엔 없다(T099 observe-only).
- **Verify는 조건부 컬럼**: `status:verify` 티켓이 실제로 있을 때만 표시한다(없으면 접어 죽은 공간 제거). 루프가 향후 verify 상태를 노출하면 자동으로 다시 나타난다.

**stuck(막힘) 관측 신호 (게이트 아님)**

- forging 카드 age ≥ `MISSION_CONTROL_STUCK_FORGING_MS`(기본 30분) → `⏳ stuck` 배지.
- `failures.log`에 같은 ticket이 `MISSION_CONTROL_STUCK_FAILS`(기본 2) 이상 → `↻ 반복 실패 N` 배지.
- 모두 **표시 전용 관측 메타**다 — 디스패치/승인/scope 판단에 쓰지 않는다.

**필터 (client-side)**

- 보드 상단 필터: persona, safe만, blocked 숨김. 서버 라운드트립 없이 카드 show/hide, 선택은 `localStorage`에 보존. 보드는 읽기 전용 유지(쓰기 액션 없음).
- 회귀: `tests/mission_control_board.bats`(Backlog/Open 분류·Run은 Open만·Verify 조건부·stuck/반복실패 배지·필터 컨트롤·읽기 전용).

### §11.10 Insights ⑥ — 읽기 전용 집계 대시보드 (ADR-0040)

`/insights`는 파일(tickets/·failures.log·approvals)에서 **정직하게 도출 가능한** 지표만 집계하는 읽기 전용 화면이다.

**지표 (도출 가능)**

- 처리량·구성: Done/Open/Forging/Approval 대기 수, **safe 비율**(safe vs safe:false), persona·priority 분포, **생성 코호트**(`created` 월별 — "완료 throughput 아님, 생성 시각 기준"으로 명시).
- 실패 패턴: `failures.log`를 **stage별 빈도**·**반복 티켓(≥2)**로 집계.
- 승인: safe:false 승인 마커 수 + **승인 지연**(티켓 `created` → 마커 `approved_at`, 측정 가능한 것만).

**측정 불가 (정직 표기)**

- **사이클 타임**·**토큰 비용**은 영속 시작/완료 타임스탬프·텔레메트리가 파일에 없어 `데이터 없음 — 계측 선행` 카드로 표기한다. 억지 근사를 만들지 않는다(DONE mtime은 git 체크아웃에 깨져 부적합). 추가는 `completed_at`/`state/throughput.log` 영속화 후 별도 티켓(ADR-0040 §3.3/§8).

**경계**

- 렌더는 **의존성 0**(inline SVG/CSS 바·숫자 카드, 외부 차트 라이브러리 없음)·부수효과 없는 읽기 전용. 쓰기/디스패치 액션 없음.
- `/insights`는 인증 비-exempt: 비-localhost는 bearer 토큰 필요(무토큰 401, T097). 모바일은 관측만 가능하다.
- 회귀: `tests/mission_control_insights.bats`(지표 집계·코호트 정직 라벨·실패 패턴·데이터 없음 표기·읽기 전용·비-localhost 401/인증 200).

### §11.11 Spec Studio ④ — 읽기 전용 spec/결정 네비게이터 (ADR-0042)

`/spec`은 루프를 지배하는 문서·결정을 조망하는 **읽기 전용** 화면이다. 편집·AI·생성은 하지 않는다.

**구성**

- **master-spec 렌더**: `docs/master-spec.md`를 섹션 TOC + 본문으로(zero-dep 마크다운 서브셋 — heading·문단·목록·코드펜스·표·인라인 코드/굵게/링크). Office Hours(§1)도 본문에 포함.
- **결정 인덱스(ADR)**: `docs/decisions/*.md`를 번호·제목·상태로 최신순 목록화.
- **spec ↔ ticket 링키지**: 티켓 frontmatter `spec_ref` 역색인 — "이 ADR/spec 문서를 참조하는 티켓들". 비전의 "분해"를 *생성*이 아니라 *기존 지배관계 조망*으로 충족.

**경계·안전**

- **읽기 전용**: spec/decisions/tickets를 읽어 렌더만. 편집·생성·쓰기·LLM 호출 없음(의존성 0, ADR-0024).
- **마크다운 이스케이프 우선**: 원문을 먼저 HTML 이스케이프한 뒤 제한 마크업만 변환 — 문서 내 `<script>` 등은 태그로 실행되지 않는다.
- **인증(T097)**: `/spec`은 비-exempt(비-localhost 무토큰 401). 모바일은 관측만.
- **분리된 후속(별도 결정)**: spec UI 편집·AI 인터뷰(LLM 통합)·티켓 분해 생성은 master-spec Non-goals 개정 + LLM 통합 + 승인 경계 설계가 필요(ADR-0042 §8).
- 회귀: `tests/mission_control_spec_studio.bats`(섹션·표·TOC 렌더·ADR 인덱스·spec↔ticket 링키지·마크다운 이스케이프·읽기 전용·비-localhost 401/인증 200).

### §11.12 Library ⑤ — 읽기 전용 Playbook/Knowledge 브라우저 (ADR-0044)

`/library`는 `skills/` 페르소나 Playbook과 그 트리거를 조망하는 **읽기 전용** 화면이다.

**구성**

- **Playbook 카드**: `skills/*.md`(implementer·planner·reviewer·security-reviewer)를 `name`·`description`·`when_to_invoke`(트리거)·`forbidden`(금지)·본문 카드로. 본문은 Spec Studio의 zero-dep 마크다운 서브셋 렌더러 재사용. (skills frontmatter의 YAML 블록 시퀀스는 전용 파서로 파싱 — parseFrontmatter는 인라인 배열만 다룸.)
- **트리거 구조(Knowledge)**: 모든 skill의 `when_to_invoke`를 모아 "트리거 → 페르소나"로 노출.
- **persona ↔ ticket**: 티켓 `persona`별 처리량 카운트(파일 기반). 진짜 "주입 사용 통계"의 텔레메트리 없는 대체.

**경계·정직성**

- **읽기 전용**: skills/·tickets를 읽어 렌더만. 편집·버전 스냅샷·`!매크로` 호출·쓰기 없음.
- **주입 사용 통계**("이번 주 N회 주입")는 텔레메트리 부재라 `데이터 없음 — 텔레메트리 선행`으로 정직 표기(Insights 원칙). persona↔ticket 링키지로 대체.
- **마크다운 이스케이프 우선**: skill 본문 내 `<script>` 등은 태그로 실행되지 않는다.
- **인증(T097)**: `/library`는 비-exempt(비-localhost 무토큰 401). 모바일은 관측만.
- **분리된 후속(별도 결정)**: Playbook 편집·버전 스냅샷·`!매크로` 보드 호출·실제 사용 통계는 쓰기 표면 + 디스패치 확장 + 텔레메트리 도입 필요(ADR-0044 §8).
- 회귀: `tests/mission_control_library.bats`(playbook 카드·블록리스트 트리거·트리거 구조·persona 링키지·사용 통계 데이터 없음·마크다운 이스케이프·읽기 전용·비-localhost 401/인증 200).

### §11.13 계측 기반 — 완료 타임스탬프 영속 (ADR-0046)

루프가 완료 시점에 **durable한 타임스탬프**를 ticket frontmatter에 기록해, Insights/Library의 "데이터 없음"을 실측으로 바꾼다.

**루프가 쓰는 것 (writer)**

- `run_loop.sh`의 done 단계(페르소나가 `status: done` + `git mv DONE/`를 완료·검증한 직후)가 DONE 티켓 frontmatter에 `completed_at`(현재 시각)과 `started_at`(reservation meta 값)을 추가하고 **별도 `telemetry(TXXX)` 커밋**을 만든다. 페르소나 커밋과 분리되며, 실패 시 변경분을 되돌려 트리를 clean하게 유지한다.
- DONE 티켓은 git-tracked라 타임스탬프가 영구 보존된다(gitignore 로그와 달리 유실되지 않음).

**Mission Control이 읽는 것 (read-only)**

- 파서가 `completed_at`/`started_at`을 캡처. Insights — **사이클 타임**(completed−started, 시간)·**리드 타임**(completed−created, 일)·**완료 throughput**(completed_at 월별). Library — **per-persona 사용**(completed_at 있는 DONE).
- **정직성**: 사전 계측 DONE은 타임스탬프가 없어 집계에서 빠진다 → 모두 **"계측 이후 n=N"**으로 라벨(전체 오인 금지). 데이터가 없으면 기존 "데이터 없음" 유지. **토큰 비용**은 여전히 텔레메트리 소스 부재로 "데이터 없음".
- Mission Control은 절대 타임스탬프를 쓰지 않는다 — 영속은 루프 전담(읽기 전용 경계 보존).
- 회귀: `tests/run-loop-telemetry.bats`(done이 completed_at/started_at 기록·별도 커밋·트리 clean·done-move 무손상), `mission_control_insights.bats`/`mission_control_library.bats`(계측 fixture → 실측 + "계측 이후" 라벨, 미계측 → 데이터 없음).
- 후속: git 이력 백필(과거 completed_at 추정)·토큰 비용 텔레메트리는 별도 결정(ADR-0046 §8).

### §11.14 git 이력 백필 — 추정 completed_at (ADR-0048)

계측 이전 DONE 티켓의 완료 시각을 done-move 커밋 날짜로 **추정**해 Insights 표본을 키운다. 추정은 측정과 **구조적으로 분리**된다.

**백필 실행 (일회성·사용자 수동)**

- `./scripts/backfill_completed_at.sh --dry-run` 으로 미리보고, `./scripts/backfill_completed_at.sh` 로 기록 + 1회 커밋한다. **루프가 아니라 사용자가 직접 실행하는 일회성 도구**다.
- 대상: `docs/tickets/DONE/T*.md` 중 `completed_at`·`completed_at_est`가 **둘 다 없는** 것. done-move 날짜(`git log --diff-filter=A`)를 도출해 **별도 필드 `completed_at_est`**(추정)로 기록한다.
- **측정값(`completed_at`)이 있으면 절대 건드리지 않는다.** done-move 도출 불가 시 skip(fail-closed). 멱등(이미 있으면 skip) — 재실행 안전.

**추정 경계 (측정과 절대 안 섞임)**

- 추정은 `completed_at_est`, 측정은 `completed_at` — **다른 필드**다. `completed_at`을 읽는 코드에 추정이 들어갈 수 없다(플래그보다 강한 구조 분리).
- **started_at은 복원 불가**(reservation gitignore·ephemeral) → 추정은 **cycle time에 쓰지 않는다**. Insights **사이클 타임은 측정 전용**.
- Insights **리드 타임·완료 throughput**은 측정+추정을 함께 보이되 **"측정 n=N · 추정 n=M"**로 분리 라벨한다. 추정은 명시되며 측정으로 오인되지 않는다.
- 회귀: `tests/backfill_completed_at.bats`(추정 기록·측정 미덮어씀·멱등·dry-run 무변경·단일 커밋), `mission_control_insights.bats`(측정/추정 split 라벨·사이클 측정 전용).

### §11.15 토큰 텔레메트리 — usage 카운트(측정) + 비용(요율 추정) (ADR-0050)

토큰 사용량을 Claude CLI에서 캡처해 Insights에 표기한다. **기본 OFF** — 켤 때만 동작한다.

**활성화 (기본 OFF, 옵트인)**

- `RALPH_TOKEN_TELEMETRY=1`로 루프/`run_headless`를 실행하면 claude를 `--output-format stream-json`으로 띄우고 usage(input/output/cache 토큰·model)를 `state/token_usage.log`에 세션별 append한다. `usage_capture.mjs` 필터가 사람이 읽을 텍스트를 stdout으로 흘리며 usage만 추출한다(로그 가독성 보존).
- **OFF면 기존 동작과 완전히 동일**하다(텍스트 출력·timeout watchdog·exit code 무변경). 필터는 항상 exit 0 → `pipefail`로 claude의 exit code(124 timeout 등)가 전파된다.
- 활성화 전 사용하는 claude 버전이 `--output-format stream-json` 이벤트 형태를 지원하는지 확인할 것(이벤트 형태가 다르면 텍스트만 흐르고 usage는 fail-closed로 미기록). `bash-watchdog` 폴백 경로(timeout/gtimeout 미존재)는 telemetry 미적용.

**Insights 표기 (카운트=측정, 비용=요율 추정)**

- **토큰(측정)**: input/output 토큰 합계 + "계측 이후 n=세션수". Claude 실측이다.
- **추정 비용**: `MISSION_CONTROL_TOKEN_RATE_IN`/`MISSION_CONTROL_TOKEN_RATE_OUT`($/Mtok)이 설정된 경우에만 = (in/1e6·rateIn)+(out/1e6·rateOut), **"요율 in $X/out $Y per Mtok (가정)"** 명시. 요율 미설정이면 "데이터 없음 — 요율 미설정", 토큰 데이터 없으면 "데이터 없음 — 계측 선행". 비용은 **요율 가정**이며 측정으로 오인하지 않는다.
- 과거 세션은 usage가 없어 백필 불가 → "계측 이후"만. Mission Control은 `token_usage.log`를 읽기만 한다(영속은 run_headless).
- 회귀: `tests/run-headless-token-usage.bats`(usage append·텍스트 보존·exit 전파·파싱 실패 fail-closed), `mission_control_insights.bats`(토큰 측정 카운트·요율 미설정 시 비용 데이터 없음).

### §11.16 자율성 모드 전환 — set_mode + state/loop_mode (ADR-0054)

자율성 모드(Suggest/Co-pilot/Autopilot)를 실행 중에도 전환한다. 모드는 **`state/loop_mode` 선언 파일이 유일 진실(truth)**이고, 실행 중 루프는 **사이클 경계(다음 티켓 집기 직전)에서 재읽기**해 적용한다 — 진행 중 티켓은 절대 중단하지 않는다.

**전환 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/set_mode.sh co-pilot` 또는 `./scripts/set_mode.sh suggest`. `state/loop_mode`에 단일 토큰을 기록한다.
- **Mission Control (localhost 전용)**: Autonomy 화면의 모드 전환 버튼 → `POST /api/exec {command:set_mode, mode}`. 비-localhost(모바일)는 `set_mode`가 스코프 거부(403, approve-only — T099). 모바일 화면엔 전환 컨트롤이 렌더되지 않는다(관측 전용).

**모드 매핑**: `suggest` → dry-run(실행 전 확인), `co-pilot` → safe-only(기본 — safe:true 자동, safe:false 승인 대기). 파일 부재/불명 토큰 → 시작 플래그 유지(fail-safe).

**Autopilot 진입은 v1 제외 (ADR-0054 §6.3 b)**: `set_mode`/Mission Control로는 Autopilot에 진입할 수 없다(인간 개입 최소화는 별도 결정). 런타임에 `state/loop_mode=autopilot`을 써도 루프는 경고 후 현재 모드를 유지한다. Autopilot은 오직 **CLI에서 `run_loop.sh`를 `--safe-only` 없이 직접 기동**하는 deliberate 결정으로만 진입한다.

**승인 게이트는 모드와 직교(불변)**: 어떤 모드에서도 `safe:false` 티켓은 `docs/approvals/<T>.md` 마커가 있어야 merge된다. 모드는 실행 페이스(확인 케이던스)일 뿐 승인 게이트를 우회하지 않는다. 라이브 현재-모드는 `state/loop_mode`(truth)에서 읽으며, 미설정 시 "기본(Co-pilot)"로 정직 표기한다(추정 아님).

- 회귀: `tests/run-loop-mode-switch.bats`(사이클 경계 재읽기·suggest/co-pilot 적용·autopilot 런타임 거부·부재/불명 fail-safe·set_mode CLI), `tests/mission_control_autonomy.bats`(라이브 모드·localhost 컨트롤·autopilot 버튼 없음·set_mode 400(autopilot)/403(비-localhost)·모바일 관측 전용).

### §11.17 Autopilot — 유한·자기만료 무인 연속 운영 grant (ADR-0056)

**중요 — 무엇을 인가하고 무엇을 인가하지 않는가.** Autopilot grant는 orchestrator의 **무인 연속 운영(`--watch` 드레이닝)**을 인가한다. **safe:false 자동 포징을 인가하지 않는다** — orchestrator는 어느 모드에서도 safe:false를 자동으로 집지 않으며(`pick_next_ticket`이 항상 skip), safe:false는 오직 사람이 `run_loop.sh <T>` + 마커로만 구현된다. merge/close는 모든 모드에서 `docs/approvals/<T>.md` 마커가 필요하다(직교 불변).

**grant 발급/철회 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/autopilot_grant.sh issue --budget N --expiry-min M` / `revoke` / `status`. `state/autopilot_grant`에 `budget`(처리 가능 티켓 수)·`expiry_epoch`(절대 만료, epoch초)를 기록한다.
- **Mission Control (localhost 전용)**: Autonomy 화면의 "무인 연속 운영 인가" 버튼(2차 확인) → `POST /api/exec {command:autopilot_grant, budget, expiryMin}`. 철회는 "철회" 버튼 → `autopilot_revoke`. 비-localhost(모바일)는 스코프 거부(403, T099) — 발급/철회 컨트롤이 렌더되지 않는다(관측 전용).

**동작 (default-tightens)**

- `orchestrator.sh --watch`는 진입 시 grant 유효성(미만료·budget>0)을 검사한다. **무효/만료/소진/부재면 무인 연속 운영을 하지 않고 단발 attended 라운드로 강등**한다. 단발 라운드(`--once`/기본)는 grant 없이도 그대로 동작한다.
- 유효하면 watch 루프가 돌며, 라운드마다 처리한 티켓 수만큼 budget을 차감한다. **budget 소진 또는 expiry 만료 중 먼저 닿는 쪽에서 연속 운영이 자동 정지**한다 — 인간이 끄지 않아도 시스템이 스스로 조여진다. 즉시 철회(`revoke`)는 비상 브레이크다.
- v1 권장 기본값: **budget=1, expiry-min=30** (보수적 — 한 번 처리 후/30분 내 자동 정지).

**라이브 상태**: Autonomy 화면이 `state/autopilot_grant`(truth)를 읽어 잔여 budget·만료까지 분·발급자를 표시한다. 미발급이면 "미발급 — 무인 연속 운영 안 함"으로 정직 표기.

- 회귀: `tests/autopilot-grant.bats`(grant issue/revoke/검증·CLI, orchestrator --watch grant 없음/만료/철회 시 단발 강등·유효 시 연속 운영 진입), `tests/mission_control_autonomy.bats`(grant 패널·미발급 상태·localhost 발급 컨트롤·budget 검증 400·비-localhost 403·모바일 관측 전용).

### §11.18 구조적 티켓 메타 편집 — ticket_edit (ADR-0058)

**무엇을 쓰고 무엇을 안 쓰는가.** Mission Control이 처음으로 소스(티켓 파일)를 바꾸는 표면이지만 **조직적 메타데이터(priority·labels)만** 편집한다. 실행 게이트 필드(safe·status·id·depends_on)·DONE 티켓·승인 마커(`docs/approvals/`)는 **하드 가드로 거부**한다. priority/labels는 실행/승인/머지 의미가 없어 safe:false 승인 게이트(ADR-0007)와 직교한다.

**편집 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/ticket_edit.sh set-priority <TXXX> <P0|P1|P2|P3>` / `set-labels <TXXX> "<csv>"`. open 티켓의 프론트매터 해당 키만 치환(본문·다른 키 무변경), 단일 git commit으로 감사한다(`git revert` 가역).
- **Mission Control (localhost 전용)**: Forge Board의 open/backlog 카드에 인라인 priority(select)·labels(input) + "메타 저장" 버튼 → `POST /api/exec {command:ticket_edit, action, ...}`. 비-localhost(모바일)는 스코프 거부(403, T099) — 편집 컨트롤이 렌더되지 않는다(관측 전용).

**경계**

- **MC는 직접 writer가 아니다**: exec가 `ticket_edit.sh`를 디스패치하고 스크립트가 writer다(set_mode/grant와 동일 패턴). 파일=진실·CLI parity 보존.
- **검증**: priority는 P0–P3 enum, labels는 안전 토큰(영숫자·하이픈·언더스코어) csv만. open 상태 티켓만 편집 가능.
- **가역·감사**: 각 편집은 `ticket_edit(TXXX): ...` 단일 커밋. `git revert`로 되돌린다.

**v1 제외(별도 결정)**: status 전이·safe 편집·자유 본문/spec 저작·AI 인터뷰/초안(LLM 통합). 승인은 기존 `approve.sh` 경로만.

- 회귀: `tests/ticket-edit.bats`(CLI 편집·하드 가드(DONE/awaiting/invalid/safe), server exec localhost 성공·검증 400·비-localhost 403, Board localhost 컨트롤·모바일 관측 전용).

### §11.19 티켓 라이프사이클 전이 — ticket_lifecycle cancel/reopen (ADR-0060)

**무엇을 전이하고 무엇을 안 하는가.** 운영자의 **조직적 스케줄 전이만** 한다 — `cancel`(open→skipped, 픽 큐에서 제외)·`reopen`(skipped|blocked→open, 픽 큐 복귀). **실행/승인/머지 상태(forging·verify·awaiting-approval·done)는 루프·approve.sh 전용**이며 ticket_lifecycle로 쓸 수 없다(의미 동사 + from-state 가드가 화이트리스트를 인코딩 — raw set-status 없음). reopen된 safe:false 티켓은 재픽 시 다시 `awaiting-approval` 게이트를 거친다(승인 게이트 직교 불변).

**전이 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/ticket_lifecycle.sh cancel <TXXX>` / `reopen <TXXX>`. status 프론트매터 한 줄만 치환, 단일 git commit 감사(`git revert` 가역). from-state 불일치·DONE·승인 마커는 거부.
- **Mission Control (localhost 전용)**: Forge Board의 open 카드 "취소"·**보류/거절 컬럼**(skipped+blocked)의 "재개" 버튼 → `POST /api/exec {command:ticket_lifecycle, action:cancel|reopen, ticketId}`. 비-localhost(모바일)는 스코프 거부(403, T099) — 컨트롤이 렌더되지 않는다(관측 전용).

**경계**: MC는 직접 writer가 아니다(exec가 ticket_lifecycle.sh 디스패치, 스크립트가 writer). 진행 중 중단은 `session_ctl abort`, 승인/거절은 `approve.sh` — 라이프사이클 전이와 분리된 경로다.

**v1 제외(별도 결정)**: raw set-status·done/awaiting-approval/forging/verify 쓰기·자유 본문 저작·LLM 통합.

- 회귀: `tests/ticket-lifecycle.bats`(cancel/reopen·from-state 하드 가드·게이트 상태 거부·raw set-status 없음, server exec localhost 성공/invalid 400/비-localhost 403, Board Parked 컬럼·모바일 관측 전용).

### §11.20 자유 본문 저작 — ticket_body (비-LLM, 본문 한정) (ADR-0062)

**무엇을 쓰는가.** open 티켓의 **본문(프론트매터 이후 자유 마크다운)**만 교체한다. **프론트매터 블록(---…---)은 바이트 그대로 보존** — safe/status/id/depends_on 등 실행 게이트 필드를 건드릴 경로가 없다. 본문은 Spec/Library/Board에서 escape-first 렌더(ADR-0042)되어 데이터로 표시되지 실행되지 않는다.

**편집 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/ticket_body.sh set <TXXX> < newbody.md`. stdin에서 새 본문을 읽어 본문만 교체, 단일 git commit 감사(`git revert` 가역). open 외·DONE·승인 마커·TEMPLATE·NUL·16KB 초과 거부.
- **Mission Control (localhost 전용)**: Forge Board open 카드의 "본문 편집"(`<details>` textarea) → "본문 저장" → `POST /api/exec {command:ticket_body, action:set, ticketId, body}`. **본문은 stdin으로 전달**(서버 runScript 선택적 stdin) — 서버는 직접 writer가 아니라 `ticket_body.sh`로 파이프만 한다. 비-localhost(모바일)는 스코프 거부(403, T099) — 편집 컨트롤 미렌더(관측 전용).

**경계**: 서버는 소스/스테이징 파일을 쓰지 않고 stdin 파이프만(writer는 스크립트). 본문은 실행/승인/머지 의미가 없어 safe:false 게이트(ADR-0007)와 직교. exec 엔드포인트는 본문 JSON 봉투를 위해 요청 본문 상한을 96KB로 둔다(필드 16KB 바이트 상한은 execPlan에서 강제).

**v1 제외(별도 결정)**: 신규 티켓 생성·spec/playbook 저작·AI 인터뷰/초안(LLM 통합)·프론트매터 자유 편집.

- 회귀: `tests/ticket-body.bats`(본문 교체·프론트매터 바이트 보존·하드 가드(DONE/non-open/NUL/16KB), server exec localhost/oversize 400/비-localhost 403, Board 본문 편집 컨트롤·모바일 관측 전용).

### §11.21 신규 티켓 생성 — new_ticket (safe 강제 false) (ADR-0064)

**핵심 안전 앵커.** MC가 만드는 모든 티켓은 **`safe: false`로 강제**된다 — 운영자가 safe를 설정할 수 없다. 따라서 생성물은 **절대 자동 실행되지 않으며**, 실행/merge에는 `docs/approvals/<T>.md` 승인 마커가 선행해야 한다(ADR-0007). `id`는 `docs/tickets/` + `DONE/` 스캔으로 자동 할당(max+1, 충돌 불가), `status`는 open, `created`는 오늘, `depends_on/blocks`는 빈 배열, `spec_ref`는 기본값으로 강제된다.

**생성 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/new_ticket.sh create --title "<t>" [--priority P2] [--persona implementer] [--labels "a,b"]` (본문은 stdin, 선택). 파일명 `T<NNN>-<slug>.md`, 단일 git commit 감사(`git revert`로 파일 제거).
- **Mission Control (localhost 전용)**: Forge Board 상단 "+ 새 티켓" 폼(title/priority/persona/labels + 본문 textarea) → `POST /api/exec {command:new_ticket, action:create, ...}`. **본문은 stdin으로 전달**(서버는 writer 아님). 비-localhost(모바일)는 스코프 거부(403, T099) — 폼 미렌더(관측 전용).

**검증**: title 필수·제어문자(개행 포함) 금지·길이 상한; priority P0–P3·persona 4종(implementer/planner/reviewer/security-reviewer)·labels 안전 토큰; 본문 NUL/16KB. **safe 파라미터 자체가 없다** — true로 만들 경로가 없다.

**v1 제외(별도 결정)**: safe:true 생성·id 수동 지정·spec/playbook 저작·AI 인터뷰/초안(LLM 통합)·프론트매터 자유 편집.

- 회귀: `tests/new-ticket.bats`(id 자동·safe 강제 false·필드 적용·하드 가드(title/제어문자/priority/persona/NUL/16KB), server exec localhost/검증 400/비-localhost 403, Board 폼·모바일 관측 전용).

### §11.22 지배 문서(운영) 저작 — doc_edit (master-spec 제외) (ADR-0066)

**무엇을 편집하고 무엇을 안 하는가.** **운영 living 문서만** 전체 교체로 편집한다 — `docs/runbook.md`와 페르소나 플레이북 `skills/{implementer,planner,reviewer,security-reviewer}.md`. **master-spec.md는 편집 대상이 아니다**(읽기 전용 유지 — ADR-0042 보류·master-spec Non-goals 개정 선행 필요, 별도 결정). 티켓·ADR·소스·승인 마커도 이 경로로 편집 불가.

**경로 안전 — doc-key(raw 경로 아님).** `runbook`·`skill:implementer`·`skill:planner`·`skill:reviewer`·`skill:security-reviewer`만 받아 고정 경로로 매핑한다. 임의 경로·`..`·traversal은 표현 불가능(master-spec/소스로 못 샌다).

**편집 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/doc_edit.sh set <doc-key> < new.md`. stdin 전체 내용으로 교체, NUL/256KB/빈(최소 16B) 거부, 단일 git commit 감사(`git revert` 가역).
- **Mission Control (localhost 전용)**: Spec Studio "운영 문서 편집" 패널 — 각 문서 `<details>` textarea(현재 전체 내용 prefill) + "전체 교체 저장" → `POST /api/exec {command:doc_edit, action:set, docKey, content}`. **내용은 stdin으로 전달**(서버는 writer 아님). 비-localhost(모바일)는 스코프 거부(403, T099) — 패널 미렌더(관측 전용).

**경계**: 문서는 escape-first 렌더(ADR-0042)라 주입 텍스트가 실행되지 않는다. exec 요청 상한은 256KB 문서 수용을 위해 512KB로 둔다(필드 256KB 바이트 상한은 execPlan에서 강제).

**v1 제외(별도 결정)**: master-spec 편집·부분 패치·`.vN` 자동 스냅샷(현재 git 이력 감사)·AI 인터뷰/초안(LLM 통합)·임의 경로.

- 회귀: `tests/doc-edit.bats`(allowlist 전체 교체·하드 가드(master-spec/raw 경로/traversal/empty/NUL/256KB), server exec localhost/검증 400/비-localhost 403, Spec Studio 편집 패널(master-spec 키 없음)·모바일 관측 전용).

### §11.23 master-spec 편집 — spec_edit (가장 강한 게이트) (ADR-0068)

**무엇을·어떻게.** 가장 지배적 문서 `docs/master-spec.md`를 전체 교체로 편집한다 — **doc_edit과 분리된 별도 게이트**(master-spec는 doc_edit allowlist에 없다). doc_edit 대비 **추가 게이트**: ① **사유(reason) 필수**(왜 지배 문서를 바꾸나, 감사 커밋에 기록), ② **버전 스냅샷**(`master-spec.v<N>.md` — 교체 전 내용 보존), ③ **강한 2차 확인**("지배 문서 — 루프 행동 전체에 영향"). master-spec §4에 카브아웃이 명문화돼 있다(ADR-0042 보류 해소).

**자율성 분리(핵심).** master-spec 편집은 **인간 확인 동작 전용**이다 — 루프·orchestrator·pick_next·autopilot grant는 master-spec을 **절대 쓰지 않는다**. Autopilot grant가 있어도 master-spec은 불변. spec_edit은 localhost exec(UI 2차 확인)/CLI로만 트리거된다.

**편집 방법 (둘 다 동등 — CLI parity)**

- **CLI**: `./scripts/spec_edit.sh set --reason "<why>" < new-spec.md`. stdin 전체 내용으로 교체, `master-spec.vN` 스냅샷, NUL/256KB/최소 길이 거부, 단일 git commit(`spec_edit: <reason>`)으로 감사(`git revert` + 스냅샷 복원 가역).
- **Mission Control (localhost 전용)**: Spec Studio "master-spec 편집" 패널 — textarea(현재 내용) + **사유 입력** + "전체 교체 저장" → 강한 confirm → `POST /api/exec {command:spec_edit, action:set, reason, content}`. 내용은 stdin 전달(서버는 writer 아님). 비-localhost(모바일)는 스코프 거부(403, T099)·읽기 전용 유지.

**v1 제외(별도 결정)**: 루프/grant의 master-spec 편집·부분 패치·AI 인터뷰/초안(LLM 통합)·비-localhost.

- 회귀: `tests/spec-edit.bats`(사유+vN 스냅샷·하드 가드(reason/empty/NUL/256KB)·doc_edit allowlist 분리·server exec localhost/검증 400/비-localhost 403·Spec Studio 편집(localhost)/모바일 관측·**자율 분리**(루프/orchestrator/pick_next/grant가 spec_edit 미호출)·§4 카브아웃 존재).

### §11.24 per-ticket 토큰 합계 — durable tokens_total + 티켓별 Insights (ADR-0070)

**무엇을·왜.** ADR-0050 토큰 텔레메트리(세션별 `state/token_usage.log`·전체 합계 Insights)의 후속. `token_usage.log`는 gitignore·per-session이라 체크아웃에 유실 가능 — 한 티켓의 총 토큰은 **영구 기록 가치**가 있다(시간 계측 `completed_at` durable frontmatter와 동형). done 시 그 티켓 합계를 frontmatter로 굳히고, Mission Control이 티켓별로 보여준다.

**writer (루프).** `run_loop.sh` §11 telemetry 훅(`completed_at` 기록 직후)에서 완료 티켓 id의 `token_usage.log` 세션들을 input/output 합산해 DONE frontmatter `tokens_total`(+ `tokens_in`/`tokens_out`)을 `fm_set_field`로 기록한다. completed_at과 **동형**: 분리 telemetry 커밋(`telemetry(<id>): tokens_total`)·실패 시 `git checkout -- <done_file>` 트리 복원(cycle 비치명). usage 없으면 **미기록**(fail-closed — 0 아님). 로그 없음/`TOKEN_TELEMETRY` OFF면 무동작.

**reader (Mission Control).** `tokens_total`은 **측정 카운트만** durable — 비용($)은 frontmatter에 굳히지 않고 reader가 요율로 추정한다(요율 가변·오인 방지). Insights "티켓별 토큰(측정)" 패널: **done 티켓 frontmatter `tokens_total`(durable) 우선**, `token_usage.log` ticket group(라이브)이 진행 중/로그-only 티켓 보완(라이브 표식). 측정 카운트 막대 정렬·요율 구성(`MISSION_CONTROL_TOKEN_RATE_IN/OUT`) 시 티켓별 추정 비용 보조(`~$`·요율 명시)·데이터 없으면 "데이터 없음 — 계측 선행". MC는 frontmatter를 쓰지 않는다(루프=writer·MC=reader, `usage_capture.mjs` 무변경).

**v1 제외(별도 결정)**: 비용 frontmatter 영속·사전 계측 백필(불가)·요율 테이블 구성 UI·cache 토큰 티켓별 패널.

- 회귀: `tests/per-ticket-tokens.bats`(run_loop done 훅 합산·frontmatter tokens_total/in/out·fail-closed 미기록·분리 telemetry 커밋/트리 clean·completed_at·done-move 무회귀; server 티켓별 durable 우선·라이브 보완·동일 티켓 durable 승, 빈 데이터 "데이터 없음", 요율 미설정 시 비용 미표시).

### §11.25 읽기 전용 AI 초안 제안 — ai_draft (LLM 통합 v1) (ADR-0072)

**무엇을·왜.** 쓰기 표면 아크가 닫힌 뒤 분리됐던 본류 **LLM 통합**의 가장 보수적 첫 슬라이스. LLM이 티켓 본문 초안을 **제안만** 하고, 인간이 검토 후 기존 쓰기 표면(`ticket_body`)으로 적용한다. **챗봇이 아니다** — master-spec §5 Non-goal("범용 AI 챗봇/대화형 어시스턴트")은 유지된다. "AI 분리"는 "시스템에 LLM 부재"가 아니라 **"Mission Control 상호작용 표면이 결정론적이었다"**로 재해석된다(자율 루프는 이미 Act 단계에서 claude를 쓴다).

**proposer는 writer가 아니다 (핵심 경계).** `scripts/ai_draft.sh ticket-body <id>`는 티켓 제목·본문·라벨을 컨텍스트로 제약 프롬프트를 구성하고 `${CLAUDE_CMD:-claude}`를 **읽기 전용 권한**(`AI_DRAFT_PERMISSION_MODE` 기본 `plan` — 파일 편집 불가, **절대 bypassPermissions 아님**)·**단발**(`-p`, 멀티턴 없음)로 호출해 초안을 **STDOUT으로만** 반환한다. 파일·git을 쓰지 않는다. `RALPH_TOKEN_TELEMETRY=1`이면 호출 usage를 `lib/usage_capture.mjs`로 `token_usage.log`에 해당 티켓 귀속(per-ticket 토큰 v0.38로 비용 표면화).

**Mission Control (localhost 전용).** 티켓 본문 편집 패널에 "AI 초안 제안" 버튼 → `POST /api/exec {command:ai_draft, target:ticket-body, ticketId}` → 서버는 `ai_draft.sh` 디스패치(파일 미작성)·초안을 `stdoutTail`로 응답 → UI가 읽기 전용 블록("AI 초안 — 검토 후 적용")에 `textContent`(escape-safe)로 표시. 인간이 위 편집기에 복사·편집해 기존 `ticket_body`로 적용한다. `ai_draft`는 `NON_LOCALHOST_EXEC_ALLOW`(='approve'만)에 없어 비-localhost는 403(T099)·모바일 컨트롤 없음.

**자율 분리.** AI 초안 제안은 **인간 개시 전용** — 루프/orchestrator/pick_next/autopilot grant는 `ai_draft`를 호출하지 않고 자동 적용도 없다(초안→쓰기는 항상 인간의 별도 동작).

**v1 제외(별도 결정)**: 스펙/master-spec 초안·AI 인터뷰(멀티턴 — 챗봇 경계 재검토)·코드 초안·자동 적용·비-localhost.

- 회귀: `tests/ai-draft.bats`(ai_draft.sh 초안 stdout·파일 미작성(proposer≠writer)·bad target/id 거부·bypassPermissions 미사용; server exec localhost 200(실제 초안)/검증 400/비-localhost 403; 본문 패널 'AI 초안 제안' localhost present·모바일 absent; **자율 분리**(루프/orchestrator/pick_next/grant가 ai_draft 미호출)).

### §11.26 스펙 초안 제안 — ai_draft doc 타겟 (master-spec 제외) (ADR-0074)

**무엇을·왜.** LLM 통합 v1(읽기 전용 초안 제안)을 **지배 문서(운영)**까지 넓힌다. `ai_draft`에 `doc <doc-key>` 타겟을 추가해, LLM이 운영 문서 개정 초안을 **제안만** 하고 인간이 검토 후 기존 `doc_edit` 쓰기 표면으로 적용한다. 쓰기 표면이 doc_edit(운영 문서 allowlist·master-spec 제외)과 spec_edit(master-spec 전용)으로 분리됐듯, 초안 제안도 **doc_edit allowlist 타겟만** 다루고 **master-spec 초안은 분리**한다(후속).

**타겟 = doc_edit allowlist, master-spec 제외.** `ai_draft.sh doc <doc-key>`의 doc-key는 doc_edit와 **동일 매핑**(`runbook`·`skill:implementer`·`skill:planner`·`skill:reviewer`·`skill:security-reviewer`). doc-key→고정 경로라 master-spec·raw 경로·임의 경로는 인자로조차 표현 불가(거부). 해당 문서를 컨텍스트로 개정 초안을 제안한다.

**proposer ≠ writer (동일 불변).** claude를 읽기 전용 권한(`plan`·bypassPermissions 아님)·단발로 호출해 초안을 **STDOUT 반환만**(파일·git 미작성). 적용은 인간이 **기존 doc_edit 표면**으로(allowlist·경로 안전·localhost 게이트 그대로 통과). 비용: doc 초안은 티켓이 없어 usage를 `doc:<doc-key>` pseudo-id로 token_usage.log에 귀속(per-ticket 토큰 v0.38이 doc 단위 집계).

**Mission Control (localhost 전용).** Spec Studio "운영 문서 편집" 패널의 각 doc-key 행에 "AI 초안 제안" 버튼 → `POST /api/exec {command:ai_draft, target:doc, docKey}` → 초안을 읽기 전용 블록("AI 초안 — 검토 후 적용")에 `textContent`(escape-safe) 표시 → 인간이 편집기에 복사·`doc_edit`로 적용. master-spec 패널 없음·`ai_draft`는 `NON_LOCALHOST_EXEC_ALLOW` 밖이라 비-localhost 403(T099)·모바일 컨트롤 없음. 자율 분리(루프/grant 미호출) 유지.

**v1 제외(별도 결정)**: master-spec 초안(가장 지배적 문서 — 분리된 더 강한 판단)·AI 인터뷰(멀티턴)·코드 초안·자동 적용·비-localhost.

- 회귀: `tests/ai-draft.bats`(doc 타겟: 초안 stdout·파일 미작성·master-spec/raw 경로/bad key 거부; server doc exec localhost 200/master-spec·bad key 400/비-localhost 403; Spec Studio doc 패널 'AI 초안 제안' localhost present·master-spec 초안 키 없음; ticket-body 타겟 무회귀).

### §11.27 master-spec 초안 제안 — ai_draft master-spec 타겟 (적용은 spec_edit 게이트) (ADR-0076)

**무엇을·왜.** 읽기 전용 LLM 초안 제안을 마지막 타겟 **master-spec**(가장 지배적 문서)까지 넓혀 초안 아크를 완결한다. 핵심: master-spec §4 카브아웃(ADR-0068)은 **편집(쓰기)**을 규율하나, proposer는 **읽기 전용**이라 카브아웃 조건을 건드리지 않는다 — 위험은 전적으로 **적용 경로**에 있고, 그 경로는 이미 가장 강한 `spec_edit` 게이트(사유·vN 스냅샷·강한 2차 확인)다.

**proposer ≠ writer (동일 불변).** `ai_draft.sh master-spec`은 **별도 verb**(doc-key 아님 — doc 타겟이 master-spec을 표현 불가)로, docs/master-spec.md를 컨텍스트로 claude를 읽기 전용 권한(`plan`)·단발 호출해 초안을 **STDOUT 반환만**(파일·git 미작성). usage는 `doc:master-spec` 귀속.

**적용 = 기존 spec_edit 강한 게이트 (인간 동작).** 초안은 읽기 전용 제안이다. 인간이 검토 후 기존 spec_edit 표면(Spec Studio master-spec 편집기)으로 적용한다 — 카브아웃 ①~⑤(localhost·**사유 필수**·**vN 스냅샷**·**강한 2차 확인**·git 가역)를 모두 통과한다. proposal 단계엔 추가 게이트를 두지 않는다(제안은 읽기 전용이라 위험이 적용에 묶임). master-spec 초안은 다른 타겟과 달리 별도 verb라 doc allowlist와 명확히 분리된다.

**Mission Control (localhost 전용).** Spec Studio master-spec 편집 패널(mc-specedit)에 "AI 초안 제안" 버튼 → `POST /api/exec {command:ai_draft, target:master-spec}` → 초안을 읽기 전용 블록("AI 초안 — spec_edit 게이트(사유·2차 확인·vN)로 적용")에 `textContent`(escape-safe) 표시 → 인간이 편집기 복사·사유 입력·강한 2차 확인으로 적용. `ai_draft`는 `NON_LOCALHOST_EXEC_ALLOW` 밖이라 비-localhost 403(T099)·모바일 컨트롤 없음. 자율 분리(루프/grant 미호출·카브아웃 자율 미작성 무변경) 유지.

이로써 **읽기 전용 LLM 초안 아크 완결**: ticket-body(v0.39) → doc(v0.40) → master-spec(v0.41). 다음 큰 라운드는 멀티턴(AI 인터뷰)으로 챗봇 경계 재검토.

**v1 제외(별도 결정)**: AI 인터뷰(멀티턴)·코드 초안·proposal 단계 추가 게이트(적용 게이트가 담당)·자동 적용·비-localhost.

- 회귀: `tests/ai-draft.bats`(master-spec 타겟: 초안 stdout·파일 미작성; doc 타겟이 여전히 master-spec 거부(별도 verb); server master-spec exec localhost 200/비-localhost 403; Spec Studio master-spec 패널 'AI 초안 제안'·spec_edit 게이트 명시; 자율 분리; ticket-body·doc 타겟 무회귀).

### §11.28 유한 턴 AI 인터뷰 — ai_draft interview 모드 (챗봇 아님) (ADR-0078)

**무엇을·왜.** LLM 보조의 마지막·가장 큰 본류 **멀티턴**을 가장 보수적 슬라이스로 연다 — 고정 소수 턴으로 요구사항을 모은 뒤 티켓 초안을 제안. **챗봇이 아니다**(master-spec §5 Non-goal 보존): 네 경계로 구분한다 — ① 유한 턴(서버 강제 캡, 기본 3) ② 단일 목적(요구 수집→티켓 초안) ③ 무상태·ephemeral(대화 미영속) ④ 출력은 초안. "챗봇 = 무제한·범용·영속 대화", "인터뷰 = 유한·단일목적·무상태·초안-산출".

**MC 무상태 (file=truth).** 서버는 대화 상태를 보유하지 않는다 — 누적 트랜스크립트는 **클라이언트(인터뷰 패널 JS)에만** 존재하고 매 턴 exec로 전달된다. **턴 캡만 서버가 권위 강제**: `turn`은 정수 1..`INTERVIEW_MAX_TURNS`(기본 3, env `MISSION_CONTROL_INTERVIEW_MAX_TURNS`)여야 하며 초과는 400. 트랜스크립트 크기 상한(32KB)·NUL 거부. 클라이언트의 턴 주장을 신뢰하지 않는다.

**proposer ≠ writer.** `ai_draft.sh interview <turn>`은 트랜스크립트를 stdin으로 받아, turn < 캡이면 명확화 질문 1개를, turn == 캡이면 최종 티켓 초안을 claude 읽기 전용 권한(`plan`)·단발로 호출해 **STDOUT 반환만**(파일·git 미작성). 단일 목적 프롬프트(범용 대화 금지). usage `interview` 귀속(유한 턴이 비용 상한 보장).

**적용 = 기존 new_ticket (인간 동작).** 최종 티켓 초안은 인간이 검토 후 보드의 "새 티켓"(new_ticket — safe:false 강제·localhost·검증, ADR-0064)으로 생성한다. proposer는 티켓을 만들지 않는다. 인터뷰 패널은 보드 localhost 전용·모바일 absent. 자율 분리(루프/grant 미호출·자동 생성 없음) 유지.

이로써 LLM 보조는 **단발 초안**(ticket-body·doc·master-spec — 아크 완결)과 **유한 멀티턴 인터뷰** 두 모드를 갖되, 둘 다 읽기 전용·인간 적용·자율 분리·비용 표면화 위에 선다. 무제한·범용·영속 대화는 여전히 Non-goal.

**v1 제외(별도 결정)**: 무제한 멀티턴·대화 영속·코드 초안·자동 생성·비-localhost.

- 회귀: `tests/ai-draft.bats`(interview: 질문/초안 stdout·파일 미작성·turn 범위 밖 거부; server turn 1..3 200·turn 4·0 400(서버 캡)·트랜스크립트 32KB 초과 400·비-localhost 403; 인터뷰 패널 localhost present(무상태·챗봇 아님 라벨)·모바일 absent; 서버 대화 상태 미영속; 자율 분리; 단발 타겟 무회귀).

### §11.29 비용 텔레메트리 마무리 — 요율 구성(file=truth) + cache 토큰 (ADR-0080)

**무엇을·왜.** 토큰 텔레메트리(ADR-0050)·per-ticket 토큰(ADR-0070)의 두 미완 마무리 — 요율이 env 전용이라 MC 구성 불가였고, cache 토큰(`cache_read`/`cache_creation`)이 로그에 있으나 미표면화였다. **측정(카운트) ≠ 추정(비용)** 경계를 유지한 채 요율을 MC에서 구성 가능하게 하고 cache 토큰을 정직하게 표면화한다.

**요율 구성 = file=truth (set_mode/loop_mode 동형).** `scripts/rate_config.sh set --in <X> --out <Y> [--cache-read <A>] [--cache-creation <B>]`이 숫자·비음수 검증 후 `state/token_rates.json`에 직접 기록(gitignore·무커밋·CLI parity). **MC는 직접 writer 아님** — 서버는 `rate_config` exec(localhost T099·검증 400·비-localhost 403) 디스패치·읽기만. `readTokenRates()` 우선순위: **파일 > env(`MISSION_CONTROL_TOKEN_RATE_*`) > 미설정**(기존 env 하위 호환).

**요율 = 가정, 측정 아님.** 비용 = 토큰 카운트(측정) × 요율(가정·구성값). Insights는 "추정 비용 (요율 in $X/out $Y · 가정·<출처 파일/env>)"으로 요율·출처를 명시한다 — ADR-0050 측정/추정 분리 유지. 요율 구성이 토큰 카운트를 바꾸지 않는다.

**cache 토큰 표면화.** `cache_read`·`cache_creation`은 측정 카운트로 "토큰(측정)" 카드·티켓별 패널(라이브 행)에 표면화. cache 비용은 cache 요율(선택) 설정 시만 추정에 포함·미설정 시 카운트만(분리 라벨). Insights "요율 구성" 패널(localhost)에서 in/out/cache 요율을 입력·저장하고 현재 요율·출처를 본다. 비-localhost 구성 패널 없음·관측 전용.

**v1 제외(별도 결정)**: 다중 model별 요율 테이블·요율 이력·예산 알림.

- 회귀: `tests/rate-config.bats`(rate_config.sh 숫자/비음수 검증·token_rates.json 기록·음수/누락 거부; server reader 파일>env 우선·rate_config exec localhost 200/검증 400/비-localhost 403; Insights cache 카운트 표면화·요율 출처(파일/env) 표기·요율 미설정 시 비용 "데이터 없음"·구성 패널 모바일 absent).

### §11.30 AI 초안 diff 미리보기 — 클라이언트 측 읽기 전용 (ADR-0082)

**무엇을·왜.** AI 초안(ticket_body·doc·master-spec)이 읽기 전용 전문(全文)으로만 표시돼 현재 내용과 무엇이 다른지 한눈에 안 보였다(긴 문서 전체 교체). 초안을 **현재 내용과의 라인 diff**로 미리 보여 검토 UX를 실제 쓸모 있게 한다.

**클라이언트 측·새 표면 없음.** diff는 `mission-control/server.mjs`가 렌더하는 클라이언트 JS(`window.__mcDraftPreview`)가 브라우저에 이미 있는 두 문자열(현재 textarea 값·초안 `stdoutTail`)로 계산·표시한다 — **새 exec/스크립트/writer/파일 경로 없음**. ai_draft(읽기 전용 proposer)·쓰기 게이트·MC reader 무변경. diff는 응답의 *표현*일 뿐이다.

**대상 = 현재 기준 보유 3곳, 인터뷰 제외.** ticket_body·doc·master-spec 초안 핸들러가 공유 `__mcDraftPreview(out, 현재값, 초안)`로 라우팅(localhost 전용·세 페이지 공통, renderShell이 localhost일 때만 helper 주입). **인터뷰는 제외** — 최종 산출이 신규 티켓이라 비교 기준(현재 내용)이 없다(자체 transcript 로그·전문 유지).

**렌더 안전·정직성.** 간단 LCS로 added/removed/unchanged 라인을 마킹하고, **각 라인을 textContent로** 렌더(escape-first·주입 미실행, ADR-0042)·마커(+/−)는 CSS 클래스. 라인 수 상한(`MAX_LINES`=2000)·초과 시 전문 폴백. "diff ↔ 전문" 토글·"AI 초안 — 변경 미리보기 (아직 적용되지 않음)" 라벨. **적용은 인간이 기존 쓰기 표면**(ticket_body/doc_edit/spec_edit 강한 게이트)으로 — diff는 검토 보조만, 적용 경로·게이트 무변경.

**v1 제외(별도 결정)**: 단어 단위 diff·구문 하이라이트·인터뷰 diff·서버 측 diff.

- 회귀: `tests/draft-diff.bats`(diff 렌더러 localhost board/spec present·모바일 absent; 세 핸들러가 `__mcDraftPreview` 라우팅(raw textContent 아님)·인터뷰는 자체 로그(append, diff 미경유); escape-first(라인 textContent·innerHTML draft sink 없음); 라인 수 상한 상수 존재).

### §11.31 `.vN` 스냅샷 도구화 — snapshot_doc.sh (ADR-0084)

**무엇을·왜.** 전역 CLAUDE.md 컨벤션("기존 문서 업데이트 시 version 파일 생성")이 spec_edit 인라인(master-spec.vN)·doc_edit 미스냅샷(git 이력·의도적)·수동(runbook.vN) 세 방식으로 적용돼 왔다. next-N·내용 보존 로직 중복·수동 오류를 **재사용 도구**로 해소한다 — 도구화이지 정책 변경이 아니다.

**도구.** `scripts/snapshot_doc.sh <doc-path>`는 allowlist된 지배/운영 문서(`docs/master-spec.md`·`docs/runbook.md`·`skills/{implementer,planner,reviewer,security-reviewer}.md`·`docs/*.md` 최상위)의 현재 내용을 `<base>.v<N>.md`로 보존한다(N = 기존 `<base>.v[0-9]*.md` 최대+1). **경로 안전**: 절대 경로·`..`/traversal·`docs/decisions/*`·`docs/tickets/*`·`docs/*.v[0-9]*.md`(.vN 자체)·하위 디렉터리·소스는 거부. **무손실·원본 불변**(읽기→바이트 보존 복사, 대상 문서 미수정)·**무커밋**(스냅샷은 유발한 doc 편집 커밋에 포함)·스냅샷 경로 stdout.

**spec_edit 리팩터(DRY).** `spec_edit.sh`의 인라인 master-spec.vN 스냅샷 블록을 `snapshot_doc.sh docs/master-spec.md` 호출로 대체 — N 계산·내용 보존·파일명 동일(회귀로 동작 동일 고정). 사유·교체·커밋·가드 무변경.

**doc_edit 정책 존중.** doc_edit(ADR-0066)의 git-이력 감사 선택은 무변경 — 스냅샷을 강제하지 않는다. 도구는 *가용*할 뿐. MC 표면 무변경(새 exec/서버 없음).

**v1 제외(별도 결정)**: doc_edit 자동 스냅샷·MC 스냅샷 exec·스냅샷 보존/정리 정책·runbook 자동 스냅샷.

- 회귀: `tests/snapshot-doc.bats`(next-N 1→2→3·바이트 보존·원본 불변·무커밋(git 비의존)·runbook/skills 허용·거부(티켓/ADR/.vN/하위 경로/소스/traversal/절대/미존재)) + `tests/spec-edit.bats` 무회귀(master-spec.v<N> 동작 동일).

### §11.32 doc_edit 옵트인 스냅샷 — --snapshot (기본은 git-이력) (ADR-0086)

**무엇을·왜.** `.vN` 도구화(v0.45)의 첫 후속. doc_edit(ADR-0066)은 운영 문서를 스냅샷 없이 git-이력으로만 감사했다(의도적). runbook 같은 문서의 큰 개정 시 명시 `.vN` 롤백 지점이 유용할 때가 있어, 기존 선택을 뒤집지 않고 **옵트인**으로 푼다.

**메커니즘 (기본 무변경).** `doc_edit.sh set <key> [--snapshot]` — `--snapshot`가 있으면 전체 교체 **전** 현재 내용을 `snapshot_doc.sh <file>`(v0.45 도구 재사용)로 `<base>.v<N>.md` 보존하고, **파일+스냅샷을 같은 단일 커밋**(`doc_edit(<key>): replace`)에 담는다(spec_edit 동형). 플래그가 없으면 **현행 그대로**(스냅샷 미생성·git-이력, ADR-0066). `set <key>` 위치 인자 파싱 무회귀.

**경로 안전 이중·무손실.** 스냅샷 대상은 doc_edit이 이미 검증한 allowlist 경로(`key_to_path`)이며, snapshot_doc.sh가 그 경로를 다시 allowlist 대조한다(임의 경로·traversal 불가). snapshot_doc.sh의 바이트 보존·원본 불변이 그대로 적용된다.

**Mission Control (localhost).** Spec Studio "운영 문서 편집" 패널의 각 doc-key 행에 **"스냅샷 보존(.vN)" 체크박스**(기본 off). 체크 시 `POST /api/exec {command:doc_edit, …, snapshot:true}` → server doc_edit이 `--snapshot`을 doc_edit.sh에 전달. 미체크면 현행. master-spec 패널·모바일 무관. master-spec은 doc_edit allowlist 밖이라 옵트인 대상이 아니다(spec_edit이 .vN 강제 유지).

**v1 제외(별도 결정)**: master-spec 옵트인·스냅샷 보존/정리 정책·doc_edit 외 자동 스냅샷.

- 회귀: `tests/doc-edit.bats`(--snapshot: 교체 전 내용 .vN 보존·파일+snap 단일 커밋·기본(플래그 없음) 스냅샷 미생성·`set <key>` 무회귀·미지 플래그 거부; server snapshot:true → .vN/기본 미생성; doc 패널 '스냅샷 보존' 체크박스 localhost present) + snapshot-doc/spec-edit 무회귀.

### §11.33 단어 단위 diff — __mcDraftPreview 단어 모드 (클라이언트 측) (ADR-0088)

**무엇을·왜.** AI 초안 diff(v0.44, `__mcDraftPreview`)는 라인 단위라, 한 줄에서 단어 몇 개만 바뀌어도 줄 전체를 삭제+추가로 표시한다. **단어 단위 diff**로 줄-내부 변경을 강조해 검토 정밀도를 높인다.

**적용 = 인접 -/+ 줄 쌍의 줄-내부 단어 diff (라인 diff 후처리).** 라인 diff 결과(`[' '|'-'|'+', line]`)에서 **연속한 `['-', x]`,`['+', y]` 쌍**(수정된 줄)을 감지해, x·y를 단어 토큰(공백 경계 split)으로 분할하고 단어 단위 LCS(`wordLcs`)로 **변경 단어만** del/add 강조한다. 단독 추가/삭제·변경 없음(context)은 라인 diff 그대로. 줄당 단어 수 상한(`MAX_WORDS`=400) 초과 시 그 줄은 라인 diff 폴백.

**순수 클라이언트·새 표면 없음 (v0.44 동일).** 단어 diff는 클라이언트가 이미 가진 두 문자열로 라인 diff에 이어 계산·표시한다 — **새 exec/스크립트/writer/파일 경로 없음**. ai_draft(읽기 전용 proposer)·쓰기 게이트·MC reader 무변경. escape-first: 단어 토큰 각각 `span.textContent`(주입 미실행, ADR-0042)·강조는 CSS 클래스(`mc-wdiff__del`/`__add`).

**표면.** 툴바에 **"단어"** 모드 추가 — `diff(라인) / 단어 / 전문` 3모드. 기본은 기존 `diff(라인)`(무변경 → 회귀 최소), 단어 모드만 줄-내부 강조. 세 AI 초안 블록(ticket_body·doc·master-spec) 공통. 인터뷰는 v0.44대로 diff 미경유. 적용은 인간이 기존 쓰기 표면으로(diff는 검토 보조만)·"변경 미리보기 — 아직 적용 안 됨" 라벨 유지.

**v1 제외(별도 결정)**: 구문 하이라이트·문자 단위 diff·인터뷰 단어 diff·서버 측 diff.

- 회귀: `tests/draft-diff.bats`(단어 모드 버튼·`wordLcs`·`MAX_WORDS` 캡; 변경 단어 span textContent(escape-first·innerHTML sink 없음); 라인 diff(v0.44)·기본 모드 'diff'·라벨 무회귀) + ai-draft/spec_studio/doc-edit 무회귀.

### §11.34 예산 임계값 알림 — 관측 전용 비용 임계 표시 (ADR-0090)

**무엇을·왜.** 비용 텔레메트리(v0.43)가 추정 비용을 보여주나 "얼마면 주의"인지 신호가 없었다. **예산($) 임계값**을 더해, 추정 비용이 예산을 넘으면 Insights가 시각 표시를 한다.

**관측 전용 (핵심).** 추정 비용 ≥ 예산이면 "추정 비용" 카드에 `예산 초과` 배지·경고 색을 표시한다 — **알림 부작용 없음**: push/email·외부 호출·루프/자율 동작 개입 일체 없다(Insights 읽기 전용, ADR-0040). 임계 비교는 페이지 렌더 시점 reader 계산일 뿐이다.

**정직성 (측정/추정 분리).** 비용은 추정(요율(가정)×토큰 카운트(측정)), 예산은 구성값(가정) — 둘 다 측정이 아니다. 표시는 "추정 비용 $X · 예산 $Y (NN%) — 예산 초과(추정·관측 전용) (둘 다 가정)"으로 라벨해 측정 오인을 차단한다(ADR-0050). **요율 미설정 시 fail-closed** — 비용 추정 불가이므로 예산 비교도 안 함("비용 추정 불가 — 요율 미설정 (예산 설정됨)").

**구성·표면.** 예산은 `state/token_rates.json`의 `budget` 필드(요율과 동거·`rate_config.sh --budget <$>`·옵트인·비음수 검증·file=truth). reader 우선순위 요율과 동일(파일 > env, 단 env에 budget 없음). 요율 구성 패널(localhost)에 예산 입력 필드. 비-localhost는 구성 입력 없음·표시(읽기)는 동일. 예산 미설정 시 현행(비용 표시만) 무회귀. MC는 직접 writer 아님(rate_config.sh가 writer).

**v1 제외(별도 결정)**: push/email 알림·루프 개입/자동 중단·기간별 예산(월별)·예산 이력.

- 회귀: `tests/rate-config.bats`(rate_config --budget 기록·비음수 거부·미지정 미기록; Insights 초과 시 `예산 초과` 배지·`둘 다 가정` 라벨·정상 시 배지 없음·요율 미설정 fail-closed·관측 전용(notification/loop-control sink 없음)) + insights/per-ticket-tokens 무회귀.

### §11.35 문자 단위 diff — __mcDraftPreview "문자" 모드 (ADR-0092)

**무엇을·왜.** 단어 diff(v0.47)가 변경된 단어만 강조해, 한 단어 안에서 글자 몇 개만 바뀐 경우(`configuration`→`configurations`, `색상`→`색깔`)에도 단어 전체가 삭제+추가로 보였다. **문자 단위 diff**를 더해 바뀐 글자만 강조한다.

**후처리·별 모드 (핵심).** 문자 diff는 단어 diff(v0.47)의 **후처리**이고 **별 모드("문자")** 다 — 라인 diff(v0.44)·단어 LCS 자체는 한 글자도 안 바꾼다. 단어 모드의 변경 단어 run(연속 `-` run + 뒤따르는 `+` run)을 글자로 합쳐 문자 LCS(`charLcs`)로 다시 쪼개, 공통 글자는 `mc-cdiff__ctx`, 바뀐 글자만 `mc-cdiff__del`/`__add`로 강조한다. 툴바는 `diff`(라인)/`단어`/`문자`/`전문` 4모드·기본은 여전히 라인 diff.

**무표면·escape-first.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청 없음(v0.44/v0.47 동일). 글자 토큰 각각 `span.textContent`(데이터·미실행)·강조는 CSS 클래스. innerHTML draft sink 없음(ADR-0042). 글자 합이 `MAX_CHARS`(2000) 초과 시 단어 단위 강조로 폴백(라인 수 `MAX_LINES`·단어 수 `MAX_WORDS` 상한과 동형).

**무회귀·경계.** 라인 diff(v0.44)·단어 diff(v0.47)·전문 폴백·각 상한·기본 모드(diff) 무변경 — 문자는 후처리·별 모드. 세 AI 초안 블록 공통·인터뷰 제외 유지·적용은 인간이 기존 쓰기 게이트로. proposer≠writer·localhost(T099)·인증(T097) 무변경.

**v1 제외(별도 결정)**: 구문 하이라이트(언어 파싱)·인터뷰 산출 비교·서버 측 diff.

- 회귀: `tests/draft-diff.bats`(`문자` 모드 버튼·`charLcs`·`MAX_CHARS` 캡; 변경 글자 `mc-cdiff__*` span textContent(escape-first·innerHTML sink 없음); `mode === 'char'` 디스패치·wordRows char 플래그; 단어 diff(v0.47)·라인 diff(v0.44)·기본 모드 'diff'·라벨 무회귀; ui.css 문자 스타일) + ai-draft/spec_studio/doc-edit 무회귀.

### §11.36 스냅샷 인벤토리 — 관측 전용 snapshot_ls.sh (ADR-0094)

**무엇을·왜.** `snapshot_doc.sh`(v0.45)·`doc_edit --snapshot`(v0.46)으로 `<base>.v<N>.md` 스냅샷이 누적되나(현재 36개·runbook 33개) 무엇이 몇 개·최신 N인지 가시성이 없었다. **읽기 전용 인벤토리**로 "무엇이 얼마나 쌓였나"를 드러낸다.

**사용.** `scripts/snapshot_ls.sh docs/runbook.md` → 그 base의 스냅샷(개수·N 숫자 정렬·최신). 인자 없이 `scripts/snapshot_ls.sh` → allowlist 범위에서 스냅샷 있는 모든 base를 결정적 정렬로. 출력 예: `docs/runbook · 33개 · v1,v4,…,v35 · 최신 v35`.

**관측 전용 (핵심).** 파일 시스템을 **읽기만** 한다 — 쓰기·삭제·prune·자동 정리·커밋 일체 없음. base 문서·스냅샷 파일·git 상태 무변경(테스트로 실행 전후 무변경 단언). **삭제·보존 한도 강제는 파괴적 동작이라 범위 밖**(별도 ADR·확인 게이트). 이 슬라이스는 "무엇이 쌓였나"만 답한다.

**경로 안전.** `snapshot_doc.sh`와 동형 — 절대 경로·`..` traversal·`.vN` 자체·티켓·ADR·하위 경로·임의 경로 거부(exit 2). 인자 있을 때 지배/운영 문서 allowlist(master-spec·runbook·top-level docs/*.md·persona skills). N은 숫자 정렬(v2 < v10). file=truth 일관 — 상태 파일·캐시 없이 매번 파일 시스템 조회.

**v1 제외(별도 결정)**: 삭제·prune·보존 한도 강제·자동 정리(파괴적)·MC 표면(패널·엔드포인트).

- 회귀: `tests/snapshot-ls.bats`(단일 base 개수·N 정렬 v2<v10·최신; 전체 인자 없음·결정적·하위 경로 base 제외; 경로 거부 절대·`..`·`.vN`·티켓·ADR·하위 경로 exit 2; 관측 전용 실행 후 파일 시스템 무변경) + snapshot-doc/spec-edit/doc-edit 무회귀.

### §11.37 MC 스냅샷 인벤토리 표면 — Insights 읽기 전용 패널 (ADR-0096)

**무엇을·why.** 스냅샷 인벤토리 CLI(`snapshot_ls.sh`, v0.50)는 `.vN` 누적을 드러내나 MC 화면엔 안 보였다. Insights 읽기 전용 집계 홈(ADR-0040)에 "스냅샷 인벤토리" 패널을 더해 base별 `.vN` 개수·최신을 화면에서 본다.

**서버 reader (exec 아님).** 서버 측 `computeSnapshotInventory()`가 `docs/*.md`·persona `skills/*.md`의 `<base>.v<N>.md`를 직접 globbing해 base별 개수·N 숫자 정렬(v2<v10)·최신을 만든다. `snapshot_ls.sh`를 exec하지 않는다 — 둘은 같은 file=truth(.vN)를 읽는 **독립 리더**이고 allowlist·N 정렬 의미가 동형이다(readTokenRates↔rate_config.sh 관계). 회귀로 CLI↔서버 같은 base·개수를 단언.

**읽기 전용 (핵심).** 서버 reader는 `.vN`를 읽기만 한다 — 쓰기·삭제·prune·exec·상태 변경 없음. Insights 패널은 표시 전용(버튼·exec·삭제 컨트롤 없음). `/insights` 렌더가 파일 시스템을 바꾸지 않음(테스트로 렌더 전후 무변경 단언). 캐시 없이 렌더 시점 globbing(file=truth). escape-first(base 경로·숫자, ADR-0042). 스냅샷 전무 시 "스냅샷 없음"(데이터 없음 honest).

**경계.** 하위 경로(`docs/*/*`)·`.vN` 자체·티켓·ADR 제외(snapshot_ls.sh allowlist 동형). Insights 기존 카드 무회귀. 삭제·보존 강제는 파괴적이라 별도 결정 유지(ADR-0094 §8).

**v1 제외(별도 결정)**: 삭제·prune·보존 한도 강제(파괴적)·인벤토리 JSON 엔드포인트.

- 회귀: `tests/snapshot-inventory-surface.bats`(패널 base·개수·최신(N 숫자 정렬); 하위 경로 제외; 관측 전용 컨트롤/exec 부재; 읽기 전용 /insights 렌더 파일 시스템 무변경; CLI(snapshot_ls.sh) 일관; 스냅샷 없을 때 '스냅샷 없음') + insights/snapshot-ls/snapshot-doc 무회귀.

### §11.38 다중 model 요율 — per-model 비용 추정 (옵트인) (ADR-0098)

**무엇을·why.** 비용 추정(v0.43)은 단일 flat 요율을 모든 토큰에 model 구분 없이 적용했다. `token_usage.log`엔 model 컬럼이 이미 있다. **per-model 단가**를 옵트인으로 더해 모델별 단가 차이를 반영한다.

**옵트인·무회귀 (핵심).** `state/token_rates.json`에 옵트인 `models` 맵(`{ "<model>": { "input": X, "output": Y } }`)을 둔다. flat `input`/`output`은 그대로 **기본(fallback) 요율**. computeInsights는 `models` 설정 시 토큰을 model별로 그룹해 per-model 요율(없으면 flat fallback)을 적용·합산하고, **`models` 미설정 시 flat 전체와 수학적으로 동일**(무회귀). 안전망: 로그 model이 맵에 없으면 flat fallback, flat 자체가 없으면 현행 fail-closed(추정 불가).

**정직성.** 모델별 토큰=측정, 모델별·flat 요율=구성값(가정), 비용=추정. per-model이어도 비용은 "가정" — 비용 카드 라벨에 `· model별 요율 N개(가정)` 첨언(측정 오인 차단·ADR-0050). 예산(ADR-0090)·"둘 다 가정" 무변경.

**구성·표면.** `rate_config.sh --model <name>:<in>:<out>`(반복·옵트인·비음수 검증·이름 비어있지 않음·`"`/`:` 거부). MC writer 아님(rate_config.sh가 writer·file=truth·stateless 전체 쓰기). 요율 패널(localhost)에 `name:in:out, …` 입력. reader는 파일만(env엔 models 없음)·무효 엔트리 무시. macOS Bash 3 호환.

**v1 제외(별도 결정)**: 요율 이력(writer/append)·per-model cache 요율·자동 model 단가 조회(외부 호출).

- 회귀: `tests/rate-config.bats`(rate_config --model 기록·비음수/형식/빈이름 거부·미지정 미기록; per-model 비용 적용·`model별 요율` 라벨·로그 model 미등록 시 flat fallback·models 미설정 무회귀(flat=$18)·exec 무효 model 400) + insights/per-ticket-tokens/exec 무회귀.

### §11.39 요율 이력 — append-only 감사 로그 + 읽기 전용 표면 (ADR-0100)

**무엇을·why.** 요율(가정·비용 추정 입력)은 현재 값만 `token_rates.json`에 남고 변경 이력이 사라져, "지난주 비용이 왜 달랐나" 같은 감사가 안 됐다. 요율을 쓸 때마다 **append-only 감사 로그**에 한 줄을 더하고 Insights에 읽기 전용으로 최근 이력을 드러낸다.

**append-only·writer (핵심).** `rate_config.sh`가 token_rates.json 쓰기 **성공 직후** `state/token_rates_history.log`(TSV·`state/*.log`로 이미 gitignored)에 한 줄 append: `ts·in·out·cache_read·cache_creation·budget·model_count`(미설정 `-`). **best-effort·non-fatal** — 이력 append가 실패해도(예: 경로 문제) 요율 쓰기는 성공·exit 0(이력은 보조 감사). 과거 항목은 수정·삭제 안 함(추가만). MC는 이력을 **쓰지 않는다**(file=truth·CLI writer·MC reader).

**읽기 전용 표면·정직성.** server `parseRateHistory()`가 로그를 읽어 최근 N(10)·newest-first. Insights "요율 이력" 패널은 표시 전용(컨트롤·exec·삭제 없음·escape-first)·이력 없으면 "이력 없음"(honest). `/insights` 렌더는 로그를 바꾸지 않음(테스트로 무변경 단언). **값=가정(구성값)·시각=측정(기록 시각)** — 과거 항목은 그 시점 구성이지 측정 비용이 아니다(ADR-0050).

**무회귀.** token_rates.json 쓰기·기존 요율/비용/예산/다중 model 표시 무변경. 이력은 가산 append·gitignored(트리 무영향).

**v1 제외(별도 결정)**: prune·보존 한도 강제·과거 항목 편집/삭제(파괴적)·이력 기반 과거-시점 비용 재계산.

- 회귀: `tests/rate-config.bats`(rate_config 쓰기당 1줄 append·연속 누적(append-only)·기존 token_rates.json 무회귀·append 실패해도 exit 0(non-fatal); Insights 패널 최근 항목 newest-first·escape-first·이력 없으면 '이력 없음'·렌더가 로그 미작성) + insights/inventory-surface/exec 무회귀.

### §11.40 per-model cache 요율 — 옵트인 · flat cache fallback (ADR-0102)

**무엇을·why.** 다중 model 요율(v0.52)은 model별 in/out만 적용하고 cache(cache_read·cache_creation)는 flat 단일 요율을 썼다. model별 cache 단가 차이를 옵트인으로 반영한다.

**옵트인·무회귀 (핵심).** `models` 엔트리에 옵트인 `cache_read`/`cache_creation`을 더한다. computeInsights는 per-model 그룹에 cache 토큰을 합산해 model별 cost에 cache(per-model cache 요율 있으면 그것·없으면 **flat cache fallback**)를 포함한다. **per-model cache 미설정 시 flat cache와 수학적으로 동일**(무회귀)·3필드 `--model`은 v0.52와 완전 동일. flat in/out 없으면 현행 fail-closed.

**안전망·정직성.** model 엔트리에 cache 요율 없으면 flat cache 적용·flat cache도 없으면 cache 비용 0(현행). cache 토큰(모델별)=측정, cache 요율(모델별·flat)=구성값(가정), 비용=추정 — per-model cache여도 "가정"(ADR-0050).

**구성.** `rate_config.sh --model <name>:<in>:<out>[:<cacheRead>[:<cacheCreation>]]`(3~5 필드·옵트인 cache·비음수 검증·3필드 하위호환). MC writer 아님(rate_config.sh writer·file=truth). reader `normalizeModelRates`가 per-model cache 파싱(유효만). exec dispatch 3~5 필드 검증. macOS Bash 3 호환(`:` 분해·globbing off).

**v1 제외(별도 결정)**: 과거-시점 비용 재계산·이력 prune·새 cache 종류.

- 회귀: `tests/rate-config.bats`(rate_config --model 4/5필드 cache 기록·3필드 cache 없음·비음수/6필드 거부; per-model cache 비용 적용($38.25)·cache 미지정 model flat fallback·per-model cache 없이 flat cache 무회귀($36.15)·exec 무효 cache 400) + insights/inventory-surface/exec 무회귀. 비용 수학 sandbox 사전 검증(per-model cache 16.8·flat fallback 15.6·flat cache 없으면 0).

### §11.41 과거-시점 비용 재계산 — 요율 이력 시간 조인 (읽기 전용 가산) (ADR-0104)

**무엇을·why.** 현재 추정 비용은 *현재 요율*을 모든 과거 토큰에 적용한다. 요율 이력(v0.53)과 `token_usage.log`의 행별 ts를 **시간 조인**하면 각 세션을 *그 시점에 유효했던 요율*로 추정할 수 있다. 기존 추정을 안 바꾸고 **가산 figure**로 더한다.

**가산·무회귀 (핵심).** 새 "이력 요율 기준 추정 비용"은 기존 `estimatedCost`(현재 요율) *옆에* 표시된다 — 기존 추정·예산·per-model 표시 무변경(두 lens 병존). reader가 각 token_usage 행 ts에 `ts <= 행.ts`인 마지막 요율 이력 항목의 flat 요율을 적용·합산한다. 이력 전 행은 현재 flat 요율 fallback·이력 전혀 없으면 figure 생략(중복 방지·honest).

**flat·per-model 제외 (정직).** 요율 이력 로그는 flat in/out/cache만 기록하고 **per-model 요율 맵을 저장하지 않으므로**(ADR-0100 스키마), 이력 기준 비용은 **flat만** 사용한다. 라벨 `이력 요율 기준 ~$X (flat·per-model 제외·가정)`로 명시 — 측정 아님·추정(ADR-0050). (현재-요율 estimatedCost는 v0.54대로 per-model 적용 — 두 lens는 다른 계산임을 라벨로 구분.)

**읽기 전용.** token_usage·token_rates_history를 읽기만(시간 조인 계산)·쓰기/exec 없음·렌더 시점 계산. localhost(T099)·인증(T097) 무변경.

**v1 제외(별도 결정)**: per-model 과거 재계산(이력 스키마 확장 필요)·이력 prune.

- 회귀: `tests/rate-config.bats`(시간 조인 행별 그 시점 요율·합계(current 130 vs 이력 64); 이력 전 행 현재 flat fallback; 이력 없음 figure 생략·기존 추정 무변경; per-model 설정돼도 이력 기준 flat만($18)·estimatedCost는 per-model($36)) + insights/inventory-surface/exec 무회귀. 시간 조인 sandbox 사전 검증(18+36+10=64).

### §11.42 per-model 과거-시점 재계산 — 요율 이력 per-model 컬럼 (하위호환) (ADR-0106)

**무엇을·why.** 과거-시점 비용(v0.55)은 요율 이력에 per-model이 없어 flat만 썼다("per-model 제외"). 요율 이력에 **per-model 컬럼을 append-only로 추가**(하위호환)해, 시간 조인이 *그 시점 per-model 요율을 반영*한다.

**append-only·하위호환 (핵심).** 요율 이력 TSV에 **8번째 컬럼**(per-model compact `name=in/out/cr/cc;...`·cache 없으면 `-`·`;` 구분·models 없으면 `-`)을 추가한다. **구 7컬럼 라인은 무변경**(소급 변경 없음) — 구 라인이 in-effect면 per-model 컬럼이 없으므로 **flat fallback**(v0.55 동작·무회귀). `rate_config.sh`가 이미 파싱한 per-model 루프를 재사용해 best-effort·non-fatal append.

**retro per-model 조인.** `parseRateHistoryChrono`가 컬럼 7을 `models` 맵으로 파싱(구 라인/`-` → {}). computeInsights는 각 token_usage 행의 in-effect 항목에서 `models[행.model]`을 찾아 per-model 요율(필드별 그 항목 flat fallback)을 적용·합산한다. fallback 체인: per-model → 그 항목 flat → 이력 전 현재 flat. 라벨 `이력 요율 기준 ~$X (가정·per-model 이력 반영)`.

**무회귀·정직성.** 기존 `estimatedCost`(현재 요율·per-model)·예산 무변경 — retro figure만 정밀화. 읽기 전용(MC reader·rate_config append-only). 비용=추정(가정)·per-model을 기록된 만큼 반영·미기록 flat(ADR-0050).

**v1 제외(별도 결정)**: 이력 prune·구 라인 소급 per-model 보강(기록 시점에 없던 정보)·기존 estimatedCost 변경.

- 회귀: `tests/rate-config.bats`(history per-model 컬럼 compact 기록·models 없으면 line1 no `=`; retro per-model 반영($54 — 'model'=9/45 이력)·구 7컬럼 라인 → flat fallback($18·v0.55 compat); 'per-model 이력 반영' 라벨; v0.55 시간 조인($64)·estimatedCost($36) 무회귀) + insights/inventory-surface/exec 무회귀. per-model 조인 sandbox 사전 검증(opus90+haiku1+sonnet flat3=94).

### §11.43 모바일 e2e 흐름 자동 테스트 — wire-level 해피패스 (ADR-0108)

**무엇을·why.** 모바일(비-localhost) 경계는 조각별로 검증돼 있었으나(401·approve 허용·inbox 렌더·R1/R2), 사용자 여정 전체를 한 순차 흐름으로 묶은 e2e가 없었고 approve는 상태코드(`!403`)만 봤다. wire-level 해피패스를 한 e2e로 묶어 회귀 고정한다.

**흐름(순차).** `tests/mobile-e2e.bats` — 한 디바이스 토큰으로: 부트스트랩(pair→exchange) → 게이트(비-localhost 무토큰 `/` → 401, T097) → 렌더(비-localhost 토큰 `/`·`/inbox` → 200·"approve/reject only"·쓰기 패널(`data-rateconfig`·`data-ai-draft`) absent) → **승인 효과**(비-localhost `/api/exec approve T001` → 200 **AND `docs/approvals/T001.md` 실제 생성** — 서버가 approve.sh 실행) → 스코프 거부(비-localhost run_loop/set_mode/ai_draft → 403, T099).

**테스트 전용·safe:true.** 운영/경계(server/scripts) 코드 무변경 — 새 bats만 추가. 127.0.0.2 출처가 비-localhost(모바일) 경로를 검증(실기기/TLS 불요·서버 판정은 socket peer 주소). 비-localhost 출처 미가용 시 graceful skip(`require_nonlocal_source`). 승인 게이트 불요(safe:false 아님).

**T108 분리(비클로즈).** 실기기 브라우저 SW 런타임의 navigation/정적/SSE 실주입·오프라인 셸은 **자동화 범위 밖** — 온디바이스 수동 검증(T108)으로 남는다. 본 라운드는 보완이며 T108을 닫지 않는다.

- 회귀: `tests/mobile-e2e.bats`(부트스트랩 토큰 발급; 무토큰 401; 렌더 'approve/reject only'·쓰기 패널 absent; /inbox 200·티켓 노출; 승인 효과 마커 생성; 비-approve exec 403) + private_path_scope/inbox/exec 무회귀.

### §11.44 markdown 구문 하이라이트 — __mcDraftPreview "구문" 모드 (ADR-0110)

**무엇을·why.** 초안 "전문" 모드는 plain text라 markdown 구조가 안 보였다. 저장소 문서가 전부 markdown이므로, 옵트인 "구문" 별 모드로 초안 전체를 markdown 토큰별로 색칠해 가독성을 높인다.

**markdown 전용·읽기 전용 (핵심).** 툴바 `diff`/`단어`/`문자`/`전문`/`구문` 5모드(`전문` 뒤). "구문"만 초안 전체를 토큰화해 색칠한다 — 라인: 제목(`#`~`######`)·펜스 코드블록(상태 추적)·목록 마커(`- `·`* `·`+ `·`1. `)·인용(`> `); 인라인: 코드 스팬(백틱·매칭 쌍만). 각 토큰 `span.textContent`(escape-first)·클래스(`mc-md-heading`/`code`/`codespan`/`list`/`quote`). **markdown→HTML 변환 없음·innerHTML 없음** — 렌더링이 아니라 *토큰 색칠*(주입 표면 회피, ADR-0042). 범용 언어 파싱 아님(markdown만)·인라인 bold/italic/link v1 제외.

**무표면·무회귀.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader 무변경. `MAX_LINES` 초과 시 plain 전문 폴백. diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경 — 구문은 가산 별 모드(변경이 아니라 전체 색칠·diff와 직교). 세 AI 초안 블록 공통·인터뷰 제외 유지·적용은 인간이 기존 쓰기 게이트로.

**v1 제외(별도 결정)**: 범용 언어 구문 하이라이트·인라인 bold/italic/link·markdown→HTML 렌더링.

- 회귀: `tests/draft-diff.bats`(`구문` 모드 버튼·`mdRender`/`mdInline` 토크나이저·`mode === 'syntax'` 디스패치; 토큰 `mc-md-*` span textContent(escape-first·markdown→HTML/innerHTML 없음); `MAX_LINES` 폴백; diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 diff 무회귀; ui.css `mc-md-*` 스타일) + ai-draft/spec_studio/doc-edit 무회귀. 토크나이저 sandbox 사전 검증(펜스 토글·제목/목록/인용·매칭/미매칭 인라인 코드).

### §11.45 인라인 강조/링크 하이라이트 — mdInline 확장 (구문 모드) (ADR-0112)

**무엇을·why.** 구문 하이라이트(v0.58)는 라인 토큰 + 인라인 코드 스팬만 색칠하고 굵게/기울임/링크는 plain이었다. `mdInline`을 확장해 코드 스팬 밖 plain 세그먼트에 강조/링크를 더한다(새 모드·표면 없음).

**mdEmphasis (코드 스팬 밖만).** `mdEmphasis(parent, text)`가 한 정규식 alternation(우선순위 링크→굵게→기울임)으로 스캔: 링크 `[text](url)`→`mc-md-link`·굵게 `**`/`__`→`mc-md-strong`·기울임 `*`/`_`→`mc-md-em`. `mdInline`이 **코드 스팬(v0.58·백틱)을 먼저 분리**하고 plain 세그먼트만 `mdEmphasis`로 라우팅하므로 **코드 우선이 자연 보존**(코드 안 텍스트는 강조 미적용·sandbox 검증). 비탐욕·미매칭은 plain(거짓 강조 회피).

**escape-first·마커 보존·무표면 (핵심).** 각 토큰 `span.textContent`(마커 `**`·`*`·`[`·`](`·`)` *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). **링크는 `<a>` 아님**(텍스트만·네비게이션/주입 표면 회피). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader 무변경.

**무회귀.** 코드 스팬·라인 토큰(제목/목록/인용/펜스)·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 강조는 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: 취소선·이미지·각주·중첩 강조·다중 라인 강조·링크 `<a>` 렌더·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`mdEmphasis`·`mc-md-strong`/`em`/`link` span textContent(마커 보존·escape-first); 링크 `<a>` 아님·markdown→HTML/innerHTML 없음; 코드 스팬 우선(coffee 밖 plain만 라우팅); 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-strong/em/link`) + ai-draft/spec_studio/doc-edit 무회귀. 토크나이저 sandbox 사전 검증(굵게/기울임/링크 마커 보존·코드 스팬 안 강조 미적용·미매칭 plain).

### §11.46 master-spec 옵트인 변경 검토 — 적용 전 읽기 전용 diff (ADR-0114)

**무엇을·why.** master-spec 편집(spec_edit·ADR-0068)은 강한 게이트(사유·vN 스냅샷·강한 confirm)를 갖지만, "전체 교체 저장" 직전 **무엇이 바뀌는지(on-disk vs 편집기) diff를 보여주는 검토가 없었다**(confirm은 사유 텍스트만). 옵트인 "변경 검토" 버튼이 적용 전 변경 내용을 읽기 전용 diff로 띄운다.

**옵트인·게이트 직교 (핵심).** master-spec 편집 패널(localhost)에 "변경 검토" 버튼(`data-spec-review`) + 전용 read-only 컨테이너(`data-spec-review-out`). 클릭 시 기존 클라이언트 측 `__mcDraftPreview`(v0.44~v0.59 라인/단어/문자/구문 diff)를 재사용해 **on-disk master-spec(기준선) vs 편집기 내용** diff를 표시한다. baseline은 페이지 로드 시 편집기 초기값(= on-disk specMd) 캡처(재fetch 없음). **저장을 게이트하지 않는다** — 적용 게이트는 기존 강한 confirm(사유·2차 확인·vN 스냅샷·spec_edit exec)이 그대로다(검토는 보조 가시성).

**무표면·읽기 전용.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청·서버 상태 없음(`spec_review` 같은 새 명령 없음). 전용 컨테이너·검토용 노트("변경 검토 — 적용 전 …·읽기 전용·아직 적용 안 됨"·`__mcDraftPreview`가 설정한 'AI 초안' 노트를 호출 후 검토용으로 복원). proposer≠writer·escape-first(ADR-0042). localhost(T099)·인증(T097)·비-localhost 패널 부재(기존).

**무회귀.** spec_edit 저장·사유·confirm·vN 스냅샷·writer·AI 초안(ADR-0076) 무변경. 검토는 가산·게이트 직교.

**v1 제외(별도 결정)**: 검토 강제(저장 차단)·서버 측 diff·runbook/페르소나 등 다른 문서 검토.

- 회귀: `tests/mission_control_spec_studio.bats`(변경 검토 버튼·전용 컨테이너(localhost)·비-localhost 부재; `__mcDraftPreview(reviewOut, baseline ...)` 재사용·baseline 로드 시 캡처·새 exec/엔드포인트 없음; spec_edit 게이트(사유·confirm·spec_edit exec) 무변경) + draft-diff/ai-draft/spec-edit/doc-edit 무회귀.

### §11.47 doc_edit 옵트인 변경 검토 — runbook·페르소나 적용 전 읽기 전용 diff (ADR-0116)

**무엇을·why.** master-spec 옵트인 검토(v0.60·ADR-0114)를 **운영 문서 편집(doc_edit·runbook + persona 플레이북)** 패널로 확장한다. doc_edit도 전체 교체·감사 커밋·옵트인 .vN 스냅샷을 갖지만, 저장 직전 변경 내용을 diff로 볼 수단이 없었다.

**행별 옵트인·게이트 직교 (핵심).** doc_edit 패널은 문서마다 행(`data-docedit`·`data-doc-content` 편집기). 각 행에 "변경 검토" 버튼(`data-doc-review`) + 전용 read-only 컨테이너(`data-doc-review-out`). 클릭 시 기존 클라이언트 측 `__mcDraftPreview`(v0.44~v0.59 라인/단어/문자/구문/인라인 diff)를 재사용해 **그 행 on-disk 기준선 vs 편집기 내용** diff를 표시한다. baseline은 페이지 로드 시 행별 편집기 값을 **Map**으로 캡처(`baselines.set(ta, ta.value)`·재fetch 없음). **저장을 게이트하지 않는다** — doc_edit 저장·전체 교체·감사 커밋·옵트인 스냅샷은 그대로(검토는 보조 가시성·게이트 직교).

**무표면·읽기 전용.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청·서버 상태(`doc_review` 같은 새 명령) 없음. 검토용 노트로 복원(`__mcDraftPreview`가 설정한 'AI 초안' 노트 덮어씀). proposer≠writer·escape-first(ADR-0042). localhost(T099)·인증(T097)·비-localhost 패널 부재(기존).

**무회귀.** doc_edit 저장·스냅샷·AI 초안(ADR-0074)·master-spec 검토(v0.60) 무변경. 검토는 가산·게이트 직교.

**v1 제외(별도 결정)**: 검토 강제(저장 차단)·서버 측 diff·티켓 본문 검토.

- 회귀: `tests/doc-edit.bats`(행별 변경 검토 버튼·전용 컨테이너(localhost)·비-localhost 부재; `__mcDraftPreview(reviewOut ...)` 재사용·행별 `baselines.set(ta` 로드 시 캡처·새 명령 없음; doc_edit 저장(`command: 'doc_edit'`)·옵트인 스냅샷 무변경) + spec_studio/draft-diff/ai-draft/spec-edit 무회귀.

### §11.48 티켓 본문 옵트인 변경 검토 — 본문 저장 적용 전 읽기 전용 diff (ADR-0118)

**무엇을·why.** 옵트인 변경 검토를 **세 번째이자 마지막 쓰기 표면 — Forge Board 티켓 본문 편집기(ticket_body·ADR-0062)** 로 확장한다. 티켓 본문도 전체 교체·프론트매터 보존·AI 초안(ADR-0072)을 갖지만, 저장 직전 변경 내용을 diff로 볼 수단이 없었다. 이로써 검토가 세 쓰기 표면(master-spec v0.60·doc_edit v0.61·ticket-body v0.62) 전체에 닫힌다.

**카드별 옵트인·게이트 직교 (핵심).** Board는 open 티켓마다 카드(`data-ticket-body-row`·`data-ticket-id`·`data-ticket-body` 편집기). 각 카드에 "변경 검토" 버튼(`data-ticket-body-review`) + 전용 read-only 컨테이너(`data-ticket-review-out`). 클릭 시 기존 클라이언트 측 `__mcDraftPreview`(v0.44~v0.59 라인/단어/문자/구문/인라인 diff)를 재사용해 **그 카드 on-disk 기준선 vs 편집기 내용** diff를 표시한다. baseline은 페이지 로드 시 카드별 본문 편집기 값을 **Map**으로 캡처(`ticketBaselines.set(ta, ta.value)`·document 범위·재fetch 없음). **저장을 게이트하지 않는다** — ticket_body 저장·전체 교체·프론트매터 보존은 그대로(검토는 보조 가시성·게이트 직교).

**무표면·읽기 전용.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청·서버 상태(`ticket_review` 같은 새 명령) 없음. 검토용 노트로 복원(`__mcDraftPreview`가 설정한 'AI 초안' 노트 덮어씀). proposer≠writer·escape-first(ADR-0042). localhost(T099)·인증(T097)·비-localhost 본문 편집기 부재(기존·관측 전용).

**무회귀.** ticket_body 저장(`command: 'ticket_body'`)·AI 초안(ADR-0072)·master-spec 검토(v0.60)·doc_edit 검토(v0.61) 무변경. 검토는 가산·게이트 직교.

**v1 제외(별도 결정)**: 검토 강제(저장 차단)·서버 측 diff.

- 회귀: `tests/ticket-body.bats`(카드별 변경 검토 버튼·전용 컨테이너(localhost)·비-localhost 부재; `__mcDraftPreview(reviewOut ...)` 재사용·카드별 `ticketBaselines.set(ta` 로드 시 캡처·새 명령 없음; ticket_body 저장(`command:"ticket_body"` exec 200)·프론트매터 보존 무변경) + board/ai-draft/draft-diff/doc-edit/spec_studio 무회귀.

### §11.49 취소선 하이라이트 — mdEmphasis 확장 (구문 모드) (ADR-0120)

**무엇을·why.** 인라인 강조/링크 하이라이트(v0.59)는 굵게/기울임/링크만 색칠하고 취소선(`~~text~~`)은 plain이었다. `mdEmphasis` 정규식 alternation에 취소선 대안 1개를 더한다(새 모드·툴바·함수·표면 없음 — 가장 작은 단일 토큰 추가).

**MD_INLINE 맨 끝 m4 (겹침 없음).** `MD_INLINE`에 취소선 대안을 **맨 끝(m4)** 으로 추가: `(~~[^~\n]+~~)`(비탐욕·한 라인). cls 분기 `m[1] ? 'mc-md-link' : m[2] ? 'mc-md-strong' : m[3] ? 'mc-md-em' : 'mc-md-strike'`. `~~`는 `*`/`_`/`[`와 시작 문자가 겹치지 않아 **leftmost 매칭이 기존 강조/링크와 자연 분리**(맨 끝 추가로 기존 m1~m3 인덱스 의미 보존). 단일 `~`·미매칭은 plain(거짓 취소선 회피). sandbox 사전 검증(취소선 매치·강조와 혼재 분리·단일 `~` plain·인접 2개 취소선).

**escape-first·마커 보존·무표면 (핵심).** 취소선 토큰 `span.textContent`(마커 `~~` *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). CSS `mc-md-strike`(`text-decoration: line-through`·색만)는 표현일 뿐 텍스트·마커 보존. 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader·세 검토 표면(v0.60/v0.61/v0.62) 무변경.

**무회귀.** 코드 스팬(v0.58·백틱) 우선·라인 토큰(제목/목록/인용/펜스)·굵게/기울임/링크(v0.59)·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 취소선은 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: 이미지·각주·중첩 강조·다중 라인 취소선·마커 제거 렌더·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`MD_INLINE` 취소선 대안(`~~[^~`)·cls 분기 `'mc-md-strike'`·span textContent(마커 `~~` 보존·escape-first); markdown→HTML/innerHTML 없음; 코드 스팬 우선·강조/링크(v0.59) 무회귀; 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-strike`·`line-through`) + ai-draft/spec_studio/doc-edit/ticket-body/board 무회귀.

### §11.50 이미지 하이라이트 — mdEmphasis 확장 (구문 모드) (ADR-0122)

**무엇을·why.** 인라인 강조/링크(v0.59)는 링크(`[text](url)`)만 색칠하고 이미지(`![alt](url)`)는 plain이었다. `mdEmphasis` 정규식 alternation에 이미지 대안 1개를 더한다(새 모드·툴바·함수·표면 없음 — 링크의 `!` 접두 변형·같은 클래스의 최소 확장).

**MD_INLINE 맨 끝 m5 (링크와 leftmost 분리).** `MD_INLINE`에 이미지 대안을 **맨 끝(m5)** 으로 추가: `(!\[[^\]\n]*\]\([^)\n]+\))`(비탐욕·한 라인·alt 빈 문자열 허용 `*`). cls 분기 `m[1] ? 'mc-md-link' : m[2] ? 'mc-md-strong' : m[3] ? 'mc-md-em' : m[4] ? 'mc-md-strike' : 'mc-md-image'`. `![alt](url)`은 `!`(index0)에서 시작하고 링크 대안은 `[`(index1)에서 시작하므로 **leftmost 매칭이 이미지를 통째로 우선**(링크가 `[alt](url)`만 떼가지 않음·맨 끝 추가로 기존 m1~m4 의미 보존). 미매칭/단일 `!`는 plain. sandbox 사전 검증(이미지 통째 매칭·빈 alt·링크 무회귀·링크/이미지 혼재 분리·강조+이미지+취소선 혼재).

**escape-first·마커 보존·`<img>` 아님 (핵심).** 이미지 토큰 `span.textContent`(마커 `!`·`[`·`](`·`)`·URL *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). **`<img>`로 렌더하지 않는다**(원격 fetch·주입·트래킹 픽셀 표면 회피 — 링크를 `<a>`로 안 만든 것과 동일 원칙). CSS `mc-md-image`(색만). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader·세 검토 표면(v0.60/v0.61/v0.62) 무변경.

**무회귀.** 코드 스팬(v0.58)·라인 토큰·굵게/기울임/링크(v0.59)·취소선(v0.63)·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 이미지는 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: `<img>` 렌더(원격 fetch)·각주·참조 스타일 링크/이미지·중첩·마커 제거 렌더·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`MD_INLINE` 이미지 대안(`(!\[[^\]`)·cls 분기 `'mc-md-image'`·span textContent(마커·URL 보존·escape-first); `<img>` 아님(`createElement('img')` 없음)·markdown→HTML/innerHTML 없음; 코드 스팬 우선·링크(v0.59)/취소선(v0.63) 무회귀; 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-image`) + ai-draft/spec_studio/doc-edit/ticket-body 무회귀.

### §11.51 각주 참조 하이라이트 — mdEmphasis 확장 (구문 모드) (ADR-0124)

**무엇을·why.** 이미지 하이라이트(v0.64)에 이어, `mdEmphasis` 정규식 alternation에 각주 참조(`[^id]`) 대안 1개를 더한다(새 모드·툴바·함수·표면 없음 — 단일 브래킷 토큰·같은 클래스의 최소 확장). v1은 인라인 각주 참조 *색칠*만 — 각주 정의 라인(`[^id]: ...`) 해석·번호 연결·정의 점프는 제외.

**MD_INLINE 맨 끝 m6 (링크 우선).** `MD_INLINE`에 각주 대안을 **맨 끝(m6)** 으로 추가: `(\[\^[^\]\n]+\])`(한 라인). cls 분기 `... : m[5] ? 'mc-md-image' : 'mc-md-footnote'`. **링크 대안(m1)이 alternation에서 먼저 시도**되므로 `[^id](url)`은 텍스트가 `^id`인 링크로 통째 잡히고, 각주는 `[^id]` 뒤에 `(url)`이 없을 때만 매칭(링크 우선 보존·맨 끝 추가로 기존 m1~m5 의미 보존). sandbox node 사전 검증(`[^1]`→각주·`[^1](x)`→링크·각주+링크 혼재). 단일 `[`·미매칭은 plain.

**escape-first·마커 보존·앵커 없음 (핵심).** 각주 토큰 `span.textContent`(마커 `[^`·`]` *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). **앵커/정의 점프 없음**(클릭→정의 네비게이션 표면 회피 — 링크를 `<a>`로 안 만든 것과 동일 원칙). CSS `mc-md-footnote`(색만). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader·세 검토 표면(v0.60/v0.61/v0.62) 무변경.

**무회귀.** 코드 스팬(v0.58)·라인 토큰·굵게/기울임/링크(v0.59)·취소선(v0.63)·이미지(v0.64)·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 각주는 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: 각주 정의 해석·점프 앵커·참조 스타일 링크/이미지·중첩·마커 제거 렌더·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`MD_INLINE` 각주 대안(`(\[\^[^\]`)·cls 분기 `'mc-md-footnote'`·span textContent(마커 보존·escape-first); 앵커 아님(`createElement('a')` 없음)·markdown→HTML/innerHTML 없음; 링크 우선(m1)·코드 스팬 우선·링크/이미지(v0.59/v0.64) 무회귀; 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-footnote`) + ai-draft/spec_studio/doc-edit/ticket-body 무회귀.

### §11.52 참조 스타일 링크/이미지 하이라이트 — mdEmphasis 확장 (구문 모드) (ADR-0126)

**무엇을·why.** 각주 참조(v0.65)에 이어, `mdEmphasis` 정규식 alternation에 참조 스타일 링크/이미지(`[text][ref]`·`![alt][ref]`·collapsed `[text][]`) 대안을 더한다(새 모드·툴바·함수·표면 없음). 이로써 흔한 인라인 markdown 토큰(강조·링크·이미지·취소선·각주·참조)이 구문 모드에서 닫힌다.

**MD_INLINE 맨 끝 m7/m8 (인라인 우선·한 클래스).** 참조 링크 m7 `(\[[^\]\n]+\]\[[^\]\n]*\])` + 참조 이미지 m8 `(!\[[^\]\n]*\]\[[^\]\n]*\])`를 **맨 끝**에 추가, cls 분기 끝에 `: 'mc-md-reflink'`(m7·m8 공통). 인라인 링크/이미지(m1/m5)는 `](url)`(둥근 괄호)을, 참조는 `][ref]`(대괄호)를 요구해 **두 번째 구분자가 달라 충돌 없음** — `[a](u)`는 인라인·`[a][b]`는 참조로 leftmost+순서 자연 해소(기존 m1~m6 의미 보존). 참조 이미지 `![a][b]`는 `!`(index0) 시작이라 통째. **bare shortcut `[text]` 단독은 미매칭**(임의 대괄호 과매칭 회피). sandbox node 사전 검증(full/collapsed/이미지-ref/인라인 무회귀/bare 미매칭).

**escape-first·마커 보존·앵커/`<img>` 없음 (핵심).** 참조 토큰 `span.textContent`(마커 `[`·`]`·`![` *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). **`<a>`/`<img>`·참조 정의 해석·점프 없음**(네비게이션·원격 fetch 표면 회피 — 인라인 링크/이미지와 동일 원칙). CSS `mc-md-reflink`(색만·점선 밑줄). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader·세 검토 표면(v0.60/v0.61/v0.62) 무변경.

**무회귀.** 코드 스팬(v0.58)·라인 토큰·인라인 링크/이미지(v0.59/v0.64)·각주(v0.65)·강조/취소선·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 참조는 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: bare shortcut 참조·참조 정의 해석·점프 앵커·`<a>`/`<img>` 렌더·중첩·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`MD_INLINE` 참조 대안(`\]\[[^\]`)·cls 분기 `'mc-md-reflink'`·span textContent(마커 보존·escape-first); 앵커/`<img>` 아님(`createElement('(a|img)')` 없음)·markdown→HTML/innerHTML 없음; 인라인 우선(m1/m5)·코드 스팬 우선·링크/이미지/각주(v0.59/v0.64/v0.65) 무회귀; 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-reflink`) + ai-draft/spec_studio/doc-edit/ticket-body 무회귀.

### §11.53 중첩 강조(삼중 마커) 하이라이트 — mdEmphasis 확장 (구문 모드) (ADR-0128)

**무엇을·why.** 인라인 토큰 시리즈(v0.63~v0.66)가 닫힌 뒤, 사용자 선택으로 중첩 강조에 진입. 모호·재귀 영역이라 v1은 **삼중 마커 결합 강조(`***text***`·`___text___`, bold+italic) 단일 플랫 토큰**으로만 좁힌다 — 마커 섞인 임의 중첩(`**_x_**` 등 재귀)은 명시 제외. `***x***`는 현재 strong/em 매칭 못 해 plain이라 순수 가산.

**MD_INLINE 맨 끝 m9 (충돌 없음·무재귀).** `MD_INLINE`에 삼중 대안을 **맨 끝(m9)** 으로 추가: `(\*\*\*[^*\n]+\*\*\*|___[^_\n]+___)`. cls 분기 `... : (m[7] || m[8]) ? 'mc-md-reflink' : 'mc-md-strongem'`. strong(`\*\*[^*]..`)·em(`\*[^*]..`)은 `***x***`의 *세 번째 마커 문자* 때문에 매칭 실패 → 충돌 없이 plain이던 자리만 가산(맨 끝 추가로 기존 m1~m8 의미 보존). 전체 `***...***`를 한 토큰으로 색칠(내부 비파싱·재귀 없음). `****`(내부 텍스트 없음)·미매칭은 plain. sandbox node 사전 검증(삼중·strong·em·혼재·`****`).

**escape-first·마커 보존·무재귀 (핵심).** 삼중 토큰 `span.textContent`(마커 `***`·`___` *유지*하고 색칠만 — markdown→HTML 변환 없음, ADR-0042). 재귀 파서 없음(내부를 다시 토크나이즈하지 않음). CSS `mc-md-strongem`(`font-weight:700; font-style:italic`). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음. ai_draft·쓰기 게이트·MC reader·세 검토 표면(v0.60/v0.61/v0.62) 무변경.

**무회귀.** 코드 스팬(v0.58)·라인 토큰·strong/em(v0.59)·링크/이미지/각주/참조(v0.59~v0.66)·취소선(v0.63)·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 삼중은 "구문" 모드의 코드 밖 plain 세그먼트에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: 마커 섞인 임의 중첩(`**_x_**` 등)·재귀 파싱·마커 제거 렌더·범용 언어 하이라이트.

- 회귀: `tests/draft-diff.bats`(`MD_INLINE` 삼중 대안(`(\*\*\*[^*`)·cls 분기 `'mc-md-strongem'`·span textContent(마커 보존·escape-first); 재귀/innerHTML 없음; strong/em(v0.59)·참조(v0.66)·코드 스팬 우선 무회귀; 라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-strongem`·`italic`) + ai-draft/spec_studio/doc-edit/ticket-body 무회귀.

### §11.54 인터뷰 산출 비교 — 턴별 AI 산출 옵트인 읽기 전용 diff (ADR-0130)

**무엇을·why.** 옵트인 변경 검토 패턴(master-spec v0.60·doc_edit v0.61·ticket-body v0.62·`__mcDraftPreview`)을 **네 번째 표면 — AI 인터뷰(ADR-0078)** 산출 비교로 확장한다. 인터뷰는 유한 턴·무상태로 턴마다 AI 산출을 로그에 append하지만, 턴 간 산출이 어떻게 수렴/변화했는지 볼 수단이 없었다.

**옵트인·무상태 보존 (핵심).** 인터뷰 액션에 "산출 비교" 버튼(`data-iv-compare`) + 전용 read-only 컨테이너(`data-iv-compare-out`). 턴별 AI 산출을 인메모리 배열 `aiOutputs`(인터뷰 transcript와 동일하게 *패널 JS에만*·서버 미전송·미영속·`reset`이 비움)에 push한다. 클릭 시 기존 클라이언트 측 `__mcDraftPreview`로 **직전 턴(`len-2`) vs 최신 턴(`len-1`)** 산출 diff를 표시(2개 미만이면 토스트 안내). **인터뷰 send/턴/서버 캡(ADR-0078)·`ai_draft` exec·무상태·자동 append 흐름은 무변경** — 자동 흐름은 여전히 diff에 라우팅되지 않고(비교는 *수동 옵트인*·게이트 직교).

**무표면·읽기 전용.** 클라이언트 측 렌더 — 새 exec/스크립트/writer/파일/요청·서버 상태(`iv_compare` 같은 새 명령) 없음. 검토용 노트로 복원. proposer≠writer·escape-first(ADR-0042·`__mcDraftPreview`가 span.textContent). localhost(T099)·인증(T097)·비-localhost 패널 부재(기존)·모바일 부재.

**무회귀.** 인터뷰 send/턴/서버 캡·`ai_draft`(target interview) exec·무상태(미영속)·세 검토 표면(v0.60~v0.62)·하이라이트(v0.63~v0.67·draft-diff) 무변경. 비교는 가산·게이트 직교.

**v1 제외(별도 결정)**: 산출 영속(로그/파일/서버 상태)·턴별 자동 diff·서버 측 diff·임의 두 턴 선택 비교.

- 회귀: `tests/draft-diff.bats`("산출 비교" 버튼·전용 컨테이너(localhost)·비-localhost 부재; `__mcDraftPreview(compareOut ...)` 재사용·`aiOutputs.push`·`aiOutputs.length = 0`(reset 비움)·새 명령 없음; 인터뷰 send/턴/서버 캡·`target: 'interview'` exec·자동 append 흐름 무회귀) + ai-draft/spec_studio/doc-edit/ticket-body/board 무회귀.

### §11.55 prune 보존 미리보기 — 읽기 전용 dry-run/manifest (삭제 없음) (ADR-0133)

**무엇을·why.** 이력·스냅샷 prune 전체 정책(ADR-0132)은 파괴적(삭제)이라 별도 승인을 기다린다. 그 전에 **dry-run/manifest 읽기 전용 절반만**(B-1) 분리해, 삭제 표면을 닫아둔 채 보존 정책의 *가시성*과 후속 confirm 게이트의 *검증 기반(manifest-sha)* 을 먼저 얻는다.

**순수 reader·삭제 코드 부재 (핵심).** `scripts/prune_preview.sh`(`snapshots`/`logs` 서브커맨드)는 snapshot_ls.sh 인벤토리를 재사용해 보존 정책(keep-last-N≥floor 5·옵션 `--older-than`)을 적용, 각 `.vN`·state 로그 행을 **보존(keep) vs 삭제후보(candidate)** 로 *분류만* 하고 manifest(파일·행·바이트·**sha256**)를 출력한다. **삭제·쓰기·git 변경·`.bak` 전무**(`rm`/`git`/`--confirm` 부재 — bats가 검증)·실행 전후 파일 byte-동일. 경로 안전(절대·`..`·하위·티켓·ADR·심볼릭·NUL 거부)은 snapshot_ls.sh와 동일. manifest-sha는 결정적(같은 입력 같은 sha).

**MC reader/dispatcher 불변·읽기 전용 노출.** exec `prune_preview`(no ticketId·localhost 전용·**비-localhost 403**·T099·인증 T097)가 reader를 호출만. Insights에 *보존 미리보기* 읽기 전용 패널(스냅샷/로그 버튼 → manifest·sha를 `textContent`로 표시·escape-safe)·**삭제 버튼·confirm UI 없음**·localhost 전용 렌더. manifest-sha는 *계산·표시만*, 아무 행동도 안 함.

**무회귀.** snapshot_doc.sh·doc_edit `--snapshot`·snapshot_ls.sh·요율/사용량 기록·기존 인벤토리/요율 패널 무변경. 정직 경계(ADR-0050): manifest=측정 사실(파일·바이트·sha)·가정 없음.

**v1 제외(전부 T216·ADR-0132·파괴적·별도 승인)**: 실제 삭제·`--confirm`/`--reason`/`--manifest-sha` 소비·`git rm`·로그 `.bak`/tail 재작성·UI 삭제 버튼·자동 prune.

- 회귀: `tests/prune-preview.bats`(keep-last-N·floor 분류·로그 행 분류·**읽기 전용 fs byte-동일**·manifest sha 결정성·**삭제 코드 부재**(`rm`/`git`/`--confirm` 없음)·경로 안전; exec localhost 200+manifest·비-localhost 403; Insights 패널 localhost 유·비-localhost 부재) + exec/insights/snapshot-ls/snapshot-inventory/draft-diff/ticket-body 무회귀.

### §11.56 능력 맵 — 누적 능력 자기문서화 + 드리프트 검증 (ADR-0135)

**무엇을·why.** 보수적 백로그가 소진된 시점에, 새 기능 대신 v0.58~v0.69에 걸쳐 누적된 횡단 능력을 *하나의 능력 맵으로 자기문서화*하고 그 횡단 불변을 *단일 드리프트 테스트로 실행 가능 스펙화*한다. **운영 코드(server.mjs·writer·ui.css)는 미접촉** — tests + 이 절(runbook)만.

**능력 맵 (측정 사실·현존 클래스/표면).**

- **구문 모드 토큰 16종(`mc-md-*`)** — 인라인 강조 계열: `mc-md-strong`/`em`(v0.59)·`mc-md-link`(v0.59)·`mc-md-strike`(v0.63)·`mc-md-image`(v0.64)·`mc-md-footnote`(v0.65)·`mc-md-reflink`(v0.66)·`mc-md-strongem`(v0.67); 코드 스팬 `mc-md-codespan`(v0.58); 라인 토큰 `mc-md-heading`/`list`/`quote`/`code`/`table`/`h`/`line`(v0.58). server.mjs(cls 분기/`mdSpan`) ↔ ui.css 집합 *정확히 동일*.
- **읽기 전용 비교/검토 4표면** — master-spec(`data-spec-review`·v0.60)·doc_edit(`data-doc-review`·v0.61)·ticket-body(`data-ticket-body-review`·v0.62)·interview(`data-iv-compare`·v0.68). 모두 클라이언트 측 `window.__mcDraftPreview` 재사용(AI 초안 proposer 3 + 검토 3 + 인터뷰 비교 1).
- **prune 보존 미리보기**(v0.69·ADR-0133) — 읽기 전용 dry-run/manifest(삭제 코드 부재). 파괴적 삭제는 T216/ADR-0132로 닫힘.
- **전역 불변** — escape-first(ADR-0042·`innerHTML` 부재)·proposer≠writer·localhost(T099)·인증(T097)·정직 경계(ADR-0050).

**실행 가능한 스펙 = `tests/capability-map.bats`.** 횡단 드리프트를 한곳에서 잡는다: (i) `mc-md-*` 토큰 *server.mjs ↔ ui.css 집합 동일*(차집합 0 → JS-only/CSS-only 토큰 시 실패), (ii) 검토/비교 4표면 마커 전부 + `__mcDraftPreview` 재사용, (iii) escape-first 전역(`innerHTML` 부재·`run`+status로 *enforced*), (iv) prune 미리보기 읽기 전용 교차확인. 모든 assertion은 enforced(부정 검사는 `run`+status — bash `set -e`가 `!`-부정 명령을 면제하므로 bare `! grep`는 무력).

**무회귀.** 운영 코드 무변경(`git diff`에 server.mjs/writer/ui.css 없음). 기존 분산 테스트(draft-diff·prune-preview·ai-draft·doc-edit·ticket-body·spec_studio) 무변경·무삭제. 능력 맵=측정 사실·가정 없음.

- 회귀: `tests/capability-map.bats`(토큰 집합 동일·16종 존재·4표면·`__mcDraftPreview` 재사용·`innerHTML` 부재(enforced)·prune 읽기 전용 교차확인·러ンbook 능력 맵 포인터) + 전체 스위트 무회귀.

### §11.57 무력 부정 assertion 강화 — enforced-negation (phase 1) (ADR-0137)

**무엇을·why.** §11.56(ADR-0136 §7.2)의 발견 — bash `set -e`(bats 기본)는 `!`-부정 명령을 errexit에서 *면제*하므로, `@test`의 마지막 줄이 아닌 bare `! grep`/`! ( cmd )`/`! echo|grep` 부정 assertion은 *무력*(검증하는 척하나 실패하지 않음) — 의 비파괴 후속. 감사 결과 `tests/*.bats`에 bare 부정 **167개**. phase 1로 MC 표면 5파일을 enforced 형태로 변환·잠근다. **운영 코드 미접촉** — tests + 이 절만.

**enforced 형태·phase 1 (5파일).** bare `! CMD [# c]` → `if CMD; then return 1; fi [# c]`(명령 verbatim·의미 보존·CMD 성공 시 실제 실패). 변환·잠금: `draft-diff.bats`(19)·`doc-edit.bats`(13)·`ticket-body.bats`(10)·`mission_control_spec_studio.bats`(7)·`prune-preview.bats`(4) = 53개. 나머지 27파일은 phase 2+.

**per-file 잠금 lint.** `tests/lint-negation.bats`가 잠금 allowlist(5파일)에 대해 bare `^\s*!\s` 라인 0을 enforced 검증(주입 시 실패·self-check 포함). 새 bare `! ` 유입 차단·allowlist 단조 증가.

**findings (정직 surface·올바른 수정·은폐 금지).**

- **`mission_control_spec_studio.bats` "spec is read-only: no write POST"** — *거짓 assertion이었다*. localhost `/spec`(Spec Studio)은 의도적으로 게이트된 쓰기 표면(spec_edit·ADR-0068·doc_edit·ADR-0066·ai_draft)을 노출하므로 write POST 4개가 존재한다. bare `! grep`가 무력이라 통과했을 뿐. **정직 수정**: 실제 불변으로 교체 — 원시 `<form>` 없음·외부 `<script src=>` 없음·**모든 write POST가 단일 게이트 dispatch `/api/exec`로 funnel**(다른 쓰기 엔드포인트 없음). 더 참되고 강한 assertion.
- **`prune-preview.bats` "no delete code path"** — `! grep -- '--confirm'`/`! grep rm`이 스크립트 *주석*("NO --confirm")과 mktemp 정리(`rm -f`)를 잡아 무력+거짓이었다. **정직 수정**: 주석 제외 grep(`grep -vE '^\s*#'`) + 임시파일 정리(`MANIFEST_TMP`) 제외로 *진짜 불변*(비-주석에 git/`--confirm`/저장소 rm 없음)을 enforced.

**무회귀.** 운영 코드 무변경(server.mjs·writer·ui.css 미접촉). 변환된 5파일 의미 보존(전수 green)·findings는 더 강한 참 assertion으로 교체. 나머지 27파일·phase 2+ 무변경.

- 회귀: 변환 5파일 전수 green(bare `! ` 0) + `tests/lint-negation.bats`(잠금 5파일 bare 0·self-check) + capability-map/전체 스위트 무회귀.

### §11.58 enforced-negation phase 2 — 5파일 추가 변환 + lint 확장 (ADR-0139)

**무엇을·why.** phase 1(§11.57·v0.71)의 직접 연장 — 무력 부정 assertion(bash `set -e`의 `!`-면제)을 *검증·경계 핵심* 5파일에서 추가로 enforced 변환·잠근다. **운영 코드 미접촉** — tests + 이 절만.

**phase 2 (5파일·43개).** `ai-draft.bats`(17·reject-guard + 비-localhost + 소스 격리)·`new-ticket.bats`(7·입력 검증 거부)·`snapshot-doc.bats`(8·경로 안전 거부)·`mission_control_board.bats`(7·form/post 부재·필터-exec 분리)·`mission_control_insights.bats`(4)의 bare `! CMD` → `if CMD; then return 1; fi`(명령 verbatim·의미 보존). `tests/lint-negation.bats` LOCKED allowlist += 5(총 **10파일** bare `! ` 0 enforced).

**findings (정직 surface·더 강한 참 assertion으로 교체·은폐 금지).**

- **`mission_control_insights.bats` "no write POST"는 거짓이었다** — v0.69(ADR-0133)에서 Insights에 *보존 미리보기* 패널을 더하며 `fetch('/api/exec', {method:'POST'})`가 추가됐다. bare `! grep`가 무력이라 통과했을 뿐. **정직 수정**: spec_studio(v0.71)와 동일하게 실제 불변 — 원시 `<form>` 없음·외부 `<script src=>` 없음·모든 write POST가 단일 게이트 `/api/exec`로 funnel.
- **`ai-draft.bats` "never uses bypassPermissions"의 `! grep`** 은 스크립트 *주석*("NEVER bypassPermissions here")을 잡아 무력+거짓이었다. **정직 수정**: 주석 제외 grep(`grep -vE '^\s*#'`)으로 *코드 경로*에 bypassPermissions 부재(진짜 read-only 불변)를 enforced. 금지를 문서화한 주석은 유지.

**무회귀.** 운영 코드 무변경(server.mjs·writer·ui.css 미접촉). 변환 5파일 의미 보존(전수 green). 나머지 22파일·phase 3+ 무변경.

- 회귀: 변환 5파일 전수 green(bare `! ` 0) + `tests/lint-negation.bats`(잠금 **10파일** bare 0·self-check) + phase-1 잠금/capability-map/전체 스위트 무회귀.

### §11.59 enforced-negation phase 3 — 5파일 추가 변환 + lint 15파일 잠금 (ADR-0141)

**무엇을·why.** phase 1(§11.57·v0.71)·phase 2(§11.58·v0.72)의 직접 연장 — 무력 부정 assertion(bash `set -e`의 `!`-면제)을 *검증·게이트·정직 핵심* 5파일에서 추가로 enforced 변환·잠근다. **운영 코드 미접촉** — tests + 이 절만.

**phase 3 (5파일·42개).** `rate-config.bats`(18·요율/예산/모델 reject + 정직 라벨)·`spec-edit.bats`(11·강한 게이트 reject + 소스 격리)·`mission_control_library.bats`(5)·`mission_control_pwa.bats`(5·SW 캐시 경계)·`mission_control_autonomy.bats`(3)의 bare `! CMD` → `if CMD; then return 1; fi`(명령 verbatim·의미 보존). `tests/lint-negation.bats` LOCKED allowlist += 5(총 **15파일** bare `! ` 0 enforced).

**findings (정직 surface·더 강한 참 assertion으로 교체·은폐 금지).**

- **`mission_control_pwa.bats` "excludes api data"의 `! grep "/api/"`는 거짓이었다** — SW는 *주석*·토큰 renew URL(`'/api'+'/tokens/renew'`)·Authorization 주입에서 `/api`를 정당하게 *참조*한다. bare `! grep`가 무력이라 통과했을 뿐. **정직 수정**: 실제 R5 불변 — *precache 목록(`STATIC_CACHE_URLS`)이 `/api`·페이지 루트(`"/"`)를 제외*(런타임 `cache.put('/api')` 부재는 별도 테스트가 커버). precache 목록 한정으로 좁힘.
- **변환 시 발견된 변환기 버그**: 단일 공백 주석(` # comment`)이 `\s{2,}#` splitter를 비껴가 `; then return 1; fi`가 주석 뒤로 붙어 spec-edit가 파싱 실패했다(`bats-gather-tests`). **수정**: 해당 1행(spec-edit:58)의 주석을 `fi` 뒤로 이동. (phase 1/2엔 단일 공백 주석 부정 라인이 없어 미발생.)

**무회귀.** 운영 코드 무변경. 변환 5파일 의미 보존(전수 green). 나머지 17파일·phase 4+ 무변경.

- 회귀: 변환 5파일 전수 green(bare `! ` 0) + `tests/lint-negation.bats`(잠금 **15파일** bare 0·self-check) + phase-1/2 잠금·capability-map·전체 스위트 무회귀.

### §11.60 enforced-negation phase 4 — 남은 17파일 마무리·lint 저장소 전역 (아크 종료) (ADR-0143)

**무엇을·why.** phase 1~3(§11.57~59·v0.71~v0.73)의 마무리 — 남은 17파일(bare 부정 29개·전부 소형)을 한 배치로 enforced 변환하고, lint를 *allowlist → 저장소 전역*으로 전환해 하니스 하드닝 아크를 닫는다. **운영 코드 미접촉** — tests + 이 절만.

**전수 변환 + lint 전역.** 17파일(autopilot-grant·backfill_completed_at·headless_diagnostics·headless_idle_watchdog·notifications·sessions_stream·skeleton·mobile-e2e·pause_timeout_clock·per-ticket-tokens·run-headless-token-usage·run-loop-mode-switch·session_ctl_abort·snapshot-inventory-surface·snapshot-ls·ticket-edit·ticket-lifecycle)의 bare `! CMD` → `if CMD; then return 1; fi`(명령 verbatim·의미 보존). 이제 **모든 `tests/*.bats`가 bare `! ` 0** — `tests/lint-negation.bats`를 *전수 스캔*(`tests/*.bats` bare `^\s*!\s` 0)으로 전환(allowlist 수동 유지 종료·self-check 유지). 변환 직후 전수 파싱+green으로 변환기 버그(단일 공백 주석) 가드(이번엔 해당 라인 없음·재발 0).

**findings.** 이번 17파일에서 *새 finding 없음* — 전부 reject-guard·소스 grep·경계 부재로 참이었다(phase 1~3에서 주석/참조 catch 패턴은 표면 집중형이라 소형 유틸 테스트엔 적었음). 의미 보존·전수 green.

**무회귀.** 운영 코드 무변경. 변환 17파일 의미 보존(전수 green·단, headless_diagnostics 1·skeleton 4는 *샌드박스 전용 환경 실패*[stat 포맷·pidfile mount-unlink]로 host 미재현·변환 라인과 무관[서버 미기동/stat 단계에서 실패]). phase 1~3 잠금·capability-map·전체 스위트 무회귀.

**아크 종료.** enforced-negation이 *저장소 전역 불변*이 됐다(32/32 파일·bare `! ` 0). 이후 어느 테스트 파일에 새 bare `! ` 부정이 들어와도 `lint-negation.bats`가 차단한다.

- 회귀: 17파일 전수 green(bare `! ` 0·sandbox 전용 env 실패 제외) + `tests/lint-negation.bats`(저장소 전역 `tests/*.bats` bare 0·self-check) + phase 1~3 잠금·capability-map·전체 스위트 무회귀.

### §11.61 인터뷰 임의 두 턴 비교 — 산출 비교 turn 선택 확장 (ADR-0145)

**무엇을·why.** 하니스 하드닝 아크(v0.71~v0.74) 이후 첫 기능 라운드. 인터뷰 산출 비교(v0.68·ADR-0130)는 *직전 vs 최신* 고정 쌍이었다 — 턴1 vs 턴3(중간 건너뛰기)을 볼 수 없었다. 이 라운드는 *임의 두 턴 선택*으로 확장한다(같은 옵트인·무상태·`__mcDraftPreview` 재사용 패턴).

**두 turn select·인메모리 재구성 (핵심).** "산출 비교" 옆에 두 `<select>`(`data-iv-cmp-a`·`data-iv-cmp-b`). `refreshCmpOptions()`가 턴 도착(`aiOutputs.push`) 직후·reset에서 두 select 옵션을 *인메모리 `aiOutputs`* 길이만큼 재생성(escape-first: `createElement('option')`+`o.textContent='턴 N'`·innerHTML 없음). **기본 선택 A=len-2·B=len-1**로 v0.68 직전 vs 최신을 보존. "산출 비교"는 선택 쌍 `__mcDraftPreview(compareOut, aiOutputs[a], aiOutputs[b])`로 diff·노트 "턴 a vs 턴 b"·2개 미만 토스트·범위 가드.

**무상태·무표면.** 옵션은 `aiOutputs`(인메모리·ADR-0078 무상태)에서만 재구성·서버 미전송·reset 비움. 새 exec/스크립트/writer/파일/요청·서버 상태(`iv_compare` 같은 새 명령) 없음. 인터뷰 send/턴/서버 캡·`ai_draft`(target interview) exec·자동 흐름 무변경(선택·비교는 옵트인·게이트 직교). proposer≠writer·읽기 전용·escape-first(ADR-0042)·localhost(T099)·인증(T097)·모바일 부재.

**무회귀.** v0.68 동작(기본 직전/최신·`aiOutputs.push`·reset 비움·`__mcDraftPreview(compareOut`·새 명령 없음) 보존. 인터뷰 흐름·세 검토 표면·하이라이트 무변경.

**v1 제외(별도 결정)**: 산출 영속·서버 측 diff·자유 텍스트 인덱스 입력.

- 회귀: `tests/draft-diff.bats`(두 select `data-iv-cmp-a/b`·`refreshCmpOptions`(인메모리·`createElement('option')`·`textContent`)·선택 쌍 `__mcDraftPreview(compareOut, aiOutputs[a], aiOutputs[b])`·기본 A=len-2/B=len-1·새 명령 없음·비-localhost 부재; v0.68 무회귀) + ai-draft/board/capability-map/lint-negation(저장소 전역) 무회귀.

### §11.62 태스크리스트 체크박스 하이라이트 — mdRender 라인 토큰 확장 (구문 모드) (ADR-0147)

**무엇을·why.** 구문 모드 라인 토큰(v0.58)에 markdown 태스크리스트 체크박스(`- [ ] 할 일` / `- [x] 완료`)를 더한다. 목록 마커(`mc-md-list`) 뒤 plain이던 `[ ]`/`[x]` 표식을 새 `mc-md-task` 토큰으로 색칠(새 모드·툴바·표면 없음).

**mdRender 목록 분기 확장.** 목록 매칭(`lm`) 후 remainder 선두를 `cm = restL.match(/^(\[[ xX]\])(\s)/)`로 검사해, 체크박스면 `mdSpan('mc-md-task', cm[1])`로 분리 색칠하고 나머지를 `mdInline`로 라우팅. **목록 선두·공백 동반만** — 본문 중간 `[x]`·공백 없는 `[]`·목록 아닌 라인은 plain(거짓 양성 회피). sandbox node 사전 검증(`[ ]`/`[x]`/`[X]` 매치·no-space/mid/no-trailing 미매치).

**escape-first·마커 보존·능력 맵 (핵심).** 체크박스 토큰 `span.textContent`(마커 `[`·`]`·내부 문자 유지·markdown→HTML 없음, ADR-0042). `mc-md-task`를 **server.mjs·ui.css 양쪽에 추가**해 능력 맵(ADR-0135) 토큰 집합 동일(server↔css·차집합 0·17↔17) 유지(capability-map.bats green). 클라이언트 측 렌더 — 새 exec/writer/파일/요청 없음.

**무회귀.** 목록 마커(`mc-md-list`)·인라인(v0.59~v0.67)·코드 스팬·제목/인용/펜스·diff(v0.44)·단어(v0.47)·문자(v0.49)·전문·기본 모드(diff) 무변경. 체크박스는 "구문" 모드 목록 항목 선두에만. markdown 전용·인터뷰 제외 유지.

**v1 제외(별도 결정)**: `<input type=checkbox>` 렌더(상호작용)·임의 위치 `[x]`·중첩·체크박스 토글.

- 회귀: `tests/draft-diff.bats`(목록 분기 체크박스(`[ xX]`)·`mdSpan('mc-md-task'`·마커 보존·escape-first(innerHTML 없음); `mc-md-list`·라인 토큰·diff/단어/문자/전문·기본 diff 무회귀; ui.css `mc-md-task`) + capability-map(server↔css 집합 동일·17 토큰)·lint-negation(저장소 전역)·ai-draft/board 무회귀.

### §11.63 새 프로젝트 부트스트랩 Phase 0 — init_new_project.sh 라이브 승격 (ADR-0149)

**무엇을·why.** "웹에서 대상 폴더 지정 → 클린 추출"(ADR-0149) 3단계 중 Phase 0. 클린 추출 위저드(`init_new_project.sh`)와 적용 가이드가 `_drafts`에만 있어 README·quickstart가 깨진 경로를 가리켰다 — 이를 라이브로 승격해 exec(T235)·웹 패널(T236)이 부를 수 있는 기반을 만든다.

**승격.** `_drafts/scripts/init_new_project.sh` → `scripts/init_new_project.sh`(실행권한), `_drafts/새_프로젝트_적용_가이드.{md,html}` → 루트. 승격만으로 README(L66/71)·quickstart(L268/272) 참조가 실재 경로를 가리킨다(별도 편집 불요). SOURCE 불변·argv 안전·SOURCE/내부 대상 거부·`--force` 게이트는 스크립트 기존 가드 유지.

**자체 발견 2건(정직).**
- **결함 1(수정).** `run_checks.sh`가 `mission-control/` 없이도 Mission Control UI 검사(`check_ui_requirements.sh`는 서버를 띄움)를 돌려, 추출 레포에서 호스트에서도 실패했다. → `[ -d mission-control ]` 가드 추가(Hephaestus 동작 불변·추출 레포는 건너뜀).
- **결함 2(수정·복사 매니페스트).** 클린 추출이 `tests/`(66개 중 32개 mission-control 의존)를 통째로 복사해, bats 설치된 호스트의 추출 레포에서 검증이 깨졌다("즉시 검증 통과" 거짓). → 위저드가 product 테스트를 비복사하고 `tests/`는 **빈 스켈레톤 + 통과하는 starter `smoke.bats`** 만 두도록 수정. tests/는 누적물이라는 원칙과 정합.

**검증.** 추출 레포가 bats 설치 환경에서 **전체 `run_checks` green**(smoke 3건만 실행) 확인. 본체 node 116/116·lint 0·`tests/init-new-project.bats` 10/10(dry-run 매니페스트·SOURCE/내부 거부·`--force` 게이트·스택별 `run_checks.local.sh`·product 테스트 비복사·추출 레포 run_checks 0).

- 회귀: `tests/init-new-project.bats`(신규 10건) + 추출 레포 run_checks(bats 설치 시 smoke만·green). 후속: T235(exec 화이트리스트)·T236(웹 패널).

### §11.64 새 프로젝트 부트스트랩 Phase 1 — exec 화이트리스트 init_new_project (ADR-0149)

**무엇을·why.** ADR-0149 3단계 중 Phase 1. Mission Control이 새 프로젝트 부트스트랩을 디스패치하도록 `execPlan`에 `init_new_project` 분기를 추가한다(T236 웹 패널의 백엔드). 외부 폴더에 새 레포를 만드는 명령이라 localhost 전용·미리보기 우선으로 좁게 잠근다.

**분기(server.mjs execPlan).** payload `{ targetPath, name?, stack?, force?, dryRun? }`. 인자는 **argv 배열**(`[targetPath, '--stack', stack, ...]`)로만 — 셸 문자열 보간·`sh -c` 없음(주입 차단). 검증: `targetPath` 필수·≤4096·제어문자 거부, `resolve(ROOT, targetPath)`가 ROOT 자신·내부면 거부(`outside this repository` — SOURCE 불변 방어, 스크립트 가드와 이중), `name` ≤64·`[A-Za-z0-9 ._-]`, `stack` ∈ {node,python,go,rust,none}. **`dryRun` 기본 true** — 실제 추출은 명시 `dryRun:false`만(미리보기 우선, ADR-0133 패턴).

**localhost 전용(T099).** `init_new_project`는 `NON_LOCALHOST_EXEC_ALLOW`(=`approve`만)에 없으므로 비-localhost는 `execScopeDecision`이 upstream에서 403. token-auth.mjs 무변경(구조적 default-deny).

**무회귀.** 기존 15개 exec 분기·세 검토 표면·구문/능력 맵 무변경. `init_new_project`는 ticketId 없는 명령이라 prune_preview처럼 ticketId 가드 **앞**에 배치.

**검증.** node 117/117(r6-security-boundaries에 `init_new_project` 비-localhost 403 대조 추가)·`tests/init-new-project-exec.bats` 6/6(localhost dryRun 200+매니페스트·복사 0 / 누락·내부(`.`)·over-length·stack 밖 400 / 비-localhost 403)·capability-map 7/7·init-new-project 10/10 무회귀.

- 회귀: `tests/init-new-project-exec.bats`(신규 6건·HTTP 통합) + `mission-control/r6-security-boundaries.test.mjs`(+1 scope). 후속: T236(웹 패널·미리보기→생성 UI).

### §11.65 새 프로젝트 부트스트랩 Phase 2 — Mission Control "새 프로젝트" 패널 (ADR-0149)

**무엇을·why.** ADR-0149 3단계의 마지막. 사용자의 원래 요청("웹에서 대상 폴더 지정 → 시작")을 완성한다 — Spec 페이지에 localhost 전용 "새 프로젝트" 패널을 두고, 경로/코드명/스택 입력 + **미리보기(dry-run) → 생성(confirm)** 으로 T235 exec를 디스패치한다.

**패널(server.mjs renderNewProjectPanel).** spec_edit 패널과 동형. 입력: 대상 경로(≤4096)·코드명(선택·≤64)·스택 select(none/node/python/go/rust). 버튼 2개: "미리보기(dry-run)"(`dryRun:true` → 읽기 전용 매니페스트)·"생성"(`window.confirm` → `dryRun:false`). 출력은 **escape-first**(`outBody.textContent` — innerHTML 없음, ADR-0042). 비-localhost는 패널 미렌더(`if (!isLocalhost) return ''`) — exec도 403(T099)이라 이중.

**GUI 폴더 다이얼로그 비채택.** 브라우저는 임의 OS 폴더를 골라 스크립트를 실행할 수 없고, 서버측 디렉터리 브라우저는 단일-레포 reader 원칙(ROOT 밖 읽기)을 깬다 → **경로 입력 + 서버측 검증**(T235)만. SOURCE 불변(원복 = 대상 폴더 삭제)을 패널 문구로도 고지.

**무회귀.** 기존 패널(master-spec·doc_edit)·15+1 exec·세 검토 표면·구문/능력 맵 무변경. 새 패널은 Spec 페이지 localhost 분기에만 가산.

**검증.** node 117/117·`tests/new-project-panel.bats` 3/3(localhost 패널 present·preview/create 버튼 / 비-localhost 미노출 / escape-first textContent·innerHTML 없음)·init-new-project-exec 6/6·capability-map 7/7(전역 no-innerHTML 포함) 무회귀.

- 회귀: `tests/new-project-panel.bats`(신규 3건). ADR-0149 3단계(T234·T235·T236) 완료 — 웹에서 대상 폴더 지정 → 클린 추출 부트스트랩이 가동.

### §11.66 새 프로젝트 패널 --force 옵션 (UI-only) (ADR-0151)

**무엇을·why.** 패널은 비어있지 않은 대상에서 막다른 길(오류만·우회 불가)이었다. T235 exec는 이미 `force`를 받으므로(`payload.force === true → --force`) **UI 노출만** 하면 된다 — 새 exec/스크립트 변경 없음.

**패널·스크립트(server.mjs).** 스택 select 아래 옵트인 체크박스 `data-np-force`(기본 off). `dispatch`가 체크 시 `payload.force = true`(미체크 시 미전송 → 기존 동작 보존). 생성 confirm 문구에 force 체크 시 "비어있지 않은 대상이면 기존 파일에 덮어쓸 수 있음" 경고 한 줄.

**안전.** `--force`는 비어있지 않음 가드만 푼다(스크립트 `cp -R` 병합 — 파일 삭제 아님). 옵트인·기본 off·dry-run은 force와 무관하게 먼저 미리보기 가능·SOURCE 불변(원복 = 대상 폴더 삭제). escape-first·비-localhost 미렌더·exec 403(T099) 무변경.

**무회귀.** exec 분기·`init_new_project.sh`·검증 스택·경로/코드명/스택·미리보기→생성·세 검토 표면·능력 맵 무변경. 패널 입력 1개 가산.

**검증.** node 117/117·`tests/new-project-panel.bats` 4/4(+force 체크박스 present·기본 off·script 옵트인 전송)·init-new-project-exec 6/6·capability-map 7/7(전역 no-innerHTML 포함) 무회귀.

- 회귀: `tests/new-project-panel.bats`(+1, force 체크박스). 후속 후보: 서버측 디렉터리 브라우저·다중 레포 관제·T216·T108.

### §11.67 새 프로젝트 패널 참조 문서 옵션 (--with-onboarding / --with-glossary) (ADR-0153)

**무엇을·why.** `init_new_project.sh`는 `--with-onboarding`(quickstart)·`--with-glossary`(glossary)를 지원하지만 exec·패널이 노출하지 않았다. force 라운드와 동형이되, 이번엔 exec 분기에 boolean 2개를 추가한다(추가 복사뿐·SOURCE 불변).

**exec(server.mjs execPlan).** `withOnboarding`/`withGlossary`(boolean `=== true`만) → argv `--with-onboarding`/`--with-glossary` push + cliCommand 반영. targetPath/stack/name/force/dryRun 순서·검증 무변경·argv 배열 유지.

**패널·스크립트.** force 체크박스 아래 옵트인 체크박스 2개 `data-np-onboarding`·`data-np-glossary`(기본 off). `dispatch`가 체크 시 `payload.withOnboarding`/`withGlossary = true`(미체크 시 미전송).

**안전.** 두 플래그는 TARGET에 문서를 *더* 복사할 뿐(삭제·덮어쓰기 아님)·SOURCE 불변·dryRun 기본 true·비-localhost 403(`NON_LOCALHOST_EXEC_ALLOW` 무변경, T099)·escape-first.

**무회귀.** `init_new_project.sh`·검증 스택·경로/코드명/스택/force·미리보기→생성·세 검토 표면·능력 맵 무변경.

**검증.** node 117/117·`tests/init-new-project-exec.bats` 8/8(+flag 전달·기본 off 매니페스트 onboarding=0/glossary=0)·`tests/new-project-panel.bats` 5/5(+참조 문서 체크박스 present·기본 off·옵트인 전송)·capability-map 7/7(전역 no-innerHTML) 무회귀.

- 회귀: `tests/init-new-project-exec.bats`(+2)·`tests/new-project-panel.bats`(+1). 후속 후보: 서버측 디렉터리 브라우저·다중 레포 관제·T216·T108.

### §11.68 새 프로젝트 디렉터리 선택기 Phase 1 — 읽기 전용 GET /api/fs/dirs (ADR-0155)

**무엇을·why.** ADR-0149가 기각했던 "서버측 디렉터리 브라우저"를 ADR-0155에서 재검토 — 임의 브라우저가 아니라 **localhost·허용 base 한정·디렉터리명만**의 제약된 읽기 선택기로 좁혀, ROOT 밖 임의 읽기 우려를 해소하며 "폴더를 골라 시작" 편의를 더한다. Phase 1은 그 백엔드 엔드포인트.

**엔드포인트(server.mjs `GET /api/fs/dirs?base=`).** localhost 전용(비-localhost 403, T099). `listProjectDirs()`: `allowRoot = realpath(env.MC_NEW_PROJECT_BASE || dirname(ROOT))`; 요청 경로를 `resolve(allowRoot, base)` 후 **realpath**해 allowRoot 봉쇄 검사(prefix 아니면 거부 — `..`·심링크 탈출 차단). 디렉터리만·dotfile/파일/심링크 제외·ROOT 및 내부 제외·정렬·≤1000. 반환 `{base,parent,entries}`.

**안전(핵심).** realpath를 봉쇄 검사 *전에* 수행해 심링크가 base 밖을 가리키면 거부. 파일·파일 내용·숨김 미반환. SOURCE 변경 없음(읽기만). 새 exec 아님(`/api/exec` 화이트리스트 무변경).

**경계 갱신(정직).** 이전 baseline의 "읽기 표면 미확장"을 **base 한정 읽기 전용 디렉터리 목록**으로 갱신(작지만 실제 표면 확장·ADR-0155에 명시). import에 `realpathSync`·`sep` 추가.

**검증.** node 117/117·`tests/fs-dirs-endpoint.bats` 7/7(디렉터리만·dotfile/파일/심링크/repo 제외·drill-down·`..`/절대/심링크/repo 거부·비-localhost 403)·capability-map 7/7(전역 no-innerHTML)·exec 8/8 무회귀.

- 회귀: `tests/fs-dirs-endpoint.bats`(신규 7건). 후속: T243(패널 "찾아보기" 보조 UI).

### §11.69 새 프로젝트 디렉터리 선택기 Phase 2 — 패널 "찾아보기" 보조 UI (ADR-0155)

**무엇을·why.** ADR-0155 마지막 단계. "새 프로젝트" 패널 경로 입력 아래에 **"찾아보기"** 토글을 두어, `GET /api/fs/dirs`(T242) 목록으로 디렉터리를 드릴다운하며 경로를 고른다. 손으로 치는 대신 클릭으로 경로 입력란을 채우는 **보조**다(생성 권위는 그대로).

**UI·스크립트(renderNewProjectPanel).** "찾아보기" → `data-np-browser` 목록(현재 base `data-np-cwd`·"상위로" `data-np-up`·`data-np-dirlist`). `loadDirs(base)`가 `/api/fs/dirs?base=` fetch → `renderDirs`가 `createElement('li'/'button')` + **`textContent`** 로 목록 생성(innerHTML 없음). 디렉터리 클릭 → 경로 입력란을 그 경로로 채우고 드릴다운. 열 때 기본 base에서 시작(타이핑한 경로는 아직 없는 대상일 수 있음).

**권위 불변.** 선택기는 경로 입력 보조일 뿐, 생성은 기존 경로 검증 + `init_new_project` exec(미리보기→생성). 새 쓰기 표면 없음·비-localhost 패널 미렌더·`/api/fs/dirs` 자체가 비-localhost 403(T242).

**무회귀.** 경로/코드명/스택/force/참조문서·미리보기→생성·세 검토 표면·능력 맵(전역 no-innerHTML 포함) 무변경.

**검증.** node 117/117·`tests/new-project-panel.bats` 6/6(+찾아보기 picker present·`/api/fs/dirs`·textContent escape-first)·`fs-dirs-endpoint` 7/7·capability-map 7/7 무회귀. ADR-0155 2단계(T242·T243) 완료 — 웹에서 폴더를 골라 새 프로젝트 시작 가능.

- 회귀: `tests/new-project-panel.bats`(+1, 찾아보기 picker). 후속 후보: 다중 레포 관제·T216·README/quickstart 정합·T108.

### §11.70 새 프로젝트 패널 체크박스 정렬 수정 (CSS-only · 라이브 QA 발견) (T244)

**무엇을·why.** browser-vibe-coding 라이브 QA(localhost:7474/spec)에서 새 프로젝트 패널 체크박스 3종(force/onboarding/glossary)이 라벨과 분리돼(체크박스가 블록·전체폭) 보이는 시각 문제를 발견. 기능·exec·보안 경계는 라이브 QA로 이미 GREEN이었고 남은 건 시각 품질뿐이라 즉시 닫음.

**원인·수정.** `.mc-specedit__reason input { display:block; width:100% }` 를 체크박스가 상속 → full-width 블록 렌더. `ui.css`에 `.mc-newproj__force`/`.mc-newproj__ref` 를 `display:flex; align-items:center; gap`, 내부 `input[type=checkbox]` 를 `display:inline-block; width:auto` 로 추가해 라벨과 인라인 정렬(CSS-only·server.mjs 마크업 무변경).

**라이브 검증.** 링크 캐시버스트 후 `labelDisplay=flex`·checkbox 13px(자연 크기) 확인, 스크린샷으로 라벨 옆 정렬 확인. node 117/0·capability-map 7/7(no-innerHTML)·new-project-panel bats 무회귀·lint 0.

**메모.** ui.css는 `Cache-Control` 없이 서빙 → 브라우저 캐시로 사용자는 hard reload 후 반영(서버는 새 CSS 서빙 확인). 캐시 헤더 자체는 별도 후속 후보.

- 회귀: CSS-only(테스트 변경 없음·기존 패널 bats 무회귀). 후속 후보: 다중 레포 관제·T216·README/quickstart 정합·ui.css 캐시 헤더·T108.

### §11.71 Forge Board 가로 오버플로(오른쪽 잘림) 수정 (CSS-only · 라이브 vibe-coding) (T245)

**무엇을·why.** 라이브 vibe-coding에서 Board 오른쪽(Forging·Approval·Done·카드 버튼)이 화면 밖으로 잘리는 걸 확인. 진단: `.mc-page`(`minmax(0,1fr) 320px` 2열)에서 보드(5컬럼)가 320px 트랙에 짓눌리고 카드 입력이 안 줄어 5컬럼이 넘쳐 **문서 전체가 2400px로 흘러**(창 1800px) 오른쪽 잘림.

**수정(ui.css `.mc-board`).** `grid-column: 1 / -1`(페이지 전 폭 span — 좁은 트랙 탈출) + `overflow-x: auto`(좁은 화면 시 문서가 아니라 보드 내부 스크롤). server.mjs/기능/exec/보안 무변경.

**라이브 검증.** docScrollW 2400→1800(=창폭), boardClientW 320→1744(=scrollW, 내부도 안 넘침), 5컬럼(Backlog·Open·Forging·Approval·Done) 전부 표시·카드 Run/메타 저장/취소 비잘림. node 117/0·capability-map 7/7(no-innerHTML)·lint 0 무회귀.

**메모.** ui.css는 `Cache-Control` 없이 서빙 → 사용자 hard reload 후 반영(서버는 새 CSS 정상 서빙). 캐시 헤더는 별도 후속 후보.

- 회귀: CSS-only(테스트 변경 없음). 후속 후보: ui.css 캐시 헤더·Autonomy/Insights 표 오버플로(있으면)·다중 레포 관제·T216·README/quickstart 정합·T108.

### §11.72 /ui.css no-cache 헤더 — CSS 수정이 정상 reload로 반영 (T246)

**무엇을·why.** 라이브 vibe-coding에서 "보드 오른쪽 잘림이 여전하다"는 보고의 진짜 원인이 코드가 아니라 **브라우저 캐시**임을 측정으로 확인했다(일반 reload 시 `grid-column=auto`·docScrollW 2400, 캐시버스트 시 `1/-1`·1800). `GET /ui.css` 가 `Cache-Control` 없이 서빙돼 브라우저가 무기한 캐시 → T244(체크박스)·T245(보드) CSS 수정이 hard reload 전엔 안 보였다.

**수정(server.mjs).** `GET /ui.css` 응답에 `Cache-Control: no-cache` 추가(이미 `/sw.js`가 쓰던 동일 정책). file=truth로 서버는 매 요청 fresh를 읽으므로, 브라우저만 매번 재검증하면 CSS 수정이 정상 reload로 반영된다. server 라우트 1줄·기능/exec/보안 무변경.

**적용 메모.** 헤더는 **서버 재시작 후** 활성(라우트는 기동 시 로드된 모듈). 현재 떠 있는 서버에서 기존 수정은 1회 hard reload로 확인. node 117/0·`node --check` OK.

- 회귀: node 117/0(서버 라우트 1줄). 후속 후보: Autonomy/Insights 표 오버플로·다중 레포 관제·T216·README/quickstart 정합·T108.

### §11.73 ui.css <link> 버전 쿼리(mtime) 캐시버스트 (T247)

**무엇을·why.** T246(no-cache) 후에도 "정상 새로고침하면 이전 레이아웃으로 돌아간다". 원인: no-cache 이전에 브라우저가 저장한 **헐벗은 `/ui.css` 캐시 항목**(캐시 지시 없음→휴리스틱)을 정상 reload가 재검증 없이 재사용. 측정: 정상 reload `gridColumn=auto`/2400, `?v` 직접요청 `1/-1`/1800.

**수정(server.mjs).** shell `<link rel=stylesheet href="/ui.css">` → `href="${uiCssHref()}"`; `uiCssHref()`가 `/ui.css?v=<statSync(UI_CSS_PATH).mtimeMs>` 반환. 버전 URL이 옛 항목을 우회하고, mtime이라 CSS 편집마다 자동 버스트. no-cache(T246)와 결합해 매 로드 fresh. 기능/exec/보안 무변경.

**적용 메모.** 서버 재시작 후 활성(shell은 기동 시 로드 모듈). 현재 서버는 이미 no-cache라 hard reload 1회로도 즉시 durable. node 117/0·`node --check` OK.

- 회귀: node 117/0. 캐시 전달 이슈(T246 no-cache + T247 versioned link)로 CSS 수정이 정상 새로고침에 반영되도록 닫음. 후속 후보: Autonomy/Insights 표 오버플로·다중 레포 관제·T216·README/quickstart 정합·T108.

### §11.74 새 프로젝트 패널 FormField + 범위 토큰 (UX 강화 Phase 1) (ADR-0158)

**무엇을·why.** 디자인 연구·프로토타입·리뷰어 검토(ADR-0158)의 4단계 중 Phase 1 — 후속 검증/모달/로딩이 얹힐 **기반**(FormField 구조 + 토큰). 시각·구조만, 동작 무변경.

**토큰(ui.css).** `:root`에 `--space-1..6`·`--radius-sm/md/lg`·`--dur-fast/base` 신설(전역 px 치환은 비범위·회귀). `.mc-field`(label/hint/error 슬롯)·`.mc-jump`(앵커)가 토큰 사용.

**FormField(server.mjs renderNewProjectPanel).** 대상 경로·코드명·검증 스택을 `.mc-field`(`<label for>` + input/select + `.mc-field__hint` + `.mc-field__err role=alert hidden`)로 구조화, `aria-describedby="..-hint ..-err"`로 연결. `data-np-*` 셀렉터 보존(스크립트 무변경). 빌려쓰던 `.mc-specedit__reason` 결합 제거(T244 회귀 원인 차단). 입력 min-height 32px(WCAG 2.2 타겟).

**발견성.** Spec 상단에 localhost 전용 in-page 앵커 `<a.mc-jump href="#mc-newproj">`(상단 primary 버튼보다 덜 튀게), 패널 `id="mc-newproj"`. grid-column:1/-1로 레이아웃 균형 보존.

**무회귀.** 검증/모달/로딩 동작·exec·생성 권위·찾아보기·escape-first(no-innerHTML) 무변경. node 117/0·new-project-panel 8/8(+FormField·토큰 2건)·capability-map 7/7. 마크업은 서버 재시작 후 라이브 반영(bats는 fresh 서버로 검증).

- 회귀: `tests/new-project-panel.bats`(+2: FormField 구조·토큰). 후속: T250(검증 매핑)·T251(모달)·T252(로딩).

### §11.75 새 프로젝트 입력 검증 — 힌트 + 서버 에러 필드 매핑 (UX 강화 Phase 2) (ADR-0158)

**무엇을·why.** ADR-0158 Phase 2 — 클라이언트는 **힌트만**(blur 후), 검증 **권위는 서버**. 잘못된 입력이 서버 400으로만 반려되던 것을 해당 **필드 에러**로 즉시 표시. 프로토타입의 클라이언트-only false-OK 위험을 회피(서버 판정이 권위).

**구현(newProjectPanelScript).** `setErr/clearErr`(`.mc-field.is-invalid` + `aria-invalid` + `data-np-*-err` 슬롯 textContent·DOM 텍스트만). blur 힌트: 경로 길이(≤4096)·코드명 형식(`[A-Za-z0-9 ._-]`·≤64). 제출(미리보기/생성) 시 `clearAllErr()` 후, `/api/exec` 400 `{error}`를 `mapServerError`로 매핑 — `targetPath`/`outside this repository` → 경로 필드, `invalid name` → 코드명 필드, 그 외 → toast. 입력 시 에러 빠른 해소(`input` 리스너). 로드 시점 에러 표시 없음.

**회귀 가드(리뷰 반영).** ① 서버 권위·false-OK 금지(클라이언트는 힌트). ② DOM/textContent — no-innerHTML 계약 유지(주석의 리터럴 'innerHTML'도 제거: capability-map 전역 grep 가드). ③ 검증 타이밍 — 로드 즉시 에러 없음, blur/제출 후. ④ `aria-invalid`/`aria-describedby`(T249 슬롯) 연결. exec/생성 권위/찾아보기 무변경.

**검증.** node 117/0·`new-project-panel.bats` 9/9(+검증 매핑·aria-invalid·no-innerHTML·로드 즉시검증 부재)·capability-map 7/7(전역 no-innerHTML, count 0)·init-new-project-exec 8/8(서버 400 메시지 = 매핑 regex 근거).

- 회귀: `tests/new-project-panel.bats`(+1). 후속: T251(mc-confirm-modal 재사용+a11y)·T252(로딩 a11y).

### §11.76 새 프로젝트 생성 확인 — mc-confirm-modal 재사용 + a11y (UX 강화 Phase 3) (ADR-0158)

**무엇을·why.** ADR-0158 Phase 3 — 새 프로젝트 "생성"의 `window.confirm`(테마·접근성 약함)을 공용 `#mc-confirm-modal` **요소 재사용**으로 교체. 리뷰어 지적(현 opener는 submit 포커스·trap/inert/focus-return 미비)을 반영해 위험 액션 접근성을 보강.

**opener(ui.mjs `window.__mcConfirm`).** 공용 모달 요소 재사용(새 모달 추가 안 함). 무엇이/예상 결과/잘못되면 + 복구 명령을 textContent로 채우고, **위험 액션 → 취소 초기 포커스**(`initialFocus:'cancel'`), **focus trap**(Tab/Shift+Tab 순환), **ESC·backdrop 닫힘**, 배경 형제 요소 `inert`(toast 제외), 닫을 때 **트리거로 포커스 복귀**. submit 라벨은 opts로 바꾸고 닫을 때 원복(세션 흐름 오염 방지). `{ok}` 반환. 세션 흐름(`confirmSessionAction`)은 무변경.

**create(server.mjs).** create 핸들러가 `await window.__mcConfirm({title/what/expected/downside/recovery, submitLabel:'생성', initialFocus:'cancel'})` 사용. force 시 덮어쓰기 경고를 what에 포함. `__mcConfirm` 부재 시 `window.confirm` 폴백. 생성 권위(미리보기→exec)·escape-first(textContent) 무변경.

**무회귀.** server.mjs no-innerHTML 0(전역 가드 green)·ui.mjs innerHTML은 기존 QR 1건(HEAD 동일·capability-map은 server.mjs만 검사). 세션 모달·기존 패널·exec 무변경. node 117/0·new-project-panel 10/10(+모달 재사용·inert·focus return·취소 초기 포커스·backdrop)·capability-map 7/7.

- 회귀: `tests/new-project-panel.bats`(+1). 후속: T252(로딩 a11y).

### §11.77 새 프로젝트 미리보기/생성 로딩 상태 a11y (UX 강화 Phase 4·완결) (ADR-0158)

**무엇을·why.** ADR-0158 Phase 4(마지막) — 미리보기/생성 디스패치가 진행 중임을 보조기술과 시각 모두에 노출. 기존엔 클릭한 버튼만 비활성될 뿐 진행 신호가 없어, 느린 클린 추출 동안 무응답처럼 보이고 이중 디스패치 위험이 있었음(Primer Loading 가이드).

**구현(newProjectPanelScript).** 액션 영역 아래 `<p data-np-status role="status" aria-live="polite" hidden>` 상태 영역 추가. `setBusy(on, text)`: 미리보기·생성 버튼 **모두** 비활성(이중 디스패치 차단), 패널 `aria-busy` 토글, 상태 영역 `textContent`로 라벨('미리보기 중…'/'생성 중…')·`.is-busy` 클래스 토글. `dispatch` 시작에 `setBusy(true, …)`, `finally`에서 `setBusy(false)`(에러·정상 모두 해제).

**스피너(ui.css).** `.mc-newproj__status.is-busy::before` CSS pseudo-element + `@keyframes mc-spin`(토큰 `--dur-base`). **DOM 텍스트만**(라벨은 textContent, 스피너는 pseudo) — no-innerHTML 계약 유지.

**무회귀.** 매니페스트·생성 권위(미리보기→exec)·검증(T250)·모달(T251)·찾아보기·escape-first 무변경. server.mjs no-innerHTML 0(전역 가드 green). node 117/0·new-project-panel 11/11(+role=status·aria-busy·버튼 비활성·textContent 라벨·pseudo 스피너·no-innerHTML)·capability-map 7/7·check_ui_requirements 6/6.

- 회귀: `tests/new-project-panel.bats`(+1). ADR-0158(새 프로젝트 패널 UX 강화) **4단계 완결** — 다음은 v0.82.0 봉인(T244·T245·T246·T247·T249·T250·T251·T252).

### §11.78 새 프로젝트 패널 라이브 시각 감사 (T253·ADR-0160) — 결과

**무엇을·why.** v0.82 봉인 후, UX 강화 4단계(T249–T252)를 서버 재시작된 라이브 `/spec`에서 Claude-in-Chrome로 eyes-on 감사(ADR-0157 §7.1 "live screen is the source of truth"). 정적 GREEN이 화면 상호작용(정렬·포커스·로딩)을 보장하지 못하므로 실측.

**선행 확인.** 서버 최신 코드 서빙 검증 — `data-np-status[role=status]`·`__mcConfirm`(function)·`ui.css?v=<mtime>`·스피너 CSS rule 모두 존재. 서버 재시작 반영 OK.

**판정 (A–F).**
- **A FormField (T249)** PASS — 경로/코드명/스택 모두 label→input→hint 정렬, 체크박스 라벨 인라인(T244 유지). 토큰 간격 일관.
- **B 앵커 (T249)** PASS — `↓ 새 프로젝트 만들기` 클릭 → `#mc-newproj` 스크롤(scrollBy 6664·hash 설정).
- **C 검증 (T250)** PASS — 빈 경로→경로 필드 `aria-invalid`+에러("대상 경로를 입력하세요."), 잘못된 코드명 blur→코드명 힌트, repo 내부 경로('docs')→서버 400 "outside this repository"가 경로 필드에 매핑. 입력 시 해소.
- **D 확인 모달 (T251)** PASS(코어) — 생성 클릭→`#mc-confirm-modal` 열림, **취소 초기 포커스**, focus trap(Tab→Cancel), ESC·backdrop 닫힘, **생성 버튼으로 포커스 복귀**, 배경 형제 inert 6→0, 깨끗한 단일 오픈 시 submit "생성"·recovery `rm -rf <대상>` 노출.
- **E 로딩 (T252)** PASS — 디스패치 중 `aria-busy=true`·상태 "미리보기 중…"·스피너(is-busy)·미리보기/생성 **양쪽 버튼 비활성**, 완료 후 전부 해제. dry-run 프리뷰가 SOURCE(읽기 전용)·TARGET 표시 → SOURCE 불변 확인.
- **F 콘솔/회귀** PASS — 콘솔 에러 0(리로드 후 재확인), 찾아보기(14개 디렉터리)·force 체크박스 토글 무회귀.

**발견(비차단·후속 fix 티켓 후보).**
- **AUDIT-1** (minor) — 패널 토스트 무동작: 패널 인라인 스크립트가 init 시점에 `getElementById('mc-toast')`를 캐시하는데 `#mc-toast`가 패널보다 **뒤에** 렌더되어 `null` → 패널 성공/안내/에러 토스트가 조용히 스킵됨. 필드 에러는 호출 시점 조회라 영향 없음. fix: `showToast` 내부에서 지연 조회.
- **AUDIT-2** (minor-moderate) — 생성 확인 모달에 세션용 "지시" textarea가 노출됨. opener가 wrap에 `hidden`을 걸지만 CSS `display:grid`가 `[hidden]`을 무력화. 위험 확인 다이얼로그에 무기능 입력이 남음. fix: 클래스/`style.display='none'` 또는 스코프된 `[hidden]` 우선.
- **AUDIT-3** (low) — 확인 모달 취소 버튼 "Cancel"(영문)인데 본문/제출 "생성"은 국문 → i18n 불일치(공용 모달 기본 라벨).
- **AUDIT-4** (low/잠재) — 모달 **빠른 재오픈** 시 submit 라벨 복원 레이스로 "Run"이 보인 사례. 깨끗한 단일 오픈에선 재현 안 됨(실사용 영향 낮음).

**결론.** UX 강화 4단계의 핵심 동작은 라이브 GREEN. 발견 4건은 표현/보조 계층(토스트·모달 잔여 입력·i18n)으로 기능·exec·보안 무관. 코드 변경 없는 검증 마일스톤으로 T253 종료. 후속 fix는 별도 라운드(AUDIT-1·AUDIT-2 우선)로 설계.

- 후속: AUDIT-1/2 fix 라운드(ADR-0161 후보). README/quickstart 정합·non-localhost 검증 환경은 잔여.

### §11.79 새 프로젝트 패널 감사 결함 수정 — AUDIT-1 토스트 · AUDIT-2 모달 지시 textarea (ADR-0161)

**무엇을·why.** T253 감사(§11.78)에서 발견한 표현/보조 계층 결함 2건을 최소 수정으로 닫음. 기능·exec·보안 무관.

**AUDIT-1 fix (server.mjs `newProjectPanelScript`).** 패널 `showToast`를 **호출 시점 지연 조회**로 변경 — `const showToast = (m,bad) => { const toast = document.getElementById('mc-toast'); if(!toast) return; … }`. init 캐시(`const toast = …`) 제거. `#mc-toast`가 패널보다 뒤에 렌더돼 init 시 null이던 문제 해소(패널 성공/안내/에러 토스트 동작). 패널 내 `toast` 다른 참조 없음 → 안전. 이 패널 스크립트만 수정(다른 페이지 동일 패턴은 렌더 순서상 정상이라 무변경). escape-first(textContent·innerHTML 0) 유지.

**AUDIT-2 fix (ui.css).** `.mc-modal__instruction[hidden] { display: none; }` 추가. 기존 `.mc-modal__instruction{display:grid}`(특이도 0,1,0)가 `[hidden]`을 무력화하던 것을 (0,2,0)으로 교정 → `__mcConfirm`(새 프로젝트)·`confirmSessionAction`(지시 불필요 액션) 두 경로에서 `hidden`이 실제로 숨김. JS 무변경. 지시 **필요한** redirect 경로는 `hidden=false`라 정상 노출(무회귀). 라이브 검증(현 서버에 규칙 주입): `textareaVisible:false`·`wrapDisplay:none`.

**무회귀.** 매니페스트·생성 권위·exec·세션 모달 흐름·T250 검증·T252 로딩 무변경. node 117/0·new-project-panel 12/12(+T254: 지연 조회·`[hidden]` 규칙)·capability-map 7/7(no-innerHTML 0)·check_ui_requirements 6/6.

- 회귀: `tests/new-project-panel.bats`(+1). AUDIT-3(모달 취소 i18n)·AUDIT-4(빠른 재오픈 라벨 레이스)는 백로그. 다음: host GREEN 후 v0.83.0 봉인.

### §11.80 작업트리 정합 — 문서 커밋 + 잔여 삭제 (T255·ADR-0163, housekeeping)

**무엇을·why.** 여러 라운드에서 누적된 dirty 작업트리를 정합. 봉인 범위에서 의도적으로 제외해 온 미커밋 파일을 (a) 정당한 문서는 커밋, (b) 잔여/중복은 삭제로 정리. 코드·exec·보안 무관.

**커밋(샌드박스, `c750cb3`).** `README.md`·`docs/onboarding/quickstart.md`+`.html`(새 프로젝트 적용 섹션)·`docs/status-v0.76.md`(v0.76 측정 스냅샷)·`docs/onboarding/web-manual.html`(웹 스크린샷 매뉴얼). web-manual 고아 해소 위해 quickstart(md/html)에 발견성 링크 1줄 추가. 커밋 전 링크 무결성 확인 — 참조 가이드(`새_프로젝트_적용_가이드.md/.html`)·svg(`docs/assets/ralph-bootstrap-flow.svg`) 모두 tracked.

**삭제(호스트).** 샌드박스는 마운트 작업트리에서 unlink 불가(rename만) → 삭제는 호스트 위임. stale `tickets/` 원본 10개(T234·235·236·238·240·242·243·249·250·251 — 각 DONE/ 버전이 권위·status:done) + `docx-open-investigation.png`(루트 디버그 아티팩트) + `__unlink_probe.tmp`(진단 잔여). 모두 untracked라 순수 삭제(`git rm` 아님). DONE/ 티켓·가이드·자산 무영향.

**결과.** `git status --short` 무출력(작업트리 clean). `.git` 임시물 0(locks/tmp_obj). 코드 변경 없어 봉인 불필요 — housekeeping 마일스톤.

**운영 메모(회귀).** ① `element.hidden`은 CSS `display` 클래스에 질 수 있다(§11.79 AUDIT-2와 동류) — 표현 계약은 화면/스코프 규칙으로 방어. ② 샌드박스 마운트는 unlink 전역 차단(rename 허용) → 삭제성 정리는 호스트 단계로 설계해야 함(분할 실행). ③ 봉인/커밋은 rename 우회로 가능하나 `.git` lock/tmp_obj가 누적 → 주기적 호스트 정리.

- 후속(ADR-0162 §8): AUDIT-3·4·non-localhost 검증 환경·다중 레포 관제·T216·T108(비차단).

### §11.81 MC 전면 재구상 P1a — 디자인 토큰 전역화 + a11y 최소 + 버전 라벨 (T256·ADR-0164)

**무엇을·why.** MC 전면 재구상(연구 v2·프로토타입 v2 기반)의 P1 첫 조각. 표현 기반만 — 페이지 본문·렌더 로직 무변경. 도메인(HITL·trace·policy)은 P2+(ADR-0164 §0 비범위).

**토큰 전역화(ui.css :root).** 상태색 `--ok/--warn/--danger/--info`·중간색 `--dim-2/--surface-3/--border-2`·타이포 스케일 `--fs-1..6`·`--rail`·`--tap(24px)`·`--ease` 추가(기존 `--space/--radius/--dur` 위에). **전역 px 일괄 치환은 비범위** — 정의만, 셸/신규 컴포넌트부터 채택(T249 정책 유지).

**a11y 최소(WCAG 2.2).** 전역 `:focus-visible` 포커스 링(2.4.7) + `html{scroll-padding-top:64px}`(2.4.11 focus not obscured — sticky 헤더 대비). 기존 `.mc-field :focus` 동작과 공존.

**버전 라벨 수정(server.mjs, file=truth).** package.json 부재(zero-dep 레포)로 `v0.0.0`이던 버그를, 최신 baseline ADR 파일명(`docs/decisions/NNNN-vX.Y-baseline.md`)에서 도출(`deriveBaselineVersion`) → `0.83.0`. 봉인마다 자동 갱신, exec/네트워크 없음(`readdirSync`만). `/api/version`도 동일.

**무회귀.** 페이지 본문·exec·localhost·escape-first 무변경. server.mjs innerHTML 0(전역 가드 green). node 117/0·mc-shell 4/4(토큰·focus-visible·버전≠0.0.0·/api/version)·capability-map 7/7·check_ui_requirements 6/6·new-project-panel 12/12.

- 회귀: `tests/mc-shell.bats`(신규, +4). 후속: T257(셸·세로 내비·상태 스트립·모바일 ESC/trap)·T258(팔레트 ARIA). P1 3개 완료 시 baseline 봉인.

### §11.82 MC 전면 재구상 P1b — 공통 셸: 좌측 세로 그룹 내비 + 글로벌 상태 스트립 + 모바일 오프캔버스 (T257·ADR-0164)

**무엇을·why.** `renderShell` 전역 교체 — 평면 8탭을 좌측 세로 그룹 내비로, 페이지명 중복을 제거하고 "지금 할 일"을 상단 상태 스트립으로 상시 노출. **페이지 본문(main) 무변경** — 새 셸에 기존 페이지를 끼움(도메인은 P2+).

**셸(server.mjs).** `<div class="mc-app">`(grid: 세로 내비 + main) > `<aside class="mc-sidenav">`(브랜드·`renderNav`·접기·버전) + `<div class="mc-main">`(`mc-strip` + `mc-pagehead h1` + 기존 `${main}`) + `mc-nav-backdrop`. `renderNav`는 그룹(운영 Board/Inbox/Sessions · 이해 Insights/Library · 구성 Spec/Autonomy/Pairing/새 프로젝트)·`aria-current`·아이콘. **클래스 `mc-nav`/`mc-nav__item` 유지(R5 호환).**

**상태 스트립.** `shellStats(isLocalhost)` — 기존 데이터만으로 카운트(신규 백엔드 없음): 승인=`byStatus['awaiting-approval']`·실패=`parseFailures()`·세션=`listSessions()`·모드=`readLoopMode()`. 각 칩 클릭→해당 페이지.

**모바일(ui.css + ui.mjs).** ≤768px에서 `.mc-sidenav` 오프캔버스(fixed·translateX), 햄버거(`data-nav-toggle`)로 열고 **ESC 닫힘·focus trap(Tab 순환)·포커스 복귀·backdrop**. 데스크톱 접기(`data-nav-collapse`). clientScript에 토글 JS 추가(escape-first — DOM API만, innerHTML 0). R5 정적 검사용 768px `.mc-nav{overflow-x}` 유지.

**무회귀.** 페이지 본문·exec·localhost·CLI 동등 무변경. server.mjs innerHTML 0. **R1–R5 라이브 통과**(셸 전역 변경의 핵심 게이트). node 117/0·mc-shell 8/8(+T257 4)·capability-map 7/7·new-project-panel 12/12·session_events 무회귀. `.mc-page` 데스크톱 패딩 유지(콘텐츠 비-flush).

- 회귀: `tests/mc-shell.bats`(+4). **라이브 확인은 서버 재시작 필요**(세로 내비·상태 스트립·모바일 햄버거 eyeball). 후속: T258(팔레트). P1 완료 시 baseline 봉인.

### §11.83 MC 전면 재구상 P1c — 커맨드 팔레트 뼈대(⌘K) ARIA + 키보드 (T258·ADR-0164)

**무엇을·why.** P1 마지막 — CLI 동등(ADR-0024) 철학에 맞는 ⌘K 커맨드 팔레트. *기존* 페이지 점프/액션만(신규 exec 없음). 정식 ARIA + 키보드로 발견성·접근성 확보.

**마크업(server.mjs renderShell).** 스트립에 트리거 `data-cmd-open`(검색·실행 ⌘K). 본문에 `data-cmd-scrim` > `role=dialog`/`aria-modal` 다이얼로그 — 입력 `role=combobox`(`aria-expanded`/`aria-controls`/`aria-activedescendant`) + `role=listbox`(`mc-cmd-list`). 비어 있는 리스트(런타임 채움).

**동작(ui.mjs clientScript).** 항목은 **렌더된 `.mc-nav__item`에서 도출** — localhost 노출(Pairing/새 프로젝트 포함 여부)을 자동 반영, 신규 백엔드 없음. + 기존 액션 2개(승인 검토→/inbox·다음 safe 실행 가이드→/autonomy, **이동만**). 각 항목 CLI 등가 부제. ⌘K/Ctrl+K 토글·↑↓ 이동(`aria-selected`/`aria-activedescendant` 갱신)·Enter 이동·Esc·backdrop·**Tab 트랩(입력만 포커스)**·**포커스 복귀**(opener). 리스트는 `createElement`+`textContent`로만 빌드(escape-first).

**무회귀.** server.mjs innerHTML 0(전역 가드 green)·ui.mjs innerHTML 1(기존 QR만, 팔레트는 DOM API). 페이지 본문·exec·localhost·CLI 동등 무변경. **R1–R5 라이브 통과**. node 117/0·mc-shell 10/10(+T258 2)·capability-map 7/7·check_ui_requirements 6/6·new-project-panel 12/12.

- 회귀: `tests/mc-shell.bats`(+2, host-portable: grep -P 미사용). **P1(T256·T257·T258) 완료** — 다음은 baseline 봉인. 라이브 확인은 서버 재시작 후(⌘K 팔레트 eyeball).

### §11.84 MC 재구상 P2-Trace-1 — trace projection 모듈(읽기 전용) (T259·ADR-0166)

**무엇을·why.** P2-Trace의 데이터-우선 1단계. 기존 파일 산출물을 canonical run/span **읽기 모델**로 투영하는 자립 모듈 — UI/HTTP/writer 없이 데이터 계약을 먼저 고정. 이후 Sessions/Insights UI가 이 한 모델을 소비.

**모듈(`mission-control/trace.mjs`, 신규·의존성 0).** `listRuns(root)`(요약 최신순·spans 제외)·`getRun(root, runId)`(스팬 포함). 서버를 import하지 않고 root를 받아 파일을 직접 읽음(픽스처 단위 테스트 가능). **신규 writer/exec/HTTP/loop 변경 0** — 기존 포맷 미러(reservations events.jsonl·failures.log·token_usage.log·approvals).

**투영(ADR-0166 §3).** run = 티켓 1회 처리(runId=ticket, v1). span type: lifecycle(이벤트)·model(토큰 텔레메트리)·failure(실패 로그)·decision(승인 마커) + 예약(tool/guardrail/handoff/custom). run.state는 예약 이벤트 우선(`sessionState`), 없으면 failure→failed·그 외 completed. **정직**: durationMs는 양 끝 파싱 가능할 때만(추정 아님·불명 null), fine span 부재.

**무회귀.** 순수 읽기 모듈 — 서버/exec/페이지 무변경. trace.mjs innerHTML 0. node 122/122(+trace 5: 요약 스키마·스팬 타입/정렬·과거 failure run·빈 root·parse-error 견고성)·capability-map 7/7.

- 회귀: `mission-control/trace.test.mjs`(신규, +5). 후속: T260(읽기 전용 `/api/trace` API) → 이후 UI. P2-Trace 완료 시 baseline 후보.

### §11.85 MC 재구상 P2-Trace-2 — 읽기 전용 trace API (T260·ADR-0166)

**무엇을·why.** P2-Trace 마무리 — T259 `trace.mjs` 모듈을 읽기 전용 JSON API로 노출. 이후 Sessions/Insights UI의 계약. 신규 exec/writer 0.

**라우트(server.mjs).** `GET /api/trace/runs` → `{ runs: listRuns(ROOT) }`(요약·스팬 제외). `GET /api/trace/runs/:id` → `getRun(ROOT, id)`(스팬 포함)·없으면 404. `:id`는 `sessionStream`과 동일한 정규식 매칭 패턴(`/^\/api\/trace\/runs\/(T[0-9]{3,})$/`)으로 라우트 테이블 앞에서 처리. trace 함수는 `./trace.mjs`에서 import.

**경계.** 읽기 전용 — 기존 dispatch가 GET 외 `/api/*`를 405로 거부(ADR-0024) → POST 405. non-localhost는 기존 토큰 인증 게이트 통과(읽기 허용, ADR-0099). **신규 exec/writer/loop 변경 0**. escape-first(JSON `JSON.stringify`).

**무회귀.** server.mjs innerHTML 0. **R1–R5 라이브 통과**. node 122/122·trace-api 5/5(목록·상세·과거 failure·404·405)·capability-map 7/7·new-project-panel 12/12·mc-shell 10/10.

- 회귀: `tests/trace-api.bats`(신규, +5, host-portable). **P2-Trace(T259·T260) 완료** — 다음은 baseline 봉인. UI(Sessions 라이브 trace·Insights run explorer)는 별도 후속 ADR.

### §11.86 MC 재구상 P2-Trace-UI-a — Sessions trace 요약(읽기 전용) (T261·ADR-0168)

**무엇을·why.** P2-Trace 데이터의 첫 UI 소비자. Sessions 활성 워커 상세에 해당 run의 trace 요약을 읽기 전용으로 부착 — 세션 제어는 그대로.

**구현(server.mjs).** `renderTraceSummary(run)` 헬퍼 신규 — `getRun(ROOT, selected.id)`(ADR-0166 projection)를 서버 렌더로 주입. 표시: state·status·spanCount·dur + 최근 6개 스팬(type/name/status). 세션 상세의 intervention bar 다음, 로그/이벤트 그리드 앞에 추가 패널. escape-first(escapeHtml) — DOM 텍스트만.

**무회귀.** 세션 리스트·제어(시작/중단/입력)·SSE attach(`data-session-stream`)·로그/이벤트 패널 무변경(추가 패널만). exec/writer/trace 스키마 무변경. server.mjs innerHTML 0. **R1–R5 라이브 통과**. node 122/122·trace-ui 3/3(요약 마커·스팬 타입·기존 패널 잔존)·capability-map 7/7·session_events·new-project-panel 무회귀.

- 회귀: `tests/trace-ui.bats`(신규, +3, host-portable·ASCII 테스트명). 후속: T262(Insights run explorer + 실패 drill-down). P2-Trace-UI 완료 시 baseline 봉인(v0.86 후보).

### §11.87 MC 재구상 P2-Trace-UI-b — Insights run explorer + 실패 drill-down (T262·ADR-0168)

**무엇을·why.** P2-Trace-UI 마무리 — Insights에 run explorer를 추가해 "trace/run drill-down 우선"을 화면으로. 기존 KPI 집계/분포는 보조로 유지.

**구현(server.mjs).** `renderRunExplorer(selectedRunId)` 헬퍼 신규 — `listRuns(ROOT)` 요약 목록(최신순·각 행 `/insights?run=ID` 링크) + `getRun(ROOT, id)` 상세 스팬 트리. 기본 선택 = 지정 run → **첫 실패 run** → 최신. 실패 run엔 **`왜 실패했는가` drill-down**(실패 span의 message/stage). KPI `mc-stats` 섹션 다음에 삽입(집계/분포 패널은 그대로 아래 유지). `/insights?run=` 쿼리로 선택(sessions `?session=`과 동형). escape-first(escapeHtml — DOM 텍스트만), T261의 `.mc-trace-span` 클래스 재사용.

**무회귀.** 기존 KPI 집계·분포 패널(`mc-stats`·`mc-insights-grid`·persona 분포 등) **잔존**. exec/writer/trace 스키마·세션 무변경. server.mjs innerHTML 0. **R1–R5 라이브 통과**. node 122/122·trace-ui 7/7(+T262 4: run 목록·실패 drill-down·?run 선택·KPI 잔존)·capability-map 7/7·failures-report 무회귀.

- 회귀: `tests/trace-ui.bats`(+4). **P2-Trace-UI(T261·T262) 완료** — 다음은 baseline 봉인(v0.86 후보). 후속: richer event emission·P2-Inbox·P2-Autonomy(별도 ADR).

### §11.88 MC 재구상 P2-Inbox-a — HITL 읽기 큐 강화 (T263·ADR-0170)

**무엇을·why.** 대기 승인 카드를 공식 HITL 모델(study v2 §11) 표면으로 *읽기* 강화 — 결정 지점·스코프·허용 결정·요청 맥락을 표시. 기존 approve/reject 실행은 그대로(실행 배선은 후속).

**구현(server.mjs).** `renderHitlContext(ticket)` 헬퍼 신규 — 승인 카드(근거/예상/다운사이드 다음, actions 앞)에 4행 컨텍스트: **결정 지점**(exec dispatch 승인 — 티켓·persona·labels)·**스코프**(`localhost` · exec whitelist)·**허용 결정**(approve/reject 칩, edit/respond는 계약 예약)·**요청 맥락**(`getRun(ROOT, id)` trace 요약 — state·status·spanCount·실패 span 여부). escape-first(escapeHtml — DOM 텍스트만).

**무회귀.** 기존 카드 내용·Approve/Reject 버튼·`approve` exec·묶음 승인(ADR-0037) 무변경(추가 표시만). server.mjs innerHTML 0. **R1–R5 라이브 통과**. node 122/122·inbox-hitl 3/3(컨텍스트 블록·결정 칩·기존 버튼 잔존)·mission_control_approval_inbox_v2 무회귀·capability-map 7/7.

- 회귀: `tests/inbox-hitl.bats`(신규, +3, host-portable·ASCII 테스트명). 후속: T264(결정 계약 + 상태 읽기 모델). P2-Inbox 완료 시 baseline 봉인(v0.87 후보).

### §11.89 MC 재구상 P2-Inbox-b — 결정 계약 + 상태 읽기 모델 (T264·ADR-0170)

**무엇을·why.** HITL 결정 계약(허용 결정·상태)을 *읽기 모델*로 고정 + UI 배지. 실행 배선(edit/respond)은 비범위(후속).

**모듈(`mission-control/inbox.mjs`, 신규·읽기 전용).** `listPending(root)` — 대기 승인(awaiting-approval) 항목별 `allowedDecisions`(v1 `[approve, reject]`, edit/respond 계약 예약) + `state`. `decisionState(root, ticket)` — `pending`(awaiting·마커 없음)·`decided`(승인 마커 존재)·`superseded`(awaiting 이탈·마커 없음). `stale`(만료)은 만료 데이터 소스 부재로 v1 도출 불가 — 계약 예약. 기존 포맷 미러(티켓 frontmatter·approvals 마커), **신규 writer/exec 0**.

**UI(server.mjs).** `renderHitlContext`에 **상태 배지**(`decisionState(ROOT, ticket)`) 1행 추가 — pending(노랑)·decided(초록)·superseded(점선). 기존 카드·버튼·exec 무변경.

**무회귀.** 읽기 전용·신규 exec/writer 0·기존 approve/reject·묶음 승인 무변경. server.mjs innerHTML 0. **R1–R5 라이브 통과**. node 126/126(+inbox 4: listPending 필터·pending/decided·superseded·빈 root)·inbox-hitl 5/5(+상태 배지 pending→decided)·capability-map 7/7·mission_control_approval_inbox_v2 무회귀.

- 회귀: `mission-control/inbox.test.mjs`(신규, +4)·`tests/inbox-hitl.bats`(+2). **P2-Inbox(T263·T264) 완료** — 다음은 baseline 봉인(v0.87 후보). 후속(별도 ADR): 실행 배선(edit/respond exec + stale 쓰기)·정책 엔진(P2-Autonomy).

### §11.90 MC 재구상 P2-Inbox-exec-a — 결정 계약 v2 (respondable 도출, 읽기) (T265·ADR-0172)

**무엇을·why.** HITL respond 실행 배선(ADR-0172)의 첫 슬라이스 — 그 *읽기 계약*만 연다. 대응 세션이 live면 respond를 허용 결정에 더하는 도출을 `inbox.mjs`에 추가. UI·exec 무변경(배선은 T266).

**모듈(`mission-control/inbox.mjs`, 읽기 확장).** `respondableDecisions(sessionState)`(순수) — live(`paused`/`running`)면 `['respond']`, terminal/null이면 `[]`(정직: 살아있지 않은 세션엔 respond 미제안). `sessionStateForTicket(root, id)` — `state/reservations/<id>.d/events.jsonl`에서 상태 도출(server.mjs `sessionStateFromEvents` 동치 미러), 예약 없으면 `null`. `listPending`이 항목별 `allowedDecisions = [approve, reject] + respondableDecisions(...)` — **approve/reject는 항상 보존**, live 세션일 때만 respond 추가. **신규 writer/exec 0**(읽기만).

**왜 respond는 새 exec가 필요 없나.** approve/reject는 이미 `approve` exec, respond는 기존 `session_ctl redirect`(abort+재디스패치) exec와 의미가 동일. 이 라운드는 *어느 항목이 respondable인가*를 읽기 모델로 못 박을 뿐 — 배선은 T266(localhost-only UI+route).

**무회귀.** 읽기 전용·신규 exec/writer 0·`ALLOWED_DECISIONS_V1` 보존·예약 없는 기존 픽스처는 `[approve, reject]` 유지(기존 node 테스트 green). node 129/129(+inbox 3: respondableDecisions 순수·sessionStateForTicket·listPending live respond)·capability-map 7/7(innerHTML 0)·inbox-hitl 5/5(UI 미변경). 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/inbox.test.mjs`(+3). 다음: **T266**(respond UI+route, localhost-only, 기존 `session_ctl redirect` 재사용·새 exec 0). 후속(별도 ADR): edit 배선·stale 쓰기·P2-Autonomy.

### §11.91 MC 재구상 P2-Inbox-exec-b — 응답 가능 세션 sub-queue + respond 배선 (T266·ADR-0172)

**무엇을·why.** P2-Inbox-exec의 respond 배선. 구현 중 실제 모델 제약을 확인했다: reservation이 있는 티켓은 `getModel()`에서 `forging`으로 분류되어 `awaiting-approval` 승인 카드와 동시에 존재할 수 없다. 따라서 respond는 승인 카드가 아니라 Inbox의 **응답 가능 세션 sub-queue**에 노출한다. 기존 Sessions의 `session_ctl redirect` 의미와 동일하게 사람 지시를 남기고 세션을 재디스패치한다.

**구현(server.mjs/ui.mjs/ui.css).** `renderRespondableSessionsQueue({ isLocalhost })` 신규 — `listSessions()`에서 live 상태(`paused`/`running`)만 골라 Inbox 상단에 렌더. localhost에서는 `renderRespondButton(id)`를 통해 기존 `/api/exec { command:'session_ctl', action:'redirect', ticketId, instruction }` 계약과 기존 confirm modal을 재사용한다. 비-localhost는 observe-only note만 표시하고 redirect 버튼을 렌더하지 않는다. `execPlan`·`session_ctl.sh`·`execScopeDecision`·신규 writer는 모두 무변경.

**계약 정정.** ADR-0172 T266 티켓의 표면을 "승인 카드 respond"에서 "응답 가능 세션 sub-queue respond"로 정정했다. approve/reject 승인 카드와 bulk approval은 그대로 유지된다. T265 `respondableDecisions` 읽기 모델은 세션 상태 계약으로 유지하되, 화면은 실제 서버 분류 모델에 맞춰 세션 큐에서 소비한다.

**무회귀.** server.mjs innerHTML 0(기존 QR sink 제외 ui.mjs only). `run_checks --fast` 통과: **R1–R5**, node **131/131**, bats **640/640**. Targeted: `inbox-hitl.bats` 8/8(비-localhost unavailable skip 포함)·`lint-negation.bats` green·capability-map green. 첫 fast run에서 새 테스트의 bare `! cmd` 금지 규칙이 잡혀 `if ...; then return 1; fi` 형태로 수정 후 재실행 green.

- 회귀: `mission-control/ui.test.mjs`(+2 renderRespondButton)·`tests/inbox-hitl.bats`(+3 T266). **P2-Inbox-exec(respond) 완료** — 다음은 baseline 봉인(v0.88 후보). 후속(별도 ADR): edit 배선·stale 쓰기·P2-Autonomy.

### §11.92 MC 재구상 P2-Inbox edit+stale-a — stale 도출(내용 기반, 읽기) (T267·ADR-0174)

**무엇을·why.** HITL 결정 계약의 마지막 두 조각(edit·stale) 중 stale의 *읽기 도출*. ADR-0174 발견: 콘텐츠/메타 writer 셋(`ticket_edit`·`ticket_body`·`ticket_lifecycle`)이 모두 open 전용이라 awaiting-approval은 동결 게이트 — 게이트 직접 편집 불가(edit는 reject→reopen→Board 흐름, T268에서 read-only 안내). 본 라운드는 stale 도출만.

**모듈(`mission-control/inbox.mjs`, 읽기 확장).** `decisionState`가 `stale` 추가 도출 — awaiting-approval + 승인 마커 존재 + **마커 `scope_confirmation`이 현재 티켓 §변경범위/§Scope 추출값과 불일치**면 stale(전형: 이전 사이클 잔여 마커). `extractSection`(approve.sh `section_oneline` 정확 미러: `## ` 헤딩만 경계·리스트/인용/체크박스·`*#` 제거·첫 3줄 압축) + `yamlEscapeCut`(yaml_escape+cut400 미러) + `markerScopeConfirmation`(선두 `-` 허용) + `readTicketText`. **측정 불가(구형 마커·TODO 폴백·섹션 없음)는 보수적 decided** — 거짓 stale 금지(ADR-0040). 신규 writer/exec 0.

**왜 mtime 아닌 내용 기반.** git checkout이 mtime을 흔들어 거짓 stale을 만든다. 승인 시점 `scope_confirmation`(approve.sh가 §변경범위에서 기록) vs 현재 추출값 비교가 "승인된 범위 ≠ 현재 범위"를 정직하게 잡는다.

**무회귀.** 읽기 전용·신규 writer/exec 0·escape-first(server.mjs innerHTML 0, 미변경)·기존 마커(scope_confirmation 없음)는 decided 유지. node 133/133(+inbox 2: stale 일치/불일치·측정불가 보수적)·capability-map 7/7·inbox-hitl 8/8(미변경). 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/inbox.test.mjs`(+2). 다음: **T268**(stale 배지 + edit 경로 read-only 안내, UI). 후속(별도 ADR): 게이트 편집 완화·승인 마커 내용 해시·P2-Autonomy.

### §11.93 MC 재구상 P2-Inbox edit+stale-b — stale 배지 + edit 경로 안내 (read-only UI) (T268·ADR-0174)

**무엇을·why.** T267 stale 도출을 화면에 정직하게 노출 + edit가 동결 게이트에서 불가함을 read-only로 안내. HITL 결정 계약(approve/reject·respond·edit·stale)의 읽기 표면 마무리.

**구현(server.mjs `renderHitlContext`, read-only).** ① 상태 배지가 `decisionState`=stale일 때 `mc-state--stale`로 표시(이미 escapeHtml 경로) + `mc-hitl__stale` 강조 안내("승인이 현재 티켓과 불일치 — 재확인 필요"). ② **편집 행 신설** — "게이트에서 직접 편집 불가(동결) — reject 후 Board에서 reopen·수정·재포지"(정적 텍스트, escapeHtml). 새 writer/exec/버튼 0 — `ticket_edit`/`ticket_body` exec를 부르지 않는다(동결 게이트 보존, ADR-0174 §1). ui.css `.mc-hitl__stale` 1줄.

**무회귀.** read-only·신규 writer/exec/버튼 0·escape-first(server.mjs innerHTML 0)·approve/reject·respond sub-queue 무변경. node 133/133·capability-map 7/7(innerHTML 0)·inbox-hitl 11/11(+3 T268: stale 배지·edit 안내·read-only 무회귀; 비-localhost skip). 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/inbox-hitl.bats`(+3). **P2-Inbox edit+stale 완료 → HITL 4결정 읽기 계약 모두 닫힘.** 다음은 baseline 봉인(v0.89 후보) 후 P2-Autonomy(정책 엔진). 후속(별도 ADR): 게이트 편집 완화·승인 마커 내용 해시.

### §11.94 MC 재구상 P2-Autonomy-a — 정책 projection 읽기 모델 (deny/ask/allow + provenance) (T269·ADR-0176)

**무엇을·why.** 자율성 "정책 엔진"의 첫 슬라이스 — *읽기 projection*. ADR-0052 "MC는 관측만" 불변식을 지키려, 새 정책 규칙 파일을 만들지 않고 **기존 enforcement 원시(loop_mode·per-ticket safe·승인 게이트·exec scope·autopilot grant)를 deny/ask/allow + provenance로 합성**한다. 동일 입력에 enforcement와 같은 결론(정직).

**모듈(`mission-control/autonomy.mjs`, 신규·읽기 전용).** `readLoopMode`/`readAutopilotGrant`(server.mjs 동치 미러) + `policyPosture(root)`(mode·grant 유효성; 미설정 mode는 governing 기본 co-pilot) + `evaluatePolicy(posture, request)` 순수 — request `{safe, command, localhost, unattended}` → `{decision: deny|ask|allow, provenance:[{rule,source,detail}], reason}`. `projectPolicy(root)`가 대표 5개 클래스(safe 자동·safe 무인·safe:false 실행·safe:false 무인·비-localhost exec)를 판정. **신규 writer/exec/게이트 0** — 막거나 허용하지 않는다(관측만).

**판정(ADR-0176 §2.2 projection).** safe:true+co-pilot→allow·suggest→ask / safe:false 무마커→ask·무인→deny(grant도 safe:false 자동 미인가) / 무인 연속 grant 유효→allow·무효→deny / 비-localhost exec approve→allow·그 외→deny. 분류 불가는 보수적 ask.

**무회귀.** 읽기 전용·신규 writer/exec/게이트 0·기존 enforcement(set_mode·grant·safe) 무변경·escape-first 무관(데이터 모듈). node 142/142(+autonomy 9)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/autonomy.test.mjs`(+9). 다음: **T270**(Autonomy 페이지 projection 표시, read-only UI). 후속(별도 ADR): budget/expiry/kill 가시화 → (매우 신중) 실제 gate 적용.

### §11.95 MC 재구상 P2-Autonomy-b — Autonomy 페이지 정책 projection 표시 (read-only) (T270·ADR-0176)

**무엇을·why.** T269 정책 projection을 Autonomy 페이지에 표시 — 요청 클래스별 deny/ask/allow 배지 + provenance(근거 enforcement 원시). 관측만(ADR-0052) — 막거나 허용하지 않는다.

**구현(server.mjs `renderAutonomyPage`, read-only).** `projectPolicy(ROOT)`(T269)로 대표 5클래스 판정 → `mc-policy-projection` 섹션(표: 요청 클래스·판정 배지·provenance). 현재 포스처(effectiveMode·grant 활성) 한 줄 요약. escape-first(escapeHtml). 기존 모드 매핑·모드 전환·grant 섹션·exec 스코프 무변경. ui.css `mc-policy*` 배지(allow=ok·ask=warn·deny=danger) + 표. 새 exec/writer/게이트 0.

**라이브 검증.** 기본 포스처(co-pilot·grant 없음): allow 1(safe 자동)·ask 1(safe:false 실행)·deny 3(safe 무인·safe:false 무인·비-localhost exec). 유효 grant 주입 시 safe 무인이 allow로 전환(allow≥2)·`grant 활성` 표기.

**무회귀.** read-only·새 writer/exec/게이트 0·escape-first(server.mjs innerHTML 0)·기존 Autonomy 무변경. node 142/142·capability-map 7/7(innerHTML 0)·autonomy-policy 5/5. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/autonomy-policy.bats`(신규, +5; @test명 ASCII). **P2-Autonomy 정책 projection 완료 → v0.90 baseline 후보.** 후속(별도 ADR): budget/expiry/kill 가시화 → (매우 신중) 실제 gate 적용·P3–P6.

### §11.96 MC 재구상 P2-Autonomy-grant-a — grant posture 분류 읽기 모델 (T271·ADR-0178)

**무엇을·why.** budget/expiry/kill 가시화의 첫 슬라이스 — *읽기 모델*. 발견: `readAutopilotGrant`는 none/revoked/expired/exhausted를 전부 `null`로 뭉개 "왜 멈췄는가"가 안 보였다. 파일(file=truth)은 구분 가능(`revoked_at`·`expiry_epoch`·`budget`; budget은 orchestrator `autopilot_grant_consume`가 차감 → 잔여 정직).

**모듈(`mission-control/autonomy.mjs`, 읽기 확장).** `grantPosture(root)` — 파일 필드로 분류: **none**(파일 없음/측정 불가)·**active**(budget>0·미만료)·**revoked**(budget=0+`revoked_at`, kill)·**expired**(budget>0·만료)·**exhausted**(budget=0·revoked_at 없음). active는 `bindsFirst`(default-tighten 임박 한계) 도출 — budget≤1이면 'budget'·minutesLeft≤1이면 'expiry'·둘 다 여유/동률은 **null**(추정 금지, ADR-0040). 신규 writer/exec 0. 기존 `readAutopilotGrant`(server.mjs/autonomy.mjs) 무변경(back-compat).

**무회귀.** 읽기 전용·신규 writer/exec 0·관측만(ADR-0052)·enforcement(orchestrator) 무변경. node 149/149(+autonomy 7: 5포스처·bindsFirst·보수적 none)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/autonomy.test.mjs`(+7). 다음: **T272**(Autonomy 페이지 grant posture 가시화, read-only UI). 후속(별도 ADR): 실제 gate 적용·grant 파라미터 UI·P3–P6.

### §11.97 MC 재구상 P2-Autonomy-grant-b — Autonomy 페이지 grant posture 가시화 (read-only) (T272·ADR-0178)

**무엇을·why.** T271 `grantPosture`를 Autonomy 페이지에 표시 — none/active/revoked/expired/exhausted를 구분해 **"왜 멈췄는가"**를 가시화. 기존엔 4포스처가 모두 "미발급"으로 보였다.

**구현(server.mjs `renderAutonomyPage`, read-only).** grant 상태 표시를 `grantPosture(ROOT)` 분류로 교체 — active(잔여 budget·만료까지·`expiry_human`·발급자 + 다음 정지 사유 `bindsFirst`)·revoked("비상 정지(kill)"·revoked_at)·expired("시간 만료·default-tighten")·exhausted("budget 소진·default-tighten")·none(미발급). 철회 버튼은 active일 때만(`isActive`); 정지 포스처는 재발급 안내. ui.css `mc-grant__stopped*` 배지(revoked=danger·expired/exhausted=warn). 기존 issue/revoke exec·`autopilotGrantScript`·정책 projection·모드 컨트롤 무변경. 새 writer/exec/컨트롤 0.

**라이브 검증.** 5포스처 픽스처(state/autopilot_grant 변형)에서 각 표시 렌더 확인: none·active(다음 정지 사유)·revoked(비상 정지·철회 버튼 미노출)·expired(시간 만료)·exhausted(budget 소진).

**무회귀.** read-only·새 writer/exec/컨트롤 0·관측만(ADR-0052)·escape-first(server.mjs innerHTML 0)·기존 grant 컨트롤·정책 projection·모드 매핑 무변경. node 149/149·capability-map 7/7·autonomy-grant 6/6·autonomy-policy 12/12. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/autonomy-grant.bats`(신규, +6; @test명 ASCII). 발견: `autopilotGrantScript`의 selector 문자열이 `data-autopilot-revoke`를 포함 → 버튼 미노출 검증은 속성 아닌 버튼 텍스트('철회 (즉시 중단)')로. **P2-Autonomy grant 가시화 완료 → v0.91 baseline 후보.** 후속(별도 ADR): 실제 gate 적용·grant 파라미터 UI·P3–P6.

### §11.98 MC 재구상 P3-Board-aging-a — card aging 읽기 모델 (T273·ADR-0180)

**무엇을·why.** P3(나머지 페이지)의 첫 슬라이스 — Board 흐름 가시성. 발견: Board는 forging에만 시간 신호 → backlog/open/approval 대기 티켓이 안 보임. `created`(271/271 존재·모델 노출) 기반으로 *생성 후 경과*를 정직하게 도출(mtime 금지).

**모듈(`mission-control/board.mjs`, 신규·읽기 전용).** `ticketAgeDays(created, nowMs)` — YYYY-MM-DD/ISO 파싱, 없음/불가 null, 미래 0 클램프. `agingLevel(ticket, nowMs, {agingDays=3, staleDays=7})` — **active 상태(backlog/open/forging/verify/awaiting-approval)에서만** fresh/aging/stale; **done/parked(skipped/blocked)→null**(종결은 지연 아님); age 불명→null(거짓 aging 금지). 임계는 관측 신호 기본값(게이트 아님, ADR-0038 stuck 동급). 신규 writer/exec 0.

**무회귀.** 읽기 전용·신규 writer/exec 0·mtime 미사용·정직(created 기반). node 155/155(+board 6)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/board.test.mjs`(+6). 다음: **T274**(Board 카드 aging 표시, read-only UI). 후속(별도 ADR): 의존 체인 명료화·done lead-time·WIP 요약·Library·Pairing.

### §11.99 MC 재구상 P3-Board-aging-b — Board 카드 aging 표시 (read-only) (T274·ADR-0180)

**무엇을·why.** T273 `agingLevel`/`ticketAgeDays`를 Board 카드에 표시 — 비종결 티켓의 *생성 후 경과*와 aging/stale 신호를 가시화. backlog/open/approval 대기 시간이 드러난다.

**구현(server.mjs `renderTicketCard`, read-only).** `agingLevel(ticket, nowMs)`·`ticketAgeDays`로 카드 meta에 칩 추가: aging/stale이면 `mc-aging--{aging,stale}` 강조 배지(Nd), fresh이면 비-forging 카드에만 muted `mc-age` 칩(forging은 reservation-age 이미 표시 → 중복 숫자 방지). done/parked·age 불명은 미표시. ui.css `mc-age`/`mc-aging*`(aging=warn·stale=danger). 기존 카드·필터·forging stuck·run/edit/lifecycle 컨트롤 무변경. escape-first. 새 writer/exec 0.

**라이브 검증.** 오래된 open→stale 배지·오늘 open→fresh 칩·old done→aging 미표시(배지 카운트 1).

**무회귀.** read-only·새 writer/exec 0·escape-first(server.mjs innerHTML 0)·기존 Board(컬럼·필터·forging 신호) 무변경. node 155/155·capability-map 7/7·board-aging 4/4. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/board-aging.bats`(신규, +4; @test명 ASCII). **P3-Board aging 완료 → v0.92 baseline 후보.** 후속(별도 ADR): 의존 체인 명료화·done lead-time·WIP 요약·Library·Pairing.

### §11.100 MC 재구상 P3-Board-leadtime-a — done lead-time 읽기 모델 (T275·ADR-0182)

**무엇을·why.** aging(active 경과, v0.92)과 짝 — done 카드의 lead-time(생성→완료 일수)을 읽기 도출해 흐름-시간을 완성. Insights가 이미 쓰는 measured/estimated 분리(ADR-0046/0048)를 *카드 단위*로 미러.

**모듈(`mission-control/board.mjs`, 읽기 확장).** `leadTimeDays(ticket)` — `created`+`completed_at`(≥created)→`{days, basis:'measured'}`; 아니면 `created`+`completed_at_est`→`{days, basis:'estimated'}`; 둘 다 불가(계측 이전·created 없음)→null. **measured 우선**(추정이 측정으로 둔갑 금지)·`completed ≥ created` 가드(`spanDays`)·mtime/재계산 없음. 신규 writer/exec 0.

**무회귀.** 읽기 전용·measured/estimated 분리·신규 writer/exec 0. node 160/160(+board 5)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/board.test.mjs`(+5). 다음: **T276**(done 카드 lead-time 표시, read-only UI). 후속(별도 ADR): WIP/요약·의존 체인·Library·Pairing.

### §11.101 MC 재구상 P3-Board-leadtime-b — done 카드 lead-time 표시 (read-only) (T276·ADR-0182)

**무엇을·why.** T275 `leadTimeDays`를 done 카드에 표시 — aging(active 경과)과 짝지어 흐름-시간 완성. measured/estimated 구분 표기.

**구현(server.mjs `renderTicketCard`, read-only).** done 카드에만 lead-time 칩: measured "Nd 리드"·estimated "~Nd 리드(추정)"(`mc-lead--est`); null(계측 이전)·non-done 미표시. aging과 상호배타(aging=active·lead=done) — 한 카드에 둘 다 안 뜸. ui.css `mc-lead`/`mc-lead--est`(measured=ok·estimated=dim italic). 기존 카드·aging·필터·컨트롤 무변경. escape-first. 새 writer/exec 0.

**라이브 검증.** measured done→"7d 리드"·estimated done→`mc-lead--est`+추정·pre-instrumentation done·active→미표시.

**무회귀.** read-only·새 writer/exec 0·escape-first(server.mjs innerHTML 0)·기존 Board/aging 무변경. node 160/160·capability-map 7/7·board-leadtime 4/4·board-aging 4/4. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/board-leadtime.bats`(신규, +4; @test명 ASCII). 구현 중 테스트 픽스처 헬퍼 위치 인자 오정렬(status/created 밀림) 자체 발견·수정 — 코드 아닌 bats 헬퍼. getModel은 캐시(modelDirty 기반)라 픽스처는 서버 기동 전 전부 배치. **P3-Board lead-time 완료 → v0.93 baseline 후보.** 후속(별도 ADR): WIP/요약·의존 체인·Library·Pairing.

### §11.102 MC 재구상 P3-Board-flow-a — 컬럼 흐름 요약 읽기 모델 (T277·ADR-0184)

**무엇을·why.** 카드 aging/lead-time 신호를 *컬럼* 단위로 종합 — "Open에 stale 몇 건?", "Done measured 몇 건?"이 헤드에서 안 보이던 갭. per-card 모델을 집계만.

**모듈(`mission-control/board.mjs`, 읽기 확장).** `columnFlowSummary(tickets, nowMs)` 순수 — 각 티켓에 `agingLevel`/`leadTimeDays`를 적용해 `{aging, stale, leadMeasured, leadEstimated}` 카운트. active 상태는 aging/stale, done은 lead-time basis로 누적(계측 이전 done 미가산). **median/평균 없음**(카운트만, Insights 소관). aging(active)과 lead(done)은 분리 집계 — 카드 신호와 동일 결론. 신규 writer/exec 0.

**무회귀.** 읽기 전용·집계만·신규 writer/exec 0. node 164/164(+board 4: active aging/stale·done measured/estimated·분리·빈 0)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/board.test.mjs`(+4). 다음: **T278**(컬럼 헤드 흐름 요약 표시, read-only UI). 후속(별도 ADR): 의존 체인·Library·Pairing.

### §11.103 MC 재구상 P3-Board-flow-b — 컬럼 헤드 흐름 요약 표시 (read-only) (T278·ADR-0184)

**무엇을·why.** T277 `columnFlowSummary`를 컬럼 헤드에 표시 — aging/lead-time 카드 신호를 컬럼 단위로 종합. Board 깊이 마무리.

**구현(server.mjs `renderBoardPage`, read-only).** 컬럼 헤드 개수 아래에 흐름 요약 칩(`mc-column__flow`): active는 `aging N`/`stale M`, done은 `측정 N`/`추정 M`(`mc-flow--lead-est`). 각 0이면 항목 생략·전부 0이면 칩 미표시. `flowSummaryChip(tickets)`가 `columnFlowSummary(tickets, nowMs)` 집계를 escape 안전 정적 마크업으로 렌더(인라인 클라이언트 JS 아님 — 서버 렌더). ui.css `mc-flow*`(aging=warn·stale=danger·측정=ok·추정=dim). 기존 컬럼 개수·카드·필터·컨트롤 무변경. 새 exec/writer 0.

**라이브 검증.** Open(오래된 open 2)→`stale 2`·Done(measured+estimated)→`측정 1`+`추정 1`·요약 0 컬럼은 칩 미표시(흐름 블록 2개만).

**무회귀.** read-only·새 writer/exec 0·escape-first(server.mjs innerHTML 0)·기존 Board(카드 aging/lead-time·컬럼·필터) 무변경. node 164/164·capability-map 7/7·board-flow-summary 4/4. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/board-flow-summary.bats`(신규, +4; @test명 ASCII). **P3-Board 흐름 요약 완료 → v0.94 baseline 후보. Board 깊이(aging·lead-time·흐름 요약) 마무리.** 다음(별도 ADR): 의존 체인·Library·Pairing.

### §11.104 MC 재구상 P3-Library-coverage-a — playbook coverage 읽기 모델 (T279·ADR-0186)

**무엇을·why.** P3 폭 확대 — Library(지식/플레이북) 페이지. 발견: playbook 카드는 보이나 "빈약함"(트리거 없음·description 없음)이 카드에 묻혀 자동 호출 불가 skill이 한눈에 안 보임. 이미 파싱된 구조 필드를 *분류*만.

**모듈(`mission-control/library.mjs`, 신규·읽기 전용).** `skillCoverage(skill)` 순수 → `{hasDescription, triggerCount, hasForbidden, level}`; level=complete(desc+트리거≥1)·partial(하나만)·sparse(둘 다 없음). `coverageSummary(skills)` → `{complete, partial, sparse, noTrigger, total}` 카운트. **품질 점수·AI 평가 없음**(존재/개수만, ADR-0040). 누락 필드/null은 sparse로 견고. 신규 writer/exec 0.

**무회귀.** 읽기 전용·파싱만·신규 writer/exec 0. node 170/170(+library 6)·capability-map 7/7. 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `mission-control/library.test.mjs`(+6). 다음: **T280**(Library coverage 표시 — 카드 배지 + 상단 요약, read-only UI). 후속(별도 ADR): Pairing 재구상.

### §11.105 MC 재구상 P3-Library-coverage-b — playbook coverage 표시 (read-only) (T280·ADR-0186)

**무엇을·why.** T279 읽기 모델(`library.mjs`)을 Library 페이지에 표시만. 각 playbook 카드 상단에 coverage 배지(완전/부분/빈약), 페이지 상단에 요약 패널(완전·부분·빈약·트리거 없음·총 카운트). 빈약·트리거 없음을 한눈에 — 자동 호출 불가 skill을 director가 즉시 식별. **점수·평가 아님**(구조 필드 존재/개수만, ADR-0040).

**표면(`renderPlaybookCard`·`renderLibraryPage`, escape-first).** `skillCoverage`→카드 배지 `mc-cov--{level}`(완전/부분/빈약). `coverageSummary`→상단 `mc-cov-summary` 패널: 완전 N·부분 N·빈약 N·트리거 없음 N(`when_to_invoke` 없음=자동 호출 불가, danger·dashed)·총 N. ui.css `.mc-cov*`(complete=ok·partial=warn·sparse/notrigger=danger). 신규 writer/exec/gate 0, innerHTML 0.

**무회귀.** 읽기 전용 UI·기존 카드/패널 무변경. node 170/170·capability-map 7/7(innerHTML 0)·`library-coverage.bats` 4/4(배지·sparse 강조·요약 카운트·무회귀). 호스트 `run_checks --full`로 R1–R5 확인 예정.

- 회귀: `tests/library-coverage.bats`(+4). 다음: v0.95.0 봉인(ADR-0187, T279·T280). 후속(별도 ADR): Pairing 재구상(보안 민감 — device token/QR).

### §11.106 MC 재구상 P3-Pairing-posture-a — device fleet posture 읽기 모델 (T281·ADR-0188)

**무엇을·why.** P3 폭 확대 — Pairing 페이지. Pairing 스택은 이미 성숙(발급·회전·갱신·폐기·QR·TTL·상한·last_seen·token-auth/R6). 누락: fleet 수준 위생 신호("활성 N/상한 M" 카운트뿐). `listDevices` 레코드를 *분류*만.

**모듈(`mission-control/device-posture.mjs`, 신규·읽기 전용).** `devicePosture(device, nowMs, {staleDays=14})` → `{level, expiresInDays, staleDays, neverSeen}`; level 우선순위 inactive(!active)→renew-soon(renewable)→stale(미사용>14d/neverSeen)→active. `fleetPosture(devices, {staleDays, max})` → `{active, renewSoon, stale, inactive, total, activeTotal, nearCap, atCap}`. **점수·평가 없음**(일수/개수만, ADR-0040). **토큰 발급/회전/폐기/인증/QR/엔드포인트 미접촉** — 신규 writer/exec/endpoint 0. null/누락 견고.

**무회귀.** 읽기 전용·분류만. node 182/182(+device-posture 12). 호스트 `run_checks --full`로 R1–R6 확인 예정.

- 회귀: `mission-control/device-posture.test.mjs`(+12). 다음: **T282**(기기 패널 헤더 posture 요약 표시, read-only UI).

### §11.107 MC 재구상 P3-Pairing-posture-b — 기기 패널 posture 요약 표시 (read-only) (T282·ADR-0188)

**무엇을·why.** T281 읽기 모델을 Pairing "등록된 기기" 패널 헤더에 표시만. posture 요약 칩(정상/갱신 임박/미사용/비활성)·상한 근접/도달 배지로 director가 위생(갱신 임박·잊힌 기기·상한)을 한눈에.

**표면(`renderPairingMain`, escape-first).** `fleetPosture`(ui.mjs import)→`mc-fleet-summary` 칩 행: 정상 N(ok)·갱신 임박 N(warn)·미사용 N(danger)·비활성 N(dim)·각 0 생략·기기 없으면 미표시. nearCap→`상한 근접 N/M`(warn·dashed)·atCap→`상한 도달 M/M`(danger). ui.css `.mc-fleet*`. 서버 렌더 정적 마크업(인라인 JS 아님). 신규 writer/exec/endpoint 0, innerHTML 0.

**무회귀.** 읽기 전용 UI·기존 기기 테이블/페어링 패널/시작·복사·폐기·이름변경·갱신 무변경. **보안 영역(token-store/auth/qr/엔드포인트) 0 변경.** node 182/182·capability-map 7/7(innerHTML 0)·ui+R6 보안 경계 44/44·`pairing-posture.bats` 4/4(요약 칩·level 카운트·near-cap·무회귀). 호스트 `run_checks --full`로 R1–R6 확인 예정.

- 회귀: `tests/pairing-posture.bats`(+4). 다음: v0.96.0 봉인(ADR-0189, T281·T282) — P3(Board·Library·Pairing) 폭 마무리. 후속(별도 ADR·신중): 토큰 회전 UX·만료 알림.

### §11.108 MC 재구상 P3-Board-dep-a — resolveDeps 의존 체인 읽기 모델 (T283·ADR-0190)

**무엇을·why.** Board는 이미 `depends_on` 미충족 시 카드를 blocked로 분류하지만, dep 칩이 미충족 ID만 나열(⛓ T201) — 어느 티켓·무슨 상태인지 불명. dep ID를 이미 로드된 모델에 *대조*만.

**모듈(`mission-control/board.mjs` `resolveDeps`, 순수·읽기).** `resolveDeps(dependsOn, ticketsById)` → `[{id, title, status, met, missing}]`. met=status==='done'·missing=맵에 없는 ID(오타/삭제 무결성 신호, ADR-0040). depends_on 순서 보존·id 정규화·충족 dep도 포함·견고(비배열/null·맵 누락). 점수 없음. blocked 판정·게이트·티켓 파일 무변경. 신규 writer/exec 0.

**무회귀.** 읽기 전용·대조만. node 188/188(+board resolveDeps 6). 호스트 `run_checks --full` R1–R6.

- 회귀: `mission-control/board.test.mjs`(+6). 다음: **T284**(카드 dep 칩 명료화 표시, read-only UI).

### §11.109 MC 재구상 P3-Board-dep-b — 카드 dep 칩 명료화 표시 (read-only) (T284·ADR-0190)

**무엇을·why.** T283 모델을 Board 카드 미충족 dep 칩에 표시만. ID 나열 대신 각 blocker의 상태(승인대기/forging/보류…)·missing(파일 없는 ID)을 보여 director가 *왜* 막혔는지 즉시 읽음.

**표면(`renderTicketCard`·`renderBoardPage`, escape-first).** `renderBoardPage`가 모델 전체에서 `ticketsById`(id→{title,status}) 1회 조립→카드 주입. 카드 칩: 미충족 dep마다 `⛓ <id> <상태>`(`depStatusLabel` 한글 라벨·기존 컬럼 라벨과 일관), 제목은 title 툴팁/aria. missing은 `<id> 없음`(`mc-dep--missing` danger·dashed). 충족 dep은 칩 없음. ui.css `.mc-dep*`. 서버 렌더 정적 마크업. 신규 writer/exec 0, innerHTML 0.

**무회귀.** blocked 판정(doneIds 기반)·is-blocked·data-blocked·Backlog 분류·Run 가시성·aging/lead-time/흐름 요약 전부 무변경. node 188/188·capability-map 7/7(innerHTML 0)·`board-dep-clarity.bats` 4/4(상태 칩·missing 강조·충족 미표시·blocked 무회귀). 호스트 `run_checks --full` R1–R6.

- 회귀: `tests/board-dep-clarity.bats`(+4). 다음: v0.97.0 봉인(ADR-0191, T283·T284). 후속(별도 ADR): 전이적 체인·`blocks` 역방향·richer events.

### §11.110 MC 재구상 P3-Board-rev-a — reverseDeps 역방향 의존 읽기 모델 (T285·ADR-0192)

**무엇을·why.** 정방향 dep(ADR-0190)의 역방향 — "이 티켓이 무엇을 막는가". `blocks` 필드는 모델에 없고 저자 유지라 drift 가능 → 실제 `depends_on` 엣지에서 계산(X blocks Y ⟺ Y.depends_on∋X, ADR-0040).

**모듈(`mission-control/board.mjs` `reverseDeps`, 순수·읽기).** `reverseDeps(ticketId, tickets)` → `{downstream:[{id,title,status}], openCount, total}`. downstream=ticketId을 depends_on에 적은 티켓들·자기참조 제외·tickets 순서 보존. openCount=downstream 중 status!=='done'(아직 대기)="끝내면 N개 진전" 우선순위 신호. 점수 없음. 견고(비배열/null·무효 id·null 항목·id 정규화). blocked 판정·게이트·티켓 파일 무변경. 신규 writer/exec 0.

**무회귀.** 읽기 전용·계산만. node 195/195(+board reverseDeps 7). 호스트 `run_checks --full` R1–R6. (검증 중 read-model 캐시 안정화 별도 커밋 — fs.watch 누락 시 fingerprint 재스캔.)

- 회귀: `mission-control/board.test.mjs`(+7). 다음: **T286**(카드 downstream 표시, read-only UI).

### §11.111 MC 재구상 P3-Board-rev-b — 카드 downstream 표시 (read-only) (T286·ADR-0192)

**무엇을·why.** T285 모델을 Board 카드에 표시만. 카드가 막는 downstream(아직 대기 중) 수를 보여 director가 리더십 티켓("끝내면 N개 진전")을 눈으로 식별.

**표면(`renderTicketCard`·`renderBoardPage`, escape-first).** `renderBoardPage`가 `allTickets`(평탄화) 조립→카드 주입. 카드 칩: active(비-done)이고 openCount>0일 때 `⛓→ N`(`mc-blocks`), downstream id·상태는 title 툴팁/aria(done downstream 제외). done 카드는 미표시(이미 엣지 충족·active-only). ui.css `.mc-blocks`(정방향 `.mc-deps`와 방향 `→` 구분). 신규 writer/exec 0, innerHTML 0.

**무회귀.** 정방향 dep 칩·blocked/Backlog·Run 가시성·aging/lead-time/흐름 요약 전부 무변경. node 195/195·capability-map 7/7(innerHTML 0)·`board-reverse-deps.bats` 4/4(downstream 카운트·툴팁·done 카드 미표시·정방향 무회귀). 호스트 `run_checks --full` R1–R6.

- 회귀: `tests/board-reverse-deps.bats`(+4). 다음: v0.98.0 봉인(ADR-0193, T285·T286). 후속(별도 ADR): declared blocks 불일치 경보·전이적 체인·richer events.

### §11.112 MC 재구상 P3-Board-consist-a — blocksConsistency 정합성 읽기 모델 (T287·ADR-0194)

**무엇을·why.** read-first 측정: `blocks` 필드는 vestigial(285개 중 120개 drift·actual-not-declared 183=규범). director 결정 → declared-not-actual(진짜 stale 선언 25건)만 경보(양방향 노이즈 배제).

**모듈(`mission-control/board.mjs` `blocksConsistency`, 순수·읽기).** `blocksConsistency(declaredBlocks, ticketId, tickets)` → `{stale:[{id,reason}], staleCount, consistent}`. declared blocks 중 실제 `depends_on` 역엣지(reverseDeps) 없는 항목만 stale — reason `missing`(대상 부재)/`no-edge`(대상 있으나 미의존). actual-not-declared는 계산조차 안 함(규범). 순서 보존·중복 제거·견고. 점수 없음. 게이트·티켓 파일 무변경. 신규 writer/exec 0.

**무회귀.** 읽기 전용·대조만. node 202/202(+board blocksConsistency 7). 호스트 `run_checks --full` R1–R6.

- 회귀: `mission-control/board.test.mjs`(+7). 다음: **T288**(blocks 파싱 + 카드 stale 경보 표시, read-only UI).

### §11.113 MC 재구상 P3-Board-consist-b — 카드 blocks stale 경보 표시 (read-only) (T288·ADR-0194)

**무엇을·why.** T287 모델을 Board 카드에 표시만. declared blocks가 실제 엣지와 어긋나면(stale 선언) 경보 — 메타데이터 무결성 신호(missing-dep 계열). vestigial `blocks`의 진짜 결함만 조용히 표면화.

**표면(`renderTicketCard`·모델 파싱, escape-first).** 모델 티켓에 `blocks` 파싱 추가(읽기 경로·신규 writer 0). 카드에서 `blocksConsistency(ticket.blocks, ticket.id, allTickets)`→staleCount>0일 때 `⚠ blocks 선언 N`(`mc-blocks-stale` warn)·stale id·reason(대상 없음/엣지 없음)은 title 툴팁. 0이면 미표시. 모든 상태 표시(메타 무결성이라 active-only 아님). ui.css `.mc-blocks-stale`. 서버 렌더 정적 마크업. 신규 writer/exec 0, innerHTML 0.

**무회귀.** 정방향 `mc-deps`·역방향 `mc-blocks`·blocked/Backlog·Run 가시성 전부 무변경. node 202/202·capability-map 7/7(innerHTML 0)·`board-blocks-consistency.bats` 4/4(stale 배지·missing/no-edge reason·정합·미선언 무경보(노이즈 없음)·무회귀). 호스트 `run_checks --full` R1–R6.

- 회귀: `tests/board-blocks-consistency.bats`(+4). 다음: v0.99.0 봉인(ADR-0195, T287·T288). 후속(별도 ADR): 전이적 체인·richer events·보안 민감 쓰기.
