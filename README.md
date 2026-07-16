# ProjectK-Shaman

오늘신당은 React PWA와 FastAPI API를 동일 origin으로 배포하는 모듈러 모놀리스입니다.
Python 제품 코드는 설치 가능한 `src/shindang` 패키지이며, 순수 domain → application
ports → adapters → web 경계를 자동 테스트로 고정합니다. 작업 운영에는 Ralph Loop
(명세 → 분할 → 헤드리스 실행 → 검증 → 복구 → 인간 승인)를 사용합니다.

## 빠른 시작

```bash
python3 -m venv .venv
source .venv/bin/activate
python -m pip install --require-hashes -r requirements-build.lock
python -m pip install --require-hashes -r requirements.lock
python -m pip install --no-deps --no-build-isolation -e .
python -m pip install pytest==9.0.2 ruff==0.15.0
npm --prefix frontend ci
./ralph/scripts/run_checks.sh --full
```

서버 실행은 [`docs/runbooks/local-server.md`](docs/runbooks/local-server.md)를 따른다.

## 구조

| 경로 | 역할 |
|---|---|
| `src/shindang/` | domain/application/adapters/web로 나눈 Python 제품 패키지 |
| `frontend/` | React + TypeScript UI와 정적 자산 단일 원본 |
| `contracts/fortune/` | 운세 JSON Schema와 버전 고정 샘플 |
| `tools/` | 배포 패키지와 분리된 오프라인 검증·분석 도구 |
| `docs/master-spec.md` | 제품 명세 (Step 1) |
| `docs/planning/` | 서비스 기획과 실행 계획 버전 |
| `docs/product/` | 캐릭터 시트 등 제품 정본 |
| `docs/prompts/` | 버전 관리되는 LLM 프롬프트 명세 |
| `docs/reports/` | 분석·측정·TTS·경쟁·임원 보고서 |
| `docs/runbooks/` | 로컬 서버 실행과 운영 절차 |
| `ralph/docs/runbook.md` | Ralph Loop 운영 규칙 |
| `docs/tickets/` | 작업 단위 (`TEMPLATE.md` 복사) |
| `docs/decisions/` | ADR (의사결정 기록) |
| `ralph/skills/` | AI 페르소나 4종 |
| `ralph/scripts/` | 루프 실행 도구 (`run_checks.local.sh`에 프로젝트 검증) |
| `ralph/mission-control/` | 이 프로젝트 전용 Mission Control 웹 (`./ralph/scripts/mission_control.sh start`) |
| `ralph/tests/` | Ralph Loop 및 Mission Control 회귀 테스트 |
| `state/`, `.ralph/` | 런타임 상태 (git 무시) |

운영 규칙 전체: [`ralph/docs/runbook.md`](ralph/docs/runbook.md)

디렉터리 구조: [`docs/project-structure.md`](docs/project-structure.md)

아키텍처 결정: [`docs/decisions/0006-modular-monolith-src-layout.md`](docs/decisions/0006-modular-monolith-src-layout.md)
