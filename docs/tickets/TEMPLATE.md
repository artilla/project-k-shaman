---
id: TXXX
title: (한 줄 제목)
status: open            # open | awaiting-approval | done | skipped | blocked
                        # ('reserved'/'in-progress'는 status가 아니라 state/reservations/<TXXX>.d
                        #  디렉터리 lock으로 표현됩니다 — git history에 남지 않음)
priority: P2            # P0 | P1 | P2 | P3
safe: true              # true면 Step 2/4 자동 루프 대상,
                        # false면 docs/approvals/<TXXX>.md 인간 승인 마커 필수
persona: implementer    # implementer | planner | reviewer
                        #   implementer → 코드 구현 (ralph/skills/implementer.md)
                        #   planner     → 명세/티켓/문서 (ralph/skills/planner.md, master-spec 수정 가능)
                        #   reviewer    → 교차 검증 (ralph/skills/reviewer.md, 코드 수정 금지)
estimate: S             # S | M | L (~1h / ~4h / ~1d)
depends_on: []          # ["TXXX", ...]
blocks: []
labels: []              # ["refactor", "docs", "test", "bug", "feature", ...]
created: YYYY-MM-DD
spec_ref: docs/master-spec.md#section-id
---

# TXXX — (한 줄 제목)

## 1. 목표 (한 줄)
> 이 티켓이 끝나면 무엇이 달라지는가?

## 2. 변경 범위 (Scope)

**포함**
- (구체적 파일/모듈/동작)

**제외**
- (이 티켓에서 의도적으로 다루지 않는 것)

## 3. 수용 기준 (Acceptance Criteria)

> Given/When/Then 또는 체크리스트.
> AI가 "끝났다"고 판단할 수 있는 객관적 조건이어야 함.

- [ ] ...
- [ ] ...

## 4. 테스트 계획

> 자동 검증 가능한 명령. `ralph/scripts/run_checks.sh`가 이 명령들을 호출 가능해야 함.

```bash
# 예시
npm test -- path/to/test
pytest tests/test_xxx.py
```

## 5. 롤백 방법 (Reversibility)

> 잘못 갔을 때 어떻게 원상복구하는가? 이 칸을 채울 수 없으면 `safe: false`로 둘 것.

```bash
# 예시
git revert <commit>
# DB 마이그레이션이 있는 경우 down 마이그레이션 명시
```

## 6. 위험 (Risk)

| 위험 | 가능성 | 영향 | 완화 |
|---|---|---|---|
| ... | L/M/H | L/M/H | ... |

## 7. 메모 / 결정 이력

- (티켓 작성 중 발견한 미결 질문 → 필요하면 `docs/decisions/`로 ADR 승격)
