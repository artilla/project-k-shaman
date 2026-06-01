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

**분기 3 — WIP 있으나 위험·범위 초과**

- **회수 금지**. `.ralph/wt-<id>` worktree를 폐기하고 티켓을 `blocked`로 변경.
- 범위 확장 WIP는 새 티켓으로 분리해 planner에게 위임.
- 선례 개념: T053 트립와이어 조건.

참조: [ADR-0017](decisions/0017-v0.12-timeout-wip-recovery.md)

### 3.8 Step 2 헤드리스 stall 후 WIP 회수

`run_loop.sh TXXX`가 메인 워크트리에서 헤드리스 세션을 디스패치한 뒤, 산출물은 작성됐지만 세션이 종료·검증·commit 단계로 돌아오지 않는 경우가 있다. 이 경우도 **실패 3회 자동 폐기 규칙을 적용하지 않는다**. 메인 워크트리는 인간 소유이고, WIP가 회수 가능한 운영 산출물일 수 있기 때문이다.

증상:

```text
🤖 헤드리스 세션 디스패치...
# 장시간 추가 출력 없음
git status --short
# M docs/master-spec.md
# M docs/tickets/TXXX-*.md
# ?? docs/decisions/...
```

회수 절차:

1. `ps` / `pgrep -fl "run_loop|run_headless|claude -p"`로 실제 프로세스가 아직 살아 있는지 확인한다.
2. `git status --short`, `git diff`, 산출물 본문을 먼저 읽어 **티켓 scope 안의 WIP인지** 확인한다.
3. 산출물이 scope 안이고 보존 가치가 있으면, 멈춘 `run_loop`/`run_headless`/`claude -p` 프로세스만 종료한다. `git reset --hard`는 금지.
4. `state/lock`, `state/current_ticket`, `state/reservations/<TXXX>.d/`가 남아 있으면 pid가 죽었음을 확인한 뒤 제거한다.
5. 사람이 빠진 의무를 마무리한다: 수용 기준 보강, `run_checks`, 티켓 `status: done`, `git mv docs/tickets/TXXX-*.md docs/tickets/DONE/`, 단일 완료 commit.
6. WIP가 scope 밖이거나 위험하면 회수하지 않고 `docs/reviews/<TXXX>-failed.diff`로 보존한 뒤 티켓을 `blocked`로 전환한다.

선례: T005 — planner가 ADR WIP를 작성했지만 종료/commit 단계에서 stall. operator가 공식 출처 보강, `run_checks` full green 확인, DONE 이동, 단일 완료 commit으로 회수.

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
