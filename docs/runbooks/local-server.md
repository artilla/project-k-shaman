# 오늘신당 서버 실행 가이드

이 문서는 저장소 루트(`/Users/artilla/Dev/workspace/project/ProjectK-Shaman`)에서
오늘신당 앱 서버와 Ralph Mission Control을 로컬로 실행하는 방법을 설명한다.

## 1. 어떤 방식으로 실행할지 선택

| 목적 | 실행 방식 | 접속 주소 |
| --- | --- | --- |
| 일상적인 프런트엔드·백엔드 개발 | FastAPI와 Vite를 각각 실행 | `http://127.0.0.1:5173` |
| 빌드된 SPA를 FastAPI에서 확인 | 프런트엔드 빌드 후 Uvicorn 실행 | `http://127.0.0.1:8000` |
| 컨테이너·Caddy까지 포함한 로컬 확인 | Docker Compose | `http://127.0.0.1:8080` |
| 티켓·승인·Ralph Loop 운영 | Mission Control | `http://127.0.0.1:7474` |

일반 개발에는 첫 번째 방식을 권장한다. Mission Control은 제품 앱 서버와 별개다.

## 2. 최초 1회 준비

필요 도구:

- Python 3.13
- Node.js와 npm
- Docker 방식까지 사용할 경우 Docker Desktop과 Compose v2

Python과 프런트엔드 의존성을 설치한다.

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman

python3 -m venv .venv
source .venv/bin/activate
python -m pip install --upgrade pip
python -m pip install --require-hashes -r requirements-build.lock
python -m pip install --require-hashes -r requirements.lock
python -m pip install --no-deps --no-build-isolation -e .

npm --prefix frontend ci
```

새 터미널을 열 때마다 Python 명령 전에 다음을 다시 실행한다.

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman
source .venv/bin/activate
```

## 3. 개발 서버 실행 — 권장

Vite 설정은 `/api`, `/audio` 요청을 FastAPI의 고정 포트 `8788`로 프록시한다.
`/static`은 `frontend/public/static`에서 Vite가 직접 제공한다. 따라서 백엔드 포트를
임의로 바꾸면 프런트엔드 API 호출이 실패한다.

### 터미널 1: FastAPI

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman
source .venv/bin/activate

export SHINDANG_ENV=development
export SESSION_SECRET=local-development-only
export TTS_BACKEND=mock
export SHINDANG_DEV_LOGIN=1
export SHINDANG_PUBLIC_BASE_URL=http://127.0.0.1:5173
unset DATABASE_URL

python -m uvicorn shindang.web.app:app \
  --host 127.0.0.1 \
  --port 8788 \
  --reload
```

- `TTS_BACKEND=mock`은 실과금 없는 로컬 오디오를 사용한다.
- `SHINDANG_DEV_LOGIN=1`은 OAuth 키 없이 로그인 이후 흐름을 확인하기 위한 선택적
  개발 기능이다. staging·production에서는 기동 자체가 거부된다.
- 현재 DB 어댑터 작업 전에는 `DATABASE_URL`을 설정하지 않는다. 값이 있으면
  `/readyz`가 의도적으로 `503 adapter-unavailable`을 반환한다.
- 직접 실행할 때는 `TRUST_PROXY=1`을 설정하지 않는다. 이 값은 신뢰할 수 있는
  Caddy 프록시 뒤에서만 사용한다.

### 터미널 2: Vite

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman
npm --prefix frontend run dev
```

브라우저에서 `http://127.0.0.1:5173`을 연다. 종료할 때는 각 터미널에서
`Ctrl+C`를 누른다.

### 개발 서버 smoke 확인

```bash
curl --fail --silent --show-error http://127.0.0.1:8788/healthz
curl --fail --silent --show-error http://127.0.0.1:8788/readyz
curl --fail --silent --show-error http://127.0.0.1:8788/api/auth/providers
curl --fail --silent --show-error http://127.0.0.1:5173/ >/dev/null
```

정상적인 로컬 mock 구성에서는 `/healthz`가 `status: ok`, `/readyz`가
`database: not-configured`를 반환한다. OAuth 키가 없더라도 서버는 기동하며
`/api/auth/providers`에서 해당 공급자가 비활성으로 표시된다.

## 4. 빌드된 SPA를 FastAPI에서 실행

프로덕션 이미지처럼 FastAPI가 `frontend/dist`를 same-origin으로 직접 서빙하는지
확인할 때 사용한다.

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman
npm --prefix frontend run build

source .venv/bin/activate
export SHINDANG_ENV=development
export SESSION_SECRET=local-development-only
export TTS_BACKEND=mock
export SHINDANG_PUBLIC_BASE_URL=http://127.0.0.1:8000
unset DATABASE_URL

python -m uvicorn shindang.web.app:app \
  --host 127.0.0.1 \
  --port 8000
```

브라우저에서 `http://127.0.0.1:8000`을 열고 다음을 확인한다.

```bash
curl --fail --silent --show-error http://127.0.0.1:8000/healthz
curl --fail --silent --show-error http://127.0.0.1:8000/readyz
curl --fail --silent --show-error http://127.0.0.1:8000/ >/dev/null
```

`frontend/dist`가 없으면 FastAPI 개발 API는 동작하지만 `/` SPA는 제공되지 않는다.

## 5. Docker Compose로 실행

Dockerfile의 비루트 사용자, read-only root filesystem, healthcheck와 Caddy reverse
proxy까지 함께 확인하는 방법이다. 호스트의 80/443 충돌을 피하려고 로컬에서는
8080/8443을 사용한다.

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman

export HTTP_PORT=8080
export HTTPS_PORT=8443
export SITE_ADDRESS=http://127.0.0.1
export SHINDANG_ENV=development
export SESSION_SECRET=local-compose-only
export TTS_BACKEND=mock

docker compose config --quiet
docker compose up --detach --build
docker compose ps
```

브라우저에서 `http://127.0.0.1:8080`을 열고 smoke를 실행한다.

```bash
curl --fail --silent --show-error http://127.0.0.1:8080/healthz
curl --fail --silent --show-error http://127.0.0.1:8080/readyz
curl --fail --silent --show-error http://127.0.0.1:8080/api/auth/providers
docker compose logs --follow app caddy
```

로그 추적은 `Ctrl+C`로 빠져나와도 컨테이너를 중지하지 않는다. 중지는 다음과 같다.

```bash
docker compose down
```

`docker compose down --volumes`는 `app_state`, Caddy 데이터 등 로컬 볼륨까지
삭제하므로 초기화가 명확히 필요할 때만 사용한다.

## 6. Ralph Mission Control 실행

Mission Control은 제품 UI가 아니라 티켓·승인·세션·Ralph Loop를 관리하는 로컬
운영 화면이다. 기본 바인딩은 localhost뿐이다.

```bash
cd /Users/artilla/Dev/workspace/project/ProjectK-Shaman

./ralph/scripts/mission_control.sh start --port 7474
./ralph/scripts/mission_control.sh status
```

브라우저에서 `http://127.0.0.1:7474`을 연다. 종료는 다음과 같다.

```bash
./ralph/scripts/mission_control.sh stop
```

모바일 또는 private-path 페어링은 보안 경계와 TLS 설정이 추가되므로
`ralph/docs/runbook.md`의 페어링 절차를 따른다.

## 7. 주요 환경변수

| 변수 | 로컬 기본/권장값 | 주의사항 |
| --- | --- | --- |
| `SHINDANG_ENV` | `development` | `development`, `test`, `staging`, `production`만 허용 |
| `SESSION_SECRET` | 로컬 전용 임의 문자열 | staging·production에서는 필수이며 실제 값은 커밋 금지 |
| `SHINDANG_PUBLIC_BASE_URL` | 브라우저가 접속하는 origin | OAuth callback 생성 기준; staging·production은 HTTPS 필수 |
| `TTS_BACKEND` | `mock` | `openai`는 `OPENAI_API_KEY`가 필요하고 실제 과금 가능 |
| `SHINDANG_DEV_LOGIN` | 필요할 때만 `1` | staging·production에서는 금지 |
| `DATABASE_URL` | 현재 로컬 mock에서는 unset | 어댑터 연결 전 값이 있으면 `/readyz`는 의도적으로 503 |
| `GOOGLE_CLIENT_ID`, `GOOGLE_CLIENT_SECRET` | 선택 | Google OAuth를 실제 확인할 때만 설정 |
| `KAKAO_REST_API_KEY`, `KAKAO_CLIENT_SECRET` | 선택 | Kakao OAuth를 실제 확인할 때만 설정 |
| `TRUST_PROXY` | 직접 실행 시 unset | 신뢰된 reverse proxy 뒤에서만 `1` |

일반 UI QA에서 `TTS_BACKEND=openai`를 사용하지 않는다. 명시적으로 실 TTS를
검증할 때만 키와 비용 범위를 확인한 뒤 별도 터미널 세션에 주입한다.

## 8. 문제 해결

### 프런트엔드는 열리지만 API가 실패한다

FastAPI가 `8788`에서 실행 중인지 확인한다.

```bash
lsof -nP -iTCP:8788 -sTCP:LISTEN
curl --fail --silent --show-error http://127.0.0.1:8788/healthz
```

### `/readyz`가 503이다

응답이 `adapter-unavailable`이면 현재 셸에 `DATABASE_URL`이 들어온 상태다.

```bash
unset DATABASE_URL
```

그 다음 백엔드를 재시작한다. DB 어댑터가 구현된 이후에는 이 절차 대신 해당
DB runbook과 migration 상태를 확인한다.

### 백엔드 포트의 `/`가 404다

Vite 개발 모드에서는 정상일 수 있다. `http://127.0.0.1:5173`으로 접속한다.
FastAPI가 SPA까지 서빙해야 한다면 먼저 `npm --prefix frontend run build`를 실행하고
백엔드를 재시작한다.

### `TTS_BACKEND=openai requires OPENAI_API_KEY`로 기동이 거부된다

일반 로컬 실행은 다음처럼 mock으로 되돌린다.

```bash
export TTS_BACKEND=mock
unset OPENAI_API_KEY
```

### 포트가 이미 사용 중이다

```bash
lsof -nP -iTCP:5173 -sTCP:LISTEN
lsof -nP -iTCP:8788 -sTCP:LISTEN
lsof -nP -iTCP:7474 -sTCP:LISTEN
```

Vite·백엔드는 프록시 계약 때문에 각각 5173·8788을 유지하는 편이 안전하다.
Mission Control은 `--port`로 다른 포트를 지정할 수 있다.

## 9. staging·production과의 경계

이 문서의 명령은 로컬 실행 전용이다. 실제 staging·production은 로컬 Compose를
그대로 실행하는 방식이 아니라, 승인된 immutable image digest와 배포 bundle,
Secrets Manager, SSM 및 health-gated rollback 계약을 따른다.

- 배포 운영 절차: `docs/research/closed-beta-deployment-runbook.md`
- AWS staging 구성: `infra/README.md`
- 배포 아키텍처 결정: `docs/decisions/0005-closed-beta-deployment-and-staging-contract.md`
