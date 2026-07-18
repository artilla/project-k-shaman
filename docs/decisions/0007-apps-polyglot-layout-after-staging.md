# ADR-0007: 첫 staging 배포 이후 `apps/api` + `apps/web` 폴리글랏 레이아웃

- 현재 hold: 채택·발효 (2026-07-18, 첫 staging apply 전 경로 이동 금지)
- 목표 레이아웃: 제안 (`apps/api` + `apps/web`, 첫 staging apply 이후 재검토)
- 관련: ADR-0005, ADR-0006, T028
- 변경 성격: 동작 수정이 아닌 저장소 구조 정제

## 맥락

현재 `src/shindang` + `frontend` 구조는 잘못된 구조가 아니다. Python 제품 코드는
PyPA의 `src` layout에 따라 import 가능한 패키지로 격리돼 있고, Vite 애플리케이션은
`frontend`를 자체 project root로 사용한다. 현재 구조는 전체 검증, PostgreSQL 16
migration 회귀 70건, 비루트·read-only 컨테이너 smoke와 T028 배포 계약을 통과했다.

다만 저장소가 Python과 TypeScript를 함께 운용하므로 두 실행 단위를 언어 중립적인
`apps/` 아래에 배치하면 다음 장점이 있다.

- Python과 Vite가 각각 자기 생태계의 project root를 가진다.
- 향후 `worker`, `admin` 같은 실행 단위가 생겨도 같은 규칙으로 확장할 수 있다.
- 루트 `src/`가 저장소 전체 source의 통칭인지 Python packaging 경계인지 생기는
  의미 충돌을 없앤다.
- `api`, `web`이라는 역할 중심 이름으로 배포·관측 단위를 찾기 쉬워진다.

이 이득은 대칭성·확장성·탐색성에 있으며 현재 기능 결함을 고치는 것은 아니다. 반면
경로 이동은 Docker build context, CI cache, Python packaging, Vite root, 테스트 발견,
문서 링크와 배포 계약을 동시에 바꾼다. 특히 첫 staging 배포 직전에는 이미 검증한
경로를 유지하는 편이 안전하다.

## 결정 제안

첫 staging apply와 smoke가 성공하기 전에는 현재 `src/shindang` + `frontend` 구조를
유지한다. 이 hold는 현재 발효 중인 결정이며 목표 레이아웃 제안의 채택 여부와
무관하게 적용한다. 성공 증거가 남은 뒤 별도 리팩터링으로 다음 목표 구조를
재검토한다.

```text
ProjectK-Shaman/
├── apps/
│   ├── api/
│   │   ├── pyproject.toml
│   │   ├── src/
│   │   │   └── shindang/
│   │   │       ├── domain/
│   │   │       ├── application/
│   │   │       ├── adapters/
│   │   │       └── web/
│   │   └── tests/
│   └── web/
│       ├── package.json
│       ├── package-lock.json
│       ├── vite.config.ts
│       ├── index.html
│       ├── src/
│       └── public/
├── contracts/
├── db/migrations/
├── tests/
│   ├── architecture/
│   ├── integration/
│   └── deployment/
├── deploy/
├── infra/
├── tools/
├── docs/
└── Dockerfile
```

세부 계약은 다음과 같다.

1. Python import package 이름 `shindang`과 내부
   `domain -> application <- adapters <- web` 의존성 방향은 바꾸지 않는다.
2. Vite project root는 `apps/web`, React source root는 `apps/web/src`로 둔다.
3. 프로덕션은 계속 하나의 image와 하나의 HTTPS origin을 사용한다. 이 ADR은
   frontend와 API를 독립 배포 서비스로 분리하지 않는다.
4. `db/migrations`와 `scripts/db_migrate.sh`는 첫 `apps/` 이동의 범위에서 제외해
   저장소 루트에 유지한다. 데이터베이스 변경은 앱 코드 이동보다 강한 승인·원자성
   계약을 가지며, 단순 대칭성을 위해 그 경로를 바꾸지 않는다.
5. migration을 추후 `apps/api` 아래로 옮길 필요가 생기면 별도 결정과 별도 커밋으로
   수행한다. commit tree, working tree와 blob 경로를 검증하는 runner 및 전체 Bats
   fixture를 함께 변경하고 PostgreSQL 16 전체 회귀를 다시 통과해야 한다.
6. 경로 이동에는 기능, API, schema, migration SQL과 배포 topology 변경을 섞지 않는다.

## 실행 시점 게이트

다음 조건이 모두 충족된 뒤에만 이동을 시작한다.

- T028의 clean `docker buildx build --push`가 배포 대상 commit에서 성공했다.
- 첫 staging apply, readiness/health smoke와 브라우저 핵심 흐름이 성공했다.
- 배포 image digest, 직전 정상 digest와 rollback 결과를 staging 기록에 남겼다.
- 경로 이동을 실제 staging 장애 수정과 분리할 수 있는 안정 구간을 확보했다.
- 별도 branch와 단일 목적 커밋으로 되돌릴 수 있다.

## 경로 변경 체크리스트

### Python packaging

- `pyproject.toml`, build-system lock과 runtime lock의 새 기준 위치를 한 곳으로 정한다.
- setuptools package discovery가 `apps/api/src/shindang`만 포함하는지 wheel contents로
  확인한다.
- source tree 밖의 작업 디렉터리에서 설치된 wheel의 `import shindang`과 앱 기동을
  검증한다.
- repository root를 찾는 설정 코드가 `pyproject.toml`의 기존 위치에 의존하지 않도록
  계약 테스트를 갱신한다.

### Vite와 정적 자산

- `apps/web`에서 `npm ci`, typecheck와 production build를 실행한다.
- `index.html`, `vite.config.ts`, `public/static`과 `dist`의 소유권을 함께 이동한다.
- 개발 proxy의 `/api`, `/audio` 계약과 production same-origin fallback을 재검증한다.
- asset manifest와 문서 내 상대 링크를 새 project root 기준으로 검사한다.

### Docker와 배포

- frontend build stage의 `COPY`, working directory와 dist 산출물 경로를 갱신한다.
- Python wheel stage가 `apps/api`만 build context로 사용하도록 갱신한다.
- runtime image의 정적 자산 위치, UID 10001 읽기 권한과 read-only root filesystem
  계약을 재검증한다.
- GitHub Actions의 dependency cache path, test working directory와 build context를
  모두 갱신한다.
- SSM 배포보다 앞선 clean buildx push와 immutable digest 전달 순서를 보존한다.

### 테스트와 문서

- pytest root/config, architecture AST 검사, documentation path 검사와 Bats discovery를
  새 경로에 맞춘다.
- `README`, 프로젝트 구조 문서, 로컬 실행 runbook, HTML 아키텍처 가이드와 ADR의
  경로 예시를 한 커밋에서 갱신한다.
- 이전 `src/shindang`·`frontend` 경로를 허용된 역사 문서 외에서 검색해 stale 참조가
  없음을 확인한다.
- `db/migrations` 공개본의 내용과 승인 checksum은 변경하지 않는다.

## 필수 재검증

이동 커밋은 최소한 다음 증거가 모두 있어야 승인할 수 있다.

```text
./ralph/scripts/run_checks.sh --full
PostgreSQL 16 migration Bats: 1..70, 70 ok, 0 skip
apps/web clean npm ci + typecheck + production build
Python wheel build + source tree 밖 설치/import smoke
clean no-cache multi-stage Docker build
UID 10001 + read-only root filesystem runtime smoke
same-origin API/SPA/readiness/health browser smoke
deployment contract checks and workflow path review
```

경로 변경으로 migration 테스트 수를 의도적으로 바꾸지 않는다. 테스트 수가 바뀐다면
ADR-0006과 CI의 정확한 TAP 단언을 같은 변경에서 갱신하고 이유를 별도로 리뷰한다.

필수 재검증 중 하나라도 실패하면 반쯤 이동한 트리에서 forward patch를 이어가지
않는다. 미커밋 변경은 이동 전 상태로 폐기하고, 이미 생성한 단일 목적 커밋은 전체를
revert한 뒤 실패 원인을 독립적으로 수정한다. 원인이 해결되고 현재 레이아웃의 gate가
다시 green인 상태에서만 새 이동 시도를 시작한다.

## 대안

### 현재 구조를 영구 유지

기술적으로 유효하고 가장 단순하다. 추가 실행 단위가 생기지 않으면 이 ADR을 채택하지
않고 현재 구조를 유지해도 된다.

### `src/backend` + `src/frontend`

Python packaging의 `src` 의미와 저장소 전체 source의 의미를 섞는다. 기각한다.

### `apps/backend` + `apps/frontend`

명확하고 신규 합류자에게 익숙한 대안이다. 다만 실행 역할과 향후 `worker`, `admin`
확장을 표현하는 `api`, `web` 명칭을 우선 제안한다. 이름은 구현 전에 최종 확정한다.

### 첫 staging 배포 전에 즉시 이동

아직 외부 입력만 남은 T028 경로를 다시 흔들고 기존 clean build와 migration 검증의
일부를 무효화한다. 기각한다.

## 결과

- 목표 구조와 연기 이유가 코드 이동 없이 기록된다.
- 첫 staging 배포는 이미 검증된 경로로 수행한다.
- 추후 이동은 동작 변경과 분리된 독립 리팩터가 된다.
- 데이터 migration 경계를 앱 디렉터리의 미관보다 우선한다.
- 실제로 두 번째 실행 단위가 생기지 않거나 이동 비용이 이득보다 크면 제안을 채택하지
  않고 종료할 수 있다.

## 근거

- Python Packaging User Guide, src layout vs flat layout:
  <https://packaging.python.org/en/latest/discussions/src-layout-vs-flat-layout/>
- Vite, Project Root:
  <https://vite.dev/guide/#index-html-and-project-root>
- Vite, Shared Options `root`:
  <https://vite.dev/config/shared-options#root>
