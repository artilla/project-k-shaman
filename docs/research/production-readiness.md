# 오늘신당 실운영 준비 조사

> 조사일: 2026-07-08 · 기준: 현재 코드베이스(v2 리디자인 반영) + Plan.md(v3 동기화) + master-spec
> 한 줄 진단: **프론트·재생 UX·이벤트 계측은 베타 수준에 도달했으나, 서버 런타임·데이터 영속화·실 LLM 생성·법무 문서가 없어 공개 운영은 불가한 상태.** 아래 P0를 끝내면 클로즈드 베타, P1까지 끝내면 공개 베타가 가능하다.

## 1. 현재 상태 요약

| 영역 | 상태 |
|---|---|
| 프론트 (S0~S6) | v2 디자인 구현 완료. PWA manifest 미구현 |
| 운세 생성 | **mock** — fortune-samples.v1.1 + seed 개인화. 실 LLM 생성·안전 필터 미구현 (§3 hold) |
| TTS | openai 백엔드 구현(옵트인) + presynth 캐시. 기본은 mock(무과금) |
| 서버 | Python stdlib `ThreadingHTTPServer`, 127.0.0.1, HTTP — **운영용 아님** |
| 세션/DB | 서버 메모리 세션 + 서명 쿠키. DB 없음. 프로필은 localStorage |
| 인증 | Google/카카오 OAuth 스캐폴드 완성, 실 키 미발급. 재생·부적 로그인 게이트(클라+서버 401) |
| 이벤트 | `/api/event` → `state/events` JSONL append. 분석 파이프라인 없음 |
| 공유/푸시 | 카카오·인스타·X 공유 목업(토스트), 웹푸시 목업. 시스템 공유(Web Share)만 실동작 |
| Live2D | Mao 샘플 모델(임시) — 홍연 전용 모델(L1) 발주 필요 |

## 2. 코드 갭 — mock을 실물로 (§3 hold 해제)

1. **실 LLM 운세 생성** — `fortune-prompt-hongyeon.v1.1.md` 프롬프트로 LLM API 호출 + `fortune-schema.v1.1.json` 검증 + 실패 시 samples 폴백. `fortune_fail` 이벤트는 이미 정의돼 있다.
2. **금지 표현 안전 필터** — 생성 후처리 검증(백로그 항목). 운세 도메인 특성상 의료·투자 단정 표현, 불안 조장 표현 차단이 필수.
3. **실 HMAC seed 키** — 현재 스텁. 키 발급·회전 정책과 함께 시크릿 매니저로.
4. **rate limit + 하루 1회 무료 제한** — 백로그에 있으나 미구현. LLM·TTS가 실과금이 되는 순간 어뷰징 방어가 P0가 된다.
5. **동의 기반 서버 저장(v3 §12)** — 로그인 사용자의 프로필·streak 서버 저장 단일화. DB 도입과 묶인다.
6. **웹푸시** — "내일 알림 받기"가 현재 토스트 목업. VAPID/FCM + 서비스워커 + 발송 스케줄러 필요 (P1로 미뤄도 됨).
7. **카카오 공유 실연동** — Kakao Developers 앱 등록 + JS SDK. 현재 목업.
8. **PWA manifest + 서비스워커** — Plan.md 백로그. 설치 유도·오프라인 셸.

## 3. 인프라

- **서버 런타임 교체**: stdlib http.server는 TLS·타임아웃·백프레셔·보안 헤더가 없다. 선택지: (a) 현 핸들러를 FastAPI/Starlette로 이식 + uvicorn/gunicorn, (b) 최소 변경으로 WSGI 래핑 + reverse proxy. 어느 쪽이든 **reverse proxy(nginx/Caddy) + HTTPS 종단**은 필수.
- **호스팅**: 초기 트래픽은 단일 VM(또는 Fly.io/Railway류 PaaS)으로 충분. 정적 자산(webp, Live2D 모델 ~수 MB)은 CDN/오브젝트 스토리지로 분리.
- **DB**: 세션·동의 기반 프로필·streak·구매(추후)용 Postgres 1개 + 캐시/rate limit용 Redis(또는 Postgres로 통합 시작).
- **오브젝트 스토리지**: TTS mp3 캐시(`state/tts_cache`)를 S3 호환 스토리지로 — 서버 재배포에도 캐시 유지(비용 직결). Plan.md 백로그의 "오브젝트 스토리지 업로드" 항목.
- **도메인 + TLS**: OAuth 리다이렉트 URI가 https 도메인을 요구한다. `_oauth_redirect_uri()`가 현재 `http://{host}` 하드코딩 — 프록시 뒤에서 `X-Forwarded-Proto` 반영 필요.
- **배포**: git 기반 CI/CD(테스트 78개 통과 게이트) + 롤백 수단. 현재 `nohup python3 server.py`는 개발용.

## 4. 보안

- 시크릿 관리: `.env.local`의 OPENAI_API_KEY·OAuth 시크릿·HMAC 키를 배포 환경 시크릿 매니저로. 키 노출 시 회전 절차 문서화.
- OAuth 프로덕션 심사: Google Cloud Console OAuth 동의 화면 검증(프로덕션 게시), Kakao Developers 앱 등록 + 비즈 앱 전환(프로필 스코프).
- 세션 영속화: 메모리 세션은 재시작 시 전원 로그아웃 + 다중 인스턴스 불가. Redis/DB 세션 스토어로 이전.
- 보안 헤더: CSP(Live2D CDN 없음 — self-host라 유리), HSTS, X-Content-Type-Options. Google Fonts는 self-host 전환 권장(CSP 단순화 + 국내 지연 감소 + 개인정보 관점).
- rate limit: IP·세션 기준. 특히 `/api/fortune/today`(LLM 비용), `/api/auth/login`(state 쿠키 남발 방지).
- 이벤트 endpoint 검증: `/api/event`는 현재 무인증 append — 크기 제한·스키마 검증·유량 제한 필요.

## 5. 외부 서비스 계약·키 발급 체크리스트

| 항목 | 용도 | 비고 |
|---|---|---|
| LLM API 키 | 운세 텍스트 생성 | 프롬프트 v1.1 기준 토큰 예산은 token-optimization-report.md 참조 |
| OpenAI TTS (또는 대체) | 본문 음성 | presynth 3종(greeting/blessing/ending) 캐시로 원가 절감 — unit-economics-simulator.xlsx로 CAC/원가 시뮬 |
| Google OAuth 클라이언트 | 로그인 | 동의 화면 심사 리드타임 감안 |
| Kakao Developers 앱 | 로그인 + 카카오톡 공유 | 공유는 도메인 등록 필수 |
| FCM/VAPID | 웹푸시 (P1) | |
| 도메인·인증서 | HTTPS | Let's Encrypt 자동 갱신 |

## 6. 법무·정책 (한국 기준)

- **개인정보처리방침 + 이용약관**: 생년월일·출생시간은 개인정보다. 현재 "로컬 우선 + HMAC 해시만 전송" 설계는 유리하지만, 동의 기반 서버 저장·소셜 로그인(이메일/닉네임 수집)을 켜는 순간 개인정보보호법상 수집·이용 동의, 보유 기간, 파기 절차 고지가 필요하다.
- **만 14세 미만 처리 방침**: 생년월일을 받으므로 14세 미만 식별이 가능 — 가입 차단 또는 법정대리인 동의 플로우 결정 필요.
- **운세 콘텐츠 고지**: "오락·참고 목적, 의료·법률·투자 조언 아님" 디스클레이머. 안전 필터와 세트.
- **라이선스 정리**:
  - Live2D Cubism SDK — 연매출 1천만엔 미만 소규모 사업자 출시 라이선스 면제(README 확인됨). 매출 성장 시 유료 계약 트리거 모니터링.
  - Mao 샘플 모델 — Free Material License로 소규모 상용 가능하나 **홍연 브랜드와 무관한 임시 모델**. L1 발주(Cubism 4 호환 명시)로 교체.
  - 폰트 — Song Myung·Noto Sans KR 모두 OFL(상용 가능). self-host 시에도 문제 없음.
  - 캐릭터 아트(hongyeon-*.webp) — 생성 경로·권리 관계 문서화(상표 출원 여부 포함).
- **통신판매업 신고**: 결제(캐릭터 패스/심화 운세) 도입 시점에 필요. 베타(무료)는 불요.

## 7. 운영 체계

- **모니터링**: 업타임 + 에러율 + v3 SLA("탭 후 첫 반응 3초") 대시보드. `first_text_visible`·`tts_generate_complete` 등 이벤트가 이미 계측되므로 수집기만 붙이면 된다 (JSONL → BigQuery/ClickHouse/PostHog 중 택1).
- **로그**: `state/*.log` 파일 산개 → 구조화 로깅 + 보존 정책. 키·생년월일 원문이 로그에 남지 않는 현 원칙 유지.
- **백업**: DB 일일 백업 + TTS 캐시는 재생성 가능하므로 제외 가능.
- **비용 가드**: TTS·LLM 일일 지출 상한 알림. `--presynth` 기동 워밍은 배포 파이프라인에 포함.
- **온콜/문의**: 베타는 단일 문의 채널(이메일/카카오채널)로 시작.

## 8. 출시 전 QA

- 실기기 매트릭스: iOS Safari(autoplay 정책·AudioContext), Android Chrome, 카카오 인앱 브라우저(공유 유입의 대부분 — OAuth 인앱 제약 확인 필수).
- 음성 QA: 45–60초 길이 준수(script compressor), 세그먼트 경계 자연스러움.
- 접근성: 현재 aria-live·라벨 기본은 있음 — 스크린리더 1회 점검.
- 부하: 동시 100세션 기준 smoke (ThreadingHTTPServer 한계 확인 → 런타임 교체 근거).

## 9. 우선순위 로드맵

**P0 — 클로즈드 베타 (공개 URL로 지인 테스트)**
서버 런타임 교체 + HTTPS/도메인, OAuth 실 키(리다이렉트 https), 시크릿 매니저, rate limit + 일 1회 제한, 실 LLM 생성 + 안전 필터 + 폴백, 개인정보처리방침·약관 초안, 이벤트 수집기 연결.

**P1 — 공개 베타**
DB(세션·동의 저장) + Redis, 오브젝트 스토리지 TTS 캐시, 카카오 공유 실연동, PWA manifest, 홍연 Live2D L1 교체, 모니터링·비용 가드, 실기기 QA 매트릭스.

**P2 — 수익화 준비**
결제(통신판매업 신고), 웹푸시, 다캐릭터(소월 A/B), 커스텀 보이스 계약 검토, Live2D 매출 트리거 모니터링.
