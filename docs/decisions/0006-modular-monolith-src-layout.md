# ADR-0006: same-origin 모듈러 모놀리스와 `src` 패키지 구조

- 상태: 승인 (2026-07-16)
- 대체 범위: ADR-0003의 `backend/`와 `fortune-engine/` 물리 분리
- 유지 범위: ADR-0003의 React/FastAPI 선택과 same-origin 배포

## 맥락

ADR-0003은 stdlib 서버와 단일 JavaScript UI를 React/FastAPI로 전환하는 데
성공했다. 이후 `backend/`가 `sys.path`를 조작해 하이픈이 포함된
`fortune-engine/`의 파일을 import하고, requirements와 정적 자산 소유권이 두 곳에
나뉘었다. HTTP 경계와 도메인 경계는 필요하지만 서로 다른 최상위 소스 트리일
필요는 없다.

현재 서비스는 한 팀, 한 배포, 한 데이터 경계를 가지며 API와 SPA도 same-origin을
유지해야 한다. 지금 네트워크 서비스로 분리하면 독립 확장 이득보다 분산 트랜잭션,
관측, 배포, 인증 복잡도가 먼저 생긴다.

## 결정

1. Python 제품 코드를 설치 가능한 `src/shindang` 패키지로 통합한다.
2. 패키지 내부는 `domain → application ports ← adapters ← web` 의존성 방향을
   따른다. `bootstrap.py`만 구현을 연결한다.
3. FastAPI route는 기능별 `APIRouter`로 분리하되 배포 프로세스는 하나로 유지한다.
4. React 빌드와 API는 프로덕션에서 한 origin으로 제공한다.
5. 브라우저 자산의 원본은 `frontend/public/static` 하나만 둔다.
6. JSON Schema/샘플은 런타임 코드가 아닌 `contracts/fortune`에 둔다.
7. 실험·검증 CLI와 결과 문서는 각각 `tools/`, `docs/reports/`에 둔다.
8. domain은 clock, environment, filesystem, HTTP에 직접 접근하지 않는다.
9. 생년 기반 seed는 composition root가 주입하는 용도 분리 HMAC을 사용한다.
10. 아키텍처 의존성 방향은 자동 테스트로 고정한다.
11. Python 직접 의존성은 `pyproject.toml`만 정본으로 두고, 배포용
    `requirements.lock`은 그 정본에서 hash-pinned 형태로 생성한다.
12. `app-ci`와 `deploy-staging`은 disposable PostgreSQL 16에서
    `REQUIRE_PG16=1 bats --formatter tap tests/db-migrate.bats`를 실행한다.
    PostgreSQL 16 도구 부재·클러스터 기동 실패·서버 major version 불일치는
    skip이 아니라 실패이며, TAP 결과가 정확히 `1..70`, 70 `ok`, 0 skip이어야 한다.
    테스트 수를 의도적으로 바꿀 때는 이 계약과 workflow 단언을 함께 갱신한다.

이 구조는 Python Packaging User Guide가 설명하는 `src` layout의 import 격리
장점을 취하고, FastAPI 공식 문서의 `APIRouter` 기반 큰 애플리케이션 구성법을
따른다. 내부 포트와 어댑터는 Alistair Cockburn의 원래 Hexagonal Architecture가
강조한 “애플리케이션 내부와 외부 기술의 비대칭 경계”를 적용한다.

## 대안

### 기존 `backend/` + `fortune-engine/` 유지

물리적으로는 분리되어 보이지만 Python 패키지 경계가 아니어서 import 조작과 중복
설정이 계속된다. 기각한다.

### fortune engine을 별도 마이크로서비스로 분리

현재 독립 배포·확장·팀 소유권 요구가 없다. 인증, 캐시, 실패 처리와 버전 계약이
네트워크 경계를 넘어가 복잡도만 커진다. 기각한다. 추후 실제 조직/부하 증거가
생기면 application port를 프로세스 외 adapter로 교체할 수 있다.

### 모든 코드를 FastAPI route에 수직 슬라이스로 배치

초기 탐색은 쉽지만 순수 운세 규칙, CLI, 테스트가 FastAPI에 종속된다. 기각한다.

## 결과

- editable install과 production wheel이 같은 import 의미를 갖는다.
- 패키지 메타데이터와 배포 의존성 선언이 서로 다른 직접 버전으로 드리프트하지 않는다.
- 도메인 테스트는 웹 서버 없이 실행된다.
- TTS/OAuth/cache/session 구현을 유스케이스 변경 없이 교체할 수 있다.
- 빌드 정적 자산과 Python package의 소유권이 명확해진다.
- 현재 인메모리 adapter는 단일 프로세스 제약을 가진다. 수평 확장이 필요할 때
  PostgreSQL/Redis adapter로 교체해야 한다.
- 로컬에 PostgreSQL 서버가 없으면 migration suite는 계속 skip할 수 있지만,
  리팩터 및 staging 배포 게이트에서는 PostgreSQL 16 전체 70건이 반드시 실행된다.
- 내부 모듈 수는 늘지만 AST 경계 테스트와 문서가 탐색 비용을 제한한다.

## 근거

- Python Packaging User Guide, src layout vs flat layout:
  <https://packaging.python.org/en/latest/discussions/src-layout-vs-flat-layout/>
- FastAPI, Bigger Applications - Multiple Files:
  <https://fastapi.tiangolo.com/tutorial/bigger-applications/>
- Alistair Cockburn, Hexagonal Architecture:
  <https://alistair.cockburn.us/hexagonal-architecture/>
