# ProjectK-Shaman 디렉터리와 아키텍처

오늘신당은 React 프런트엔드와 FastAPI API를 한 origin에서 제공하는 **모듈러
모놀리스**다. 배포 단위는 하나지만 Python 내부 의존성은 도메인 쪽으로만 향한다.
Ralph Loop는 제품 코드와 분리된 `ralph/`에 둔다.

## 전체 구조

```text
ProjectK-Shaman/
├── src/shindang/              # 설치 가능한 Python 제품 패키지
│   ├── domain/                # 순수 운세·꿈·카드 규칙
│   ├── application/           # 유스케이스와 외부 포트
│   ├── adapters/              # cache·TTS·OAuth·session·event 구현
│   ├── web/                   # FastAPI 입력 어댑터와 APIRouter
│   ├── config.py              # 검증 후 불변인 환경 설정
│   └── bootstrap.py           # 유일한 composition root
├── frontend/                  # React + TypeScript + Vite PWA
│   ├── src/
│   └── public/static/         # 캐릭터·Live2D 정적 자산의 단일 원본
├── contracts/fortune/         # 버전 관리되는 JSON Schema와 고정 샘플
├── tools/                     # 오프라인 검증·분석·TTS 도구
├── tests/                     # 제품·아키텍처·DB·배포 회귀
├── db/migrations/             # append-only PostgreSQL migration
├── deploy/                    # 원격 배포·rollback·Caddy 구성
├── infra/cloudformation/      # AWS 인프라 정의
├── scripts/                   # 제품 DB·배포 계약 CLI
├── docs/                      # 제품/운영 문서 정본
├── ralph/                     # 추적되는 Ralph Loop 하네스
├── state/                     # 앱 런타임 쓰기 경계; 대부분 gitignore
├── .ralph/                    # Ralph 실행 상태; 전체 gitignore
├── reference/                 # 정본이 아닌 외부 참고·프로토타입
├── pyproject.toml             # Python 패키지·테스트·lint 설정
├── requirements.lock         # pyproject에서 생성한 hash-pinned 배포 의존성
├── requirements-build.lock   # wheel builder의 hash-pinned setuptools
├── Dockerfile
├── compose.yaml
└── README.md
```

`backend/`와 `fortune-engine/`은 제거했다. HTTP와 도메인을 서로 다른 최상위
디렉터리로 나눴던 과도기 구조는 import 조작, 중복 requirements, 정적 자산 이중
소유를 만들었다. 현재는 하나의 설치 가능한 패키지 안에서 경계를 코드로 강제한다.

## Python 의존성 방향

```text
web ───────────────┐
                   v
adapters ──> application ──> domain
   ^               ^
   └── bootstrap ──┘
          ^
        config
```

- `domain/`: HTTP, 파일, 네트워크, 환경변수, 현재 시각을 읽지 않는다.
- `application/`: 유스케이스와 `Protocol` 포트만 정의한다. 어댑터를 import하지 않는다.
- `adapters/`: 포트를 기술별로 구현한다. FastAPI route를 import하지 않는다.
- `web/`: 입력 검증, cookie, status code와 route만 담당한다.
- `bootstrap.py`: 설정을 읽은 뒤 구현을 연결하는 유일한 장소다.

`tests/test_architecture.py`가 이 의존성 방향을 AST로 검사한다. 새 모듈을 추가할 때
이 검사를 우회하지 말고 책임 위치를 다시 판단한다.

### 주요 모듈

| 경로 | 책임 |
| --- | --- |
| `domain/seed.py` | 결정적 seed 신호; 해시 함수는 외부 주입 |
| `domain/fortune.py` | 운세 본문·점수 생성 |
| `domain/narration.py` | 8개 낭독 세그먼트 조립 |
| `domain/dream.py` | 꿈 상징 감지와 풀이 |
| `domain/*_card.py` | I/O 없는 SVG 렌더링 |
| `application/playback.py` | seed→fortune cache→선택적 TTS 유스케이스 |
| `application/cache.py` | 동시 miss를 막는 원자적 get-or-compute |
| `application/ports.py` | cache, speech, OAuth, event 포트 |
| `adapters/tts.py` | mock/OpenAI TTS 구현과 비용 경계 |
| `adapters/seed_hash.py` | 용도 분리된 HMAC 개인화 해시 |
| `adapters/session.py` | 현재 단일 인스턴스 세션 구현 |
| `web/cookies.py` | HTTP 세션 쿠키 이름과 서명 형식 |
| `web/routers/` | auth, fortune, dream, event, health route |
| `bootstrap.py` | 구현 선택과 애플리케이션 컨테이너 구성 |

현재 session, rate limit, fortune/cache는 단일 프로세스 메모리 어댑터다. 수평 확장이나
재시작 간 세션 유지가 필요해지면 application 포트는 유지하고 PostgreSQL/Redis
어댑터만 교체한다. 기능 경계를 먼저 네트워크 서비스로 쪼개지 않는다.

## 프런트엔드와 정적 자산

`frontend/src/`는 화면·상태·API client를 소유한다. 개발 시 Vite가 `/api`와
`/audio`만 `127.0.0.1:8788`로 프록시한다. `frontend/public/static/`은 캐릭터와
Live2D 자산의 단일 원본이며 Vite build 때 `frontend/dist/static/`으로 복사된다.

프로덕션에서는 FastAPI가 빌드된 `frontend/dist/`를 fallback mount해 API와 SPA를
동일 origin에서 제공한다. 별도 CORS나 cross-site session cookie를 도입하지 않는다.

## 계약, 도구, 테스트

| 경로 | 배치 기준 |
| --- | --- |
| `contracts/fortune/` | 앱과 도구가 함께 소비하는 버전 계약 |
| `tools/fortune/` | schema 검증, 공유 카드 오프라인 생성 |
| `tools/analytics/` | 재생 이벤트 분석 |
| `tools/tts/` | TTS 실험·A/B 산출 도구 |
| `tests/test_*.py` | 도메인·application·HTTP·아키텍처 회귀 |
| `tests/db-migrate.bats` | PostgreSQL migration 계약 |
| `tests/deployment-hardening.bats` | 배포 보안 계약 |

`tools/`는 배포 패키지에 포함하지 않는다. 저장소 루트에서 editable install 후
`python -m tools.<module>` 형태로 실행한다.

## DB와 배포

- `db/migrations/`: 공개된 SQL을 수정하지 않고 다음 번호 파일을 추가한다.
- `scripts/db_migrate.sh`: migration manifest와 원자적 apply 경계다.
- `deploy/`: immutable image digest와 고정 S3 VersionId를 받아 원격 배포/복구한다.
- `infra/cloudformation/`: 과금 가능한 AWS 리소스의 선언이다.
- `.github/workflows/`: CI와 배포 오케스트레이션만 담당한다.

앱은 포트 8000을 host에 직접 공개하지 않는다. Caddy만 80/443을 공개하고 앱은
Compose 내부 네트워크에 둔다. 이미지 runtime은 UID/GID 10001, read-only rootfs,
쓰기 가능한 `/app/state` volume을 사용한다.

## 문서와 Ralph Loop

`docs/`는 제품 정본이다.

| 경로 | 내용 |
| --- | --- |
| `docs/master-spec.md` | 현재 제품 최상위 명세 |
| `docs/planning/` | 서비스 기획·실행 계획 버전 |
| `docs/product/`, `docs/prompts/`, `docs/ux/` | 제품·프롬프트·화면 계약 |
| `docs/assets/` | 에셋 생성·선정 명세 |
| `docs/decisions/` | ADR |
| `docs/research/`, `docs/reports/` | 조사와 측정 결과 |
| `docs/runbooks/` | 반복 가능한 실행·운영 절차 |
| `docs/tickets/` | open/DONE/ARCHIVE 작업 단위 |
| `docs/approvals/`, `docs/deployments/`, `docs/reviews/` | 승인·배포·review evidence |

`ralph/`는 추적 가능한 운영 하네스 소스이고 `.ralph/`는 실행 중 생기는 상태다.
Ralph 스크립트·Mission Control·회귀 테스트를 제품 `scripts/`·`tests/`와 섞지 않는다.

## 새 파일 배치 규칙

| 목적 | 위치 |
| --- | --- |
| 순수 제품 규칙 | `src/shindang/domain/` |
| 여러 입구에서 재사용할 유스케이스 | `src/shindang/application/` |
| DB·네트워크·파일·provider 구현 | `src/shindang/adapters/` |
| FastAPI route·cookie·HTTP validation | `src/shindang/web/` |
| 구현 연결·환경별 선택 | `src/shindang/bootstrap.py` |
| React UI·브라우저 상태 | `frontend/src/` |
| 브라우저 정적 자산 | `frontend/public/static/` |
| 공유 JSON 계약 | `contracts/` |
| 오프라인/분석 도구 | `tools/` |
| 반복 운영 절차 | `docs/runbooks/` |
| Ralph 하네스 | `ralph/` |
| 재생성 가능한 상태 | `state/` 또는 `.ralph/` |

프로젝트 루트에는 저장소 전체의 진입점과 빌드 설정만 둔다. 일반 Markdown, 보고서,
실행 로그, 생성 이미지를 루트에 추가하지 않는다.

## 주요 진입점

| 작업 | 진입점 |
| --- | --- |
| FastAPI 앱 | `shindang.web.app:app` |
| 로컬 서버 | `docs/runbooks/local-server.md` |
| 프런트엔드 개발 | `frontend/package.json`의 `dev` script |
| 전체 검증 | `ralph/scripts/run_checks.sh --full` |
| DB migration | `scripts/db_migrate.sh` |
| 배포 계약 | `scripts/check_deployment_contract.sh` |
| Mission Control | `ralph/scripts/mission_control.sh` |
