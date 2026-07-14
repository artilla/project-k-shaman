# 오늘신당 실운영 준비 조사

> 현행화: 2026-07-15 · 기준: 현재 코드베이스 + ADR-0003~0005 + T027 read-only 조사
>
> 한 줄 진단: **FastAPI same-origin runtime, React build, 인메모리 rate limit, DB migration
> 계약과 실제 앱 gate는 갖췄지만, 영속 DB adapter·전용 DB role·컨테이너/CI/CD·HTTPS
> hosting·운영 secret/OAuth 설정은 아직 없다. 따라서 로컬 베타 기능은 검증 가능하나
> 클로즈드 베타 공개 URL을 운영할 단계는 아니다.**

## 1. 현재 구현 상태

| 영역 | 현재 상태 | 운영 판정 |
|---|---|---|
| 프론트 | Vite + React + TypeScript, S0~S6, production build 가능 | build gate 통과, PWA 미구현 |
| 서버 | FastAPI + Uvicorn, `frontend/dist` same-origin 정적 서빙 | runtime 교체 완료, reverse proxy/health/보안 설정 미구현 |
| 운세 | sample + deterministic seed 기반 mock | 실 LLM·안전 필터 미구현 |
| TTS | OpenAI backend opt-in + presynth/cache, 기본 mock | 실과금 기동 가드 있음, cache 영속 스토리지 미구현 |
| 인증 | Google/Kakao OAuth authorization-code 스캐폴드 | 실 key/domain/provider console 미설정, session은 메모리 |
| session/profile | 서명 cookie + 서버 메모리 session, profile은 localStorage | 재시작·다중 인스턴스에 취약, 서버 동의 저장 미구현 |
| rate limit | IP/session 고정 윈도우 + 운세/꿈 daily limit | 단일 process에서만 유효, 재시작 시 초기화 |
| 이벤트 | payload 크기 제한·timeline 검증 후 JSONL append | DB/분석 pipeline·보존 정책 미구현 |
| DB | Postgres migration 001~005와 owner/ACL/soft-delete contract | backend adapter/driver 없음; 관찰 대상 DB는 001~002 applied, 003~005 pending |
| 배포 | 전체 repo/app gate만 존재 | Dockerfile, Compose, CI/CD, IaC, hosting resource 없음 |

DB status는 2026-07-15 read-only 관찰값이며 배포 직전에 다시 확인해야 한다. 현재 target의
접속 role과 migration ledger owner가 `postgres` superuser이므로, 그대로 003~005를
적용하거나 runtime connection으로 사용하는 것은 금지한다.

## 2. 이미 닫힌 과거 gap

이 문서의 2026-07-08판에 있던 다음 항목은 현재 구현됐다.

- stdlib `ThreadingHTTPServer` → FastAPI/Uvicorn 이식
- Vite React TypeScript frontend와 production build
- proxy 뒤 `X-Forwarded-Proto` 기반 OAuth redirect URI 생성
- endpoint별 rate limit과 운세/꿈 daily limit
- `/api/event` body size 제한과 JSON 형식 거부
- migration 001~005, ledger, owner anchor, runtime role ACL, soft-delete 불변식
- frontend typecheck/build, Python dependency consistency, pytest, Node, Bats를 묶은 실제 앱 gate

구현됐다는 사실과 운영 준비가 끝났다는 뜻은 다르다. rate limit/session/event는 여전히
process-local이고, migration은 backend가 소비하지 않으며, 대상 DB에는 일부만 적용돼 있다.

## 3. 클로즈드 베타 P0 gap

### 3.1 배포 경로

- ADR-0005가 AWS EC2 `ap-northeast-2`, Docker Compose, Caddy, FastAPI same-origin을
  결정했다. 실제 EC2/VPC/ECR/IAM/DNS/TLS resource와 배포 workflow는 없다.
- multi-stage image, `/healthz`와 `/readyz`, immutable digest, 이전 digest rollback,
  GitHub Actions gate/image publish/deploy 단계가 필요하다.
- Caddy 한 홉만 trusted proxy로 인정하고 app port는 private network로 닫아야 한다.
- HTTPS에서 session/state cookie에 `Secure`를 강제하는 환경별 cookie policy가 필요하다.

### 3.2 DB와 영속화

- Python DB driver와 repository/transaction 계층이 없다.
- OAuth callback이 사용자·session을 DB에 upsert하지 않으며 재시작하면 전원 로그아웃된다.
- 동의한 profile과 streak의 server persistence/API가 없다. 비동의 guest profile은 계속
  local-first여야 한다.
- `shindang_deploy` migration owner와 `shindang_app` runtime role을 staging에서 먼저
  생성하고, fresh 001~005 및 001~002→003~005 upgrade를 모두 리허설해야 한다.
- production의 기존 `postgres` owner를 별도 deploy owner로 옮기는 bootstrap 변경은
  독립 승인·backup·복구 계획 없이는 실행하지 않는다.

### 3.3 인증·secret·개인정보

- production domain의 Google/Kakao callback URI와 provider console 설정이 없다.
- session signing secret, OAuth secret, API key, DB credential을 AWS Secrets Manager로
  옮기고 EC2 instance role에 resource-scoped read만 부여해야 한다.
- `.env.local`은 운영 secret source가 아니다. static AWS access key를 VM에 배치하지 않는다.
- 개인정보처리방침·이용약관·만 14세 미만 정책·운세 면책 고지가 필요하다.
- OAuth subject/profile persistence와 soft-delete/rejoin이 ADR-0004 계약을 지키는지
  integration test와 staging browser smoke가 필요하다.

### 3.4 비용·안전·관찰성

- 실 LLM 운세 생성, schema 검증, 금지 표현/의료·투자 단정 안전 필터, sample fallback이 없다.
- 현재 TTS cache는 local filesystem이라 instance 교체 시 사라진다. closed beta에서
  재생성 허용 여부를 정하고, 필요하면 S3 호환 object storage로 옮긴다.
- process-local rate limiter는 단일 EC2에서는 기능하지만 재시작 내구성이 없다.
  DB-backed counter 또는 Redis 전환 전까지 이 한계와 비용 상한을 운영 지표로 감시한다.
- 구조화 log, secret/PII redaction, uptime/error/latency/429/OAuth failure/DB connection
  dashboard와 비용 alarm이 없다.

## 4. 출시 전 운영 계약

정본은 ADR-0005와 `closed-beta-deployment-runbook.md`다. 순서는 다음과 같다.

```text
read-only preflight
  -> staging apply
  -> staging app smoke
  -> production approval
  -> production apply
  -> runtime/browser verification
```

- app image 배포와 DB migration은 같은 startup command로 묶지 않는다.
- staging과 production은 같은 image digest와 migration runner를 사용하되 서로 다른
  DB/credential을 사용한다.
- T027 승인은 문서 결정을 승인한 것이며 cloud/DNS/OAuth/DB write를 승인하지 않는다.
- production apply는 staging evidence, backup/restore, 이전 image digest, rollback owner가
  채워진 별도 safe:false 티켓에서만 수행한다.

## 5. 외부 서비스·법무 체크리스트

| 항목 | 현재 | 클로즈드 베타 전에 필요한 것 |
|---|---|---|
| AWS compute/registry/secrets | 결정만 완료 | resource 생성, least-privilege IAM, budget/alert |
| domain/TLS | 없음 | DNS, Caddy HTTPS, 자동 갱신 smoke |
| Google OAuth | code scaffold | client/consent screen/callback 등록과 staging/prod 분리 |
| Kakao OAuth | code scaffold | app/callback/profile scope와 staging/prod 분리 |
| OpenAI | TTS opt-in | secret manager, 비용 상한, 실패 fallback |
| 개인정보/약관 | 없음 | 수집 항목·목적·보유/파기·14세 정책·면책 고지 |
| Live2D | Mao sample | 홍연 전용 모델 권리·배포 라이선스 확인 |

결제, 웹푸시, 카카오 공유 실연동, PWA, 다중 캐릭터는 closed beta 이후 별도 범위로 둔다.

## 6. QA와 기계 검증

repo gate:

```bash
./scripts/run_checks.sh --full
```

DB read-only preflight:

```bash
ENV_FILE="$TARGET_ENV_FILE" ./scripts/db_migrate.sh --status
```

staging 이후에는 iOS Safari, Android Chrome, 카카오 인앱 브라우저에서 guest→login→profile→
fortune→audio/share, app 재시작 후 session 유지, soft-delete/rejoin을 확인한다. screenshot만
보지 않고 API status, cookie 속성, DB row/ACL, runtime log를 함께 증거로 남긴다.

## 7. 후속 작업 단위

1. **T028** — container/CI-CD와 AWS EC2 hosting, DNS/TLS/OAuth wiring
2. **T029** — backend DB adapter, session/profile/streak persistence
3. **T030** — staging role/DB 생성과 migration fresh/upgrade rehearsal
4. **T031** — production owner/role 전환, 003~005 apply, app/runtime/browser verification

네 티켓은 모두 safe:false다. 특히 T031은 T028~T030의 증거가 없으면 승인하지 않는다.

## 8. 이후 로드맵

**P1 — 공개 베타**

- durable/distributed rate limit, object storage TTS cache, structured analytics pipeline
- 카카오 공유, PWA/service worker, 홍연 Live2D L1, 실기기 접근성/부하 QA
- managed DB/backup 정책과 단일 EC2 장애 복구 목표 확정

**P2 — 수익화**

- 결제·통신판매업 신고, 웹푸시, 다캐릭터, custom voice 계약
- Live2D 매출 trigger와 API/provider 원가의 정기 검토
